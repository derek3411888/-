[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$ahkBefore = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%' OR Name = 'AutoHotkey.exe'")
if ($ahkBefore.Count) { throw 'Native RuntimeUtilities acceptance requires zero AHK baseline' }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$run = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\native-utilities-' + $stamp)
[void][IO.Directory]::CreateDirectory($run)
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler is required' }

$native = Join-Path $project 'native-helper'
$framework = Join-Path $native 'FrameworkTarget.cs'
$source = Join-Path $native 'RuntimeUtilities.cs'
$testSource = Join-Path $PSScriptRoot 'native\RuntimeUtilitiesTests.cs'
$helper = Join-Path $run 'RuntimeUtilities.exe'
$tests = Join-Path $run 'RuntimeUtilitiesTests.exe'
$adapterPath = Join-Path $project 'payload\NativeRuntimeUtilities.ahk'
$adapterText = [IO.File]::ReadAllText($adapterPath)

$createPipeBody = [Text.RegularExpressions.Regex]::Match(
    $adapterText,
    '(?s)NativeRuntime_CreateInputPipe\([^\r\n]*\)\s*\{.*?(?=\r?\nNativeRuntime_NewOverlapped\()')
if (-not $createPipeBody.Success -or
    $createPipeBody.Value.IndexOf('NativeRuntime_CancelOverlapped(&parentWrite', [StringComparison]::Ordinal) -lt 0) {
    throw 'CreateInputPipe failure must transfer a nonterminal overlapped operation to the shared retention path'
}

$writeBody = [Text.RegularExpressions.Regex]::Match(
    $adapterText,
    '(?s)NativeRuntime_WriteUtf8Bounded\([^\r\n]*\)\s*\{.*?(?=\r?\nNativeRuntime_CancelOverlapped\()')
if (-not $writeBody.Success -or
    $writeBody.Value -notmatch '"Ptr",\s*0,\s*"Ptr",\s*overlapped') {
    throw 'Overlapped WriteFile must pass NULL for lpNumberOfBytesWritten'
}

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
    if (-not $process.Start()) { throw 'Cannot start isolated AHK wrapper fixture' }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $timedOut = $false
    try {
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $timedOut = $true
            $process.Kill()
            if (-not $process.WaitForExit(5000)) {
                throw 'Exact retained AHK fixture process did not exit after kill'
            }
        }
        if (-not [Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000)) {
            throw 'AHK fixture redirected streams did not close'
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [IO.File]::WriteAllText($StdoutPath, $stdout, [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($StderrPath, $stderr, [Text.UTF8Encoding]::new($false))
        if ($timedOut) { throw 'Isolated AHK RuntimeUtilities wrapper test timed out' }
        if ($process.ExitCode -ne 0) {
            throw ('Isolated AHK RuntimeUtilities wrapper test failed: exit=' + $process.ExitCode + ' error=' + $stderr)
        }
        return $process.ExitCode
    } finally {
        if (-not $process.HasExited) {
            $process.Kill()
            [void]$process.WaitForExit(5000)
        }
        $process.Dispose()
    }
}

& $compiler /nologo /warnaserror /langversion:5 /optimize+ /target:exe `
    /r:System.Web.Extensions.dll /main:Wuthering.Native.RuntimeUtilities `
    ('/out:' + $helper) $framework $source 2>&1 |
    Tee-Object -FilePath (Join-Path $run 'compile-helper.txt')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $helper)) {
    throw 'RuntimeUtilities helper compilation failed'
}

& $compiler /nologo /warnaserror /langversion:5 /optimize+ /target:exe `
    /r:System.Web.Extensions.dll /main:RuntimeUtilitiesTests `
    ('/out:' + $tests) $framework $source $testSource 2>&1 |
    Tee-Object -FilePath (Join-Path $run 'compile-tests.txt')
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tests)) {
    throw 'RuntimeUtilities native test compilation failed'
}

& $tests (Join-Path $run 'fixtures') $helper 2>&1 |
    Tee-Object -FilePath (Join-Path $run 'RuntimeUtilitiesTests.txt')
if ($LASTEXITCODE -ne 0) { throw 'RuntimeUtilities native regression failed' }

$ahkRuntime = Join-Path $project 'AutoHotkey64.exe'
$wrapperCopy = Join-Path $run 'NativeRuntimeUtilities.ahk'
[IO.File]::Copy($adapterPath, $wrapperCopy, $true)
$pendingFixture = Join-Path $run 'PendingIoLifetimeFixture.ahk'
$pendingSource = @'
#Requires AutoHotkey v2.0+
#Include NativeRuntimeUtilities.ahk

global probeDeletes := 0
global fakeTerminal := false
global fakeCancelCalls := 0
global fakeWaitCalls := 0
global fakeStatusCalls := 0
global fakeClosed := []

class PendingLifetimeProbe {
    __Delete() {
        global probeDeletes
        probeDeletes += 1
    }
}

FakeCancel(handle, overlapped) {
    global fakeCancelCalls
    fakeCancelCalls += 1
    return true
}

FakeWait(eventHandle, timeoutMs) {
    global fakeTerminal, fakeWaitCalls
    fakeWaitCalls += 1
    return fakeTerminal ? 0 : 258
}

FakeStatus(handle, overlapped) {
    global fakeTerminal, fakeStatusCalls
    fakeStatusCalls += 1
    return fakeTerminal ? 2 : 0
}

FakeClose(handle) {
    global fakeClosed
    fakeClosed.Push(handle)
    return true
}

ops := {cancel:FakeCancel, wait:FakeWait, status:FakeStatus, close:FakeClose}
if NativeRuntime_PendingIoCount() != 0
    ExitApp 30

pipeHandle := 7001
state := {eventHandle:7002, overlapped:Buffer(A_PtrSize = 8 ? 32 : 20, 0),
    keepAlive:[Buffer(64, 0), PendingLifetimeProbe()]}
cancelResult := NativeRuntime_CancelOverlapped(&pipeHandle, state, ops)
state := ""
if cancelResult.terminal || !cancelResult.deferred || pipeHandle != 0
    ExitApp 31
if NativeRuntime_PendingIoCount() != 1 || probeDeletes != 0
    ExitApp 32
if fakeCancelCalls != 1
    ExitApp 33

NativeRuntime_ReapPendingIo()
if NativeRuntime_PendingIoCount() != 1 || probeDeletes != 0 || fakeClosed.Length != 0
    ExitApp 34

blocked := NativeRuntime_Invoke("audio", "{}", 500)
if blocked.ok || !InStr(blocked.message, "previous native utility I/O")
    ExitApp 41
if NativeRuntime_PendingIoCount() != 1 || fakeCancelCalls != 1
    ExitApp 42

fakeTerminal := true
NativeRuntime_ReapPendingIo()
if NativeRuntime_PendingIoCount() != 0 || probeDeletes != 1
    ExitApp 35
if fakeClosed.Length != 2 || fakeClosed[1] != 7001 || fakeClosed[2] != 7002
    ExitApp 36
fastHandle := 7101
fastState := {eventHandle:7102, overlapped:Buffer(A_PtrSize = 8 ? 32 : 20, 0),
    keepAlive:Buffer(8, 0)}
fastResult := NativeRuntime_CancelOverlapped(&fastHandle, fastState, ops)
if !fastResult.terminal || fastResult.deferred || fastHandle != 7101
    ExitApp 38
if NativeRuntime_PendingIoCount() != 0 || fakeClosed.Length != 2
    ExitApp 39
if fakeCancelCalls != 2 || fakeWaitCalls < 2 || fakeStatusCalls < 4
    ExitApp 40
ExitApp 0
'@
[IO.File]::WriteAllText($pendingFixture, $pendingSource, [Text.UTF8Encoding]::new($false))
$pendingExit = Invoke-IsolatedAhkFixture -Runtime $ahkRuntime -Fixture $pendingFixture `
    -WorkingDirectory $run -TimeoutMilliseconds 10000 `
    -StdoutPath (Join-Path $run 'pending-io-stdout.txt') `
    -StderrPath (Join-Path $run 'pending-io-stderr.txt')

$fixture = Join-Path $run 'NativeRuntimeUtilitiesFixture.ahk'
$fixtureSource = @'
#Requires AutoHotkey v2.0+
#Include NativeRuntimeUtilities.ahk
invalidMail := NativeRuntime_SendMail("host", "not-a-port", "user", "pass", "sender@example.test", "recipient@example.test", "subject", "body", false)
if invalidMail.ok || !invalidMail.HasOwnProp("message")
    ExitApp 10
parsed := NativeRuntime_ParseResponse('{"ok":false,"code":"no_target","message":"\u92e4\u5730","exitCode":2}', 2)
if parsed.exitCode != 2 || parsed.message != Chr(0x92E4) Chr(0x5730)
    ExitApp 11
audioExit := NativeRuntime_SetGameMute("2147483647", "Client-Win64-Shipping.exe", true)
if audioExit != 2
    ExitApp 12
ExitApp 0
'@
[IO.File]::WriteAllText($fixture, $fixtureSource, [Text.UTF8Encoding]::new($false))
$fixtureExit = Invoke-IsolatedAhkFixture -Runtime $ahkRuntime -Fixture $fixture `
    -WorkingDirectory $run -TimeoutMilliseconds 15000 `
    -StdoutPath (Join-Path $run 'ahk-wrapper-stdout.txt') `
    -StderrPath (Join-Path $run 'ahk-wrapper-stderr.txt')

$stall = Join-Path $run 'stalled-stdin'
[void][IO.Directory]::CreateDirectory($stall)
[IO.File]::Copy($tests, (Join-Path $stall 'RuntimeUtilities.exe'), $true)
[IO.File]::Copy((Join-Path $project 'payload\NativeRuntimeUtilities.ahk'), (Join-Path $stall 'NativeRuntimeUtilities.ahk'), $true)
$stallFixture = Join-Path $stall 'StalledInputFixture.ahk'
$stallSource = @'
#Requires AutoHotkey v2.0+
#Include NativeRuntimeUtilities.ahk
EnvSet "RUNTIME_UTILITIES_STALL_STDIN", "1"
body := StrReplace(Format("{:200000}", ""), " ", "x")
started := DllCall("Kernel32\GetTickCount64", "UInt64")
result := NativeRuntime_Invoke("mail", '{"body":"' body '"}', 750)
elapsed := DllCall("Kernel32\GetTickCount64", "UInt64") - started
if result.exitCode != 124
    ExitApp 20
if elapsed > 5000
    ExitApp 21
reapDeadline := DllCall("Kernel32\GetTickCount64", "UInt64") + 3000
while NativeRuntime_PendingIoCount() &&
    DllCall("Kernel32\GetTickCount64", "UInt64") < reapDeadline {
    NativeRuntime_ReapPendingIo()
    if !NativeRuntime_PendingIoCount()
        break
    Sleep 20
}
if NativeRuntime_PendingIoCount() != 0
    ExitApp 22
ExitApp 0
'@
[IO.File]::WriteAllText($stallFixture, $stallSource, [Text.UTF8Encoding]::new($false))
$stallExit = Invoke-IsolatedAhkFixture -Runtime $ahkRuntime -Fixture $stallFixture `
    -WorkingDirectory $stall -TimeoutMilliseconds 10000 `
    -StdoutPath (Join-Path $run 'stalled-input-stdout.txt') `
    -StderrPath (Join-Path $run 'stalled-input-stderr.txt')

$ahkAfter = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%' OR Name = 'AutoHotkey.exe'")
if ($ahkAfter.Count) { throw 'Zero-AHK postcondition failed' }
$fixtureHelpers = @(Get-CimInstance Win32_Process -Filter "Name = 'RuntimeUtilities.exe'" | Where-Object {
    $path = [string]$_.ExecutablePath
    $path -and $path.StartsWith($run + '\', [StringComparison]::OrdinalIgnoreCase)
})
if ($fixtureHelpers.Count) { throw 'Fixture RuntimeUtilities child remained after isolated tests' }

$summary = [ordered]@{
    ok = $true
    targetFramework = '.NETFramework,Version=v4.8'
    compiler = $compiler
    compilerArguments = @('/nologo','/warnaserror','/langversion:5','/optimize+','/target:exe','/r:System.Web.Extensions.dll','/main:Wuthering.Native.RuntimeUtilities')
    helper = $helper
    ahkBefore = $ahkBefore.Count
    ahkAfter = $ahkAfter.Count
    pendingIoLifetimeExitCode = $pendingExit
    isolatedAhkWrapperExitCode = $fixtureExit
    stalledInputWrapperExitCode = $stallExit
    fixtureHelpersAfter = $fixtureHelpers.Count
    exactMissingPidAudioExitCode = 2
    externalSmtpAllowedDuringTests = $false
    evidence = $run
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $run 'summary.json') -Encoding utf8
Write-Output ('PASS: RuntimeUtilities suite; baseline/post AHK=0; evidence=' + $run)
