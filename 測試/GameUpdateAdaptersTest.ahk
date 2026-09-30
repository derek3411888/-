#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameUpdateAdapters.ahk
GMTest_Run(TestUpdateAdapters)
TestUpdateAdapters() {
    TestLauncherModalSelection()
    calls := [], allowed := false, persisted := false, observation := {phase:"unknown"}
    install := {provider:"steam",appId:3513350,launchAdapterReady:true,updateAdapterReady:true,identityVerified:true,
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
    install.provider := "steam", install.appId := 3513350, install.updateAdapterReady := true
    action.actionId := "second", action.attempted := false
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
    install.provider := "kuro", install.appId := 0, install.updateAdapterReady := false
    install.launcherPath := TestRuntime_NewCaseDir("gm-kuro-adapter") "\launcher.exe"
    install.fingerprint := "kuro-i1", action := {type:"start_update",actionId:"kuro-start",expectedRevision:"r1",
        expectedRemoteGeneration:1,expectedFingerprint:"kuro-i1"}, observation := {phase:"unknown"}
    allowed := true, hooks.PersistIntent := (*) => true
    result := GMU_Start(install,action,hooks)
    GMTest_Assert(result.ok && result.attempted && calls.Length = 2,
        "verified official launcher must open even before UI layout acceptance exists")
    GMTest_Assert(calls[2][1] = install.launcherPath && calls[2][2] = '"' install.launcherPath '"',
        "official launcher uses its exact verified path without extra arguments")
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
    launcher := {pid:80,hwnd:81,started:100,path:install.launcherPath,identityVerified:true,foregroundVerified:true,desktopAvailable:true}
    live := launcher.Clone(), taps := [], guard := {CanAct:(*) => true,InspectWindow:(*) => live,
        PrepareWindow:(*) => true,ClickPoint:(args*) => RecordAdapterClick(taps,args)}
    button := {x:100,y:200}, action := {type:"click_update",button:button}
    GMTest_Assert(GMU_ClickLauncherVerified(install,launcher,action,guard) && taps.Length = 1,"launcher-specific wrapper permits exact identity")
    live.path := TestRuntime_RepoRoot() "\fixture\pythonw.exe"
    GMTest_Assert(!GMU_ClickLauncherVerified(install,launcher,action,guard) && taps.Length = 1,"OKWW never masquerades as launcher")
    live := launcher.Clone(), live.pid := 82
    GMTest_Assert(!GMU_ClickLauncherVerified(install,launcher,action,guard) && taps.Length = 1,"HWND with replaced PID rejected")
    live := launcher.Clone(), live.started := 101
    GMTest_Assert(!GMU_ClickLauncherVerified(install,launcher,action,guard) && taps.Length = 1,"launcher PID reuse must reject the click")
    SplitPath(install.launcherPath,,&officialRoot)
    launcher.path := officialRoot "\2.6.5.0\launcher_main.exe", live := launcher.Clone()
    GMTest_Assert(GMU_ClickLauncherVerified(install,launcher,action,guard) && taps.Length = 2,
        "official versioned launcher_main window receives verified physical click")
    launcher.path := officialRoot "-other\2.6.5.0\launcher_main.exe", live := launcher.Clone()
    GMTest_Assert(!GMU_ClickLauncherVerified(install,launcher,action,guard) && taps.Length = 2,"sibling install is not the selected official launcher")
    launcher.path := officialRoot "\untrusted\launcher_main.exe", live := launcher.Clone()
    GMTest_Assert(!GMU_ClickLauncherVerified(install,launcher,action,guard),"unrecognized helper subfolder cannot receive updater input")
}

TestLauncherModalSelection() {
    parent := {hwnd:10,pid:20,started:100,identityVerified:true,visible:true,enabled:false,owner:0}
    dialog := {hwnd:11,pid:20,started:100,identityVerified:true,visible:true,enabled:true,owner:10}
    selected := GMU_SelectLauncherWindow([parent,dialog])
    GMTest_Assert(IsObject(selected) && selected.hwnd = 11,"launcher-owned update dialog overrides disabled main window")
    unrelated := dialog.Clone(), unrelated.hwnd := 12, unrelated.owner := 0
    GMTest_Assert(!IsObject(GMU_SelectLauncherWindow([parent,dialog,unrelated])),"two independent launcher windows must not be guessed")
    dialog.identityVerified := false
    GMTest_Assert(!IsObject(GMU_SelectLauncherWindow([parent,dialog])),"foreign updater dialog cannot be adopted")
}
FlipAdapterGuard(&allowed) {
    allowed := false
    return true
}
RecordAdapterClick(calls,args) {
    calls.Push(args)
    return true
}
