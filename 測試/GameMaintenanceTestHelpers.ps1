Set-StrictMode -Version 2
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ProjectDevelopmentPaths.ps1')

function Assert-GMEqual($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message : expected=$Expected actual=$Actual" }
}
function Assert-GMTrue([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Read-GMTestOutput([string]$Path) {
    $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
function Invoke-GMTestProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)]$Context,
        [ValidateRange(1,60)][int]$TimeoutSeconds = 60)
    $scriptFile = [IO.Path]::GetFullPath($ScriptPath)
    if (-not (Test-ProjectContainedPath $scriptFile $Context.ProjectRoot)) { throw 'Test script is outside project' }
    if (-not (Test-Path -LiteralPath $scriptFile -PathType Leaf)) { throw "Missing test: $scriptFile" }
    $testRoot = Join-Path $Context.ProjectRoot '測試'
    if (-not (Test-ProjectContainedPath $scriptFile $testRoot) -and
        -not (Test-ProjectContainedPath $scriptFile $Context.Root)) { throw 'Only test scripts may execute' }
    $currentPath = $scriptFile
    while ($currentPath -and (Test-ProjectContainedPath $currentPath $Context.ProjectRoot)) {
        if ((Get-Item -LiteralPath $currentPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Reparse-point test paths are forbidden' }
        $currentPath = Split-Path $currentPath -Parent
    }
    $tag = [Guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path $Context.RunRoot "$tag.stdout.log"
    $stderrPath = Join-Path $Context.RunRoot "$tag.stderr.log"
    switch ([IO.Path]::GetExtension($scriptFile)) {
        '.ahk' { $exe = Join-Path $Context.ProjectRoot 'AutoHotkey64.exe'; $arguments = '/ErrorStdOut=UTF-8 "' + $scriptFile + '"' }
        '.ps1' { $exe = (Get-Process -Id $PID).Path; $arguments = '-NoProfile -File "' + $scriptFile + '"' }
        default { throw 'Unsupported test script type' }
    }
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $Context.ProjectRoot `
        -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    # Cache the native handle before waiting: PS 5.1 can otherwise lose ExitCode.
    [void]$process.Handle
    $startedAt = $process.StartTime.ToUniversalTime().Ticks
    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        $owned = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
        if ($owned -and $owned.StartTime.ToUniversalTime().Ticks -eq $startedAt) { Stop-Process -InputObject $owned -ErrorAction Stop }
        [void]$process.WaitForExit(5000)
        $exitCode = 124
    } else { $process.WaitForExit(); $exitCode = $process.ExitCode }
    $result = [pscustomobject]@{ ExitCode=$exitCode; TimedOut=$timedOut; ProcessId=$process.Id
        Stdout=(Read-GMTestOutput $stdoutPath); Stderr=(Read-GMTestOutput $stderrPath) }
    $process.Dispose()
    return $result
}
