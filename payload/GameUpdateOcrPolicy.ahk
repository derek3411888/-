#Requires AutoHotkey v2.0
#Include GameMaintenancePolicy.ahk

GMU_NormalizeOcr(text) {
    if IsObject(text) || StrLen(text) > 2048
        return ""
    text := StrLower(text)
    for pair in [["伺服器","服务器"],["維護","维护"],["暫時","暂时"],["暫停","暂停"],["無法","无法"],["遊戲","游戏"],["下載","下载"],["安裝","安装"],["驗證","验证"],["開始","开始"],["繼續","继续"],["啟動","启动"],["確認","确认"],["確定","确定"],["發現","发现"],["重啟","重启"],["請","请"]]
        text := StrReplace(text,pair[1],pair[2])
    return RegExReplace(text,"\s+","")
}

GMU_BlockInRoi(block,identity,roi) {
    if !IsObject(block) || !IsObject(roi)
        return false
    width := GM_Value(identity,"clientWidth",0), height := GM_Value(identity,"clientHeight",0)
    if !IsNumber(width) || !IsNumber(height) || width < 100 || height < 100
        return false
    for key in ["left","top","right","bottom"] {
        if !IsNumber(GM_Value(block,key,"")) || !IsNumber(GM_Value(roi,key,""))
            return false
    }
    if (block.left < 0 || block.top < 0 || block.right > width || block.bottom > height || block.right <= block.left || block.bottom <= block.top)
        return false
    x := (block.left + block.right) / (2 * width), y := (block.top + block.bottom) / (2 * height)
    return x >= roi.left && x <= roi.right && y >= roi.top && y <= roi.bottom
}

GMU_ClassifyMaintenance(blocks,identity) {
    result := {confirmed:false,evidence:"",identityKey:GM_Value(identity,"key","")}
    if !(blocks is Array) || !GM_Value(identity,"verified",false) || result.identityKey = ""
        return result
    roi := {left:0.15,top:0.15,right:0.9,bottom:0.85}
    for block in blocks {
        if !GMU_BlockInRoi(block,identity,roi)
            continue
        text := GMU_NormalizeOcr(GM_Value(block,"text",""))
        if RegExMatch(text,"^(?:当前)?服务器(?:正在|处于|停机)?维护中|^服务器正在维护|^(?:the)?servers?(?:is|are)?(?:currently)?undermaintenance|^servermaintenanceisinprogress") {
            result.confirmed := true, result.evidence := SubStr(text,1,300)
            return result
        }
    }
    return result
}

GMU_ConfirmMaintenance(previous,candidate,nowMs,captureId) {
    result := {confirmed:false,count:0,identityKey:GM_Value(candidate,"identityKey",""),evidence:GM_Value(candidate,"evidence",""),lastSeen:nowMs,captureId:captureId}
    if !GM_Value(candidate,"confirmed",false) || result.identityKey = "" || captureId = ""
        return result
    result.count := 1
    age := nowMs - GM_Value(previous,"lastSeen",0)
    if (IsObject(previous) && previous.identityKey = result.identityKey && previous.evidence = result.evidence
        && previous.captureId != captureId && age >= 250 && age <= 10000) {
        result.count := Min(2,previous.count + 1), result.confirmed := result.count >= 2
    }
    return result
}

GMU_DefaultKuroLayout(launcherVersion) {
    ; 官方啟動器的可操作文字僅接受右下角單一、完整命中的動作按鈕。
    ; 座標仍會由 OCR 文字方塊本身決定；這裡只限制可接受的區域，
    ; 並不依螢幕解析度硬編碼點擊位置。
    if IsObject(launcherVersion) || Trim(String(launcherVersion)) = ""
        return 0
    return {verified:true,launcherVersion:String(launcherVersion),source:"built-in-safe-roi",
        button:{left:0.68,top:0.72,right:0.99,bottom:0.99},
        status:{left:0.48,top:0.50,right:0.99,bottom:0.94}}
}

GMU_ClassifyLauncher(blocks,identity) {
    result := {kind:"unknown",button:0,percent:"",evidence:"",identityKey:GM_Value(identity,"key","")}
    layout := GM_Value(identity,"layout",0)
    if (!(blocks is Array) || !GM_Value(identity,"verified",false) || GM_Value(identity,"provider","") != "kuro"
        || !GM_Value(layout,"verified",false) || GM_Value(layout,"launcherVersion","") = ""
        || GM_Value(layout,"launcherVersion","") != GM_Value(identity,"launcherVersion",""))
        return result
    selfUpdate := GMU_ClassifyLauncherSelfUpdate(blocks,identity)
    if selfUpdate.kind != "unknown"
        return selfUpdate
    buttons := [], stages := [], statusPercent := ""
    for block in blocks {
        text := GMU_NormalizeOcr(GM_Value(block,"text",""))
        if GMU_BlockInRoi(block,identity,GM_Value(layout,"status",0)) {
            kind := RegExMatch(text,"^(下载中|正在下载|downloading)") ? "downloading"
                : RegExMatch(text,"^(安装中|正在安装|installing)") ? "installing"
                : RegExMatch(text,"^(验证中|正在验证|verifying|validating)") ? "verifying" : ""
            if kind = "" && InStr(text,"暂停下载")
                kind := "downloading"
            if statusPercent = "" && RegExMatch(text,"(\d{1,3}(?:\.\d{1,2})?)%",&statusMatch)
                && Number(statusMatch[1]) <= 100
                statusPercent := Number(statusMatch[1])
            if kind != "" {
                percent := ""
                if RegExMatch(text,"(\d{1,3}(?:\.\d{1,2})?)%",&match) && Number(match[1]) <= 100
                    percent := Number(match[1])
                stages.Push({kind:kind,percent:percent,evidence:text})
            }
            if RegExMatch(text,"^(磁[碟盘]空间不足|磁[碟盘]空間不足|insufficientdiskspace|notenoughdiskspace|下载失败|更新失败)")
                return {kind:"error",button:0,percent:"",evidence:text,identityKey:result.identityKey}
            if RegExMatch(text,"^(请登录|請登入|loginrequired|signintocontinue)")
                return {kind:"login_required",button:0,percent:"",evidence:text,identityKey:result.identityKey}
        }
        if !GMU_BlockInRoi(block,identity,GM_Value(layout,"button",0))
            continue
        actionText := RegExReplace(text,"^[^0-9a-z\x{3400}-\x{9fff}]+|[^0-9a-z\x{3400}-\x{9fff}]+$","")
        kind := RegExMatch(actionText,"^(更新|更新游戏|游戏更新|update)$") ? "update"
            : RegExMatch(actionText,"^(下载|下载游戏|download)$") ? "download"
            : RegExMatch(actionText,"^(开始游戏|启动游戏|[進进]入游戏|startgame|play)$") ? "play"
            : RegExMatch(actionText,"^(继续|继续下载|resume)$") ? "resume"
            : RegExMatch(actionText,"^(确认|确定|confirm|ok)$") ? "confirm" : ""
        ; MYTUF 實際 2.6.5.0 官方按鈕「進入遊戲」固定被讀成「進入游」。
        ; 僅此完整誤讀、版本及已驗證按鈕 ROI；不接受前綴或模糊比對。
        if kind = "" && identity.launcherVersion = "2.6.5.0" && RegExMatch(actionText,"^[進进]入游$")
            kind := "play"
        if kind != ""
            buttons.Push({kind:kind,button:{x:(block.left+block.right)/2,y:(block.top+block.bottom)/2},evidence:text})
    }
    if stages.Length = 1 {
        result.kind := stages[1].kind
        result.percent := stages[1].percent != "" ? stages[1].percent : statusPercent
        result.evidence := stages[1].evidence
        return result
    }
    if buttons.Length = 1 && stages.Length = 0 {
        result.kind := buttons[1].kind, result.button := buttons[1].button, result.evidence := buttons[1].evidence
    }
    return result
}

GMU_ClassifyLauncherSelfUpdate(blocks,identity) {
    result := {kind:"unknown",button:0,percent:"",evidence:"",identityKey:GM_Value(identity,"key","")}
    ; Explicit launcher-update text in a bounded prompt region is mandatory.
    ; Generic OK/Exit buttons and news mentioning a game version are never enough.
    promptRoi := {left:0.15,top:0.08,right:0.9,bottom:0.7}
    actionRoi := {left:0.2,top:0.5,right:0.9,bottom:0.95}
    hasContext := false, completed := false, buttons := [], restartButtons := []
    for block in blocks {
        text := GMU_NormalizeOcr(GM_Value(block,"text",""))
        if GMU_BlockInRoi(block,identity,promptRoi) {
            if RegExMatch(text,"^启动器更新(?:已)?完成|^launcherupdate(?:is)?complete(?:d)?")
                completed := true, result.evidence := text
            if RegExMatch(text,"^(?:发现|检测到|檢測到|有可用的|新版本)?启动器(?:有)?(?:新版本|更新)|^(?:发现|检测到|檢測到)启动器新版本|^launcher(?:update|newversion)")
                hasContext := true, result.evidence := text
            if RegExMatch(text,"^(?:正在)?(?:更新启动器|启动器(?:正在)?(?:更新中|下载中|安装中))|^updatinglauncher") {
                result.kind := "installing", result.evidence := text
                if RegExMatch(text,"(\d{1,3}(?:\.\d{1,2})?)%",&match) && Number(match[1]) <= 100
                    result.percent := Number(match[1])
                return result
            }
        }
        if GMU_BlockInRoi(block,identity,actionRoi) && RegExMatch(text,"^(立即更新|更新启动器|更新|确认|确定|update(?:now)?|confirm|ok)$")
            buttons.Push({x:(block.left+block.right)/2,y:(block.top+block.bottom)/2})
        if GMU_BlockInRoi(block,identity,actionRoi) && RegExMatch(text,"^(立即重启|重启启动器|重启|重新启动|重新启动启动器|restart(?:now|launcher)?)$")
            restartButtons.Push({x:(block.left+block.right)/2,y:(block.top+block.bottom)/2})
    }
    if completed && restartButtons.Length = 1
        result.kind := "launcher_restart", result.button := restartButtons[1]
    else if hasContext && !completed && buttons.Length = 1
        result.kind := "launcher_update", result.button := buttons[1]
    return result
}
