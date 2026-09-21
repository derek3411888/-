$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'gm-host-worker'
try {
    $source=[IO.File]::ReadAllText((Join-Path $root 'payload\GameMaintenanceHost.ahk'))
    $functions=@()
    foreach($name in @('GMHost_ProcessStartMs','GMHost_JsonQuote','GMHost_WriteRequest','GMHost_StartWorker','GMHost_WorkerAlive','GMHost_StopWorker')){
        $match=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)')
        if(-not $match.Success){throw ('Missing actual host function '+$name)}
        $functions+=$match.Value
    }
    $testPath=Join-Path $context.RunRoot 'host-worker.ahk'
    $workerSource=Join-Path $root 'payload\GameMaintenanceWorker.ps1'
    # The actual host uses A_ScriptDir. The generated test changes only that data
    # path to the same shipped worker, not its launch/lifecycle implementation.
    $extracted=($functions -join "`n").Replace('A_ScriptDir "\GameMaintenanceWorker.ps1"',('"'+$workerSource+'"'))
    $harness=@"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
#Include $root\payload\GameMaintenance.ahk
#Include $root\payload\RuntimeFilePaths.ahk
GMTest_Run(TestActualHostWorker)
TestActualHostWorker() {
    root := TestRuntime_NewCaseDir("gm-host-native")
    EnvSet("PACK_APP_DIR",root "\program")
    DirCreate(root "\program")
    c := {state:GM_DefaultState(),worker:0,forceRevision:0,launchEntry:root "\missing.exe",lastRequestKey:"",workerMode:"install"}
    worker := GMHost_StartWorker(c)
    try {
        GMTest_Assert(GMHost_WorkerAlive(worker),"actual worker PID and creation time")
        deadline := A_TickCount + 10000
        while !FileExist(worker.outputPath) && A_TickCount < deadline
            Sleep(100)
        GMTest_Assert(FileExist(worker.outputPath),"actual AHK to PS request and snapshot")
        snapshot := GM_ReadWorkerSnapshot(worker.outputPath,worker.requestId,0,RC_UnixMs(),worker.session)
        GMTest_Assert(snapshot["notice"]["outcome"] = "pending","test mode skips HTTP entirely")
        GMTest_Assert(snapshot["install"]["provider"] = "unknown","fake install did not become real game")
        GMHost_StopWorker(worker)
        ProcessWaitClose(worker.pid,2)
        GMTest_Assert(!GMHost_WorkerAlive(worker),"owned helper stopped within two seconds")
    } finally {
        GMHost_StopWorker(worker)
        EnvSet("PACK_APP_DIR","")
    }
}
MonotonicTickMs() {
    return DllCall("GetTickCount64","UInt64")
}
RC_UnixMs() {
    ft := Buffer(8)
    DllCall("GetSystemTimeAsFileTime","Ptr",ft)
    return NumGet(ft,0,"Int64") // 10000 - 11644473600000
}
WriteLog(args*) {
}
$extracted
"@
    [IO.File]::WriteAllText($testPath,$harness,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $testPath $context 20
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'Actual AHK/PowerShell worker lifecycle'
    Write-Output 'PASS: actual host worker launch and stop without game/network actions'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
