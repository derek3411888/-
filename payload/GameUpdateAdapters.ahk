#Requires AutoHotkey v2.0
#Include GameMaintenancePolicy.ahk
#Include GameUpdateOcrPolicy.ahk

; Side effects are provided by the controller. These adapters never run a shell
; or touch a window on their own; the same guards are exercised by action spies.
GMU_Result(ok,code := "",detail := "",attempted := false,id := "") {
    return {ok:ok,errorCode:code,detail:detail,attempted:attempted,attemptId:id}
}

GMU_BuildLaunchCommand(install) {
    launcher := GM_Value(install,"launcherPath","")
    if (launcher = "" || RegExMatch(launcher,'["\x00-\x1F]'))
        throw Error("Unsafe launcher path")
    SplitPath(launcher,&name)
    if (install.provider = "steam" && install.appId = 3513350 && StrLower(name) = "steam.exe")
        return '"' launcher '" -applaunch 3513350'
    if (install.provider = "kuro" && StrLower(name) = "launcher.exe")
        return '"' launcher '"'
    throw Error("Unsupported launcher identity")
}

GMU_Start(install,action,hooks) {
    if (GM_Value(action,"type","") != "start_update" || GM_Value(action,"actionId","") = "")
        return GMU_Result(false,"INVALID_UPDATE_ACTION")
    if (!GM_Value(install,"identityVerified",false) || !GM_Value(install,"updateAdapterReady",false)
        || (install.provider != "steam" && install.provider != "kuro"))
        return GMU_Result(false,"UPDATE_ADAPTER_UNVERIFIED")
    if (GM_Value(action,"expectedFingerprint",install.fingerprint) != install.fingerprint)
        return GMU_Result(false,"INSTALL_FINGERPRINT_CHANGED")
    try command := GMU_BuildLaunchCommand(install)
    catch
        return GMU_Result(false,"INVALID_LAUNCHER_IDENTITY")
    if (!hooks.CanAct.Call(action) || !hooks.ValidateInstall.Call(install))
        return GMU_Result(false,"ACTION_GUARD_BLOCKED")
    observation := hooks.ReadObservation.Call(install)
    phase := GM_Value(observation,"phase","unknown")
    if ((phase = "game_running" && GM_Value(observation,"identityVerified",false))
        || InStr(",downloading,installing,verifying,queued,","," phase ",",true))
        return GMU_Result(true,"","已觀察到目標更新器／遊戲；不重複啟動")
    if (GM_Value(action,"recoveredIntent",false) || GM_Value(action,"attempted",false))
        return GMU_Result(true,"","動作已保存或嘗試，等待現況確認",false,action.actionId)
    if (phase = "login_required" || phase = "offline" || phase = "paused_download" || phase = "error")
        return GMU_Result(false,"UPDATER_" StrUpper(phase),"更新器需要人工處理；不重啟 Steam")
    if !hooks.PersistIntent.Call(action)
        return GMU_Result(false,"JOURNAL_WRITE_FAILED")
    if (!hooks.CanAct.Call(action) || !hooks.ValidateInstall.Call(install))
        return GMU_Result(false,"ACTION_GUARD_CHANGED")
    action.attempted := true
    try {
        if install.provider = "steam"
            hooks.LaunchSteam.Call(install.launcherPath,3513350,command)
        else
            hooks.LaunchKuro.Call(install.launcherPath,command)
    } catch as err
        return GMU_Result(false,"LAUNCH_ATTEMPT_FAILED",err.Message,true,action.actionId)
    return GMU_Result(true,"","已嘗試開啟更新入口；仍需更新／登入後置驗證",true,action.actionId)
}

GMU_Observe(install,workerObservation,ocr) {
    result := {phase:"unknown",progressPercent:"",bytesDone:"",bytesTotal:"",observedAt:0,lastProgressAt:0,detail:"",errorCode:"",identityVerified:false}
    allowed := ",unknown,not_started,queued,downloading,installing,verifying,update_ready,game_running,paused_download,login_required,offline,error,"
    for source in [workerObservation,ocr] {
        if !IsObject(source)
            continue
        if (source = ocr && !GM_Value(source,"identityVerified",false))
            continue
        phase := GM_Value(source,"phase","unknown")
        if !InStr(allowed,"," phase ",",true)
            continue
        for key in ["phase","observedAt","lastProgressAt","detail","errorCode","identityVerified"]
            result.%key% := GM_Value(source,key,result.%key%)
        if InStr(",downloading,installing,verifying,","," phase ",",true) {
            value := GM_Value(source,"progressPercent","")
            if (value != "" && IsNumber(value) && value >= 0 && value <= 100)
                result.progressPercent := value
            result.bytesDone := GM_Value(source,"bytesDone",""), result.bytesTotal := GM_Value(source,"bytesTotal","")
        } else
            result.progressPercent := "", result.bytesDone := "", result.bytesTotal := ""
    }
    return result
}

GMU_ApplyAction(target,action,hooks) {
    if (!GM_Value(target,"identityVerified",false) || !GM_Value(target,"foregroundVerified",false)
        || !GM_Value(target,"desktopAvailable",false) || GM_Value(target,"pid",0) <= 0 || GM_Value(target,"hwnd",0) <= 0)
        return GMU_Result(false,"UPDATE_WINDOW_UNVERIFIED")
    if (GM_Value(action,"attempted",false) || !hooks.CanAct.Call(action))
        return GMU_Result(false,"UPDATE_ACTION_ALREADY_ATTEMPTED_OR_BLOCKED")
    if !hooks.PersistIntent.Call(action)
        return GMU_Result(false,"JOURNAL_WRITE_FAILED")
    if !hooks.CanAct.Call(action)
        return GMU_Result(false,"ACTION_GUARD_CHANGED")
    action.attempted := true
    try {
        if !hooks.ClickVerified.Call(target,action)
            return GMU_Result(false,"UPDATE_ACTION_BLOCKED","目標輸入驗證未通過",false,GM_Value(action,"actionId",""))
        observation := hooks.ReadObservation.Call(target)
    } catch as err
        return GMU_Result(false,"UPDATE_ACTION_FAILED",err.Message,true,GM_Value(action,"actionId",""))
    if !InStr(",downloading,installing,verifying,game_running,","," GM_Value(observation,"phase","unknown") ",",true)
        return GMU_Result(false,"UPDATE_ACTION_UNCONFIRMED","輸入已嘗試，尚未確認更新狀態轉變",true,GM_Value(action,"actionId",""))
    return GMU_Result(true,"","已驗證更新狀態轉變",true,GM_Value(action,"actionId",""))
}

GMU_TargetMatchesLauncher(install,expected,current) {
    return IsObject(current) && GM_Value(current,"identityVerified",false)
        && GM_Value(current,"pid",0) = GM_Value(expected,"pid",-1)
        && GM_Value(current,"hwnd",0) = GM_Value(expected,"hwnd",-1)
        && StrLower(GM_Value(current,"path","")) = StrLower(GM_Value(install,"launcherPath","not-verified"))
        && GM_Value(current,"desktopAvailable",false)
}

GMU_ClickLauncherVerified(install,target,action,hooks) {
    if !GM_Value(install,"identityVerified",false) || !IsObject(GM_Value(action,"button",0)) || !hooks.CanAct.Call(action)
        return false
    before := hooks.InspectWindow.Call(target.hwnd)
    if !GMU_TargetMatchesLauncher(install,target,before)
        return false
    if !hooks.PrepareWindow.Call(target.hwnd,target.pid)
        return false
    current := hooks.InspectWindow.Call(target.hwnd)
    if (!hooks.CanAct.Call(action) || !GMU_TargetMatchesLauncher(install,target,current) || !GM_Value(current,"foregroundVerified",false))
        return false
    return hooks.ClickPoint.Call(target.hwnd,action.button.x,action.button.y,target.pid)
}
