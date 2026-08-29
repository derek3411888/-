[CmdletBinding()]
param([switch]$KeepLocalState)

$ErrorActionPreference = 'Stop'
$taskName = 'Wuthering Codex Support Bridge'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
$installRoot = Join-Path $env:ProgramData 'WutheringAutomation\CodexSupportBridge'
$installedScript = Join-Path $installRoot 'CodexSupportBridge.ps1'
$installedWatchdog = Join-Path $installRoot 'CodexSupportWatchdog.ps1'
$installedBootstrap = Join-Path $installRoot 'CodexSupportBootstrap.ps1'
# 先關 watchdog，否則它會在 bridge 結束後立刻重新啟動。
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -in @('powershell.exe', 'pwsh.exe') -and
        ([string]$_.CommandLine -like "*$installedWatchdog*" -or
         [string]$_.CommandLine -like "*$installedBootstrap*" -or
         [string]$_.CommandLine -like "*$installedScript*")
    } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Wuthering Codex Support Bridge.lnk'
if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
if (-not $KeepLocalState) {
    if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
}
Write-Host 'Codex 橋接已移除。'
