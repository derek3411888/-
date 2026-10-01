$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'remote-startup-hooks'
try {
    $source=[IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $actual=[regex]::Match($source,'(?ms)^RemotePauseHookTick\(.*?(?=^TrySendRunCtrlF1ToLrmc\()').Value
    if(-not $actual){throw 'Missing remote UI hooks'}
    $testPath=Join-Path $context.RunRoot 'remote-startup-hooks.ahk'
    $harness=@"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
global RC_COMMAND_APPLY_IN_PROGRESS := false, __WAITING_FOR_INTERACTIVE_DESKTOP := false
global __REMOTE_PAUSE_HOTKEY_BUSY := false, __REMOTE_PAUSE_HOOK_NONCE := -1
global __REMOTE_RESUME_SYNC_BUSY := false, __REMOTE_RESUME_HOOK_NONCE := -1
global __REWARD_MONITOR_ACTIVE := false, __REWARD_MONITOR_COMPLETION_PENDING := false
global HOOK_FIXTURE := {aux:0,ui:0,current:true}, TIMERS := [], LRMC_PRESENT := false
GMTest_Run(TestHooks)
TestHooks() {
    global RC_COMMAND_APPLY_IN_PROGRESS, HOOK_FIXTURE, TIMERS, LRMC_PRESENT
    for hook in [RemotePauseHookTick,RemoteRunResumeHookTick] {
        RC_COMMAND_APPLY_IN_PROGRESS := true, HOOK_FIXTURE.aux := 0, HOOK_FIXTURE.ui := 0, TIMERS := [], HOOK_FIXTURE.current := true
        hook.Call(119)
        GMTest_Assert(HOOK_FIXTURE.aux = 0 && HOOK_FIXTURE.ui = 0,"UI hooks cannot interrupt durable command/ACK processing")
        GMTest_Assert(TIMERS.Length = 1,"busy command defers rather than loses its hook")
        RC_COMMAND_APPLY_IN_PROGRESS := false
        TIMERS[1].Call()
        GMTest_Assert(HOOK_FIXTURE.aux = 1,"deferred current-generation hook resumes auxiliary scripts once")
        GMTest_Assert(HOOK_FIXTURE.ui = 0,"startup without LRMCAI must not wait for or operate game UI")
        HOOK_FIXTURE.current := false, HOOK_FIXTURE.aux := 0, TIMERS := []
        hook.Call(118)
        GMTest_Assert(HOOK_FIXTURE.aux = 0 && TIMERS.Length = 0,"superseded generation cannot reschedule or act")
    }
    HOOK_FIXTURE.current := true, LRMC_PRESENT := true, HOOK_FIXTURE.ui := 0
    RemotePauseHookTick(120)
    GMTest_Assert(HOOK_FIXTURE.ui > 0,"active LRMCAI pause still synchronizes its hotkey")
    HOOK_FIXTURE.ui := 0
    RemoteRunResumeHookTick(121)
    GMTest_Assert(HOOK_FIXTURE.ui > 0,"active LRMCAI resume still verifies game readiness")
}
GM_IsGateActive() => false
IsRemoteHookGenerationCurrent(args*) => HOOK_FIXTURE.current
AcquireRemoteHookGenerationGuard(state,nonce,&mutex,context) {
    mutex := 0
    return HOOK_FIXTURE.current
}
ReleaseRemoteHookGenerationGuard(&mutex) => 0
PauseAuxManagedScriptsOnRemotePause() => HOOK_FIXTURE.aux++
ResumeAuxManagedScriptsAfterRemoteRun() => HOOK_FIXTURE.aux++
ProcessExist(args*) => LRMC_PRESENT
SetTimer(callback,period) => TIMERS.Push(callback)
WriteLog(args*) => 0
FileExist(args*) => true
WaitForTemplateVisible(args*) => HOOK_FIXTURE.ui++ && false
ClickTemplateIfFound(args*) => HOOK_FIXTURE.ui++
SendHotkeyToLrmc(args*) => HOOK_FIXTURE.ui++
GetWutheringGameHwnd() => HOOK_FIXTURE.ui++
WaitForWutheringGameWindow(args*) => HOOK_FIXTURE.ui++
IsTemplateVisible(args*) => false
WaitLoginScreenClearedByOcrAndCenterClick(args*) => HOOK_FIXTURE.ui++
WaitEscMenuOCR(args*) => HOOK_FIXTURE.ui++ && false
TrySendRunCtrlF1ToLrmc(args*) => HOOK_FIXTURE.ui++
$actual
"@
    [IO.File]::WriteAllText($testPath,$harness,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $testPath $context 20
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'remote startup UI hooks'
} finally {Complete-ProjectDevelopmentPaths -Context $context}
