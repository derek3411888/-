#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include GameMaintenanceFixtures.ahk
#Include *i ..\payload\RemoteUpdateRestart.ahk
global testRoot := TestRuntime_NewCaseDir("remote-update-restart")
global CFG_FILE := testRoot "\config.ini", RC_REMOTE_DESIRED_STATE := "PAUSE", RC_REMOTE_PAUSED := true
global RC_PENDING_COMMAND_CLAIM := "", RC_COMMAND_APPLY_IN_PROGRESS := false
global REMOTE_STOP_IN_PROGRESS := false, EXITING_FROM_TRAY := false
global __RESTART_IN_PROGRESS := false, __NEXTSERVER_RESTART := false, REMOTE_SERVER_SWITCH_PENDING := false
global durableNonce := 0, saveAllowed := true, schedules := [], closes := [], resumeReady := true
global supersedeDuringReceipt := false, mutexHeld := false
GMTest_Run(TestRestart)
TestRestart() {
    global durableNonce, saveAllowed, RC_COMMAND_APPLY_IN_PROGRESS, RC_PENDING_COMMAND_CLAIM
    global __RESTART_IN_PROGRESS, RC_REMOTE_PAUSED, REMOTE_STOP_IN_PROGRESS, supersedeDuringReceipt
    if !IsSet(PrepareRemoteUpdateRestart)
        throw Error("Missing one-shot website restart/update handler")
    result := PrepareRemoteUpdateRestart({remoteNonce:1})
    GMTest_Assert(result.code = "LAUNCHER_MISSING" && schedules.Length = 0,"missing updater cannot queue a local-only restart")
    FileAppend("fixture",testRoot "\全自動鋤地.exe")
    saveAllowed := false
    result := PrepareRemoteUpdateRestart({remoteNonce:1})
    GMTest_Assert(result.code = "CONFIG_WRITE_FAILED" && schedules.Length = 0,"failed durable RUN cannot schedule shutdown")
    saveAllowed := true
    result := PrepareRemoteUpdateRestart({remoteNonce:1})
    GMTest_Assert(result.code = "ACCEPTED" && durableNonce = 1 && !RC_REMOTE_PAUSED,"restart authorizes durable RUN without hotkeys")
    GMTest_Assert(schedules.Length = 1 && closes.Length = 0,"accepted means scheduled, not already restarted")
    result := PrepareRemoteUpdateRestart({remoteNonce:1})
    GMTest_Assert(result.code = "ACCEPTED" && schedules.Length = 1,"duplicate/recovered nonce does not schedule another restart")
    RC_PENDING_COMMAND_CLAIM := {nonce:1}
    RemoteUpdateRestartCommitTick()
    GMTest_Assert(closes.Length = 0,"shutdown waits for durable command ACK")
    RC_PENDING_COMMAND_CLAIM := "", RC_COMMAND_APPLY_IN_PROGRESS := true
    RemoteUpdateRestartCommitTick()
    GMTest_Assert(closes.Length = 0,"active command handler cannot race shutdown")
    RC_COMMAND_APPLY_IN_PROGRESS := false
    RemoteUpdateRestartCommitTick()
    GMTest_Assert(closes.Length = 1 && closes[1].relaunch && closes[1].code = "WEB_RESTART_UPDATE" && closes[1].mode = "restart resume","complete close routes through update handoff retaining resume")
    RemoteUpdateRestartCommitTick()
    GMTest_Assert(closes.Length = 1,"commit tick is one-shot")
    __RESTART_IN_PROGRESS := false
    result := PrepareRemoteUpdateRestart({remoteNonce:2})
    durableNonce := 3, RC_REMOTE_PAUSED := true
    RemoteUpdateRestartCommitTick()
    GMTest_Assert(closes.Length = 1,"new PAUSE/RUN generation cancels stale queued restart")
    RC_REMOTE_PAUSED := false
    result := PrepareRemoteUpdateRestart({remoteNonce:4})
    REMOTE_STOP_IN_PROGRESS := true
    RemoteUpdateRestartCommitTick()
    GMTest_Assert(closes.Length = 1,"STOP wins before destructive action")
    REMOTE_STOP_IN_PROGRESS := false
    PrepareRemoteUpdateRestart({remoteNonce:5})
    supersedeDuringReceipt := true
    RemoteUpdateRestartCommitTick()
    GMTest_Assert(closes.Length = 1 && !__RESTART_IN_PROGRESS,"new PAUSE during receipt write wins before atomic shutdown commit")
    GMTest_Assert(IniRead(CFG_FILE,"server_schedule","index","2") = "2","restart does not modify server index")
}
ResolvePersistentToolsRoot() => testRoot
RuntimeFiles_RuntimeDir(args*) => testRoot
RC_SavePersistedDesiredState(state,nonce,args*) {
    global durableNonce
    if !saveAllowed
        return false
    durableNonce := nonce
    return true
}
RC_IsDesiredStateGenerationCurrent(state,nonce) => state = "RUN" && nonce = durableNonce
RC_SetPausedFlag(value) {
    global RC_REMOTE_PAUSED
    RC_REMOTE_PAUSED := value
}
RC_IsPaused() => RC_REMOTE_PAUSED
IsLrmcRunResumeReady() => resumeReady
SetTimer(callback,period) => schedules.Push(period)
WriteLog(args*) => 0
WriteStep(args*) => 0
SetSoftPauseClockState(args*) => 0
ShutdownGameLrmcOkww(relaunch,code,mode) => closes.Push({relaunch:relaunch,code:code,mode:mode})
RestartHandoff_WriteIni(path,section,values) {
    global durableNonce, RC_REMOTE_PAUSED
    for key,value in values
        IniWrite(value,path,section,key)
    if supersedeDuringReceipt && values["stage"] = "closing"
        durableNonce += 1, RC_REMOTE_PAUSED := true
}
RC_AcquirePersistedDesiredStateMutex() {
    global mutexHeld
    mutexHeld := true
    return 1
}
RC_ReleasePersistedDesiredStateMutex(handle) {
    global mutexHeld
    mutexHeld := false
}
ReadManagedProcessRecord(args*) => 0
ResolveManagedTargetExePath(args*) => ""
GMHost_CanonicalPath(path) => path
IsManagedByCurrentScriptFfmpegCommand(args*) => false
ParseManagedCommandLine(args*) => []
