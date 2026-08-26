[CmdletBinding()]
param(
    [string]$PayloadVersion = '4.62',
    [string]$LauncherVersion = '4.73',
    [string]$ServerVersion = '1.0.19',
    [string]$CommitMessage = '',
    [switch]$SkipPush,
    [switch]$SkipDocker,
    [switch]$SkipIntegrationSmoke
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $projectRoot

function Assert-ExitCode([string]$Task) {
    if ($LASTEXITCODE -ne 0) { throw "$Task 失敗，exit=$LASTEXITCODE" }
}

function Read-Manifest([string]$Path) {
    $value = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($name in @('release_id', 'version', 'payload_sha256', 'launcher_version',
        'launcher_sha256', 'server_version', 'server_sha256', 'web_sha256')) {
        if ([string]::IsNullOrWhiteSpace([string]$value.$name)) { throw "manifest 缺少 $name" }
    }
    return $value
}

function Wait-RemoteManifest($Expected, [int]$TimeoutSeconds = 180) {
    $releaseId = [string]$Expected.release_id
    $baseUrl = 'https://raw.githubusercontent.com/derek3411888/-/main/update_manifest.example.json'
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $url = "${baseUrl}?release=$([Uri]::EscapeDataString($ReleaseId))&t=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
            $remote = Invoke-RestMethod -UseBasicParsing -Uri $url -TimeoutSec 30
            $matches = [string]$remote.release_id -eq $releaseId
            foreach ($name in @('payload_sha256', 'launcher_sha256', 'server_sha256', 'web_sha256')) {
                $matches = $matches -and ([string]$remote.$name).ToUpperInvariant() -eq ([string]$Expected.$name).ToUpperInvariant()
            }
            if ($matches) { return $url }
        } catch {}
        Start-Sleep -Seconds 4
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "GitHub 在 $TimeoutSeconds 秒內仍未提供 release_id=$releaseId 且四份雜湊一致的 manifest。"
}

Write-Host "建立完整釋出：Payload $PayloadVersion / Launcher $LauncherVersion / Server $ServerVersion"
& (Join-Path $projectRoot '打包更新.ps1') -PayloadVersion $PayloadVersion `
    -LauncherVersion $LauncherVersion -ServerVersion $ServerVersion

$manifestPath = Join-Path $projectRoot 'update_manifest.example.json'
$manifest = Read-Manifest $manifestPath
if ([string]$manifest.version -ne $PayloadVersion -or
    [string]$manifest.launcher_version -ne $LauncherVersion -or
    [string]$manifest.server_version -ne $ServerVersion) {
    throw '打包結果的三個元件版本不一致。'
}

$releasePaths = @(
    '打包啟動器.ahk', '打包更新.ps1', '完整發布更新.ps1', '編譯打包.bat',
    'payload', '測試/SelfHealingPolicyTest.ahk', 'self-hosted-server', 'remote-control-web',
    'payload.zip', 'self-hosted-server.zip', '全自動鋤地.exe', 'update_manifest.example.json'
)
& git add -- $releasePaths
Assert-ExitCode '建立發布提交暫存區'
$stagedPaths = @(& git diff --cached --name-only)
if ($stagedPaths | Where-Object { $_ -match '^(\.vscode/|文字識別/)' }) {
    throw '安全檢查失敗：發布暫存區包含使用者保留的 VS Code 或 OCR 測試檔。'
}
if (-not $stagedPaths.Count) { Write-Host '沒有新的發布差異，沿用目前提交。' }
else {
    if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
        $CommitMessage = "發布 $PayloadVersion：自動修復與完整同步更新"
    }
    & git commit -m $CommitMessage
    Assert-ExitCode '建立 Git 提交'
}

if (-not $SkipPush) {
    & git push origin HEAD:main
    Assert-ExitCode '推送 GitHub'
    $remoteManifestUrl = Wait-RemoteManifest $manifest
    Write-Host "GitHub 已確認完整釋出：$($manifest.release_id)"
} else {
    $remoteManifestUrl = ''
    Write-Warning '已略過 GitHub 推送；不得把本次結果當作正式客戶端更新。'
}

if (-not $SkipDocker) {
    if ($SkipPush) {
        & (Join-Path $projectRoot 'self-hosted-server\Update-Server.ps1') -UseLocalFiles
    } else {
        & (Join-Path $projectRoot 'self-hosted-server\Update-Server.ps1') -ManifestUrl $remoteManifestUrl
    }

    $health = Invoke-RestMethod -UseBasicParsing -Uri 'https://220.135.218.98/health/ready' -TimeoutSec 30
    if ([string]$health.version -ne $ServerVersion -or
        ([string]$health.webSha256).ToUpperInvariant() -ne ([string]$manifest.web_sha256).ToUpperInvariant()) {
        throw "公開網站版本驗證失敗：server=$($health.version) web=$($health.webSha256)"
    }
    if (-not $SkipIntegrationSmoke) {
        $composeEnvPath = Join-Path $projectRoot 'self-hosted-server\.env'
        $composeFilePath = Join-Path $projectRoot 'self-hosted-server\compose.yml'
        & docker compose --env-file $composeEnvPath -f $composeFilePath `
            exec -T api node test/integration-smoke.mjs
        Assert-ExitCode 'Docker 控制、錄影、Range 播放與直播整合測試'
    }
} else {
    Write-Warning '已略過 Docker／網站更新；不得把本次結果視為所有元件同步完成。'
}

Write-Host "完整發布完成：$($manifest.release_id)"
Write-Host "Git=$(git rev-parse --short HEAD)｜Payload=$PayloadVersion｜Launcher=$LauncherVersion｜Server=$ServerVersion｜Web=$($manifest.web_sha256)"
