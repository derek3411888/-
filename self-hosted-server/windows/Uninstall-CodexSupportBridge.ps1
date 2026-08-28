[CmdletBinding()]
param([switch]$KeepLocalState)

$ErrorActionPreference = 'Stop'
$taskName = 'Wuthering Codex Support Bridge'
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
$installRoot = Join-Path $env:LOCALAPPDATA 'WutheringAutomation\CodexSupportBridge'
$installedScript = Join-Path $installRoot 'CodexSupportBridge.ps1'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -like "*$installedScript*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) 'Wuthering Codex Support Bridge.lnk'
if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force }
if (-not $KeepLocalState) {
    if (Test-Path -LiteralPath $installRoot) { Remove-Item -LiteralPath $installRoot -Recurse -Force }
}
Write-Host 'Codex 橋接已移除。'
