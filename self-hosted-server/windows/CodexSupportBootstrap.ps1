[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installRoot = $PSScriptRoot
$watchdogPath = Join-Path $installRoot 'CodexSupportWatchdog.ps1'
$bridgePath = Join-Path $installRoot 'CodexSupportBridge.ps1'
$configPath = Join-Path $installRoot 'config.json'
$logPath = Join-Path $installRoot 'bootstrap.log'

function Write-BootstrapLog([string]$Level, [string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

try {
    Write-BootstrapLog 'INFO' 'Scheduled bootstrap invoking watchdog'
    & $watchdogPath -BridgeScriptPath $bridgePath -ConfigPath $configPath
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    Write-BootstrapLog 'WARN' ("Watchdog exited code={0}" -f $exitCode)
    exit $exitCode
} catch {
    Write-BootstrapLog 'ERROR' (($_ | Out-String).Trim())
    exit 1
}
