[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$projectRoot = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $projectRoot -RunName 'synthesis-syntax'
try {
    $source = Join-Path $projectRoot ('payload\' + [string]::Concat([char]0x8072,[char]0x9AB8,[char]0x5408,[char]0x6210) + '.ahk')
    $outPath = Join-Path $context.RunRoot 'validate.stdout.log'
    $errPath = Join-Path $context.RunRoot 'validate.stderr.log'
    $process = Start-Process -FilePath (Join-Path $projectRoot 'AutoHotkey64.exe') -ArgumentList ('/ErrorStdOut=UTF-8 /Validate "' + $source + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
    [void]$process.Handle
    try {
        if (-not $process.WaitForExit(15000)) { $process.Kill(); throw 'Synthesis syntax validation timed out' }
        $process.WaitForExit()
        $output = (Read-GMTestOutput $outPath) + (Read-GMTestOutput $errPath)
        if ($process.ExitCode -ne 0 -or $output -match '(?i)warning:|error:') { throw "Synthesis syntax failed: $output" }
    } finally { $process.Dispose() }
    'PASS: synthesis script and runtime includes validate without executing game flow'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
