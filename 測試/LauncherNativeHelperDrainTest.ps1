[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Checks = 0
$script:Children = New-Object 'System.Collections.Generic.List[System.Diagnostics.Process]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
    $script:Checks++
}

function ConvertTo-AhkLiteral {
    param([string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

function Invoke-IsolatedAhk {
    param(
        [string]$AutoHotkey,
        [string]$ScriptPath,
        [string]$WorkingDirectory,
        [int]$TimeoutMilliseconds = 15000
    )
    $stdoutPath = $ScriptPath + '.stdout.txt'
    $stderrPath = $ScriptPath + '.stderr.txt'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AutoHotkey
    $psi.Arguments = '/ErrorStdOut=UTF-8 "' + $ScriptPath + '"'
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        throw 'Failed to start isolated AutoHotkey fixture.'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        $process.Kill()
        [void]$process.WaitForExit(5000)
        throw 'Isolated AutoHotkey fixture exceeded its bounded timeout.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText($stdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($stderrPath, $stderr, [Text.UTF8Encoding]::new($false))
    if ($process.ExitCode -ne 0) {
        throw ('Isolated AutoHotkey fixture failed: ' + $stderr.Trim())
    }
    return $stdout.Trim()
}

function Start-InertNativeChild {
    param(
        [string]$Executable,
        [int]$Milliseconds,
        [string]$ReadyPath
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Executable
    $psi.Arguments = ([string]$Milliseconds) + ' "' + $ReadyPath + '"'
    $psi.WorkingDirectory = Split-Path $Executable -Parent
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($psi)
    [void]$script:Children.Add($process)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ReadyPath)) {
        if ($process.HasExited) {
            throw ('Inert child exited before readiness: ' + $Executable)
        }
        if ($clock.ElapsedMilliseconds -ge 4000) {
            throw ('Inert child readiness timed out: ' + $Executable)
        }
        Start-Sleep -Milliseconds 20
    }
    return $process
}

$project = Split-Path $PSScriptRoot -Parent
$stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')
$evidenceRoot = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\launcher-native-helper-drain-' + $stamp + '-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
$resultPath = Join-Path $evidenceRoot 'result.txt'

try {
    $policyPath = Join-Path $project 'LauncherProcessCleanupPolicy.ahk'
    $policySource = [IO.File]::ReadAllText($policyPath)
    $launcherCandidates = @(Get-ChildItem -LiteralPath $project -Filter '*.ahk' -File | Where-Object {
        [IO.File]::ReadAllText($_.FullName).Contains('ExtractZipNative(workDir) {')
    })
    Assert-True ($launcherCandidates.Count -eq 1) 'Expected one launcher source containing ExtractZipNative.'
    $launcherPath = $launcherCandidates[0].FullName
    $launcherSource = [IO.File]::ReadAllText($launcherPath)

    $gateNeedle = 'nativeDrain := LauncherCleanup_WaitNativeHelpers(APP_DIR, 45000)'
    $needIndex = $launcherSource.IndexOf('if needUnpack {', [StringComparison]::Ordinal)
    $gateIndex = $launcherSource.IndexOf($gateNeedle, [StringComparison]::Ordinal)
    $backupIndex = $launcherSource.IndexOf('cfgTmp :=', [StringComparison]::Ordinal)
    $extractIndex = $launcherSource.IndexOf('ExtractZipNative(WORK_DIR)', [StringComparison]::Ordinal)
    Assert-True ($needIndex -ge 0 -and $gateIndex -gt $needIndex) 'Native helper drain gate must be inside needUnpack.'
    Assert-True ($backupIndex -gt $gateIndex -and $extractIndex -gt $backupIndex) 'Native helper drain must precede backup and extraction mutations.'
    $gateSegment = $launcherSource.Substring($gateIndex, $backupIndex - $gateIndex)
    Assert-True ($gateSegment.Contains('if !nativeDrain.ok') -and $gateSegment.Contains('ExitApp 1')) 'Native helper drain failure must stop the launcher before extraction.'
    Assert-True (-not $gateSegment.Contains('InstallStartupLock_Release') -and -not $gateSegment.Contains('LauncherRuntimeLock_Release')) 'Native helper drain must retain startup and runtime reservations.'
    $preExtractSegment = $launcherSource.Substring($gateIndex, $extractIndex - $gateIndex)
    Assert-True (-not $preExtractSegment.Contains('Sleep(1000)')) 'The fixed one-second update race must not remain after the drain gate.'

    $drainIndex = $policySource.IndexOf('LauncherCleanup_WaitNativeHelpers(appDir', [StringComparison]::Ordinal)
    $opsIndex = $policySource.IndexOf('LauncherCleanup_NativeDrainDefaultOps()', [StringComparison]::Ordinal)
    Assert-True ($drainIndex -ge 0 -and $opsIndex -gt $drainIndex) 'Native helper drain policy and injectable operations are required.'
    $drainSource = $policySource.Substring($drainIndex, $opsIndex - $drainIndex)
    Assert-True ($drainSource -notmatch 'TerminateProcess|ProcessClose|taskkill|kill\.Call') 'Native helper drain policy must only wait and must never terminate.'
    foreach ($helperName in @('GameMaintenanceWorker.exe','PerformanceTelemetryWorker.exe','RuntimeUtilities.exe','BootstrapAssets.exe','LauncherMaintenance.exe')) {
        Assert-True ($policySource.Contains('"' + $helperName + '"')) ('Missing exact native helper allowlist entry: ' + $helperName)
    }

    $autoHotkey = Join-Path $project 'AutoHotkey64.exe'
    Assert-True (Test-Path -LiteralPath $autoHotkey -PathType Leaf) 'AutoHotkey64.exe is required for isolated policy fixtures.'
    $baselineAhk = @(Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue)
    Assert-True ($baselineAhk.Count -eq 0) 'Serialized native helper drain test requires an AutoHotkey baseline of zero.'

    $pureFixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __POLICY__

global scenario := "", fakeTick := 0, fakeRunning := false, waitCount := 0
global inventoryCount := 0, openCount := 0, closeCount := 0, expected := 0, foreign := 0

Check(ok, message) {
    if !ok
        throw Error(message)
}

ResetScenario(name, appDir) {
    global scenario, fakeTick, fakeRunning, waitCount, inventoryCount, openCount, closeCount, expected, foreign
    scenario := name, fakeTick := 0, fakeRunning := true, waitCount := 0
    inventoryCount := 0, openCount := 0, closeCount := 0
    expected := {Name:"GameMaintenanceWorker.exe",ProcessId:4101,
        CreationDate:"20261001170000.000000+480",ExecutablePath:appDir "\GameMaintenanceWorker.exe"}
    foreign := {Name:"GameMaintenanceWorker.exe",ProcessId:5101,
        CreationDate:"20261001170001.000000+480",ExecutablePath:appDir "\..\foreign\GameMaintenanceWorker.exe"}
}

FakeInventory() {
    global scenario, inventoryCount, fakeRunning, expected, foreign
    inventoryCount += 1
    if (scenario = "inventory-error")
        throw Error("inventory denied")
    if (scenario = "foreign")
        return [foreign]
    if (scenario = "unreadable")
        return [{Name:expected.Name,ProcessId:expected.ProcessId,CreationDate:expected.CreationDate,ExecutablePath:""}]
    if (scenario = "new" && inventoryCount = 1)
        return []
    return fakeRunning ? [expected] : []
}

FakeOpen(pid) {
    global scenario, openCount, fakeRunning
    openCount += 1
    if (scenario = "stale-open") {
        fakeRunning := false
        return 0
    }
    return 77
}

FakeQuery(pid) {
    global scenario, fakeRunning, expected
    if !fakeRunning
        return 0
    if (scenario = "reused") {
        replacement := expected.Clone()
        replacement.CreationDate := "20261001170002.000000+480"
        return replacement
    }
    return expected.Clone()
}

FakeAlive(handle) {
    global scenario, fakeRunning
    if (scenario = "exited-after-open")
        fakeRunning := false
    return fakeRunning
}

FakeImage(handle) {
    global expected
    return expected.ExecutablePath
}

FakeCreated(handle) {
    return 134116000000000000
}

FakeWait(handle, milliseconds) {
    global scenario, fakeTick, fakeRunning, waitCount
    fakeTick += milliseconds, waitCount += 1
    if (scenario = "timeout")
        return 258
    if (scenario = "slow" && waitCount < 2)
        return 258
    fakeRunning := false
    return 0
}

FakeClose(handle) {
    global closeCount
    closeCount += 1
}

FakeNow() {
    global fakeTick
    return fakeTick
}

FakeSleep(milliseconds) {
    global fakeTick
    fakeTick += milliseconds
}

try {
    appDir := __APPDIR__
    ops := {inventory:FakeInventory,open:FakeOpen,query:FakeQuery,alive:FakeAlive,
        image:FakeImage,created:FakeCreated,wait:FakeWait,close:FakeClose,now:FakeNow,sleep:FakeSleep}

    for helperName in ["GameMaintenanceWorker.exe","PerformanceTelemetryWorker.exe",
        "RuntimeUtilities.exe","BootstrapAssets.exe","LauncherMaintenance.exe"]
        Check(LauncherCleanup_IsNativeHelperName(helperName),"allowlist rejected " helperName)

    ResetScenario("slow",appDir)
    result := LauncherCleanup_WaitNativeHelpers(appDir,1000,ops)
    Check(result.ok && result.waited && waitCount >= 2,"slow owned helper was not drained")

    ResetScenario("timeout",appDir)
    result := LauncherCleanup_WaitNativeHelpers(appDir,250,ops)
    Check(!result.ok && result.reason = "timeout" && fakeRunning,"timeout killed or accepted a live helper")
    Check(closeCount > 0,"timeout leaked retained helper handles")

    ResetScenario("foreign",appDir)
    result := LauncherCleanup_WaitNativeHelpers(appDir,1000,ops)
    Check(result.ok && openCount = 0 && fakeRunning,"foreign same-name helper was opened or changed")

    ResetScenario("unreadable",appDir)
    result := LauncherCleanup_WaitNativeHelpers(appDir,1000,ops)
    Check(!result.ok && InStr(result.reason,"unverifiable"),"unreadable exact-name candidate did not fail closed")

    ResetScenario("reused",appDir)
    result := LauncherCleanup_WaitNativeHelpers(appDir,1000,ops)
    Check(!result.ok && InStr(result.reason,"identity"),"PID creation reuse did not fail closed")

    ResetScenario("stale-open",appDir)
    result := LauncherCleanup_WaitNativeHelpers(appDir,1000,ops)
    Check(result.ok,"stale exited inventory record blocked drain")

    ResetScenario("exited-after-open",appDir)
    result := LauncherCleanup_WaitNativeHelpers(appDir,1000,ops)
    Check(result.ok && closeCount > 0,"exited retained candidate blocked drain or leaked handle")

    ResetScenario("new",appDir)
    result := LauncherCleanup_WaitNativeHelpers(appDir,1000,ops)
    Check(result.ok && result.waited && inventoryCount >= 3 && openCount > 0,"new helper candidate was missed between clear scans")

    ResetScenario("inventory-error",appDir)
    result := LauncherCleanup_WaitNativeHelpers(appDir,1000,ops)
    Check(!result.ok && InStr(result.reason,"inventory"),"inventory failure did not fail closed")

    FileAppend("PASS pure native helper drain policy`n","*")
} catch as fixtureError {
    FileAppend(fixtureError.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
'@
    $purePath = Join-Path $evidenceRoot 'pure-drain.ahk'
    $pureFixture = $pureFixture.Replace('__POLICY__', $policyPath).Replace('__APPDIR__', (ConvertTo-AhkLiteral (Join-Path $evidenceRoot 'pure-payload')))
    [IO.File]::WriteAllText($purePath, $pureFixture, [Text.UTF8Encoding]::new($false))
    $pureOutput = Invoke-IsolatedAhk -AutoHotkey $autoHotkey -ScriptPath $purePath -WorkingDirectory $evidenceRoot
    Assert-True ($pureOutput.Contains('PASS pure native helper drain policy')) 'Pure native helper drain fixture did not report success.'

    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    Assert-True (Test-Path -LiteralPath $compiler -PathType Leaf) 'The .NET Framework C# compiler is required for inert native proof.'
    $childSourcePath = Join-Path $evidenceRoot 'InertNativeChild.cs'
    $childBinaryPath = Join-Path $evidenceRoot 'InertNativeChild.exe'
    $childSource = @'
using System;
using System.IO;
using System.Threading;
internal static class InertNativeChild
{
    private static int Main(string[] args)
    {
        int milliseconds;
        if (args.Length != 2 || !Int32.TryParse(args[0], out milliseconds) || milliseconds < 1)
            return 2;
        File.WriteAllText(args[1], System.Diagnostics.Process.GetCurrentProcess().Id.ToString());
        Thread.Sleep(milliseconds);
        return 0;
    }
}
'@
    [IO.File]::WriteAllText($childSourcePath, $childSource, [Text.UTF8Encoding]::new($false))
    $compileOutput = & $compiler /nologo /target:exe /platform:anycpu ('/out:' + $childBinaryPath) $childSourcePath 2>&1
    Assert-True ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $childBinaryPath)) ('Inert child compilation failed: ' + ($compileOutput -join [Environment]::NewLine))

    $payloadDir = Join-Path $evidenceRoot 'install\payload'
    $foreignDir = Join-Path $evidenceRoot 'foreign'
    [IO.Directory]::CreateDirectory($payloadDir) | Out-Null
    [IO.Directory]::CreateDirectory($foreignDir) | Out-Null
    $ownSlowPath = Join-Path $payloadDir 'GameMaintenanceWorker.exe'
    $foreignPath = Join-Path $foreignDir 'GameMaintenanceWorker.exe'
    $ownTimeoutPath = Join-Path $payloadDir 'PerformanceTelemetryWorker.exe'
    Copy-Item -LiteralPath $childBinaryPath -Destination $ownSlowPath
    Copy-Item -LiteralPath $childBinaryPath -Destination $foreignPath
    Copy-Item -LiteralPath $childBinaryPath -Destination $ownTimeoutPath

    $slowReady = Join-Path $evidenceRoot 'slow.ready'
    $foreignReady = Join-Path $evidenceRoot 'foreign.ready'
    $slowProcess = Start-InertNativeChild -Executable $ownSlowPath -Milliseconds 1400 -ReadyPath $slowReady
    $foreignProcess = Start-InertNativeChild -Executable $foreignPath -Milliseconds 12000 -ReadyPath $foreignReady

    $actualFixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __POLICY__
Check(ok,message) {
    if !ok
        throw Error(message)
}
try {
    started := A_TickCount
    result := LauncherCleanup_WaitNativeHelpers(__APPDIR__,5000)
    elapsed := A_TickCount - started
    Check(result.ok && result.waited,"owned inert helper was not drained")
    Check(elapsed >= 250,"drain returned before the slow owned helper exited")
    Check(ProcessExist(__FOREIGNPID__),"foreign same-name helper was terminated")
    FileAppend("PASS actual slow-owned and foreign-ignore elapsed=" elapsed "`n","*")
} catch as fixtureError {
    FileAppend(fixtureError.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
'@
    $actualFixture = $actualFixture.Replace('__POLICY__', $policyPath).Replace('__APPDIR__', (ConvertTo-AhkLiteral $payloadDir)).Replace('__FOREIGNPID__', [string]$foreignProcess.Id)
    $actualPath = Join-Path $evidenceRoot 'actual-slow-foreign.ahk'
    [IO.File]::WriteAllText($actualPath, $actualFixture, [Text.UTF8Encoding]::new($false))
    $actualOutput = Invoke-IsolatedAhk -AutoHotkey $autoHotkey -ScriptPath $actualPath -WorkingDirectory $evidenceRoot
    Assert-True ($actualOutput.Contains('PASS actual slow-owned and foreign-ignore')) 'Actual slow/foreign native proof did not report success.'
    $slowProcess.Refresh()
    $foreignProcess.Refresh()
    Assert-True $slowProcess.HasExited 'Slow owned helper remained alive after a successful drain.'
    Assert-True (-not $foreignProcess.HasExited) 'Foreign same-name helper was killed by the drain policy.'

    $timeoutReady = Join-Path $evidenceRoot 'timeout.ready'
    $timeoutProcess = Start-InertNativeChild -Executable $ownTimeoutPath -Milliseconds 12000 -ReadyPath $timeoutReady
    $timeoutFixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __POLICY__
Check(ok,message) {
    if !ok
        throw Error(message)
}
try {
    result := LauncherCleanup_WaitNativeHelpers(__APPDIR__,350)
    Check(!result.ok && result.reason = "timeout","live owned helper did not produce a bounded timeout")
    Check(ProcessExist(__OWNPID__),"timeout path terminated the owned helper")
    FileAppend("PASS actual timeout preserves live owned helper`n","*")
} catch as fixtureError {
    FileAppend(fixtureError.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
'@
    $timeoutFixture = $timeoutFixture.Replace('__POLICY__', $policyPath).Replace('__APPDIR__', (ConvertTo-AhkLiteral $payloadDir)).Replace('__OWNPID__', [string]$timeoutProcess.Id)
    $timeoutPath = Join-Path $evidenceRoot 'actual-timeout.ahk'
    [IO.File]::WriteAllText($timeoutPath, $timeoutFixture, [Text.UTF8Encoding]::new($false))
    $timeoutOutput = Invoke-IsolatedAhk -AutoHotkey $autoHotkey -ScriptPath $timeoutPath -WorkingDirectory $evidenceRoot
    Assert-True ($timeoutOutput.Contains('PASS actual timeout preserves live owned helper')) 'Actual timeout native proof did not report success.'
    $timeoutProcess.Refresh()
    Assert-True (-not $timeoutProcess.HasExited) 'Timed-out owned helper was terminated instead of preserved.'

    $postAhk = @(Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue)
    Assert-True ($postAhk.Count -eq 0) 'Isolated native helper drain fixtures left AutoHotkey processes behind.'

    $summary = 'PASS launcher native helper drain: ' + $script:Checks + ' checks; evidence=' + $evidenceRoot
    [IO.File]::WriteAllText($resultPath, $summary + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Output $summary
} catch {
    [IO.File]::WriteAllText($resultPath, ('FAIL: ' + $_.Exception.Message + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    throw
} finally {
    foreach ($child in $script:Children) {
        try {
            $child.Refresh()
            if (-not $child.HasExited) {
                $child.Kill()
                [void]$child.WaitForExit(5000)
            }
        } catch {
            Write-Warning ('Controlled inert child cleanup failed: ' + $_.Exception.Message)
        } finally {
            $child.Dispose()
        }
    }
}
