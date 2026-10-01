[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'runtime-snapshot-throttle'
try {
    $source=Get-Content -LiteralPath (Join-Path $project 'payload\全自動.ahk') -Raw -Encoding UTF8
    $functions=foreach($name in @('ScheduleRuntimeErrorSnapshot','RuntimeErrorSnapshotTick','CaptureRuntimeSnapshot')) {
        $match=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)')
        if(!$match.Success){throw ('Missing real function: '+$name)}
        $match.Value
    }
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
global __RUNTIME_DIAGNOSTICS_ACTIVE := true, __RUNTIME_SNAPSHOT_BUSY := false
global __RUNTIME_LAST_ERROR_SNAPSHOT_TICK := 0, __RUNTIME_ERROR_SNAPSHOT_PENDING := false
global __RUNTIME_PENDING_REASON := "", __RUNTIME_LAST_REMOTE_SNAPSHOT_TICK := 0
global RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT := 30, RUNTIME_DIAGNOSTICS_MAX_WIDTH := 640
global RUNTIME_DIAGNOSTICS_JPEG_QUALITY := 35, REMOTE_CONTROL_ACTIVE := false
global nowMs := 10000, attempts := 0, failCapture := true, timerCalls := 0
global fixtureDir := "__RUN_ROOT__\snapshot-fixture"
MonotonicTickMs() => nowMs
ResolveRuntimeDiagnosticsDir() => fixtureDir
SetTimer(*) {
    global timerCalls
    timerCalls += 1
}
ImagePutFile(spec,path,quality) {
    global attempts,failCapture
    attempts += 1
    if failCapture
        throw Error("pBitmap cannot be zero.")
    ; No screenshot or UI access: model only the successful file-write boundary.
    FileAppend("fixture",path)
}
ImagePutBase64(*) => ""
RC_PublishRuntimeSnapshot(*) => 0
RC_UnixMs() => 0
PruneRuntimeDiagnosticScreenshots(*) => 0
WriteLog(*) => 0
Assert(value,message) {
    if !value
        throw Error(message)
}
try {
    Assert(ScheduleRuntimeErrorSnapshot("first failure"),"first error should schedule")
    RuntimeErrorSnapshotTick()
    Assert(attempts=1 && !__RUNTIME_SNAPSHOT_BUSY && !__RUNTIME_ERROR_SNAPSHOT_PENDING,"failed capture releases flags")
    nowMs += 1
    Assert(!ScheduleRuntimeErrorSnapshot("repeated failure"),"failed capture must also consume the 10 second cooldown")
    nowMs := 19999
    Assert(!ScheduleRuntimeErrorSnapshot("before boundary"),"cooldown must last the entire interval")
    nowMs := 20000
    Assert(ScheduleRuntimeErrorSnapshot("retry after cooldown"),"capture failure must be retryable after cooldown")
    failCapture := false
    RuntimeErrorSnapshotTick()
    Assert(attempts=2 && FileExist(fixtureDir "\latest.jpg"),"retry can recover and preserve latest file")
    nowMs := 20001
    Assert(!ScheduleRuntimeErrorSnapshot("success cooldown"),"successful capture remains throttled")
    nowMs := 30000
    __RUNTIME_SNAPSHOT_BUSY := true
    Assert(!ScheduleRuntimeErrorSnapshot("busy"),"busy capture must not schedule another")
    __RUNTIME_SNAPSHOT_BUSY := false
    __RUNTIME_DIAGNOSTICS_ACTIVE := false
    Assert(!ScheduleRuntimeErrorSnapshot("disabled"),"disabled capture must not schedule another")
    Assert(timerCalls=2,"only initial error and bounded retry should schedule")
    FileAppend("PASS runtime-snapshot failure cooldown and recovery`n","*")
} catch as e {
    FileAppend(e.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
__FUNCTIONS__
'@
    $fixture=$fixture.Replace('__RUN_ROOT__',$context.RunRoot).Replace('__FUNCTIONS__',($functions -join "`n"))
    $testPath=Join-Path $context.RunRoot 'snapshot-throttle.ahk'
    [IO.File]::WriteAllText($testPath,$fixture,[Text.UTF8Encoding]::new($false))
    $result=Invoke-GMTestProcess -ScriptPath $testPath -Context $context
    if($result.Stdout){Write-Output $result.Stdout.TrimEnd()}
    if($result.ExitCode -ne 0){throw $result.Stderr}
} finally { Complete-ProjectDevelopmentPaths -Context $context }
