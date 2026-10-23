[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'remote-update-restart-host'
try {
    $source=[IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $functions=''
    foreach($name in @('PrepareRestartRecoveryAttempt','TryQueueSafeRestartHandoff','ShutdownGameLrmcOkww','ResolveShutdownStopType')) {
        $fn=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)').Value
        Assert-GMTrue ([bool]$fn) "Missing production function $name"
        $functions+="`n$fn"
    }
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __ROOT__\測試\GameMaintenanceFixtures.ahk
global AhkExe := A_AhkPath, __RESTART_HANDOFF_LAUNCHED := false, __SCREEN_RECORDING_PID := 0
global __RESTART_IN_PROGRESS := true, __NEXTSERVER_RESTART := false, __CLEAN_FINAL_EXIT_REQUESTED := false
global MAIL_NOTIFY_ENABLED := false, calls := [], captured := [], queue := [], resumeCleared := 0
global drainAllowed := true
GMTest_Run(TestHost)
TestHost() {
    global calls, captured, queue, resumeCleared, __RESTART_IN_PROGRESS, __RESTART_HANDOFF_LAUNCHED, drainAllowed
    drainAllowed := false
    rejected := false
    try PrepareRestartRecoveryAttempt("restart resume","C:\fixture\全自動鋤地.exe",true)
    catch
        rejected := true
    GMTest_Assert(rejected && captured.Length = 0,"refused helper close keeps updater unarmed")
    rejected := false
    try TryQueueSafeRestartHandoff("restart resume","C:\fixture\全自動鋤地.exe",true)
    catch
        rejected := true
    GMTest_Assert(rejected && captured.Length = 0,"fresh final drain gate rejects a reappeared helper")
    drainAllowed := true, calls := []
    TryQueueSafeRestartHandoff("restart resume","C:\fixture\全自動鋤地.exe",true)
    GMTest_Assert(captured[5] = "C:\fixture\全自動鋤地.exe" && captured[9],"explicit web restart requires updater and cannot fall back silently")
    TryQueueSafeRestartHandoff("restart resume","C:\fixture\全自動鋤地.exe")
    GMTest_Assert(captured[5] = "" && !captured[9],"ordinary recovery remains local and avoids update network dependency")
    __RESTART_IN_PROGRESS := true, __RESTART_HANDOFF_LAUNCHED := false
    ShutdownGameLrmcOkww(true,"WEB_RESTART_UPDATE","restart resume")
    GMTest_Assert(calls[1] = "recording-stop","update restart finalizes recording before closing managed apps")
    GMTest_Assert(queue[1] = "restart resume" && queue[2] = "C:\fixture\全自動鋤地.exe" && queue[3],"shutdown uses current task update path, never nextserver")
    GMTest_Assert(resumeCleared = 0,"update restart preserves LRMCAI resume journal")
    GMTest_Assert(calls[calls.Length] = "exit","parent exits only after handoff was armed")
}
GM_PrepareCleanLauncherRestart(&detail) => true
RRD_AssertDrained(&detail) => drainAllowed
RestartHandoff_ResetCancelled() => true
ReadRestartRecoveryIntent() => {state:"RUN"}
RestartHandoff_Prepare(args*) {
    global captured
    captured := args
    return {workerPid:99,request:"fixture"}
}
RestartHandoff_RecorderIdentity(args*) => 0
RuntimeFiles_RuntimeDir(args*) => A_ScriptDir
WriteLog(args*) => 0
WriteStep(args*) => 0
ShowTip(args*) => 0
GM_CancelForStop(args*) => 0
RestartHandoff_Cancel(args*) => true
SetLrmcRunResumeReady(args*) {
    global resumeCleared
    resumeCleared += 1
}
ForceStopManagedScreenRecording(args*) => calls.Push("recording-stop")
UnmuteWutheringAudio(args*) => 0
CloseExactProcessForSelfHealing(args*) => calls.Push("close")
RawSleep(args*) => 0
CloseOkwwPythonProcesses(args*) => 0
SetTimer(args*) => 0
CrashWatcherTick(args*) => 0
CloseManagedAhkForSelfHealing(args*) => 0
SendShutdownNotifyMail(args*) => {ok:true}
QueueSafeRestartHandoff(args*) {
    global queue, __RESTART_HANDOFF_LAUNCHED
    queue := args, __RESTART_HANDOFF_LAUNCHED := true
}
ResolvePersistentToolsRoot() => "C:\fixture"
RC_MarkActiveStopSideEffectsComplete(args*) => 0
ExitApp(args*) => calls.Push("exit")
__FUNCTIONS__
'@
    $path=Join-Path $context.RunRoot 'host.ahk'
    [IO.File]::WriteAllText($path,$fixture.Replace('__ROOT__',$root).Replace('__FUNCTIONS__',$functions),[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $path $context 20
    Write-Output $result.Stdout
    Write-Output $result.Stderr
    Assert-GMEqual $result.ExitCode 0 'Web update restart uses formal launcher after full close'
} finally {Complete-ProjectDevelopmentPaths -Context $context}
