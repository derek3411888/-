[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ThreadId,
    [string]$Workspace = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$ProjectId = 'ww-control-a3988',
    [string]$ApiKey = 'AIzaSyDqWHdBixVQPt4OiTi50hseInFxPtk0hf0',
    [string]$Collection = 'ahk_clients',
    [ValidateRange(10, 300)]
    [int]$PollSeconds = 15,
    [ValidateRange(60, 3600)]
    [int]$MinimumRequestIntervalSeconds = 300
)

$ErrorActionPreference = 'Stop'
$sourceScript = Join-Path $PSScriptRoot 'CodexSupportBridge.ps1'
if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) { throw "缺少橋接主程式：$sourceScript" }
$workspaceFull = [IO.Path]::GetFullPath($Workspace)
if (-not (Test-Path -LiteralPath $workspaceFull -PathType Container)) { throw "工作區不存在：$workspaceFull" }

$codexCommand = Get-Command codex.exe -ErrorAction SilentlyContinue
if (-not $codexCommand) {
    $codexCommand = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') `
        -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}
if (-not $codexCommand) { throw '找不到 Codex CLI；請先安裝或啟動 Codex 桌面版。' }
$codexPath = if ($codexCommand.PSObject.Properties['Source']) { $codexCommand.Source } else { $codexCommand.FullName }

$installRoot = Join-Path $env:LOCALAPPDATA 'WutheringAutomation\CodexSupportBridge'
$installedScript = Join-Path $installRoot 'CodexSupportBridge.ps1'
$configPath = Join-Path $installRoot 'config.json'
New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
$existingBridgeProcesses = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -like "*$installedScript*" })
foreach ($process in $existingBridgeProcesses) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
}
if ($existingBridgeProcesses.Count -gt 0) { Start-Sleep -Milliseconds 500 }
# Windows 排程器預設使用 Windows PowerShell 5.1；含繁體中文的 UTF-8 腳本
# 必須帶 BOM，否則 5.1 會用系統 ANSI 編碼解析並產生假語法錯誤。
$scriptText = [IO.File]::ReadAllText($sourceScript, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($installedScript, $scriptText, [Text.UTF8Encoding]::new($true))

$config = [ordered]@{
    ProjectId = $ProjectId
    ApiKey = $ApiKey
    Collection = $Collection
    DocumentId = '__codex_support'
    ThreadId = $ThreadId.ToLowerInvariant()
    Workspace = $workspaceFull
    CodexPath = [string]$codexPath
    PollSeconds = $PollSeconds
    MinimumRequestIntervalSeconds = $MinimumRequestIntervalSeconds
}
[IO.File]::WriteAllText(
    $configPath,
    ($config | ConvertTo-Json -Depth 4),
    [Text.UTF8Encoding]::new($false)
)

Write-Host '正在驗證 Firestore 與本機 Codex…'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installedScript -ConfigPath $configPath -ValidateOnly
if ($LASTEXITCODE -ne 0) { throw 'Codex 橋接驗證失敗。' }

$quotedScript = '"' + $installedScript.Replace('"', '""') + '"'
$quotedConfig = '"' + $configPath.Replace('"', '""') + '"'
$arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $quotedScript -ConfigPath $quotedConfig"
$taskName = 'Wuthering Codex Support Bridge'
$oldTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($oldTask) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# 使用目前使用者的啟動資料夾，不需要系統管理員，也不受部分 Windows
# 工作排程器在 InteractiveToken 工作上回傳 FFFD0000 的問題影響。
$startupDirectory = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDirectory 'Wuthering Codex Support Bridge.lnk'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powershellPath
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = $installRoot
$shortcut.WindowStyle = 7
$shortcut.Description = '將公司控制台的固定維修請求送進目前 Codex 任務'
$shortcut.Save()

$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -like "*$installedScript*" })
if ($running.Count -eq 0) {
    Start-Process -FilePath $powershellPath -ArgumentList $arguments -WorkingDirectory $installRoot -WindowStyle Hidden
    Start-Sleep -Seconds 3
}
$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -like "*$installedScript*" })
if ($running.Count -ne 1) { throw "Codex 橋接常駐程序數量不正確：$($running.Count)" }

Write-Host ''
Write-Host 'Codex 橋接已安裝。'
Write-Host "狀態：執行中（PID $($running[0].ProcessId)）"
Write-Host "目前 Codex 任務：$ThreadId"
Write-Host "輪詢間隔：$PollSeconds 秒（每天最多約 $([Math]::Ceiling(86400 / $PollSeconds)) 次單文件讀取）"
Write-Host "設定與 Log：$installRoot"
Write-Host "開機啟動項目：$shortcutPath"
