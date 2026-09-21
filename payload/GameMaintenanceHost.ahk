#Requires AutoHotkey v2.0
#Include GameMaintenance.ahk
#Include GameUpdateAdapters.ahk

; Host glue only. This file is included by 全自動.ahk; no auto-run game action.
global GM_CONTROLLER := 0
global GM_GAME_MAINTENANCE_HIT := false

GM_Init(cfgPath,launchEntry,flowContext) {
    global GM_CONTROLLER
    flowContext.runCycle := GetCurrentServerCycleKey()
    flowContext.newTask := !flowContext.isRestart && !flowContext.isNextServerCycle
    hooks := {ReadInput:GMHost_ReadInput,WorkerStart:GMHost_StartWorker,WorkerAlive:GMHost_WorkerAlive,
        WorkerStop:GMHost_StopWorker,ApplyEffect:GMHost_ApplyEffect,Publish:GMHost_Publish,
        StopRecording:GMHost_StopRecording,ReconcileSchedule:GMHost_ReconcileSchedule}
    GM_CONTROLLER := GM_CreateController(RuntimeFiles_GameMaintenanceDir() "\state.ini",flowContext,hooks)
    c := GM_CONTROLLER
    c.cfgPath := cfgPath, c.launchEntry := launchEntry, c.snapshot := 0, c.sequence := 0
    c.tick := MonotonicTickMs(), c.lastUtcMs := RC_UnixMs(), c.activeElapsed := c.state.elapsedMs
    c.noProgressMs := 0, c.actionElapsedMs := 0, c.lastProgressToken := "", c.lastObserveTick := 0
    c.observation := 0, c.maintenanceEvidence := 0, c.lastGameCaptureTick := 0, c.forceRevision := 0
    c.clockUnstableAt := 0, c.lastSettingsRefresh := "", c.install := {provider:"unknown",updateAdapterReady:false}
    c.lastInput := 0, c.lastRequestKey := "", c.resumeExistingF11 := c.state.f11InputAttempted, c.ocrEngine := 0
    if GM_HasActiveContinuation(c.state)
        GMHost_RestoreScheduledTarget(c.state.targetServer)
    return c
}

GM_IsGateActive() {
    global GM_CONTROLLER
    return IsObject(GM_CONTROLLER) && GM_CONTROLLER.active
}

GM_IsManagedUpdateDay() {
    global GM_CONTROLLER
    return IsObject(GM_CONTROLLER) && GM_CONTROLLER.managed
}

GM_WaitForStartupGate() {
    global GM_CONTROLLER
    c := GM_CONTROLLER
    loop {
        decision := GM_ControllerTick(c)
        if decision.phase = "STOPPED"
            return {mode:"stop",detail:decision.detail}
        if (decision.phase = "NORMAL" && decision.overlay = "") {
            c.active := false
            GM_Shutdown("normal-gate-released")
            return {mode:"normal",detail:decision.detail}
        }
        if (decision.overlay = "" && (decision.effect.type = "start_update" || decision.phase = "UPDATING" || decision.phase = "CHECKING_LOGIN" || decision.phase = "READY"))
            return {mode:"managed_update",detail:decision.detail}
        DllCall("Sleep","UInt",100)
    }
}

GM_RunManagedUpdate() {
    global GM_CONTROLLER
    c := GM_CONTROLLER
    loop {
        decision := GM_ControllerTick(c,true)
        if decision.phase = "STOPPED"
            return {ok:false,readyForLogin:false,errorCode:"STOPPED",detail:"已取消"}
        if (decision.overlay = "" && (decision.phase = "CHECKING_LOGIN" || decision.phase = "READY"))
            return {ok:true,readyForLogin:true,errorCode:"",detail:decision.detail}
        DllCall("Sleep","UInt",100)
    }
}

GM_HandleRemoteIntent(state,command := 0) {
    global GM_CONTROLLER
    if !IsObject(GM_CONTROLLER)
        return {handled:false}
    return GM_ControllerRemoteIntent(GM_CONTROLLER,state,command)
}

GMHost_ProcessStartMs(pid) {
    processHandle := DllCall("OpenProcess","UInt",0x1000,"Int",false,"UInt",pid,"Ptr")
    if !processHandle
        return 0
    try {
        exitCode := 0
        if !DllCall("GetExitCodeProcess","Ptr",processHandle,"UInt*",&exitCode) || exitCode != 259
            return 0
        creation := Buffer(8), exitTime := Buffer(8), kernel := Buffer(8), user := Buffer(8)
        if !DllCall("GetProcessTimes","Ptr",processHandle,"Ptr",creation,"Ptr",exitTime,"Ptr",kernel,"Ptr",user)
            return 0
        return (NumGet(creation,0,"Int64") // 10000) - 11644473600000
    } finally DllCall("CloseHandle","Ptr",processHandle)
}

GMHost_JsonQuote(value) {
    value := StrReplace(value,"\","\\"), value := StrReplace(value,'"','\"')
    value := StrReplace(value,"`r","\r"), value := StrReplace(value,"`n","\n"), value := StrReplace(value,"`t","\t")
    return '"' value '"'
}

GMHost_WriteRequest(c,force := false) {
    if !IsObject(c.worker)
        return
    key := c.state.remoteGeneration "|" c.launchEntry "|" c.forceRevision "|" c.state.eventId
    if !force && key = c.lastRequestKey
        return
    c.worker.generation += 1
    mode := GM_Value(c,"workerMode","observe")
    GM_RequireEnum(mode,"notice,install,observe")
    json := '{"schemaVersion":1,"requestId":' GMHost_JsonQuote(c.worker.requestId)
        . ',"generation":' c.worker.generation ',"launchEntry":' GMHost_JsonQuote(c.launchEntry)
        . ',"mode":' GMHost_JsonQuote(mode) ',"createdAtUtc":' GMHost_JsonQuote(FormatTime(A_NowUTC,"yyyy-MM-dd") "T" FormatTime(A_NowUTC,"HH:mm:ss") "Z")
        . ',"pinnedEventId":' GMHost_JsonQuote(c.state.eventId) ',"refreshRequestId":' GMHost_JsonQuote(String(c.forceRevision)) '}'
    GM_AtomicText(c.worker.requestPath,json)
    c.lastRequestKey := key
}

GMHost_StartWorker(c) {
    idBuffer := Buffer(16), textBuffer := Buffer(80)
    if DllCall("ole32\CoCreateGuid","Ptr",idBuffer,"Int") != 0
        throw Error("Cannot create maintenance request identity")
    DllCall("ole32\StringFromGUID2","Ptr",idBuffer,"Ptr",textBuffer,"Int",40)
    requestId := RegExReplace(StrGet(textBuffer),"[^A-Za-z0-9_-]","")
    session := RuntimeFiles_RuntimeDir("遊戲更新") "\" requestId
    DirCreate(session)
    ownerPid := DllCall("GetCurrentProcessId"), ownerStarted := GMHost_ProcessStartMs(ownerPid)
    if !ownerStarted
        throw Error("Cannot verify maintenance worker parent")
    worker := {requestId:requestId,session:session,requestPath:session "\request.json",outputPath:session "\snapshot.ini",
        stopPath:session "\stop",pid:0,started:0,generation:0,lastSeenTick:MonotonicTickMs()}
    c.worker := worker, c.sequence := 0, c.snapshot := 0, c.lastRequestKey := ""
    GMHost_WriteRequest(c,true)
    scriptPath := A_ScriptDir "\GameMaintenanceWorker.ps1"
    if !FileExist(scriptPath)
        throw Error("Missing maintenance worker package")
    command := '"' A_WinDir '\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "' scriptPath
        . '" -RequestPath "' worker.requestPath '" -OutputPath "' worker.outputPath '" -StopPath "' worker.stopPath
        . '" -StateDirectory "' RuntimeFiles_GameMaintenanceDir() '" -ParentPid ' ownerPid ' -ParentStartUtc "' ownerStarted '"'
    Run(command,session,"Hide",&workerPid)
    worker.pid := workerPid, worker.started := GMHost_ProcessStartMs(workerPid)
    if !worker.started
        throw Error("Maintenance worker creation identity unavailable")
    WriteLog("版本更新背景查詢啟動 | pid=" worker.pid " request=" requestId)
    return worker
}

GMHost_WorkerAlive(worker) {
    return worker.pid > 0 && GMHost_ProcessStartMs(worker.pid) = worker.started
        && MonotonicTickMs() - worker.lastSeenTick <= 65000
}

GMHost_StopWorker(worker) {
    if !IsObject(worker)
        return
    ; Only signal our per-request path. Never taskkill all PowerShell/Steam.
    GM_ContainedPath(worker.stopPath,worker.session)
    GM_AtomicText(worker.stopPath,worker.requestId)
}

GMHost_ReadInput(c) {
    global RC_LAST_NONCE
    now := RC_UnixMs(), tick := MonotonicTickMs(), delta := Max(0,tick-c.tick)
    if Abs((now-c.lastUtcMs)-delta) > 120000
        c.clockUnstableAt := now, c.forceRevision += 1
    c.lastUtcMs := now, c.tick := tick
    desired := c.state.cancelled ? "STOP" : (RC_IsPaused() ? "PAUSE" : "RUN")
    desktopAvailable := GetInteractiveDesktopState().ok
    if desired = "RUN" && desktopAvailable {
        c.activeElapsed += delta, c.noProgressMs += delta
        if c.state.actionId != ""
            c.actionElapsedMs += delta
    }
    generation := Max(c.state.remoteGeneration,RC_LAST_NONCE)
    c.state.remoteGeneration := generation
    refreshId := IniReadSafe(c.cfgPath,"game_maintenance","refresh_request_id","")
    if refreshId != c.lastSettingsRefresh
        c.lastSettingsRefresh := refreshId, c.forceRevision += 1
    GMHost_WriteRequest(c)
    if IsObject(c.worker) && FileExist(c.worker.outputPath) {
        try {
            snapshot := GM_ReadWorkerSnapshot(c.worker.outputPath,c.worker.requestId,c.sequence,now,c.worker.session)
            c.snapshot := snapshot, c.sequence := snapshot["meta"]["sequence"], c.worker.lastSeenTick := tick
        }
    }
    notice := 0, sourceState := "pending", noticeError := "", observation := {phase:"unknown",observedAt:0}
    if IsObject(c.snapshot) && now - c.snapshot["meta"]["observedAtUtcMs"] <= 60000 {
        snapshot := c.snapshot, n := snapshot["notice"], i := snapshot["install"], o := snapshot["observation"]
        sourceState := n["outcome"] = "ok" ? "valid" : n["outcome"], noticeError := n["errorCode"]
        if n["present"] = "1"
            notice := {eventId:n["eventId"],revision:n["revision"],startsAt:Number(n["startsAtUtcMs"]),expectedOpenAt:Number(n["expectedOpenAtUtcMs"]),
                freshForRelease:n["freshForRelease"] = "1",sourceUrl:n["sourceUrl"],gameVersion:n["gameVersion"]}
        c.install := {provider:i["provider"],appId:i["appId"] = "" ? 0 : Integer(i["appId"]),gameRoot:i["gameRoot"],launcherPath:i["launcherPath"],
            fingerprint:i["fingerprint"],identityVerified:InStr(i["evidence"],"installation-files-verified") > 0,updateAdapterReady:false}
        c.install.updateAdapterReady := GMHost_AdapterAccepted(c.install)
        observation := {phase:o["phase"],observedAt:snapshot["meta"]["observedAtUtcMs"],progressPercent:o["progressPercent"],
            bytesDone:o["bytesDone"],bytesTotal:o["bytesTotal"],errorCode:o["errorCode"],detail:o["detail"],
            identityVerified:o["phase"] = "game_running" && o["gamePid"] != "",gamePid:o["gamePid"],gamePath:o["gamePath"]}
        progressToken := o["lastProgressAtUtcMs"] "|" o["phase"] "|" o["bytesDone"]
        if progressToken != c.lastProgressToken
            c.noProgressMs := 0, c.lastProgressToken := progressToken
        if c.clockUnstableAt && n["checkedAtUtcMs"] != "" && Number(n["checkedAtUtcMs"]) >= c.clockUnstableAt
            c.clockUnstableAt := 0
    }
    if IsObject(c.observation) && now - c.observation.observedAt <= 60000
        observation := c.observation
    input := {nowUtcMs:now,elapsedMs:c.activeElapsed,clockStable:c.clockUnstableAt = 0,desiredState:desired,remoteGeneration:generation,
        desktopAvailable:desktopAvailable,noticeState:sourceState,noticeErrorCode:noticeError,notice:notice,install:c.install,observation:observation,
        noProgressMs:c.noProgressMs,actionElapsedMs:c.actionElapsedMs,runCycle:GetCurrentServerCycleKey(),
        enabled:IniReadSafe(c.cfgPath,"game_maintenance","enabled","1") = "1",
        skipEventId:IniReadSafe(c.cfgPath,"game_maintenance","skip_event_id",""),delayEventId:IniReadSafe(c.cfgPath,"game_maintenance","override_event_id",""),
        delayUntilUtc:0}
    rawDelay := IniReadSafe(c.cfgPath,"game_maintenance","delay_until_utc","0")
    if RegExMatch(rawDelay,"^\d{1,15}$")
        input.delayUntilUtc := Integer(rawDelay)
    c.lastInput := input
    return input
}

GMHost_AdapterAccepted(install) {
    ; This acceptance file is created only after an authorized real provider test.
    ; Detection by itself, a mock launcher, or an old installed ACF never enables it.
    path := RuntimeFiles_GameMaintenanceDir() "\adapter-acceptance.ini"
    if !FileExist(path) || !install.identityVerified || install.launcherPath = ""
        return false
    section := install.provider
    if (IniReadSafe(path,section,"adapter_version","0") != "1" || IniReadSafe(path,section,"launch_verified","0") != "1"
        || StrLower(IniReadSafe(path,section,"launcher_path","")) != StrLower(install.launcherPath))
        return false
    try stamp := FileGetSize(install.launcherPath) "|" FileGetTime(install.launcherPath,"M")
    catch
        return false
    if stamp != IniReadSafe(path,section,"launcher_stamp","")
        return false
    if install.provider = "kuro" && IniReadSafe(path,section,"layout_verified","0") != "1"
        return false
    return true
}

GMHost_CanAct(action) {
    global GM_CONTROLLER
    c := GM_CONTROLLER
    input := GMHost_ReadInput(c)
    if (input.desiredState != "RUN" || !input.desktopAvailable || !input.clockStable || input.remoteGeneration != action.expectedRemoteGeneration)
        return false
    decision := GM_Evaluate(c.state,input)
    return decision.overlay = "" && !InStr(",WAIT_OPEN,WAIT_NOTICE,WAIT_SERVER,STOPPED,NEEDS_ATTENTION,","," decision.phase ",",true)
        && decision.state.revision = action.expectedRevision
}

GMHost_ApplyEffect(action) {
    global GM_CONTROLLER
    c := GM_CONTROLLER
    if action.type = "check_notice" {
        c.forceRevision += 1
        GMHost_WriteRequest(c)
    } else if action.type = "start_update" {
        action.expectedFingerprint := c.install.fingerprint
        hooks := {CanAct:GMHost_CanAct,ValidateInstall:GMHost_AdapterAccepted,
            PersistIntent:(*) => GM_LoadJournal(c.journalPath).actionStage = "intent",
            LaunchSteam:(path,appId,command) => Run(command,,"Hide"),LaunchKuro:(path,command) => Run(command,,"Hide"),
            ReadObservation:(*) => c.lastInput.observation}
        result := GMU_Start(c.install,action,hooks)
        if !result.ok
            throw Error(result.errorCode " " result.detail)
        c.actionElapsedMs := 0
        return result
    } else if action.type = "observe" {
        if MonotonicTickMs() - c.lastObserveTick >= 5000 {
            c.lastObserveTick := MonotonicTickMs()
            if c.state.phase = "WAIT_SERVER"
                GMHost_ObserveWaitingGame()
            else if c.install.provider = "kuro" && c.install.updateAdapterReady
                GMHost_ObserveKuroLauncher()
        }
    } else if action.type = "stop"
        GM_Shutdown("stopped")
    return {ok:true}
}

GMHost_StopRecording() {
    ForceStopManagedScreenRecording("版本維護等待；正常封口，與直播程序隔離")
}

GMHost_RestoreScheduledTarget(target) {
    global CFG_FILE, SERVER_SCHEDULE_LIST, SERVER_SCHEDULE_INDEX, CURRENT_SERVER_TARGET
    if target = ""
        return false
    for index, name in SERVER_SCHEDULE_LIST {
        if name = target && !IsServerCompletedInCurrentCycle(name) {
            SERVER_SCHEDULE_INDEX := index, CURRENT_SERVER_TARGET := name
            IniWrite(index,CFG_FILE,"server_schedule","current_index")
            return true
        }
    }
    return false
}

GMHost_ReconcileSchedule(state) {
    global CURRENT_SERVER_TARGET, SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_LIST
    if state.runCycle != GetCurrentServerCycleKey() {
        ClearRewardMonitorRuntimeState()
        LoadServerScheduleContext(true,false)
    }
    RefreshServerScheduleAfterStartupCommands()
    return {runCycle:GetCurrentServerCycleKey(),targetServer:CURRENT_SERVER_TARGET,
        allCompleted:SERVER_SCHEDULE_ENABLED && SERVER_SCHEDULE_LIST.Length > 0 && CURRENT_SERVER_TARGET = ""}
}

GMHost_Publish(decision) {
    WriteStep("遊戲版本維護",decision.phase (decision.overlay != "" ? "／" decision.overlay : "") "｜" decision.detail,
        decision.errorCode != "" ? "WARN" : "INFO")
}

GM_MarkF11Attempt() {
    global GM_CONTROLLER
    if !IsObject(GM_CONTROLLER)
        return true
    GM_CONTROLLER.state.f11InputAttempted := true
    try GM_ControllerSave(GM_CONTROLLER,true)
    catch
        return false
    return true
}

GM_BeforeF11() {
    global GM_CONTROLLER
    if !IsObject(GM_CONTROLLER)
        return true
    c := GM_CONTROLLER
    if GM_GameMaintenanceProbe(GetWutheringGameHwnd(),true) {
        recovered := GM_WaitForMaintenanceRecovery()
        if recovered.phase = "stopped"
            return false
    }
    if c.state.f11InputAttempted {
        c.active := true, c.managed := true, c.loadError := "LOGIN_RESUME_UNCONFIRMED：已保存 F11 嘗試，但無法證明可安全重送，請先停止並確認現場"
        GMHost_Publish(GM_ControllerTick(c,true))
        loop {
            if c.state.cancelled
                return false
            decision := GM_ControllerTick(c,true)
            DllCall("Sleep","UInt",1000)
        }
    }
    return true
}

GMHost_CanonicalPath(path) {
    handle := DllCall("CreateFileW","Str",path,"UInt",0,"UInt",7,"Ptr",0,"UInt",3,"UInt",0x02000000,"Ptr",0,"Ptr")
    if handle = -1 || !handle
        return ""
    try {
        resultBuffer := Buffer(65536)
        count := DllCall("GetFinalPathNameByHandleW","Ptr",handle,"Ptr",resultBuffer,"UInt",32768,"UInt",0,"UInt")
        if !count || count >= 32768
            return ""
        value := StrGet(resultBuffer)
        if SubStr(value,1,8) = "\\?\UNC\"
            return "\\" SubStr(value,9)
        return SubStr(value,1,4) = "\\?\" ? SubStr(value,5) : value
    } finally DllCall("CloseHandle","Ptr",handle)
}

GMHost_InspectLauncherWindow(hwnd) {
    global GM_CONTROLLER
    result := {pid:0,hwnd:hwnd,path:"",identityVerified:false,foregroundVerified:false,desktopAvailable:false}
    try {
        result.pid := WinGetPID("ahk_id " hwnd), result.path := GMHost_CanonicalPath(WinGetProcessPath("ahk_id " hwnd))
        result.identityVerified := result.path != "" && StrLower(result.path) = StrLower(GM_CONTROLLER.install.launcherPath)
        result.desktopAvailable := GetInteractiveDesktopState().ok
        result.foregroundVerified := GetForegroundRelationToTarget(hwnd) = "exact"
    }
    return result
}

GMHost_KuroLayout(install) {
    filePath := RuntimeFiles_GameMaintenanceDir() "\adapter-acceptance.ini"
    version := FileGetVersion(install.launcherPath)
    if version != IniReadSafe(filePath,"kuro","launcher_version","")
        return 0
    layout := {verified:true,launcherVersion:version,button:{},status:{}}
    for region in ["button","status"] {
        for coord in ["left","top","right","bottom"] {
            raw := IniReadSafe(filePath,"kuro",region "_" coord,"")
            if !RegExMatch(raw,"^(?:0(?:\.\d+)?|1(?:\.0+)?)$")
                return 0
            layout.%region%.%coord% := Number(raw)
        }
        if layout.%region%.left >= layout.%region%.right || layout.%region%.top >= layout.%region%.bottom
            return 0
    }
    return layout
}

GMHost_ReadKuroObservation() {
    global GM_CONTROLLER
    c := GM_CONTROLLER, install := c.install, unknown := {phase:"unknown",observedAt:RC_UnixMs()}
    if !GMHost_AdapterAccepted(install)
        return unknown
    layout := GMHost_KuroLayout(install)
    if !IsObject(layout)
        return unknown
    target := 0
    for hwnd in WinGetList("ahk_exe launcher.exe") {
        candidate := GMHost_InspectLauncherWindow(hwnd)
        if candidate.identityVerified {
            if IsObject(target)
                return unknown
            target := candidate
        }
    }
    if !IsObject(target)
        return unknown
    try {
        frame := ImagePutBuffer("ahk_id " target.hwnd), temp := RuntimeFiles_NewImagePath("kuro_update"), blocks := []
        try {
            ImagePutFile(frame,temp)
            if !IsObject(c.ocrEngine)
                c.ocrEngine := RapidOcr()
            rawBlocks := c.ocrEngine.ocr_from_file(temp,,true)
        } finally {
            if FileExist(temp)
                FileDelete(temp)
        }
        after := GMHost_InspectLauncherWindow(target.hwnd)
        if after.pid != target.pid || !after.identityVerified
            return unknown
        for block in rawBlocks {
            if block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3
                blocks.Push({text:block.text,left:block.boxPoint[1].x,top:block.boxPoint[1].y,right:block.boxPoint[3].x,bottom:block.boxPoint[3].y})
        }
        identity := {key:target.pid ":" target.hwnd,provider:"kuro",verified:true,clientWidth:frame.width,clientHeight:frame.height,
            launcherVersion:layout.launcherVersion,layout:layout}
        classified := GMU_ClassifyLauncher(blocks,identity)
        phase := InStr(",update,download,resume,play,","," classified.kind ",",true) ? "unknown" : classified.kind
        if classified.kind = "play"
            phase := "update_ready"
        return {phase:phase,progressPercent:classified.percent,observedAt:RC_UnixMs(),identityVerified:true,
            detail:classified.evidence,errorCode:classified.kind = "error" ? "KURO_UPDATE_ERROR" : "",target:target,button:classified.button,kind:classified.kind}
    } catch as err {
        unknown.detail := "官方更新器觀察失敗：" err.Message
        return unknown
    }
}

GMHost_PersistUpdaterUi(action) {
    global GM_CONTROLLER
    c := GM_CONTROLLER
    if c.state.updaterUiActionId = action.actionId
        return false
    c.state.updaterUiActionId := action.actionId, c.state.updaterUiActionStage := "intent"
    try GM_ControllerSave(c,true)
    catch
        return false
    return true
}

GMHost_ObserveKuroLauncher() {
    global GM_CONTROLLER
    c := GM_CONTROLLER, observed := GMHost_ReadKuroObservation()
    if GM_Value(observed,"kind","") = "" {
        c.observation := observed
        return
    }
    token := observed.phase "|" GM_Value(observed,"progressPercent","")
    if token != GM_Value(c,"lastKuroProgress","")
        c.noProgressMs := 0, c.lastKuroProgress := token
    c.observation := observed
    if !IsObject(observed.button)
        return
    id := c.state.eventId ":kuro:" observed.kind
    if id = c.state.updaterUiActionId
        return
    action := {type:"click_" observed.kind,actionId:id,button:observed.button,expectedRevision:c.state.revision,
        expectedRemoteGeneration:c.state.remoteGeneration}
    safeInput := {CanAct:GMHost_CanAct,InspectWindow:GMHost_InspectLauncherWindow,
        PrepareWindow:(hwnd,pid) => PrepareVerifiedWindowForInput(hwnd,pid,"版本更新器安全操作"),
        ClickPoint:(hwnd,x,y,pid) => ClickVerifiedWindowClientPoint(hwnd,x,y,pid,"版本更新器安全操作")}
    target := observed.target
    if !GMHost_CanAct(action) || !GMHost_PersistUpdaterUi(action)
        return
    clicked := GMU_ClickLauncherVerified(c.install,target,action,safeInput)
    c.state.updaterUiActionStage := "observed"
    GM_ControllerSave(c,true)
    if !clicked
        c.observation := {phase:"error",observedAt:RC_UnixMs(),errorCode:"KURO_INPUT_UNVERIFIED",detail:"官方更新器未能安全接收輸入；不重複點擊"}
    else {
        ; A click is an attempt only. The next independent capture proves a stage change.
        c.observation := {phase:"queued",observedAt:RC_UnixMs(),detail:"已嘗試更新器按鈕，等待後置畫面確認",identityVerified:true}
        WriteLog("官方更新器按鈕已嘗試；尚未宣告下載／登入成功 | action=" id)
    }
}

GM_GameMaintenanceProbe(hwnd,force := false,attempt := 0) {
    global GM_CONTROLLER, GM_GAME_MAINTENANCE_HIT
    if !IsObject(GM_CONTROLLER) || !hwnd
        return false
    c := GM_CONTROLLER, tick := MonotonicTickMs()
    if !force && tick - c.lastGameCaptureTick < 3000
        return GM_GAME_MAINTENANCE_HIT
    c.lastGameCaptureTick := tick
    if !GetInteractiveDesktopState().ok
        return false
    try {
        pid := 0, class := "", reason := ""
        if !GetWutheringWindowIdentity(hwnd,&pid,&class,&reason)
            return false
        frame := ImagePutBuffer("ahk_id " hwnd)
        temp := RuntimeFiles_NewImagePath("game_maintenance")
        try {
            ImagePutFile(frame,temp)
            if !IsObject(c.ocrEngine)
                c.ocrEngine := RapidOcr()
            blocks := c.ocrEngine.ocr_from_file(temp,,true), normalized := []
        } finally {
            if FileExist(temp)
                FileDelete(temp)
        }
        if !(blocks is Array)
            return false
        for block in blocks {
            if block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3
                normalized.Push({text:block.text,left:block.boxPoint[1].x,top:block.boxPoint[1].y,right:block.boxPoint[3].x,bottom:block.boxPoint[3].y})
        }
        actualPid := 0, actualClass := "", reason := ""
        if !GetWutheringWindowIdentity(hwnd,&actualPid,&actualClass,&reason) || actualPid != pid
            return false
        identity := {key:pid ":" hwnd ":" class,provider:c.install.provider,clientWidth:frame.width,clientHeight:frame.height,verified:true}
        candidate := GMU_ClassifyMaintenance(normalized,identity)
        c.maintenanceEvidence := GMU_ConfirmMaintenance(c.maintenanceEvidence,candidate,tick,String(tick))
        if candidate.confirmed && !c.maintenanceEvidence.confirmed && attempt = 0 {
            DllCall("Sleep","UInt",300)
            return GM_GameMaintenanceProbe(hwnd,true,1)
        }
        if c.maintenanceEvidence.confirmed {
            GM_GAME_MAINTENANCE_HIT := true
            c.active := true, c.managed := true
            c.observation := {phase:"maintenance",confirmed:true,identityVerified:true,observedAt:RC_UnixMs()}
            c.state.phase := "WAIT_SERVER", c.state.lastObserveElapsedMs := c.activeElapsed
            GM_ControllerSave(c,true)
            return true
        }
        GM_GAME_MAINTENANCE_HIT := false
    } catch as err {
        c.maintenanceEvidence := 0
        WriteLog("維護畫面查詢失敗；未視為維護或成功：" err.Message,"WARN")
    }
    return false
}

GMHost_ObserveWaitingGame() {
    global GM_CONTROLLER
    hwnd := GetWutheringGameHwnd()
    if !hwnd
        return
    if GM_GameMaintenanceProbe(hwnd,true)
        return
    if WaitEscMenuOCR(hwnd,2) {
        GM_CONTROLLER.observation := {phase:"game_ready",identityVerified:true,stable:true,observedAt:RC_UnixMs()}
    } else if IsLoginScreenByOcr(hwnd)
        GM_CONTROLLER.observation := {phase:"login_ready",identityVerified:true,observedAt:RC_UnixMs()}
}

GM_WaitForMaintenanceRecovery() {
    global GM_CONTROLLER, GM_GAME_MAINTENANCE_HIT
    c := GM_CONTROLLER
    c.active := true, c.managed := true
    loop {
        decision := GM_ControllerTick(c,true)
        if decision.phase = "STOPPED"
            return {ok:false,phase:"stopped",centerClicked:false}
        if (decision.overlay = "" && (decision.phase = "READY" || decision.phase = "CHECKING_LOGIN")) {
            GM_GAME_MAINTENANCE_HIT := false
            return {ok:decision.phase = "READY",phase:decision.phase = "READY" ? "maintenance_recovered_ready" : "maintenance_login_ready",centerClicked:false}
        }
        DllCall("Sleep","UInt",100)
    }
}

GM_MarkReady() {
    global GM_CONTROLLER
    if !IsObject(GM_CONTROLLER)
        return
    c := GM_CONTROLLER
    c.observation := {phase:"game_ready",identityVerified:true,stable:true,observedAt:RC_UnixMs()}
    c.state.phase := "READY", c.state.overlay := "", c.active := false
    c.ocrEngine := 0
    GM_ControllerSave(c,true)
    GM_Shutdown("ready")
}

GM_Shutdown(reason := "exit") {
    global GM_CONTROLLER
    if !IsObject(GM_CONTROLLER)
        return
    c := GM_CONTROLLER
    if IsObject(c.worker) {
        try GMHost_StopWorker(c.worker)
        c.worker := 0
    }
    ; Completed/normal flow may start a fresh task. Interrupted active intent is retained.
    try GM_ControllerSave(c,true)
}

GM_CancelForStop(reason) {
    global GM_CONTROLLER
    if !IsObject(GM_CONTROLLER)
        return
    c := GM_CONTROLLER
    c.state.cancelled := true, c.state.phase := "STOPPED", c.state.desiredState := "STOP", c.state.actionStage := "cancelled"
    try GM_ControllerSave(c,true)
    try IniDelete(c.cfgPath,"game_maintenance","skip_event_id")
    GM_Shutdown(reason)
}
