[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
function Assert-NoLiveGameForTelemetryTest {
    $liveGames = @(Get-CimInstance Win32_Process -Filter "Name = 'Client-Win64-Shipping.exe'")
    if ($liveGames.Count -ne 0) {
        throw 'Real telemetry adapter acceptance requires no live game; leave the game untouched and stop this test.'
    }
}
Assert-NoLiveGameForTelemetryTest
$project = Split-Path $PSScriptRoot -Parent
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$run = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\native-telemetry-' + $stamp + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void][IO.Directory]::CreateDirectory($run)

function Invoke-IsolatedAhkFixture {
    param(
        [Parameter(Mandatory=$true)][string]$Runtime,
        [Parameter(Mandatory=$true)][string]$Fixture,
        [Parameter(Mandatory=$true)][string]$WorkingDirectory,
        [Parameter(Mandatory=$true)][int]$TimeoutMilliseconds,
        [Parameter(Mandatory=$true)][string]$StdoutPath,
        [Parameter(Mandatory=$true)][string]$StderrPath
    )

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Runtime
    $start.Arguments = '/ErrorStdOut=UTF-8 "' + $Fixture + '"'
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    if (-not $process.Start()) { throw 'Cannot start isolated AHK telemetry adapter fixture.' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = $false
    try {
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $timedOut = $true
            $process.Kill()
            if (-not $process.WaitForExit(5000)) {
                throw 'Exact retained AHK telemetry fixture did not exit after kill.'
            }
        }
        if (-not [Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000)) {
            throw 'AHK telemetry fixture redirected streams did not close.'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($StdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($StderrPath, $stderr, [Text.UTF8Encoding]::new($false))
        if ($timedOut) { throw 'Isolated AHK telemetry adapter test timed out.' }
        if ($process.ExitCode -ne 0) {
            throw ('Isolated AHK telemetry adapter failed: exit=' + $process.ExitCode +
                ' stdout=' + $stdout + ' stderr=' + $stderr)
        }
        return $stdout
    } finally {
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

function Get-ExactExecutableProcesses {
    param([Parameter(Mandatory=$true)][string]$Path)

    $expected = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $name = [IO.Path]::GetFileName($expected).Replace("'", "''")
    return @(Get-CimInstance Win32_Process -Filter ("Name='" + $name + "'") | Where-Object {
        if ([string]::IsNullOrWhiteSpace($_.ExecutablePath)) { return $false }
        try { return [IO.Path]::GetFullPath($_.ExecutablePath).TrimEnd('\') -ieq $expected }
        catch { return $false }
    })
}

function Wait-ExactFixtureProcessesExit {
    param([Parameter(Mandatory=$true)][string[]]$Paths, [int]$TimeoutMilliseconds = 8000)

    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $remaining = @($Paths | ForEach-Object { Get-ExactExecutableProcesses -Path $_ })
        if ($remaining.Count -eq 0) { return @() }
        Start-Sleep -Milliseconds 100
    } while ($timer.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    return @($Paths | ForEach-Object { Get-ExactExecutableProcesses -Path $_ })
}

$ahkBefore = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%' OR Name = 'AutoHotkey.exe'")
if ($ahkBefore.Count -ne 0) {
    throw 'Native performance telemetry acceptance requires zero AHK baseline.'
}

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'The Windows .NET Framework C# compiler is required.'
}

$nativeRoot = Join-Path $project 'native-helper'
$framework = Join-Path $nativeRoot 'FrameworkTarget.cs'
$production = @(
    Join-Path $nativeRoot 'PerformanceTelemetryModel.cs'
    Join-Path $nativeRoot 'PerformanceTelemetryCollectors.cs'
    Join-Path $nativeRoot 'PerformanceTelemetryWorker.cs'
)
$worker = Join-Path $run 'PerformanceTelemetryWorker.exe'
$workerCompileLog = Join-Path $run 'worker-compile.txt'
& $compiler /nologo /warnaserror /langversion:5 /optimize+ /target:exe `
    /r:System.Web.Extensions.dll /r:System.Management.dll `
    /main:Wuthering.Native.PerformanceTelemetryWorker ('/out:' + $worker) `
    $framework @production 2>&1 | Tee-Object -FilePath $workerCompileLog
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $worker)) {
    throw 'Native performance telemetry worker compilation failed.'
}

$tests = Join-Path $run 'PerformanceTelemetryWorkerTests.exe'
$testSource = Join-Path $PSScriptRoot 'native\PerformanceTelemetryWorkerTests.cs'
$testCompileLog = Join-Path $run 'tests-compile.txt'
& $compiler /nologo /warnaserror /langversion:5 /target:exe `
    /r:System.Web.Extensions.dll /r:System.Management.dll `
    /main:PerformanceTelemetryWorkerTests ('/out:' + $tests) `
    $framework @production $testSource 2>&1 | Tee-Object -FilePath $testCompileLog
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tests)) {
    throw 'Native performance telemetry tests compilation failed.'
}

$testRoot = Join-Path $run 'fixtures'
$testLog = Join-Path $run 'tests.txt'
& $tests $testRoot $worker 2>&1 | Tee-Object -FilePath $testLog
if ($LASTEXITCODE -ne 0) {
    throw 'Native performance telemetry regression failed.'
}

$install = Join-Path $run 'adapter-install'
[void][IO.Directory]::CreateDirectory($install)
$installedWorker = Join-Path $install 'PerformanceTelemetryWorker.exe'
$installedAdapter = Join-Path $install 'PerformanceTelemetry.ahk'
$installedRuntimePaths = Join-Path $install 'RuntimeFilePaths.ahk'
[IO.File]::Copy($worker, $installedWorker, $true)
[IO.File]::Copy((Join-Path $project 'payload\PerformanceTelemetry.ahk'), $installedAdapter, $true)
[IO.File]::Copy((Join-Path $project 'payload\RuntimeFilePaths.ahk'), $installedRuntimePaths, $true)

$presentMonDir = Join-Path $install 'tools\PresentMon'
$installedPresentMon = Join-Path $presentMonDir 'PresentMon.exe'
# No PresentMon binary is needed or staged: a real no-game collector must
# remain waiting_game and must never download/launch an FPS capture session.

if ((Get-ExactExecutableProcesses -Path $installedWorker).Count -ne 0 -or
    (Get-ExactExecutableProcesses -Path $installedPresentMon).Count -ne 0) {
    throw 'The unique telemetry adapter fixture already has a managed process.'
}

$fixturePath = Join-Path $install 'PerformanceTelemetryAdapterIntegration.ahk'
$fixtureSource = @'
#Requires AutoHotkey v2.0+
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include RuntimeFilePaths.ahk
#Include PerformanceTelemetry.ahk

global CURRENT_STEP_NAME := ""
global CURRENT_STEP_DETAIL := ""
global CURRENT_SERVER_TARGET := ""

AssertAdapter(condition, message) {
    if !condition
        throw Error(message)
}

RC_JsonEsc(text) {
    return String(text)
}

adapterWorkerPid := 0
adapterWorkerCreation := 0
adapterParentPid := 0
adapterParentCreation := 0
adapterParentExe := ""
adapterFinalJson := ""
adapterFinalCollector := 0
adapterFailure := ""

try {
    AssertAdapter(!ProcessExist("Client-Win64-Shipping.exe"), "Live game detected; do not start test telemetry")
    AssertAdapter(PerformanceTelemetry_Start(), "PerformanceTelemetry_Start returned false")
    adapterWorkerPid := PERF_TELEMETRY_PID
    adapterWorkerCreation := PERF_TELEMETRY_WORKER_CREATION_FILETIME
    adapterParentPid := PERF_TELEMETRY_PARENT_PID
    adapterParentCreation := PERF_TELEMETRY_PARENT_CREATION_FILETIME
    adapterParentExe := PERF_TELEMETRY_PARENT_EXE_PATH
    AssertAdapter(adapterWorkerPid > 0, "adapter did not retain worker PID")
    AssertAdapter(PERF_TELEMETRY_PROCESS_HANDLE != 0, "adapter did not retain worker handle")
    AssertAdapter(adapterWorkerCreation > 0, "adapter did not retain worker creation time")
    AssertAdapter(adapterParentPid = DllCall("Kernel32\GetCurrentProcessId", "uint"),
        "adapter parent PID does not name this AHK fixture")

    adapterParentIdentity := PerformanceTelemetry_ReadProcessIdentity(
        DllCall("Kernel32\GetCurrentProcess", "ptr"), adapterParentPid)
    AssertAdapter(PerformanceTelemetry_ProcessIdentityMatches(adapterParentIdentity,
        adapterParentPid, adapterParentCreation, adapterParentExe), "adapter parent identity mismatch")
    adapterWorkerIdentity := PerformanceTelemetry_ReadProcessIdentity(
        PERF_TELEMETRY_PROCESS_HANDLE, adapterWorkerPid)
    AssertAdapter(PerformanceTelemetry_ProcessIdentityMatches(adapterWorkerIdentity,
        adapterWorkerPid, adapterWorkerCreation, PERF_TELEMETRY_WORKER_PATH),
        "adapter worker identity mismatch")

    foundWmiChild := false
    for adapterProc in ComObjGet("winmgmts:").ExecQuery(
            "Select ProcessId,ParentProcessId,ExecutablePath,CommandLine from Win32_Process where ProcessId=" adapterWorkerPid) {
        actualExe := ""
        actualCommand := ""
        actualParent := 0
        try actualExe := String(adapterProc.ExecutablePath)
        try actualCommand := String(adapterProc.CommandLine)
        try actualParent := Integer(adapterProc.ParentProcessId)
        AssertAdapter(actualParent = adapterParentPid, "worker WMI parent PID mismatch")
        AssertAdapter(PerformanceTelemetry_CanonicalPath(actualExe)
            = PerformanceTelemetry_CanonicalPath(PERF_TELEMETRY_WORKER_PATH),
            "worker WMI executable path mismatch")
        AssertAdapter(PerformanceTelemetry_CommandLineMatchesWorker(actualCommand,
            PERF_TELEMETRY_WORKER_PATH, PERF_TELEMETRY_ROOT, adapterParentPid,
            adapterParentCreation, adapterParentExe, PERF_TELEMETRY_CONFIG_PATH),
            "worker WMI command line does not match adapter ownership contract")
        foundWmiChild := true
    }
    AssertAdapter(foundWmiChild, "worker was not observable as the exact AHK child")

    initialUpdatedAt := 0
    initialDeadline := PerformanceTelemetry_MonotonicMs() + 10000
    while (PerformanceTelemetry_MonotonicMs() < initialDeadline) {
        initialJson := PerformanceTelemetry_ReadHeartbeatJson()
        initialCollector := PerformanceTelemetry_InspectCollector(initialJson)
        if initialCollector.valid {
            initialUpdatedAt := initialCollector.updatedAt
            break
        }
        Sleep(50)
    }
    AssertAdapter(initialUpdatedAt > 0, "native worker did not publish startup heartbeat")

    updateDeadline := PerformanceTelemetry_MonotonicMs() + 25000
    while (PerformanceTelemetry_MonotonicMs() < updateDeadline) {
        candidate := PerformanceTelemetry_ReadHeartbeatJson()
        inspected := PerformanceTelemetry_InspectCollector(candidate)
        if (inspected.valid && inspected.updatedAt > initialUpdatedAt
                && RegExMatch(candidate, 'i)"current"\s*:\s*\{')) {
            adapterFinalJson := candidate
            adapterFinalCollector := inspected
            break
        }
        Sleep(100)
    }
    AssertAdapter(adapterFinalJson != "", "native heartbeat did not advance to a real host sample")
    AssertAdapter(adapterFinalCollector.updatedAt > initialUpdatedAt,
        "native heartbeat updatedAt did not advance")
    AssertAdapter(PerformanceTelemetry_JsonScalar(adapterFinalJson, "gameRunning") = "false",
        "Real adapter fixture must never sample a live game")
    AssertAdapter(PerformanceTelemetry_JsonScalar(adapterFinalJson, "presentMon") = "waiting_game",
        "No-game adapter fixture must not start a PresentMon session")
} catch as e {
    adapterFailure := e.Message " | what=" e.What " | file=" e.File " | line=" e.Line "`n" e.Stack
} finally {
    try PerformanceTelemetry_Stop(10000)
    catch as stopError {
        if (adapterFailure = "")
            adapterFailure := "PerformanceTelemetry_Stop failed: " stopError.Message
    }
}

if (adapterWorkerPid > 0 && ProcessExist(adapterWorkerPid)) {
    deadline := PerformanceTelemetry_MonotonicMs() + 5000
    while (ProcessExist(adapterWorkerPid) && PerformanceTelemetry_MonotonicMs() < deadline)
        Sleep(50)
}
if (adapterWorkerPid > 0 && ProcessExist(adapterWorkerPid) && adapterFailure = "")
    adapterFailure := "exact native worker remained alive after PerformanceTelemetry_Stop"
if (PERF_TELEMETRY_PROCESS_HANDLE != 0 && adapterFailure = "")
    adapterFailure := "adapter retained a worker handle after PerformanceTelemetry_Stop"

if (adapterFailure != "") {
    FileAppend(adapterFailure "`n", "**")
    ExitApp(1)
}

adapterFps := PerformanceTelemetry_JsonScalar(adapterFinalJson, "fps")
adapterCpu := PerformanceTelemetry_JsonScalar(adapterFinalJson, "cpuTotalPct")
adapterGpu := PerformanceTelemetry_JsonScalar(adapterFinalJson, "gpuPct")
adapterPresentMon := PerformanceTelemetry_JsonScalar(adapterFinalJson, "presentMon")
adapterGameRunning := PerformanceTelemetry_JsonScalar(adapterFinalJson, "gameRunning")
FileAppend("PASS isolated telemetry adapter Start/heartbeat/Stop"
    . " workerPid=" adapterWorkerPid " workerCreation=" adapterWorkerCreation
    . " parentPid=" adapterParentPid " parentCreation=" adapterParentCreation
    . " state=" adapterFinalCollector.state " presentMon=" adapterPresentMon
    . " fps=" adapterFps " cpuTotalPct=" adapterCpu " gpuPct=" adapterGpu
    . " gameRunning=" adapterGameRunning "`n", "*")
ExitApp(0)
'@
[IO.File]::WriteAllText($fixturePath, $fixtureSource, [Text.UTF8Encoding]::new($false))

$ahkRuntime = Join-Path $project 'AutoHotkey64.exe'
if (-not (Test-Path -LiteralPath $ahkRuntime -PathType Leaf)) {
    $ahkRuntime = Join-Path $project 'payload\AutoHotkey64.exe'
}
if (-not (Test-Path -LiteralPath $ahkRuntime -PathType Leaf)) {
    throw 'AutoHotkey v2 runtime is required for the isolated telemetry adapter integration.'
}
$ahkStdout = Join-Path $run 'adapter-ahk.stdout.txt'
$ahkStderr = Join-Path $run 'adapter-ahk.stderr.txt'
$ahkOutput = $null
$adapterError = $null
try {
    Assert-NoLiveGameForTelemetryTest
    $ahkOutput = Invoke-IsolatedAhkFixture -Runtime $ahkRuntime -Fixture $fixturePath `
        -WorkingDirectory $install -TimeoutMilliseconds 42000 `
        -StdoutPath $ahkStdout -StderrPath $ahkStderr
} catch {
    $adapterError = $_
} finally {
    $remaining = Wait-ExactFixtureProcessesExit -Paths @($installedWorker, $installedPresentMon) -TimeoutMilliseconds 8000
    if ($remaining.Count -ne 0) {
        foreach ($record in $remaining) {
            $owned = Get-Process -Id $record.ProcessId -ErrorAction SilentlyContinue
            if ($owned) {
                try {
                    if ([IO.Path]::GetFullPath($owned.Path).TrimEnd('\') -ieq
                        [IO.Path]::GetFullPath($record.ExecutablePath).TrimEnd('\')) {
                        Stop-Process -InputObject $owned -Force -ErrorAction Stop
                        [void]$owned.WaitForExit(5000)
                    }
                } finally { $owned.Dispose() }
            }
        }
        if (-not $adapterError) {
            $adapterError = [InvalidOperationException]::new(
                'A managed native telemetry or PresentMon child remained after isolated AHK Stop.')
        }
    }
}
if ($adapterError) { throw $adapterError }
Write-Output $ahkOutput.TrimEnd()

$adapterSummary = [ordered]@{
    ok = $true
    ahkBefore = $ahkBefore.Count
    liveGameRequiredAbsent = $true
    presentMonStaged = $false
    installedWorker = $installedWorker
    installedPresentMon = $installedPresentMon
    adapterOutput = $ahkOutput.Trim()
    formalEntryPointLaunched = $false
    gameManipulated = $false
}
[IO.File]::WriteAllText((Join-Path $run 'adapter-summary.json'),
    ($adapterSummary | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

$ahkAfter = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%' OR Name = 'AutoHotkey.exe'")
if ($ahkAfter.Count -ne 0) {
    throw 'Zero-AHK postcondition failed.'
}

Write-Output ('PASS: native performance telemetry; AHK=0; evidence=' + $run)
