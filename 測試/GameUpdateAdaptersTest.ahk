#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameUpdateAdapters.ahk
GMTest_Run(TestUpdateAdapters)
TestUpdateAdapters() {
    calls := [], allowed := false, persisted := false, observation := {phase:"unknown"}
    install := {provider:"steam",appId:3513350,updateAdapterReady:true,identityVerified:true,
        launcherPath:TestRuntime_NewCaseDir("gm-adapter") "\Steam 遊戲庫\steam.exe",fingerprint:"i1"}
    action := {type:"start_update",actionId:"fixture-start",expectedRevision:"r1",expectedRemoteGeneration:1,expectedFingerprint:"i1"}
    hooks := {CanAct:(*) => allowed,ValidateInstall:(*) => true,PersistIntent:(*) => persisted,
        LaunchSteam:(args*) => calls.Push(args),LaunchKuro:(args*) => calls.Push(args),
        ClickVerified:(*) => false,ReadObservation:(*) => observation}
    result := GMU_Start(install,action,hooks)
    GMTest_Assert(!result.ok && calls.Length = 0,"guard prevents launch")
    allowed := true
    result := GMU_Start(install,action,hooks)
    GMTest_Assert(!result.ok && calls.Length = 0,"journal must persist first")
    persisted := true, install.appId := 999
    GMTest_Assert(!GMU_Start(install,action,hooks).ok && calls.Length = 0,"wrong Steam App rejected")
    install.appId := 3513350, install.identityVerified := false
    GMTest_Assert(!GMU_Start(install,action,hooks).ok,"launcher identity required")
    install.identityVerified := true, action.expectedFingerprint := "old"
    GMTest_Assert(!GMU_Start(install,action,hooks).ok,"stale install fingerprint rejected")
    action.expectedFingerprint := "i1", hooks.ValidateInstall := (*) => false
    GMTest_Assert(!GMU_Start(install,action,hooks).ok,"current install identity revalidated")
    hooks.ValidateInstall := (*) => true, observation := {phase:"game_running",identityVerified:true}
    result := GMU_Start(install,action,hooks)
    GMTest_Assert(result.ok && !result.attempted && calls.Length = 0,"existing correct game adopted without launch")
    observation := {phase:"downloading"}
    result := GMU_Start(install,action,hooks)
    GMTest_Assert(result.ok && !result.attempted && calls.Length = 0,"Steam autonomous download only observed")
    observation := {phase:"unknown"}, action.recoveredIntent := true
    GMTest_Assert(!GMU_Start(install,action,hooks).attempted && calls.Length = 0,"persisted intent not blindly replayed")
    action.recoveredIntent := false
    result := GMU_Start(install,action,hooks)
    GMTest_Assert(result.ok && result.attempted && calls.Length = 1,"single guarded launch")
    GMTest_Assert(calls[1][1] = install.launcherPath && calls[1][2] = 3513350,"fixed Steam App argument")
    GMTest_Assert(calls[1][3] = '"' install.launcherPath '" -applaunch 3513350',"quoted path with spaces")
    GMTest_Assert(!GMU_Start(install,action,hooks).attempted && calls.Length = 1,"same attempt object cannot launch twice")
    for provider in ["unknown","ambiguous","epic"] {
        install.provider := provider
        GMTest_Assert(!GMU_Start(install,action,hooks).ok,"unsupported provider " provider)
    }
    install.provider := "steam", action.actionId := "second", action.attempted := false
    hooks.PersistIntent := (*) => FlipAdapterGuard(&allowed)
    GMTest_Assert(!GMU_Start(install,action,hooks).ok && calls.Length = 1,"STOP during intent persistence blocks launch")
    install.launcherPath .= '`" & extra'
    failed := false
    try GMU_BuildLaunchCommand(install)
    catch
        failed := true
    GMTest_Assert(failed,"launcher command injection rejected")
    install.launcherPath := TestRuntime_RepoRoot() "\fixture\steam.exe"
    for phase in ["queued","downloading","installing","verifying","update_ready","paused_download","login_required","offline","error","unknown"] {
        worker := {phase:phase,progressPercent:23,bytesDone:23,bytesTotal:100,observedAt:10000,detail:"fixture",errorCode:""}
        got := GMU_Observe(install,worker,0)
        GMTest_Assert(got.phase = phase && got.phase != "game_ready","preserve distinct update evidence " phase)
        if phase = "update_ready"
            GMTest_Assert(got.progressPercent = "","ready has no invented stage percentage")
    }
    GMTest_Assert(GMU_Observe(install,{phase:"game_ready"},0).phase = "unknown","worker cannot certify main screen")
    target := {pid:123,hwnd:456,path:"fixture",identityVerified:true,foregroundVerified:true,desktopAvailable:true}
    action := {type:"click_update",actionId:"button-1",expectedRemoteGeneration:1}
    allowed := true, persisted := true, calls := []
    hooks.PersistIntent := (*) => true, hooks.ClickVerified := (args*) => RecordAdapterClick(calls,args)
    hooks.ReadObservation := (*) => {phase:"unknown"}
    result := GMU_ApplyAction(target,action,hooks)
    GMTest_Assert(!result.ok && result.errorCode = "UPDATE_ACTION_UNCONFIRMED" && calls.Length = 1,"click not mislabeled as update success")
    GMTest_Assert(!GMU_ApplyAction(target,action,hooks).ok && calls.Length = 1,"unconfirmed button not clicked repeatedly")
    target.foregroundVerified := false, action := {type:"click_update",actionId:"button-2"}
    GMTest_Assert(!GMU_ApplyAction(target,action,hooks).ok && calls.Length = 1,"wrong foreground cannot receive click")
    target.foregroundVerified := true, action := {type:"click_update",actionId:"button-3"}
    hooks.ClickVerified := (*) => false, hooks.ReadObservation := (*) => {phase:"downloading"}
    GMTest_Assert(!GMU_ApplyAction(target,action,hooks).ok,"rejected click cannot be called an applied action")
}
FlipAdapterGuard(&allowed) {
    allowed := false
    return true
}
RecordAdapterClick(calls,args) {
    calls.Push(args)
    return true
}
