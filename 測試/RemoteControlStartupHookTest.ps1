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
global HOOK_FIXTURE := {aux:0,ui:0,current:true,f9:0,readiness:0,resume:0,ready:false}, TIMERS := [], LRMC_PRESENT := false
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
    GMTest_Assert(HOOK_FIXTURE.f9 = 1,"active LRMCAI pause sends exactly one F9")
    GMTest_Assert(HOOK_FIXTURE.readiness = 0 && HOOK_FIXTURE.resume = 0,"pause does not run readiness or Ctrl+F1")
    RemoteRunResumeHookTick(121)
    GMTest_Assert(HOOK_FIXTURE.readiness = 1,"active LRMCAI resume verifies game readiness")
    GMTest_Assert(HOOK_FIXTURE.resume = 0,"unready game must not receive Ctrl+F1")
    HOOK_FIXTURE.ready := true
    RemoteRunResumeHookTick(122)
    GMTest_Assert(HOOK_FIXTURE.readiness = 2,"each resume must independently verify readiness")
    GMTest_Assert(HOOK_FIXTURE.resume = 1,"ready game resumes LRMCAI exactly once")
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
SendHotkeyToLrmc(key,args*) {
    HOOK_FIXTURE.ui++
    GMTest_Assert(key = "{F9}","pause hotkey is F9")
    HOOK_FIXTURE.f9++
    return true
}
GetWutheringGameHwnd() => HOOK_FIXTURE.ui++
WaitForWutheringGameWindow(args*) => HOOK_FIXTURE.ui++
IsTemplateVisible(args*) => false
WaitLoginScreenClearedByOcrAndCenterClick(args*) => HOOK_FIXTURE.ui++
WaitEscMenuOCR(args*) {
    HOOK_FIXTURE.ui++, HOOK_FIXTURE.readiness++
    return HOOK_FIXTURE.ready
}
TrySendRunCtrlF1ToLrmc(args*) {
    HOOK_FIXTURE.ui++
    GMTest_Assert(HOOK_FIXTURE.ready && HOOK_FIXTURE.readiness > 0,"Ctrl+F1 follows successful readiness verification")
    HOOK_FIXTURE.resume++
    return true
}
$actual
"@
    [IO.File]::WriteAllText($testPath,$harness,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $testPath $context 20
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'remote startup UI hooks'
    # Prove the specific assertions reject realistic missing-action regressions.
    # Only isolated test copies are mutated; the production source is untouched.
    $mutations=@(
        @{Name='missing-f9';From='if SendHotkeyToLrmc("{F9}", "遠端PAUSE", "PAUSE", generationNonce)';To='if true';Expected='active LRMCAI pause sends exactly one F9'},
        @{Name='missing-readiness';From='if !WaitEscMenuOCR(hwnd, 90)';To='if false';Expected='Ctrl+F1 follows successful readiness verification'},
        @{Name='missing-resume';From='TrySendRunCtrlF1ToLrmc("遠端RUN恢復", generationNonce)';To='WriteLog("test mutation: omitted resume")';Expected='ready game resumes LRMCAI exactly once'}
    )
    foreach($mutation in $mutations) {
        Assert-GMTrue ($actual.Contains($mutation.From)) "Mutation target missing: $($mutation.Name)"
        $mutantPath=Join-Path $context.RunRoot "$($mutation.Name).ahk"
        [IO.File]::WriteAllText($mutantPath,$harness.Replace($mutation.From,$mutation.To),[Text.UTF8Encoding]::new($true))
        $mutant=Invoke-GMTestProcess $mutantPath $context 20
        Assert-GMEqual $mutant.ExitCode 1 "Mutation must fail: $($mutation.Name)"
        Assert-GMTrue ($mutant.Stderr.Contains($mutation.Expected)) "Mutation missed intended assertion: $($mutation.Name)"
        Write-Output "PASS: regression rejected $($mutation.Name)"
    }
} finally {Complete-ProjectDevelopmentPaths -Context $context}
