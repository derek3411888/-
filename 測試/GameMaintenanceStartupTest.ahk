#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameMaintenance.ahk
GMTest_Run(TestMaintenanceStartup)
TestMaintenanceStartup() {
    dir := TestRuntime_NewCaseDir("gm-startup"), calls := [], input := GMTest_Input(9999), alive := true, starts := 0
    input.runCycle := "fixture"
    hooks := {ReadInput:(*) => input,WorkerStart:(*) => CountMaintenanceWorker(&starts),WorkerAlive:(*) => alive,
        WorkerStop:(*) => calls.Push("stop_worker"),ApplyEffect:(effect) => calls.Push(effect.type),
        Publish:(*) => 0,StopRecording:(*) => calls.Push("stop_recording"),
        ReconcileSchedule:(*) => {runCycle:input.runCycle,targetServer:"Asia",allCompleted:false}}
    c := GM_CreateController(dir "\state.ini",{runCycle:"fixture",targetServer:"HMT",newTask:true},hooks)
    c.state := GM_CopyState(GMTest_State())
    loop 5 {
        decision := GM_ControllerTick(c)
        GMTest_Assert(decision.phase = "WAIT_OPEN","startup waits")
    }
    GMTest_Assert(starts = 1,"single worker across wait ticks")
    for action in calls
        GMTest_Assert(!InStr("cleanup,start_recording,start_game,start_okww,send_f11,start_update",action),"no early UI/recording action")
    GMTest_Assert(c.readCount = 5,"remote intent and heartbeat input continue while waiting")
    GMTest_Assert(GM_ControllerRemoteIntent(c,"PAUSE",{remoteNonce:2}).handled,"wait handles pause without hook")
    input.desiredState := "PAUSE", input.remoteGeneration := 2, input.nowUtcMs := 10000
    GMTest_Assert(GM_ControllerTick(c).overlay = "PAUSE","deadline does not clear pause")
    resumed := GM_CreateController(dir "\state.ini",{runCycle:"fixture",targetServer:"HMT",newTask:false},hooks)
    GMTest_Assert(resumed.state.desiredState = "PAUSE","ordinary process restart preserves wait pause")
    input.desiredState := "RUN", input.remoteGeneration := 3
    GM_ControllerRemoteIntent(c,"RUN",{remoteNonce:3})
    decision := GM_ControllerTick(c)
    GMTest_Assert(decision.effect.type = "start_update" && calls.Length = 1,"startup gate releases but does not launch before managed stage")
    decision := GM_ControllerTick(c,true)
    GMTest_Assert(calls[calls.Length] = "start_update","managed stage commits update once")
    GM_ControllerTick(c,true)
    count := 0
    for action in calls {
        if action = "start_update"
            count++
    }
    GMTest_Assert(count = 1,"next tick observes rather than relaunches")
    alive := false
    GM_ControllerTick(c,true)
    GMTest_Assert(starts = 2,"worker crash rebuilt once")
    GMTest_Assert(GM_ControllerTick(c,true).errorCode = "MAINTENANCE_WORKER_FAILED","second crash requires attention not game restart")
    GMTest_Assert(starts = 2,"no helper restart loop")
    input := GMTest_Input(10000), input.runCycle := "next-cycle", alive := true
    c := GM_CreateController(dir "\next.ini",{runCycle:"fixture",targetServer:"HMT",newTask:true},hooks), c.state := GM_CopyState(GMTest_State())
    GM_ControllerTick(c,true)
    GMTest_Assert(c.state.runCycle = "next-cycle" && c.state.targetServer = "Asia","04:00 schedule reconciled before effects")
    GM_ControllerRemoteIntent(c,"SWITCH_SERVER",{remoteNonce:4,serverName:"Asia",validated:true})
    GMTest_Assert(c.state.targetServer = "Asia" && GM_LoadJournal(dir "\next.ini").targetServer = "Asia","wait target durable, no restart")
    hooks.ReconcileSchedule := (*) => {runCycle:"next-cycle",targetServer:"",allCompleted:true}
    GM_ControllerScheduleChanged(c)
    GMTest_Assert(c.state.cancelled && c.state.phase = "STOPPED","all complete prevents default-server execution")
    c.loadError := "disk unavailable"
    GMTest_Assert(GM_ControllerTick(c).phase = "STOPPED","STOP still wins when journal is unavailable")
    normal := GM_DefaultState(), normal.phase := "NORMAL", normal.f11InputAttempted := true
    GM_SaveJournal(dir "\normal.ini",normal)
    normalRestart := GM_CreateController(dir "\normal.ini",{runCycle:"fixture",newTask:false},hooks)
    GMTest_Assert(!normalRestart.state.f11InputAttempted,"ordinary non-maintenance crash restart keeps existing login behavior")
    urlPath := dir "\game.url"
    FileAppend("[InternetShortcut]`nURL=steam://rungameid/3513350`n",urlPath,"UTF-8")
    GMTest_Assert(GM_IsValidGameLaunchEntry(urlPath),"Steam URL shortcut accepted")
    FileDelete(urlPath), FileAppend("[InternetShortcut]`nURL=https://example.test/`n",urlPath,"UTF-8")
    GMTest_Assert(!GM_IsValidGameLaunchEntry(urlPath),"arbitrary URL never becomes game launch entry")
    ; Actual call sites also preserve the required startup order, not just the harness.
    source := FileRead(TestRuntime_RepoRoot() "\payload\全自動.ahk","UTF-8")
    gateAt := InStr(source,"gate := GM_WaitForStartupGate()")
    startupAt := InStr(source,'WriteLog("全自動腳本啟動:')
    cleanupAt := InStr(source,"CheckAndCloseExistingProcesses()",false,startupAt)
    GMTest_Assert(gateAt > startupAt && gateAt < cleanupAt,"production gate before cleanup")
    GMTest_Assert(InStr(source,"maintenanceContinuation := GM_HasActiveContinuation(CFG_FILE)"),"continuation checked before fresh-cycle pause reset")
}
CountMaintenanceWorker(&starts) {
    starts++
    return {pid:1000+starts}
}
