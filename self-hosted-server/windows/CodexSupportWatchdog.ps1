[CmdletBinding()]
param(
    [string]$BridgeScriptPath = (Join-Path $env:ProgramData 'WutheringAutomation\CodexSupportBridge\CodexSupportBridge.ps1'),
    [string]$ConfigPath = (Join-Path $env:ProgramData 'WutheringAutomation\CodexSupportBridge\config.json'),
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$WatchdogVersion = '1.0.0'

function Write-WatchdogLog([string]$Path, [string]$Level, [string]$Message) {
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    if ((Test-Path -LiteralPath $Path) -and (Get-Item -LiteralPath $Path).Length -ge 1MB) {
        for ($index = 14; $index -ge 1; $index--) {
            $source = "$Path.$index"
            $target = "$Path.$($index + 1)"
            if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination $target -Force }
        }
        Move-Item -LiteralPath $Path -Destination "$Path.1" -Force
    }
    $safeMessage = ($Message -replace '[\r\n]+', ' ').Trim()
    Add-Content -LiteralPath $Path -Encoding UTF8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $safeMessage"
}

function Get-BridgeProcesses([string]$ScriptPath) {
    $needlePattern = '(?i)(?:^|\s)' + [Regex]::Escape('-File ' + $ScriptPath) + '(?:\s|$)'
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.Name -notin @('powershell.exe', 'pwsh.exe')) { return $false }
            $normalized = ([string]$_.CommandLine).Replace('"', '').Replace("'", '')
            return $normalized -match $needlePattern
        })
}

$bridgeFull = [IO.Path]::GetFullPath($BridgeScriptPath)
$configFull = [IO.Path]::GetFullPath($ConfigPath)
if (-not (Test-Path -LiteralPath $bridgeFull -PathType Leaf)) { throw "找不到 Codex 橋接程式：$bridgeFull" }
if (-not (Test-Path -LiteralPath $configFull -PathType Leaf)) { throw "找不到 Codex 橋接設定：$configFull" }
$installRoot = Split-Path -Parent $bridgeFull
$logPath = Join-Path $installRoot 'watchdog.log'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) { throw '找不到 Windows PowerShell。' }

if ($ValidateOnly) {
    [pscustomobject]@{
        Ok = $true
        WatchdogVersion = $WatchdogVersion
        BridgeScriptPath = $bridgeFull
        ConfigPath = $configFull
    } | ConvertTo-Json -Depth 3
    exit 0
}

$mutex = [Threading.Mutex]::new($false, 'Local\WutheringCodexSupportWatchdog')
$mutexOwned = $false
try {
    $mutexOwned = $mutex.WaitOne(0)
} catch [Threading.AbandonedMutexException] {
    $mutexOwned = $true
}
if (-not $mutexOwned) {
    $mutex.Dispose()
    exit 0
}

try {
    Write-WatchdogLog $logPath 'INFO' "Codex bridge watchdog $WatchdogVersion started"
    $backoffSeconds = 5
    while ($true) {
        $existing = @(Get-BridgeProcesses $bridgeFull)
        if ($existing.Count -gt 0) {
            Start-Sleep -Seconds 5
            continue
        }

        $quotedBridge = '"' + $bridgeFull.Replace('"', '""') + '"'
        $quotedConfig = '"' + $configFull.Replace('"', '""') + '"'
        $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $quotedBridge -ConfigPath $quotedConfig"
        $startedAt = [DateTimeOffset]::UtcNow
        try {
            $process = Start-Process -FilePath $powershellPath -ArgumentList $arguments `
                -WorkingDirectory $installRoot -WindowStyle Hidden -PassThru
            Write-WatchdogLog $logPath 'INFO' "Started bridge pid=$($process.Id)"
            $process.WaitForExit()
            $runtimeSeconds = ([DateTimeOffset]::UtcNow - $startedAt).TotalSeconds
            Write-WatchdogLog $logPath 'WARN' "Bridge exited pid=$($process.Id) code=$($process.ExitCode) runtime=$([Math]::Round($runtimeSeconds))s"
            if ($runtimeSeconds -ge 300) { $backoffSeconds = 5 } else { $backoffSeconds = [Math]::Min(60, $backoffSeconds * 2) }
        } catch {
            Write-WatchdogLog $logPath 'ERROR' $_.Exception.Message
            $backoffSeconds = [Math]::Min(60, $backoffSeconds * 2)
        }
        Start-Sleep -Seconds $backoffSeconds
    }
} catch {
    # 排程器沒有互動式主控台；所有未處理啟動錯誤都必須落盤，才不會只剩下難以判讀的 FFFD0000。
    try { Write-WatchdogLog $logPath 'ERROR' "Watchdog fatal: $($_.Exception.Message)" } catch {}
    throw
} finally {
    if ($mutexOwned) { try { $mutex.ReleaseMutex() } catch {} }
    $mutex.Dispose()
}
