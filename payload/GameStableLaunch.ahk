#Requires AutoHotkey v2.0
; Calls the publisher's original signed wrapper in the verified installation.
; No replacement loader, shipping-binary launch, Steam/auth or anti-cheat bypass.
GM_StableLaunch(install,hooks,timeoutMs := 30000) {
    if !GM_Value(install,"identityVerified",false) || GM_Value(install,"gameRoot","") = ""
        return {ok:false,errorCode:"INSTALL_IDENTITY_UNVERIFIED",detail:"無法確認原設定對應的安裝目錄；不猜測遊戲入口"}
    path := RTrim(install.gameRoot,"\") "\Wuthering Waves.exe"
    if !hooks.Exists.Call(path)
        return {ok:false,errorCode:"GAME_ENTRY_MISSING",detail:"原廠遊戲入口不存在；請先完成遊戲安裝／更新"}
    launched := false, deadline := hooks.Now.Call()+timeoutMs
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
            return {ok:true,errorCode:"",detail:"同一安裝遊戲視窗已存在；登入與主畫面另行驗證"}
        if !launched {
            try {
                if !hooks.Launch.Call(path) {
                    if GM_StableIntent(hooks) != "RUN"
                        continue
                    return {ok:false,errorCode:"GAME_ENTRY_REJECTED",detail:"原廠入口啟動未被接受；不重複啟動"}
                }
            } catch as err
                return {ok:false,errorCode:"GAME_ENTRY_FAILED",detail:"原廠入口啟動失敗：" err.Message}
            launched := true, deadline := hooks.Now.Call()+timeoutMs
        }
        if hooks.Now.Call() >= deadline
            return {ok:false,errorCode:"GAME_ENTRY_NO_WINDOW",detail:"原廠入口尚未產生可驗證視窗；請確認登入／遊戲更新，不重複啟動更新器"}
        hooks.Wait.Call(250)
    }
}

GM_StableIntent(hooks) {
    return hooks.HasOwnProp("Intent") ? hooks.Intent.Call() : (hooks.CanAct.Call() ? "RUN" : "STOP")
}
