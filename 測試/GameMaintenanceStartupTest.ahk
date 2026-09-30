#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameMaintenance.ahk
GMTest_Run(TestMaintenanceStartup)
TestMaintenanceStartup() {
    TestOrdinaryLauncherContinuation()
    TestCleanLauncherRestart()
    TestUpdateExitVerification()
    TestMaintenanceCallbackPublication()
    TestManagedLoginSafety()
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
    input.notice.checkedAt := input.nowUtcMs
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
    GMTest_Assert(InStr(source,"maintenanceContinuation := GM_HasActiveContinuation(CFG_FILE,RC_UnixMs())"),"continuation checked with current UTC before fresh-cycle pause reset")
    GMTest_Assert(!InStr(source,'gate.mode = "normal" || !IsWutheringProcessRunning()'),"managed update never enters global cleanup")
    GMTest_Assert(InStr(source,"return GMHost_GetManagedGameHwnd()"),"managed window selection is bound to selected install")
}

TestCleanLauncherRestart() {
    dir := TestRuntime_NewCaseDir("gm-clean-launcher-restart")
    input := GMTest_Input(10000), input.runCycle := "fixture", input.notice := 0, input.requireLauncher := true
    effects := [], hooks := {ReadInput:(*) => input,WorkerStart:(*) => {pid:1},WorkerAlive:(*) => true,
        WorkerStop:(*) => 0,ApplyEffect:(effect) => effects.Push(effect.type),Publish:(*) => 0,StopRecording:(*) => 0}
    c := GM_CreateController(dir "\state.ini",{runCycle:"fixture",targetServer:"Asia",newTask:true},hooks)
    GM_ControllerTick(c,true)
    input.observation := {phase:"game_running",observedAt:10000,identityVerified:true}
    GM_ControllerTick(c,true)
    c.state.updaterUiActionId := "old:kuro:play", c.state.f11InputAttempted := true
    GMTest_Assert(!GM_ReleaseLaunchAttemptForRestart(c,false),"unconfirmed game exit cannot release launcher intent")
    GMTest_Assert(c.state.actionId != "","unconfirmed exit retains action")
    GMTest_Assert(GM_ReleaseLaunchAttemptForRestart(c,true),"explicit clean restart with verified exit releases old attempt")
    reloaded := GM_LoadJournal(c.journalPath)
    GMTest_Assert(reloaded.actionId = "" && reloaded.updaterUiActionId = "" && !reloaded.f11InputAttempted,
        "released launch and UI intents are durable before handoff")
    GMTest_Assert(reloaded.targetServer = "Asia" && reloaded.remoteGeneration = 1,"restart retains schedule and command progress")
    input.observation := {phase:"update_ready",observedAt:10000}
    resumed := GM_CreateController(c.journalPath,{runCycle:"fixture",newTask:false},hooks)
    GM_ControllerTick(resumed,true), GM_ControllerTick(resumed,true)
    count := 0
    for effect in effects {
        if effect = "start_update"
            count++
    }
    GMTest_Assert(count = 2,"clean restart allows exactly one new launcher request")
    resumed.state.phase := "READY", resumed.state.eventId := "fixture-maintenance", resumed.state.targetServer := "HMT"
    GMTest_Assert(GM_ReleaseLaunchAttemptForRestart(resumed,true),"ready maintenance can hand off a server switch")
    switched := GM_CreateController(c.journalPath,{runCycle:"fixture",newTask:false,targetServer:"Asia"},hooks)
    GMTest_Assert(switched.state.targetServer = "Asia" && !GM_HasActiveContinuation(switched.state),
        "completed maintenance must not restore old HMT over a new remote Asia target")
    resumed.state.cancelled := true, resumed.state.desiredState := "STOP"
    GMTest_Assert(!GM_ReleaseLaunchAttemptForRestart(resumed,true),"manual STOP is never cleared by restart preparation")
}

TestOrdinaryLauncherContinuation() {
    state := GM_DefaultState(), state.phase := "UPDATING", state.provider := "kuro"
    state.actionId := ":fixture:update", state.actionStage := "observed"
    GMTest_Assert(GM_HasActiveContinuation(state,10000),"ordinary launcher update survives script restart without maintenance event")
    state.phase := "READY"
    GMTest_Assert(!GM_HasActiveContinuation(state,10000),"completed ordinary launch does not pin a future run")
    state.phase := "STOPPED", state.cancelled := true
    GMTest_Assert(!GM_HasActiveContinuation(state,10000),"manual STOP cancels ordinary launcher continuation")
}

TestUpdateExitVerification() {
    now := 0
    hooks := {Now:(*) => now,Wait:(ms) => now += ms,Alive:(*) => true}
    GMTest_Assert(GM_WaitForUpdateExit(hooks,1000) = "timeout","click without exit must time out")
    GMTest_Assert(now = 1000,"exit verification is bounded")
    now := 0
    hooks.Alive := (*) => now < 500
    GMTest_Assert(GM_WaitForUpdateExit(hooks,1000) = "exited","only observed process exit confirms update exit")
    hooks.Alive := (*) => "unknown"
    GMTest_Assert(GM_WaitForUpdateExit(hooks,1000) = "unverified","unreadable process state is not successful exit")
}

TestManagedLoginSafety() {
    updateDecision := {phase:"CHECKING_UPDATE",overlay:"",effect:{type:"observe"}}
    GMTest_Assert(GM_LoginActionAllowed(updateDecision,true),"update OCR must run while waiting for in-game update completion")
    GMTest_Assert(!GM_LoginActionAllowed(updateDecision),"update OCR permission must not authorize login or F11")
    for blockedPhase in ["WAIT_OPEN","WAIT_NOTICE","WAIT_SERVER","NEEDS_ATTENTION","STOPPED"] {
        updateDecision.phase := blockedPhase
        GMTest_Assert(!GM_LoginActionAllowed(updateDecision,true),"update UI cannot bypass " blockedPhase)
    }
    updateDecision.phase := "CHECKING_UPDATE", updateDecision.overlay := "PAUSE"
    GMTest_Assert(!GM_LoginActionAllowed(updateDecision,true),"paused update UI never sends input")
    expected := "D:\fixture\Client-Win64-Shipping.exe"
    good := {hwnd:12,pid:20,started:100,path:expected,valid:true}
    other := {hwnd:11,pid:21,started:100,path:"D:\other\Client-Win64-Shipping.exe",valid:true}
    identity := GM_SelectGameIdentity([other,good],expected)
    GMTest_Assert(IsObject(identity) && identity.hwnd = 12,"other foreground installation cannot be adopted")
    duplicate := {hwnd:13,pid:22,started:101,path:expected,valid:true}
    GMTest_Assert(!IsObject(GM_SelectGameIdentity([good,duplicate],expected)),"two matching installations/windows remain ambiguous")
    recycled := {hwnd:12,pid:20,started:102,path:expected,valid:true}
    GMTest_Assert(!IsObject(GM_SelectGameIdentity([recycled],expected,good)),"PID and HWND reuse cannot replace pinned creation identity")
    GMTest_Assert(!IsObject(GM_SelectGameIdentity([good],"")),"unknown canonical path never adopts a game")
    state := GM_CopyState(GMTest_State()), input := GMTest_Input(10000)
    input.runCycle := "fixture", input.observation := {phase:"game_running",identityVerified:true,observedAt:10000}
    GMTest_Assert(GM_LoginActionAllowed(GM_Evaluate(state,input)),"verified handoff may enter login")
    input.notice.expectedOpenAt := 20000, input.notice.revision := "r2"
    GMTest_Assert(!GM_LoginActionAllowed(GM_Evaluate(state,input)),"new extension after handoff blocks login/F11")
    input := GMTest_Input(10000), input.runCycle := "fixture", input.clockStable := false
    GMTest_Assert(!GM_LoginActionAllowed(GM_Evaluate(state,input)),"clock jump after handoff blocks F11")
    input.clockStable := true, input.runCycle := "tomorrow"
    GMTest_Assert(!GM_LoginActionAllowed(GM_Evaluate(state,input)),"04:00 reconciliation is not a login permit")
    state.f11InputAttempted := true, state.f11OkwwIdentity := "20|100|12|fixture"
    ready := {phase:"game_ready",stable:true,identityVerified:true,observedAt:10000}
    GMTest_Assert(GM_CanResumeF11(state,ready,"20|100|12|fixture",10000),"stable selected game plus same original OKWW can resume without F11")
    GMTest_Assert(!GM_CanResumeF11(state,ready,"20|102|12|fixture",10000),"replacement OKWW cannot inherit attempted F11")
    ready.identityVerified := false
    GMTest_Assert(!GM_CanResumeF11(state,ready,"20|100|12|fixture",10000),"wrong-install ready screen cannot authorize resume")
}

TestMaintenanceCallbackPublication() {
    for boundary in ["StopRecording","ApplyEffect"] {
        for command in ["switch","complete"] {
            root := TestRuntime_NewCaseDir("gm-callback-" boundary "-" command)
            input := GMTest_Input(boundary = "StopRecording" ? 9999 : 10000), input.runCycle := "fixture"
            box := {controller:0,input:input,command:command}
            callback := ChangeMaintenanceDuringHook.Bind(box)
            hooks := {ReadInput:(*) => input,WorkerStart:(*) => {pid:1},WorkerAlive:(*) => true,WorkerStop:(*) => 0,
                ApplyEffect:boundary = "ApplyEffect" ? callback : (*) => 0,
                StopRecording:boundary = "StopRecording" ? callback : (*) => 0,Publish:(*) => 0,
                ReconcileSchedule:(*) => {runCycle:"fixture",targetServer:"",allCompleted:true}}
            c := GM_CreateController(root "\state.ini",{runCycle:"fixture",targetServer:"HMT",newTask:true},hooks)
            box.controller := c
            c.state := GM_CopyState(GMTest_State()), c.state.targetServer := "HMT"
            GM_ControllerTick(c,true)
            saved := GM_LoadJournal(c.journalPath)
            if command = "switch"
                GMTest_Assert(c.state.targetServer = "Asia" && saved.targetServer = "Asia", boundary " must not overwrite ACKed switch")
            else
                GMTest_Assert(c.state.cancelled && saved.cancelled, boundary " must not revive completed schedule")
        }
    }
}
ChangeMaintenanceDuringHook(box,args*) {
    c := box.controller, input := box.input, command := box.command
    if command = "switch" {
        input.remoteGeneration += 1
        GM_ControllerRemoteIntent(c,"SWITCH_SERVER",{validated:true,serverName:"Asia",remoteNonce:input.remoteGeneration})
    } else
        GM_ControllerScheduleChanged(c)
    return {ok:true}
}
CountMaintenanceWorker(&starts) {
    starts++
    return {pid:1000+starts}
}
