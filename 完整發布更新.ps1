[CmdletBinding()]
param(
    [string]$PayloadVersion = '4.87',
    [string]$LauncherVersion = '4.98',
    [string]$ServerVersion = '1.0.47',
    [string]$CommitMessage = '',
    [switch]$SkipPush,
    [switch]$SkipDocker,
    [switch]$SkipIntegrationSmoke
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $projectRoot
. (Join-Path $projectRoot 'ProjectDevelopmentPaths.ps1')
$developmentPaths = Initialize-ProjectDevelopmentPaths -ProjectRoot $projectRoot -RunName 'release'
$developmentSucceeded = $false

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

function Set-ManifestArtifactCommit([string]$Path, [string]$ArtifactCommit) {
    if ($ArtifactCommit -notmatch '^[0-9a-f]{40}$') { throw "無效的發布檔 commit：$ArtifactCommit" }
    $value = Read-Manifest $Path
    $prefix = 'https://raw.githubusercontent.com/derek3411888/-/'
    foreach ($name in @('payload_url', 'launcher_url', 'server_bundle_url')) {
        $url = [string]$value.$name
        if (-not $url.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "manifest $name 不是預期的 GitHub raw 網址。"
        }
        $value.$name = $url -replace ([regex]::Escape($prefix) + '[^/]+/'), ($prefix + $ArtifactCommit + '/')
        if ([string]$value.$name -notlike "$prefix$ArtifactCommit/*") {
            throw "manifest $name 無法固定到 commit $ArtifactCommit。"
        }
    }
    [IO.File]::WriteAllText($Path, ($value | ConvertTo-Json) + "`n", [Text.UTF8Encoding]::new($false))
    return Read-Manifest $Path
}

function Wait-RemoteManifest($Expected, [string]$CommitSha, [int]$TimeoutSeconds = 180) {
    $releaseId = [string]$Expected.release_id
    if ([string]::IsNullOrWhiteSpace($CommitSha)) { throw '無法取得本次發布的 Git commit。' }
    # main 分支的 raw CDN 可能短時間回傳前一版。以不變的 commit SHA
    # 驗證本次發布，才不會把 GitHub 快取延遲誤判成發布失敗。
    $baseUrl = "https://raw.githubusercontent.com/derek3411888/-/$CommitSha/update_manifest.example.json"
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

try {
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
    '.gitignore', 'PROJECT_AI_HANDOFF.md', 'DEVELOPMENT_ARTIFACTS.md',
    'ProjectDevelopmentPaths.ps1', 'LauncherProcessCleanupPolicy.ahk',
    '打包啟動器.ahk', '打包更新.ps1', '完整發布更新.ps1', '編譯打包.bat',
    'payload', '測試', '文字識別/文字識別測試.ahk', '郵件測試/寄送信件測試.ahk',
    'self-hosted-server', 'remote-control-web',
    'payload.zip', 'self-hosted-server.zip', '全自動鋤地.exe', 'update_manifest.example.json'
)
& git add -- $releasePaths
Assert-ExitCode '建立發布提交暫存區'
$stagedPaths = @(& git -c core.quotepath=false diff --cached --name-only)
if ($stagedPaths | Where-Object {
    $_ -match '^\.vscode/' -or $_ -eq '文字識別/LRMCAI主視窗OCR測試.ahk'
}) {
    throw '安全檢查失敗：發布暫存區包含使用者保留的 VS Code 或 LRMCAI OCR 測試檔。'
}
if (-not $stagedPaths.Count) { Write-Host '沒有新的發布差異，沿用目前提交。' }
else {
    if ([string]::IsNullOrWhiteSpace($CommitMessage)) {
        $CommitMessage = "發布 $PayloadVersion：執行檔案集中至程式資料夾"
    }
    & git commit -m $CommitMessage
    Assert-ExitCode '建立 Git 提交'
}

# 以「包含三份發布檔」的 commit 當作不變來源；再單獨提交
# manifest。這樣沒有 commit hash 自我參照，也不會受 main 分支 raw CDN 快取影響。
$artifactCommit = ([string](& git rev-parse HEAD)).Trim().ToLowerInvariant()
$manifest = Set-ManifestArtifactCommit $manifestPath $artifactCommit
& git add -- $manifestPath
Assert-ExitCode '暫存固定發布檔來源的 manifest'
if (@(& git diff --cached --name-only).Count -gt 0) {
    & git diff --cached --check
    Assert-ExitCode '固定發布檔 manifest 檢查'
    & git commit -m "固定發布檔來源 $($manifest.release_id)"
    Assert-ExitCode '建立固定發布檔 manifest 提交'
}

if (-not $SkipPush) {
    & git push origin HEAD:main
    Assert-ExitCode '推送 GitHub'
    $publishedCommit = ([string](& git rev-parse HEAD)).Trim()
    $remoteManifestUrl = Wait-RemoteManifest $manifest $publishedCommit
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
        Assert-ExitCode 'Docker 控制、正式影片停用與直播整合測試'
    }
} else {
    Write-Warning '已略過 Docker／網站更新；不得把本次結果視為所有元件同步完成。'
}

Write-Host "完整發布完成：$($manifest.release_id)"
Write-Host "Git=$(git rev-parse --short HEAD)｜Payload=$PayloadVersion｜Launcher=$LauncherVersion｜Server=$ServerVersion｜Web=$($manifest.web_sha256)"
$developmentSucceeded = $true
} finally {
    Complete-ProjectDevelopmentPaths -Context $developmentPaths -RemoveRunDirectory:$developmentSucceeded
}
