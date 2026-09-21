[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$helperPath = Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1'
if (-not (Test-Path -LiteralPath $helperPath)) { throw 'Maintenance test process helper is missing' }
. $helperPath
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot (Split-Path $PSScriptRoot -Parent) -RunName 'gm-runner-selftest'
try {
    $encoding = [Text.UTF8Encoding]::new($true)
    foreach ($extension in @('ps1','ahk')) {
        foreach ($expected in @(0,1)) {
            $fixturePath = Join-Path $context.RunRoot ("fixture-$expected.$extension")
            $body = if ($extension -eq 'ps1') { "[Console]::Out.WriteLine('GM_FIXTURE'); exit $expected" } else { "#Requires AutoHotkey v2.0+`nFileAppend('GM_FIXTURE', '*')`nExitApp($expected)" }
            [IO.File]::WriteAllText($fixturePath, $body, $encoding)
            $result = Invoke-GMTestProcess -ScriptPath $fixturePath -Context $context
            Assert-GMEqual $result.ExitCode $expected "$extension child exit propagates"
            Assert-GMTrue ($result.Stdout -match 'GM_FIXTURE') 'Child stdout is captured'
        }
    }
    $timeoutPath = Join-Path $context.RunRoot 'timeout.ahk'
    [IO.File]::WriteAllText($timeoutPath, "#Requires AutoHotkey v2.0+`nSleep(10000)`nExitApp", $encoding)
    $result = Invoke-GMTestProcess -ScriptPath $timeoutPath -Context $context -TimeoutSeconds 1
    Assert-GMEqual $result.ExitCode 124 'Owned timed out process is rejected'
    Assert-GMTrue $result.TimedOut 'Timeout is observable'
    Assert-GMTrue (-not (Get-Process -Id $result.ProcessId -ErrorAction SilentlyContinue)) 'Owned timed out test exited'
    $rejected = $false
    try { Invoke-GMTestProcess -ScriptPath 'C:\Windows\not-a-project-test.ps1' -Context $context } catch { $rejected = $true }
    Assert-GMTrue $rejected 'Outside project execution rejected'
    Write-Output 'PASS: runner 12 assertions (PS/AHK exits, output, timeout, containment)'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
