#Requires AutoHotkey v2.0
#Include GameMaintenancePolicy.ahk

GMU_NormalizeOcr(text) {
    if IsObject(text) || StrLen(text) > 2048
        return ""
    text := StrLower(text)
    for pair in [["伺服器","服务器"],["維護","维护"],["暫時","暂时"],["無法","无法"],["遊戲","游戏"],["下載","下载"],["安裝","安装"],["驗證","验证"],["開始","开始"],["繼續","继续"]]
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

GMU_ClassifyLauncher(blocks,identity) {
    result := {kind:"unknown",button:0,percent:"",evidence:"",identityKey:GM_Value(identity,"key","")}
    layout := GM_Value(identity,"layout",0)
    if (!(blocks is Array) || !GM_Value(identity,"verified",false) || GM_Value(identity,"provider","") != "kuro"
        || !GM_Value(layout,"verified",false) || GM_Value(layout,"launcherVersion","") = ""
        || GM_Value(layout,"launcherVersion","") != GM_Value(identity,"launcherVersion",""))
        return result
    buttons := [], stages := []
    for block in blocks {
        text := GMU_NormalizeOcr(GM_Value(block,"text",""))
        if GMU_BlockInRoi(block,identity,GM_Value(layout,"status",0)) {
            kind := RegExMatch(text,"^(下载中|正在下载|downloading)") ? "downloading"
                : RegExMatch(text,"^(安装中|正在安装|installing)") ? "installing"
                : RegExMatch(text,"^(验证中|正在验证|verifying|validating)") ? "verifying" : ""
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
        kind := RegExMatch(text,"^(更新|更新游戏|游戏更新|update)$") ? "update"
            : RegExMatch(text,"^(下载|下载游戏|download)$") ? "download"
            : RegExMatch(text,"^(开始游戏|启动游戏|startgame|play)$") ? "play"
            : RegExMatch(text,"^(继续|继续下载|resume)$") ? "resume" : ""
        if kind != ""
            buttons.Push({kind:kind,button:{x:(block.left+block.right)/2,y:(block.top+block.bottom)/2},evidence:text})
    }
    if stages.Length = 1 {
        result.kind := stages[1].kind, result.percent := stages[1].percent, result.evidence := stages[1].evidence
        return result
    }
    if buttons.Length = 1 && stages.Length = 0 {
        result.kind := buttons[1].kind, result.button := buttons[1].button, result.evidence := buttons[1].evidence
    }
    return result
}
