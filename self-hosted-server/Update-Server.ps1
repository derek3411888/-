[CmdletBinding()]
param(
    [switch]$UseLocalFiles,
    [string]$ManifestUrl = 'https://raw.githubusercontent.com/derek3411888/-/main/update_manifest.example.json'
)

$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$envPath = Join-Path $serverRoot '.env'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("wuthering-control-update-" + [Guid]::NewGuid().ToString('N'))
$rollbackRoot = Join-Path $tempRoot 'rollback-source'
$stagingRoot = Join-Path $tempRoot 'staging'
$bundlePath = Join-Path $tempRoot 'self-hosted-server.zip'
$rollbackImageTag = ''
$rollbackReady = $false
$sourceChanged = $false

if (-not (Test-Path -LiteralPath $envPath)) {
    throw '找不到 .env，請先執行 Install-Server.ps1。'
}

function Invoke-Compose {
    param([Parameter(Mandatory = $true)][string[]]$ComposeArguments)
    & docker compose --env-file $script:envPath -f (Join-Path $script:serverRoot 'compose.yml') @ComposeArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Docker Compose 操作失敗：$($ComposeArguments -join ' ')"
    }
}

function Get-ServerVersion([string]$Root) {
    $packagePath = Join-Path $Root 'package.json'
    if (-not (Test-Path -LiteralPath $packagePath)) { throw "伺服器套件缺少 package.json：$Root" }
    $package = Get-Content -LiteralPath $packagePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([string]::IsNullOrWhiteSpace([string]$package.version)) { throw 'package.json 缺少 version。' }
    return [string]$package.version
}

function Ensure-PublicIpAddress {
    $lines = @(Get-Content -LiteralPath $script:envPath -Encoding UTF8)
    $existing = $lines | Where-Object { $_ -match '^PUBLIC_IP_ADDRESS=\S+' } | Select-Object -First 1
    if ($existing) { return }

    $hostnameLine = $lines | Where-Object { $_ -match '^PUBLIC_HOSTNAME=\S+' } | Select-Object -First 1
    if (-not $hostnameLine) { throw '.env 缺少 PUBLIC_HOSTNAME，無法建立固定 IP HTTPS 備援。' }
    $hostname = ($hostnameLine -split '=', 2)[1].Trim()
    try {
        $publicIp = [Net.Dns]::GetHostAddresses($hostname) |
            Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } |
            Select-Object -First 1 -ExpandProperty IPAddressToString
    } catch {
        throw "無法由 $hostname 解析固定公網 IPv4：$($_.Exception.Message)"
    }
    if ([string]::IsNullOrWhiteSpace($publicIp)) {
        throw "無法由 $hostname 解析固定公網 IPv4；請在 .env 手動加入 PUBLIC_IP_ADDRESS。"
    }

    $updated = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        $updated.Add($line)
        if ($line -eq $hostnameLine) { $updated.Add("PUBLIC_IP_ADDRESS=$publicIp") }
    }
    [IO.File]::WriteAllLines($script:envPath, $updated, [Text.UTF8Encoding]::new($false))
    Write-Host "已由 $hostname 建立固定 IP HTTPS 備援：https://$publicIp/"
}

function Copy-Tree([string]$Source, [string]$Destination, [string[]]$ExcludedTopLevel = @()) {
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $sourceFull = [IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    foreach ($item in Get-ChildItem -LiteralPath $sourceFull -Recurse -Force | Sort-Object FullName) {
        $relative = $item.FullName.Substring($sourceFull.Length).TrimStart('\', '/')
        $topLevel = ($relative -split '[\\/]', 2)[0]
        if ($ExcludedTopLevel -contains $topLevel) { continue }
        $target = Join-Path $Destination $relative
        if ($item.PSIsContainer) {
            New-Item -ItemType Directory -Path $target -Force | Out-Null
        } else {
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force
        }
    }
}

function Expand-VerifiedBundle([string]$ArchivePath, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName.Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($entryName)) { continue }
            if ($entryName.StartsWith('/') -or $entryName -match '^[A-Za-z]:' -or $entryName -match '(^|/)\.\.(/|$)') {
                throw "伺服器套件包含不安全路徑：$entryName"
            }
            if ($entryName -eq '.env' -or $entryName.StartsWith('node_modules/')) {
                throw "伺服器套件不得包含敏感或本機檔案：$entryName"
            }
        }
    } finally {
        $archive.Dispose()
    }
    Expand-Archive -LiteralPath $ArchivePath -DestinationPath $Destination -Force
}

function Test-ServerHealth {
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    do {
        & docker compose --env-file $script:envPath -f (Join-Path $script:serverRoot 'compose.yml') exec -T api wget -q -O - http://127.0.0.1:3000/health/ready 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $running = @(& docker compose --env-file $script:envPath -f (Join-Path $script:serverRoot 'compose.yml') ps --status running --services 2>$null)
            $required = @('postgres', 'api', 'mediamtx', 'caddy', 'backup')
            if (@($required | Where-Object { $_ -notin $running }).Count -eq 0) { return $true }
        }
        Start-Sleep -Seconds 3
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Restore-PreviousVersion {
    Write-Warning '正在回復上一版伺服器檔案與 API 映像…'
    if ($script:sourceChanged -and (Test-Path -LiteralPath $script:rollbackRoot)) {
        Copy-Tree $script:rollbackRoot $script:serverRoot
    }
    if (-not [string]::IsNullOrWhiteSpace($script:rollbackImageTag)) {
        & docker image tag $script:rollbackImageTag 'wuthering-control-api:current'
        if ($LASTEXITCODE -ne 0) { throw '無法還原上一版 API 映像。' }
    }
    & docker compose --env-file $script:envPath -f (Join-Path $script:serverRoot 'compose.yml') build backup
    if ($LASTEXITCODE -ne 0) { Write-Warning '上一版備份容器重建失敗，API 仍會繼續嘗試回復。' }
    & docker compose --env-file $script:envPath -f (Join-Path $script:serverRoot 'compose.yml') up -d --no-build
    if ($LASTEXITCODE -ne 0) { throw '上一版容器回復失敗，請立即查看 Docker logs。' }
    if (-not (Test-ServerHealth)) { throw '上一版已重新啟動，但未通過健康檢查。' }
}

New-Item -ItemType Directory -Path $tempRoot, $rollbackRoot, $stagingRoot -Force | Out-Null
try {
    Set-Location -LiteralPath $serverRoot
    & docker info | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Docker Desktop 尚未啟動。' }

    $currentVersion = Get-ServerVersion $serverRoot
    $targetVersion = $currentVersion
    if (-not $UseLocalFiles) {
        Write-Host '讀取更新資訊並下載伺服器套件…'
        $manifestPath = Join-Path $tempRoot 'manifest.json'
        Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl -OutFile $manifestPath
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($requiredName in @('server_version', 'server_bundle_url', 'server_sha256')) {
            if ([string]::IsNullOrWhiteSpace([string]$manifest.$requiredName)) {
                throw "更新 manifest 缺少 $requiredName。"
            }
        }
        $targetVersion = [string]$manifest.server_version
        try {
            if ([version]$targetVersion -le [version]$currentVersion) {
                Write-Host "目前已是最新伺服器版本 $currentVersion。"
                return
            }
        } catch {
            if ($targetVersion -eq $currentVersion) {
                Write-Host "目前已是最新伺服器版本 $currentVersion。"
                return
            }
        }
        Invoke-WebRequest -UseBasicParsing -Uri ([string]$manifest.server_bundle_url) -OutFile $bundlePath
        $actualHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256).Hash
        if ($actualHash -ne ([string]$manifest.server_sha256).ToUpperInvariant()) {
            throw "伺服器套件 SHA-256 不符；預期 $($manifest.server_sha256)，實際 $actualHash。"
        }
        Expand-VerifiedBundle $bundlePath $stagingRoot
        $bundleVersion = Get-ServerVersion $stagingRoot
        if ($bundleVersion -ne $targetVersion) {
            throw "套件版本 $bundleVersion 與 manifest 版本 $targetVersion 不一致。"
        }
    }

    Write-Host "建立更新前資料庫備份（$currentVersion -> $targetVersion）…"
    Invoke-Compose -ComposeArguments @('exec', '-T', 'backup', '/usr/local/bin/backup-now.sh', 'preupdate')

    $currentImageId = [string](& docker image inspect 'wuthering-control-api:current' --format '{{.Id}}' 2>$null)
    if ([string]::IsNullOrWhiteSpace($currentImageId)) { throw '找不到目前的 API 映像，請先完成初次安裝。' }
    $rollbackImageTag = 'wuthering-control-api:rollback-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmss')
    & docker image tag $currentImageId.Trim() $rollbackImageTag
    if ($LASTEXITCODE -ne 0) { throw '無法保存上一版 API 映像。' }
    $rollbackReady = $true

    if (-not $UseLocalFiles) {
        Copy-Tree $serverRoot $rollbackRoot @('.env', 'node_modules')
        Copy-Tree $stagingRoot $serverRoot
        $sourceChanged = $true
    }

    Ensure-PublicIpAddress
    Invoke-Compose -ComposeArguments @('config', '-q')
    Write-Host '建立新伺服器映像並執行資料庫 migration…'
    Invoke-Compose -ComposeArguments @('build', '--pull', 'api', 'backup')
    Invoke-Compose -ComposeArguments @('run', '--rm', '--no-deps', 'caddy', 'caddy', 'validate', '--config', '/etc/caddy/Caddyfile')
    Invoke-Compose -ComposeArguments @('up', '-d')
    if (-not (Test-ServerHealth)) { throw '新版本在 3 分鐘內未通過網站／資料庫／影片服務健康檢查。' }

    Write-Host "伺服器更新完成：$currentVersion -> $(Get-ServerVersion $serverRoot)"
    if ($rollbackImageTag) { & docker image rm $rollbackImageTag 2>$null | Out-Null }
} catch {
    $failure = $_.Exception.Message
    if (-not $rollbackReady) { throw $failure }
    try {
        Restore-PreviousVersion
        throw "新版本更新失敗，已自動回復上一版：$failure"
    } catch {
        if ($_.Exception.Message -like '新版本更新失敗*') { throw }
        throw "更新失敗，且自動回復未完成：$failure；回復錯誤：$($_.Exception.Message)"
    }
} finally {
    Set-Location -LiteralPath $serverRoot
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
