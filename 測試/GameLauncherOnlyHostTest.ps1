$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'gm-launcher-only-host'
try {
    $source=[IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $actual=[regex]::Match($source,'(?ms)^EnsureWutheringRunning\(\) \{.*?(?=^LaunchWutheringGameFlowAfterUpdate\()').Value
    if(-not $actual){throw 'Missing game start entry'}
    $boot=[regex]::Match($source,'(?ms)^if \(gate.mode = "managed_update"\) \{\r?\n    managedUpdateResult.*?(?=^WriteStep\("鳴潮檢查")').Value
    $ready=[regex]::Match($source,'(?ms)^GM_MarkReady\(\)\r?\n(.*?)(?=^; 5\))').Groups[1].Value
    if(-not $boot -or -not $ready){throw 'Missing main launcher/recording orchestration'}
    $testPath=Join-Path $context.RunRoot 'launcher-only-host.ahk'
    $harness=@"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
global WUTHERING_STARTUP_WAIT_SEC := 1, DIRECT_RUNS := 0, LAUNCHER_CALLS := 0, LAUNCHER_OK := true
global FIXTURE_EVENTS := [], MAIL_NOTIFY_ENABLED := true
GMTest_Run(TestActualStart)
TestActualStart() {
    global DIRECT_RUNS, LAUNCHER_CALLS, LAUNCHER_OK, FIXTURE_EVENTS
    GMTest_Assert(EnsureWutheringRunning(),"verified launcher flow success is returned")
    GMTest_Assert(DIRECT_RUNS = 0 && LAUNCHER_CALLS = 1,"actual entry never runs original game path")
    LAUNCHER_OK := false
    GMTest_Assert(!EnsureWutheringRunning(),"launcher failure must not fall back to direct game executable")
    GMTest_Assert(DIRECT_RUNS = 0 && LAUNCHER_CALLS = 2,"failed launcher still never calls Run(game)")
    LAUNCHER_OK := true, FIXTURE_EVENTS := []
    RunBootFixture("normal")
    GMTest_Assert(FIXTURE_EVENTS.Length = 2 && FIXTURE_EVENTS[1] = "launcher" && FIXTURE_EVENTS[2] = "recording",
        "ordinary recording starts only after launcher/update readiness")
    FIXTURE_EVENTS := []
    RunReadyFixture("normal")
    GMTest_Assert(FIXTURE_EVENTS.Length = 0,"ordinary launcher control does not duplicate maintenance start mail or recording")
    RunReadyFixture("managed_update")
    GMTest_Assert(FIXTURE_EVENTS.Length = 2 && FIXTURE_EVENTS[1] = "recording" && FIXTURE_EVENTS[2] = "mail",
        "maintenance day retains post-ready recording and mail")
}
RunBootFixture(mode) {
    gate := {mode:mode}, isRestart := false
$boot
}
RunReadyFixture(mode) {
    gate := {mode:mode}, isRestart := false
$ready
}
GM_StartLauncherFlow() {
    global LAUNCHER_CALLS, LAUNCHER_OK, FIXTURE_EVENTS
    LAUNCHER_CALLS++
    FIXTURE_EVENTS.Push("launcher")
    return {ok:LAUNCHER_OK,detail:"fixture",errorCode:LAUNCHER_OK ? "" : "STOPPED"}
}
IsWutheringProcessRunning() => false
GetPathWithAsk(args*) => "D:\fixture\Client-Win64-Shipping.exe"
Run(args*) {
    global DIRECT_RUNS
    DIRECT_RUNS++
}
WaitForProcessRunning(args*) => true
WriteStep(args*) => 0
WriteStepResult(args*) => 0
WriteLog(args*) => 0
ShowTip(args*) => 0
Sleep(args*) => 0
GM_RunManagedUpdate() => GM_StartLauncherFlow()
StartCrashWatcher() => 0
TryStartScreenRecording(args*) => FIXTURE_EVENTS.Push("recording")
AttachManagedScreenRecordingOnRestart(args*) => false
GM_IsManagedUpdateDay() => true
SendStartNotifyMail(args*) {
    FIXTURE_EVENTS.Push("mail")
    return {ok:true,message:"fixture"}
}
$actual
"@
    [IO.File]::WriteAllText($testPath,$harness,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $testPath $context 20
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'actual startup uses only launcher controller'
} finally {Complete-ProjectDevelopmentPaths -Context $context}
