[CmdletBinding()]
param(
    [string]$PublicHostname,
    [string]$DataRoot,
    [string]$BackupRoot,
    [switch]$AllowDockerStorageOutsideDataDrive
)

$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $serverRoot

function New-RandomSecret([int]$Bytes = 48) {
    $buffer = New-Object byte[] $Bytes
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($buffer) } finally { $generator.Dispose() }
    return [Convert]::ToBase64String($buffer).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Read-EnvFile([string]$Path) {
    $values = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $values }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line -notmatch '=') { continue }
        $name, $value = $line -split '=', 2
        $values[$name.Trim()] = $value.Trim()
    }
    return $values
}

function Normalize-DockerPath([string]$PathValue) {
    $resolved = [IO.Path]::GetFullPath($PathValue)
    return $resolved.Replace('\', '/')
}

function Get-DockerDesktopStorageRoot {
    $settingsPath = Join-Path $env:APPDATA 'Docker\settings-store.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) { return '' }
    try {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$settings.CustomWslDistroDir
    } catch {
        Write-Warning "無法解析 Docker Desktop 儲存設定：$settingsPath"
        return ''
    }
}

if ([string]::IsNullOrWhiteSpace($PublicHostname)) {
    $PublicHostname = Read-Host '請輸入路由器 DDNS 主機名稱（例如 example.asuscomm.com）'
}
if ($PublicHostname -notmatch '^[A-Za-z0-9.-]+$' -or $PublicHostname -notmatch '\.') {
    throw 'DDNS 主機名稱格式無效，請勿包含 https:// 或路徑。'
}
if ([string]::IsNullOrWhiteSpace($DataRoot)) {
    $answer = Read-Host '中央影片／快照／Log 資料夾 [D:\WutheringControlServer\data]'
    $DataRoot = if ([string]::IsNullOrWhiteSpace($answer)) { 'D:\WutheringControlServer\data' } else { $answer }
}
if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
    $answer = Read-Host '另一顆磁碟的資料庫備份資料夾 [E:\WutheringControlBackups]'
    $BackupRoot = if ([string]::IsNullOrWhiteSpace($answer)) { 'E:\WutheringControlBackups' } else { $answer }
}

$dataFull = [IO.Path]::GetFullPath($DataRoot)
$backupFull = [IO.Path]::GetFullPath($BackupRoot)
$dataDrive = [IO.Path]::GetPathRoot($dataFull)
$backupDrive = [IO.Path]::GetPathRoot($backupFull)
if (-not (Test-Path -LiteralPath $dataDrive)) { throw "找不到中央資料磁碟：$dataDrive" }
if (-not (Test-Path -LiteralPath $backupDrive)) { throw "找不到備份磁碟：$backupDrive" }
if ($dataDrive -eq $backupDrive) {
    throw '資料與備份必須選擇不同磁碟，否則單顆磁碟故障時無法還原。'
}

$dockerStorageRoot = Get-DockerDesktopStorageRoot
if (-not [string]::IsNullOrWhiteSpace($dockerStorageRoot)) {
    $dockerStorageDrive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($dockerStorageRoot))
    if ($dockerStorageDrive -ne $dataDrive -and -not $AllowDockerStorageOutsideDataDrive) {
        throw "Docker Desktop 的磁碟映像目前在 $dockerStorageRoot；PostgreSQL named volume 和容器映像也會放在該磁碟。請先到 Docker Desktop > Settings > Resources > Advanced，把 Disk image location 移到 $($dataDrive)DockerDesktopData，再重新執行安裝。若已了解並要略過檢查，可加 -AllowDockerStorageOutsideDataDrive。"
    }
    Write-Host "Docker Desktop 儲存位置：$dockerStorageRoot"
} else {
    Write-Warning '無法確認 Docker Desktop 磁碟映像位置；請自行確認 Disk image location 位於中央資料磁碟。'
}
foreach ($directory in @($dataFull, "$dataFull\media", "$dataFull\snapshots", "$dataFull\logs", $backupFull)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

& docker info | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop 尚未啟動或目前帳號無法連線 Docker Engine。' }
& docker compose version | Out-Null
if ($LASTEXITCODE -ne 0) { throw '找不到 Docker Compose。' }

$envPath = Join-Path $serverRoot '.env'
$envValues = Read-EnvFile $envPath
if (-not $envValues.ContainsKey('POSTGRES_PASSWORD')) { $envValues.POSTGRES_PASSWORD = New-RandomSecret 36 }
if (-not $envValues.ContainsKey('SESSION_SECRET')) { $envValues.SESSION_SECRET = New-RandomSecret 48 }
if (-not $envValues.ContainsKey('LIVE_TOKEN_SECRET')) { $envValues.LIVE_TOKEN_SECRET = New-RandomSecret 48 }
if (-not $envValues.ContainsKey('LIVE_SRT_PASSPHRASE')) { $envValues.LIVE_SRT_PASSPHRASE = New-RandomSecret 24 }
$envValues.PUBLIC_HOSTNAME = $PublicHostname.ToLowerInvariant()
$envValues.PUBLIC_SRT_HOST = $PublicHostname.ToLowerInvariant()
$envValues.PUBLIC_SRT_PORT = '8890'
$envValues.DATA_ROOT_HOST = Normalize-DockerPath $dataFull
$envValues.BACKUP_ROOT_HOST = Normalize-DockerPath $backupFull
$envValues.MIN_FREE_GB = '20'
$envValues.SESSIONS_PER_DEVICE = '5'
$envValues.FIRESTORE_IMPORT_ENABLED = 'true'
$envValues.FIRESTORE_PROJECT_ID = 'ww-control-a3988'
$envValues.FIRESTORE_API_KEY = 'AIzaSyDqWHdBixVQPt4OiTi50hseInFxPtk0hf0'
$envValues.FIRESTORE_COLLECTION = 'ahk_clients'
$envValues.SERVER_IMAGE_TAG = 'current'

$orderedNames = @(
    'PUBLIC_HOSTNAME', 'PUBLIC_SRT_HOST', 'PUBLIC_SRT_PORT', 'DATA_ROOT_HOST', 'BACKUP_ROOT_HOST',
    'POSTGRES_PASSWORD', 'SESSION_SECRET', 'LIVE_TOKEN_SECRET', 'LIVE_SRT_PASSPHRASE', 'MIN_FREE_GB', 'SESSIONS_PER_DEVICE',
    'FIRESTORE_IMPORT_ENABLED', 'FIRESTORE_PROJECT_ID', 'FIRESTORE_API_KEY', 'FIRESTORE_COLLECTION', 'SERVER_IMAGE_TAG'
)
$content = foreach ($name in $orderedNames) { "$name=$($envValues[$name])" }
[IO.File]::WriteAllLines($envPath, $content, [Text.UTF8Encoding]::new($false))

Write-Host '正在建立並啟動 Docker 服務…'
& docker compose --env-file $envPath -f compose.yml up -d --build
if ($LASTEXITCODE -ne 0) { throw 'Docker Compose 啟動失敗。' }

$healthy = $false
for ($attempt = 1; $attempt -le 40; $attempt++) {
    & docker compose --env-file $envPath -f compose.yml exec -T api wget -q -O - http://127.0.0.1:3000/health/ready 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { $healthy = $true; break }
    Start-Sleep -Seconds 3
}
if (-not $healthy) {
    & docker compose --env-file $envPath -f compose.yml ps
    throw 'API 在 120 秒內未通過健康檢查，請查看 docker compose logs。'
}

& docker compose --env-file $envPath -f compose.yml exec -T backup /usr/local/bin/backup-now.sh preupdate
if ($LASTEXITCODE -ne 0) { throw '首次資料庫備份／驗證失敗。' }
& docker compose --env-file $envPath -f compose.yml exec -T backup /usr/local/bin/restore-test.sh
if ($LASTEXITCODE -ne 0) { throw '首次資料庫實際還原測試失敗。' }

Write-Host ''
Write-Host '安裝完成。請在路由器與 Windows 防火牆開放：'
Write-Host '  TCP 80、TCP 443、UDP 8890'
Write-Host "控制網站：https://$PublicHostname"
Write-Host '網站可直接開啟使用，不需要帳號、密碼或啟用連結。'
Write-Host '新裝置第一次啟動會自動加入，不需要開放註冊窗口。'
Write-Host "資料位置：$dataFull"
Write-Host "備份位置：$backupFull"
