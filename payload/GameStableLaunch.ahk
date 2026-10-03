#Requires AutoHotkey v2.0
; Calls the publisher's original signed wrapper in the verified installation.
; No replacement loader, shipping-binary launch, Steam/auth or anti-cheat bypass.
GM_StableLaunch(install,hooks,timeoutMs := 30000) {
    if !GM_Value(install,"identityVerified",false) || GM_Value(install,"gameRoot","") = ""
        return {ok:false,errorCode:"INSTALL_IDENTITY_UNVERIFIED",detail:"無法確認原設定對應的安裝目錄；不猜測遊戲入口"}
    path := RTrim(install.gameRoot,"\") "\Wuthering Waves.exe"
    if !hooks.Exists.Call(path)
        return {ok:false,errorCode:"GAME_ENTRY_MISSING",detail:"原廠遊戲入口不存在；請先完成遊戲安裝／更新"}
    launched := false, selectedPackage := "", deadline := hooks.Now.Call()+timeoutMs, graceUsed := false
    loop {
        intent := GM_StableIntent(hooks)
        if intent = "STOP"
            return {ok:false,errorCode:"STOPPED",detail:"收到停止；不再次啟動"}
        if intent = "PAUSE" {
            pausedAt := hooks.Now.Call()
            hooks.Wait.Call(250)
            deadline += Max(0,hooks.Now.Call()-pausedAt)
            continue
        }
        if !launched && hooks.HasOwnProp("BeforeLaunch") {
            gate := hooks.BeforeLaunch.Call()
            if !gate.ok
                return gate
            if GM_StableIntent(hooks) != "RUN"
                continue
        }
        ready := hooks.Ready.Call()
        if GM_StableIntent(hooks) != "RUN"
            continue
        if ready
            return {ok:true,errorCode:"",package:selectedPackage,detail:"同一安裝遊戲視窗已存在；登入與主畫面另行驗證"}
        if !launched {
            try {
                choice := GM_StablePackageChoice(install,hooks)
                if GM_StableIntent(hooks) != "RUN"
                    continue
                if choice.ok && hooks.HasOwnProp("ReportPackage")
                    hooks.ReportPackage.Call(choice.detail)
                if GM_StableIntent(hooks) != "RUN"
                    continue
                if hooks.HasOwnProp("BeforeLaunch") {
                    gate := hooks.BeforeLaunch.Call()
                    if !gate.ok
                        return gate
                }
                if GM_StableIntent(hooks) != "RUN"
                    continue
                ; Inventory can take time. Reuse a window that appeared while
                ; reading disk rather than launching an additional instance.
                ready := hooks.Ready.Call()
                if GM_StableIntent(hooks) != "RUN"
                    continue
                if ready
                    return {ok:true,errorCode:"",package:"",detail:"資源檢查期間已出現同一安裝遊戲視窗；沿用既有視窗，登入與主畫面另行驗證"}
                if !choice.ok
                    return choice
                selectedPackage := choice.package
                if !hooks.Launch.Call(path,"-krqlv=" selectedPackage) {
                    if GM_StableIntent(hooks) != "RUN"
                        continue
                    return {ok:false,errorCode:"GAME_ENTRY_REJECTED",detail:"原廠入口啟動未被接受；不重複啟動"}
                }
            } catch as err
                return {ok:false,errorCode:"GAME_ENTRY_FAILED",detail:"原廠入口啟動失敗：" err.Message}
            launched := true, deadline := hooks.Now.Call()+timeoutMs
        }
        if hooks.Now.Call() >= deadline {
            if !graceUsed && hooks.HasOwnProp("StartupAlive") && hooks.StartupAlive.Call() {
                graceUsed := true, deadline := hooks.Now.Call()+120000
                if hooks.HasOwnProp("ReportWaiting")
                    hooks.ReportWaiting.Call()
            } else
                return {ok:false,errorCode:"GAME_ENTRY_NO_WINDOW",detail:"原廠入口尚未產生可驗證視窗；啟動等待逾時，不重複啟動更新器"}
        }
        hooks.Wait.Call(250)
    }
}

; The fallback is a preflight choice, not repeated game launches. A crash,
; missing window or access-denied result is never evidence of a missing bundle.
GM_StablePackageChoice(install,hooks) {
    state := GM_StableProbePackage(hooks,"hd")
    if state != "missing"
        return {ok:true,package:"hd",detail:"資源包 HD | -krqlv=hd | " (state = "present" ? "已找到 HD 資源" : "資源狀態未確認；維持預設，不猜測缺包")}
    ; Steam 3.7 is officially HD-only. Enable future graded Steam support only
    ; after its new official-launcher installation contract has been verified.
    if GM_Value(install,"provider","") = "kuro" {
        for tier in ["sd","uhd"] {
            if GM_StableIntent(hooks) != "RUN"
                break
            if GM_StableProbePackage(hooks,tier) = "present"
                return {ok:true,package:tier,detail:"HD 資源目錄未安裝；改用已找到的 " StrUpper(tier) " | -krqlv=" tier}
        }
    }
    return {ok:false,errorCode:"GAME_PACKAGE_MISSING",detail:"確認 HD 資源目錄未安裝，且沒有可確認支援且已安裝的替代包；請由啟動器修復／安裝遊戲資源，不盲試其他參數"}
}

GM_StableProbePackage(hooks,tier) {
    try {
        if hooks.HasOwnProp("PackageState") {
            state := hooks.PackageState.Call(tier)
            return state = "present" || state = "missing" ? state : "unknown"
        }
    }
    return "unknown"
}

; Read only known package directories. Shared Content\Paks is NOT an SD pack.
; Only ERROR_FILE/PATH_NOT_FOUND proves absence; inaccessible, reparse, empty,
; incomplete and future layouts stay unknown. No launcher config is rewritten.
GM_StablePackageState(install,tier) {
    if !GM_Value(install,"identityVerified",false) || !RegExMatch(tier,"^(hd|sd|uhd)$")
        return "unknown"
    root := GM_Value(install,"gameRoot","")
    if root = ""
        return "unknown"
    content := RTrim(root,"\") "\Client\Content"
    for directory in [root,root "\Client",content,content "\Paks"] {
        attributes := DllCall("GetFileAttributesW","Str",directory,"UInt")
        if attributes = 0xFFFFFFFF || !(attributes & 0x10) || (attributes & 0x400)
            return "unknown"
    }
    directory := content "\" StrUpper(tier)
    attributes := DllCall("GetFileAttributesW","Str",directory,"UInt")
    errorCode := A_LastError
    if attributes = 0xFFFFFFFF
        return errorCode = 2 || errorCode = 3 ? "missing" : "unknown"
    if !(attributes & 0x10) || (attributes & 0x400)
        return "unknown"
    try {
        Loop Files directory "\pakchunk*-" StrUpper(tier) "-WindowsNoEditor.pak", "F" {
            if InStr(A_LoopFileAttrib,"L") || A_LoopFileSize <= 0
                continue
            signature := RegExReplace(A_LoopFileFullPath,"i)\.pak$",".sig",&replacements)
            if replacements != 1
                continue
            if FileExist(signature) && !RegExMatch(FileGetAttrib(signature),"[DL]") && FileGetSize(signature) > 0
                return "present"
        }
    }
    return "unknown"
}

GM_StableIntent(hooks) {
    return hooks.HasOwnProp("Intent") ? hooks.Intent.Call() : (hooks.CanAct.Call() ? "RUN" : "STOP")
}
