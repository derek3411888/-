[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'remote-restart-control'
try {
    $functions=''
    foreach($entry in @(
        @{Path='payload\RemoteControlFirestore.ahk';Names=@('RC_ShouldDeferCommandsForRestart','RC_PollCommandTickCore','RC_ApplyRemoteState','RC_SetPausedFlag')},
        @{Path='payload\全自動.ahk';Names=@('OnRemoteControlStateChanged','RemoteServerSwitchCommitTick','ReadRestartRecoveryIntent','CommitRestartRecoveryHandoff')}
    )) {
        $source=[IO.File]::ReadAllText((Join-Path $root $entry.Path))
        foreach($name in $entry.Names) {
            $fn=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)').Value
            Assert-GMTrue ([bool]$fn) "Missing production function $name"
            $functions+="`n$fn"
        }
    }
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __ROOT__\測試\GameMaintenanceFixtures.ahk
global RC_ENABLED := true, RC_LAST_NONCE := 0, RC_LAST_ERROR_MSG := "", RC_COMMAND_PROCESSING_READY := true
global __RESTART_IN_PROGRESS := true, __NEXTSERVER_RESTART := false, __RESTART_RECOVERY_WAITING := true
global __RESTART_RECOVERY_RETRY_ID := 0, REMOTE_STOP_IN_PROGRESS := false, __REMOTE_WAS_PAUSED := false
global __WAITING_FOR_INTERACTIVE_DESKTOP := false, __CLEAN_FINAL_EXIT_REQUESTED := false, EXITING_FROM_TRAY := false
global REMOTE_CONTROL_ACTIVE := true, RC_REMOTE_DESIRED_STATE := "RUN", RC_REMOTE_PAUSED := false
global RC_ON_STATE_CHANGED := "OnRemoteControlStateChanged", RC_CFG_PATH := "", RC_PENDING_COMMAND_CLAIM := ""
global RC_COMMAND_APPLY_IN_PROGRESS := false, RC_ACTIVE_STOP_ACK := "", RC_ACTIVE_STOP_SIDE_EFFECTS_COMPLETE := false
global REMOTE_SERVER_SWITCH_PENDING := false, REMOTE_SERVER_SWITCH_TARGET_INDEX := 2, REMOTE_SERVER_SWITCH_TARGET_NAME := "Asia"
global REMOTE_PAUSE_WAITING := false, response := 0, gets := 0, callbacks := [], acks := [], uiHooks := 0
global stopCalls := 0, switchCalls := 0, durableState := "", savedOk := true, closeDuringGet := false
GMTest_Run(TestRemoteRecovery)
TestRemoteRecovery() {
    global response, __RESTART_RECOVERY_RETRY_ID, __RESTART_RECOVERY_WAITING, acks, gets, uiHooks
    global REMOTE_STOP_IN_PROGRESS, __NEXTSERVER_RESTART, RC_LAST_NONCE, RC_REMOTE_PAUSED, stopCalls
    global REMOTE_SERVER_SWITCH_PENDING, switchCalls, closeDuringGet, RC_COMMAND_APPLY_IN_PROGRESS
    response := {desiredState:"RUN",nonce:1}
    RC_PollCommandTickCore()
    GMTest_Assert(gets = 1 && __RESTART_RECOVERY_RETRY_ID = 1 && RC_LAST_NONCE = 1,"held owner receives RUN through actual poll and apply")
    RC_PollCommandTickCore()
    GMTest_Assert(__RESTART_RECOVERY_RETRY_ID = 1,"duplicate nonce never grants another retry batch")
    response := {desiredState:"PAUSE",nonce:2}
    RC_PollCommandTickCore()
    GMTest_Assert(RC_REMOTE_PAUSED && ReadRestartRecoveryIntent().state = "PAUSE" && uiHooks = 0,"PAUSE reaches held policy without game input")
    GMTest_Assert(!CommitRestartRecoveryHandoff() && __RESTART_RECOVERY_WAITING,"PAUSE cannot commit armed handoff")
    response := {desiredState:"SWITCH_SERVER",nonce:3}
    RC_PollCommandTickCore()
    GMTest_Assert(acks[acks.Length] = "BUSY" && switchCalls = 0,"held original task rejects unrelated switch without deadlocking command queue")
    response := {desiredState:"RUN",nonce:4}
    RC_PollCommandTickCore()
    GMTest_Assert(CommitRestartRecoveryHandoff() && !__RESTART_RECOVERY_WAITING,"RUN handoff commits and atomically closes old command admission")
    before := gets
    response := {desiredState:"RUN",nonce:5}
    RC_PollCommandTickCore()
    GMTest_Assert(gets = before && RC_LAST_NONCE = 4,"armed committed owner leaves new command for successor")
    __RESTART_RECOVERY_WAITING := true, closeDuringGet := true
    RC_PollCommandTickCore()
    GMTest_Assert(RC_LAST_NONCE = 4,"GET yielding to commit cannot consume successor command")
    closeDuringGet := false, __RESTART_RECOVERY_WAITING := true
    response := {desiredState:"STOP",nonce:6}
    RC_PollCommandTickCore()
    GMTest_Assert(stopCalls = 1 && REMOTE_STOP_IN_PROGRESS,"STOP remains reachable while original restart flags are set")
    REMOTE_STOP_IN_PROGRESS := false, RC_REMOTE_PAUSED := false
    REMOTE_SERVER_SWITCH_PENDING := true
    RemoteServerSwitchCommitTick()
    GMTest_Assert(switchCalls = 1 && __NEXTSERVER_RESTART && ReadRestartRecoveryIntent().state = "RUN","remote nextserver close is not misclassified as STOP")
    GMTest_Assert(!RC_COMMAND_APPLY_IN_PROGRESS,"command apply lock is released")
}
RC_TryFlushPendingCommandAck(args*) => 0
RCSH_ShouldReadFirestore(args*) => true
RC_FirestoreGetClientDoc() {
    global gets, __RESTART_RECOVERY_WAITING
    gets += 1
    if closeDuringGet
        __RESTART_RECOVERY_WAITING := false
    return response
}
RCSH_SelectControlResponse(resp) => resp
RC_ProcessRemoteSettings(args*) => 0
RC_ReconcileCommandCursorFromResponse(args*) => 0
RC_QueuePendingCommandFromResponse(args*) => 0
RC_JsonGetString(obj,key) => obj.HasOwnProp(key) ? obj.%key% : ""
RC_JsonGetInteger(obj,key,default) => obj.HasOwnProp(key) ? obj.%key% : default
RC_GetRecoverableCommandClaim(args*) => 0
RC_CommandClaimMatches(args*) => false
RC_SaveCommandClaimJournal(args*) => true
RC_PersistCommandCursorThrough(nonce,args*) {
    global RC_LAST_NONCE
    RC_LAST_NONCE := nonce
}
RC_PatchCommandAck(nonce,state,code,args*) {
    acks.Push(code)
    return true
}
RC_ClearCommandClaimThrough(args*) => 0
RC_PatchClientState(args*) => 0
RC_NormalizeCommandAck(args*) => {}
RC_IsDesiredStateGenerationCurrent(args*) => false
RC_SavePersistedDesiredState(state,args*) {
    global durableState
    durableState := state
    return true
}
RC_Log(args*) => 0
RC_IsPaused() => RC_REMOTE_PAUSED
GM_IsMaintenanceStopped() => false
GM_HandleRemoteIntent(state,args*) {
    GMTest_Assert(state = "STOP" || durableState = state,"state must be durable before callback")
    return {handled:true,code:"APPLIED"}
}
SetSoftPauseClockState(args*) => 0
PrepareRemoteServerSwitch(args*) => 0
CompleteServerForTodayFromRemote(args*) => 0
WriteLog(args*) => 0
ShowTip(args*) => 0
RemotePauseHookTick(args*) => 0
RemoteRunResumeHookTick(args*) => 0
SetTimer(args*) {
    global uiHooks
    uiHooks += 1
}
ShutdownGameLrmcOkww(relaunch,args*) {
    global stopCalls, switchCalls
    if relaunch
        switchCalls += 1
    else
        stopCalls += 1
}
__FUNCTIONS__
'@
    $path=Join-Path $context.RunRoot 'remote-restart-control.ahk'
    [IO.File]::WriteAllText($path,$fixture.Replace('__ROOT__',$root).Replace('__FUNCTIONS__',$functions),[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $path $context 15
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'Actual remote polling/apply/host controls remain live during recovery hold'
} finally {Complete-ProjectDevelopmentPaths -Context $context}
