[CmdletBinding()]
param(
    [switch]$UseLocalFiles,
    [string]$ManifestUrl = 'https://raw.githubusercontent.com/derek3411888/-/main/update_manifest.example.json'
)

$ErrorActionPreference = 'Stop'
$originalLocation = (Get-Location).Path
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

function New-CryptoSecret([int]$ByteCount = 36) {
    $bytes = New-Object byte[] $ByteCount
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Ensure-CodexBridgeToken {
    $lines = @(Get-Content -LiteralPath $script:envPath -Encoding UTF8)
    $tokenIndex = -1
    $token = ''
    for ($index = 0; $index -lt $lines.Count; $index++) {
        if ($lines[$index] -match '^\s*CODEX_BRIDGE_TOKEN\s*=\s*(.*)$') {
            $tokenIndex = $index
            $token = $matches[1].Trim().Trim('"').Trim("'")
            break
        }
    }
    if ($token.Length -ge 32) { return }
    $newToken = New-CryptoSecret 36
    if ($tokenIndex -ge 0) {
        $lines[$tokenIndex] = "CODEX_BRIDGE_TOKEN=$newToken"
    } else {
        $lines += "CODEX_BRIDGE_TOKEN=$newToken"
    }
    $tempPath = "$script:envPath.$PID.tmp"
    [IO.File]::WriteAllLines($tempPath, $lines, [Text.UTF8Encoding]::new($false))
    try {
        [IO.File]::Replace($tempPath, $script:envPath, $null)
    } catch {
        Move-Item -LiteralPath $tempPath -Destination $script:envPath -Force
    }
    Write-Host '已為中央 Codex loopback 補齊本機橋接憑證。'
}

# 新版 API 在載入設定時即要求此憑證；必須早於任何 compose config/build。
Ensure-CodexBridgeToken

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

function Get-WebAssetHash([string]$Root) {
    $lines = foreach ($name in @('app.js', 'index.html', 'styles.css') | Sort-Object) {
        $path = Join-Path $Root "public\$name"
        if (-not (Test-Path -LiteralPath $path)) { throw "伺服器套件缺少網站檔案：$path" }
        "${name}:$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') } finally { $sha.Dispose() }
}

function Get-RunningServerIdentity {
    $compose = @('--env-file', $script:envPath, '-f', (Join-Path $script:serverRoot 'compose.yml'))
    $raw = @(& docker compose @compose exec -T api wget -q -O - http://127.0.0.1:3000/health/ready 2>$null) -join "`n"
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($raw)) {
        try {
            $health = $raw | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$health.version)) {
                return [pscustomobject]@{ Version = [string]$health.version; WebSha256 = ([string]$health.webSha256).ToUpperInvariant() }
            }
        } catch {}
    }
    $version = @(& docker compose @compose exec -T api node -e "console.log(JSON.parse(require('node:fs').readFileSync('/app/package.json','utf8')).version)" 2>$null) -join ''
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($version)) {
        return [pscustomobject]@{ Version = $version.Trim(); WebSha256 = '' }
    }
    return [pscustomobject]@{ Version = ''; WebSha256 = '' }
}

function Ensure-FixedIpRouting {
    $lines = @(Get-Content -LiteralPath $script:envPath -Encoding UTF8)
    $existing = $lines | Where-Object { $_ -match '^PUBLIC_IP_ADDRESS=\S+' } | Select-Object -First 1
    if ($existing) {
        $publicIp = ($existing -split '=', 2)[1].Trim()
    } else {
        $hostnameLine = $lines | Where-Object { $_ -match '^PUBLIC_HOSTNAME=\S+' } | Select-Object -First 1
        if (-not $hostnameLine) { throw '.env 缺少 PUBLIC_HOSTNAME 與 PUBLIC_IP_ADDRESS。' }
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
    }

    $updated = New-Object System.Collections.Generic.List[string]
    $srtUpdated = $false
    foreach ($line in $lines) {
        if ($line -match '^PUBLIC_SRT_HOST=') {
            $updated.Add("PUBLIC_SRT_HOST=$publicIp")
            $srtUpdated = $true
        } else {
            $updated.Add($line)
        }
        if (-not $existing -and $line -eq $hostnameLine) { $updated.Add("PUBLIC_IP_ADDRESS=$publicIp") }
    }
    if (-not $srtUpdated) { $updated.Add("PUBLIC_SRT_HOST=$publicIp") }
    [IO.File]::WriteAllLines($script:envPath, $updated, [Text.UTF8Encoding]::new($false))
    Write-Host "控制 API 與外網 SRT 已固定使用公網 IP：https://$publicIp/"
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

function Get-OptionalJsonValue($Object, [string]$Name, $Fallback) {
    if ($null -eq $Object) { return $Fallback }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Fallback }
    return $property.Value
}

function Update-InstalledCodexBridge {
    $bridgeRoot = Join-Path $env:ProgramData 'WutheringAutomation\CodexSupportBridge'
    $bridgeConfigPath = Join-Path $bridgeRoot 'config.json'
    $legacyBridgeRoot = Join-Path $env:LOCALAPPDATA 'WutheringAutomation\CodexSupportBridge'
    $legacyBridgeConfigPath = Join-Path $legacyBridgeRoot 'config.json'
    if (-not (Test-Path -LiteralPath $bridgeConfigPath -PathType Leaf) -and
        (Test-Path -LiteralPath $legacyBridgeConfigPath -PathType Leaf)) {
        # One-time migration: read the old AppContainer/LocalAppData config and
        # let the installer write a secured ProgramData installation.
        $bridgeConfigPath = $legacyBridgeConfigPath
    }
    if (-not (Test-Path -LiteralPath $bridgeConfigPath -PathType Leaf)) {
        Write-Host '本機尚未安裝 Codex 橋接，略過橋接更新。'
        return
    }
    $installer = Join-Path $script:serverRoot 'windows\Install-CodexSupportBridge.ps1'
    if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) { throw '新伺服器套件缺少 Codex 橋接安裝工具。' }
    $bridgeConfig = Get-Content -LiteralPath $bridgeConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $threadId = [string](Get-OptionalJsonValue $bridgeConfig 'ThreadId' '')
    if ($threadId -notmatch '^[0-9a-fA-F-]{36}$') { throw '既有 Codex 橋接 ThreadId 無效，無法安全更新。' }
    & $installer `
        -ThreadId $threadId `
        -Workspace ([string](Get-OptionalJsonValue $bridgeConfig 'Workspace' (Split-Path -Parent $script:serverRoot))) `
        -ProjectId ([string](Get-OptionalJsonValue $bridgeConfig 'ProjectId' 'ww-control-a3988')) `
        -ApiKey ([string](Get-OptionalJsonValue $bridgeConfig 'ApiKey' '')) `
        -Collection ([string](Get-OptionalJsonValue $bridgeConfig 'Collection' 'ahk_clients')) `
        -SelfHostedBaseUrl 'http://127.0.0.1:3000' `
        -PollSeconds ([int](Get-OptionalJsonValue $bridgeConfig 'PollSeconds' 15)) `
        -MinimumRequestIntervalSeconds ([int](Get-OptionalJsonValue $bridgeConfig 'MinimumRequestIntervalSeconds' 300))
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

    $sourceVersion = Get-ServerVersion $serverRoot
    $runningIdentity = Get-RunningServerIdentity
    $currentVersion = if ([string]::IsNullOrWhiteSpace($runningIdentity.Version)) { 'unknown' } else { $runningIdentity.Version }
    $targetVersion = $sourceVersion
    $targetWebSha256 = Get-WebAssetHash $serverRoot
    if (-not $UseLocalFiles) {
        Write-Host '讀取更新資訊並下載伺服器套件…'
        $manifestPath = Join-Path $tempRoot 'manifest.json'
        Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl -OutFile $manifestPath
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($requiredName in @('server_version', 'server_bundle_url', 'server_sha256', 'web_sha256')) {
            if ([string]::IsNullOrWhiteSpace([string]$manifest.$requiredName)) {
                throw "更新 manifest 缺少 $requiredName。"
            }
        }
        $targetVersion = [string]$manifest.server_version
        $targetWebSha256 = ([string]$manifest.web_sha256).ToUpperInvariant()
        if (-not [string]::IsNullOrWhiteSpace($runningIdentity.Version)) {
            if ([version]$targetVersion -lt [version]$runningIdentity.Version) {
                throw "拒絕把執行中容器由 $($runningIdentity.Version) 降級為 $targetVersion。"
            }
        }
        if ($targetVersion -eq $runningIdentity.Version -and
            $targetWebSha256 -eq $runningIdentity.WebSha256) {
            Write-Host "執行中的伺服器與網站已是最新版 $targetVersion。"
            Write-Host '重新確認 Windows Codex 橋接 watchdog…'
            Update-InstalledCodexBridge
            return
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
        $bundleWebSha256 = Get-WebAssetHash $stagingRoot
        if ($bundleWebSha256 -ne $targetWebSha256) {
            throw "套件網站 SHA-256 不符；預期 $targetWebSha256，實際 $bundleWebSha256。"
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

    Ensure-FixedIpRouting
    Invoke-Compose -ComposeArguments @('config', '-q')
    Write-Host '建立新伺服器映像並執行資料庫 migration…'
    Invoke-Compose -ComposeArguments @('build', '--pull', 'api', 'backup')
    Invoke-Compose -ComposeArguments @('run', '--rm', '--no-deps', 'caddy', 'caddy', 'validate', '--config', '/etc/caddy/Caddyfile')
    Invoke-Compose -ComposeArguments @('up', '-d')
    if (-not (Test-ServerHealth)) { throw '新版本在 3 分鐘內未通過網站／資料庫／影片服務健康檢查。' }

    $deployedIdentity = Get-RunningServerIdentity
    if ($deployedIdentity.Version -ne $targetVersion) {
        throw "容器回報版本 $($deployedIdentity.Version)；預期 $targetVersion。"
    }
    if ($deployedIdentity.WebSha256 -ne $targetWebSha256) {
        throw "容器網站 SHA-256 $($deployedIdentity.WebSha256)；預期 $targetWebSha256。"
    }

    Write-Host '更新並重新啟動 Windows Codex 橋接 watchdog…'
    Update-InstalledCodexBridge

    Write-Host "伺服器與網站更新完成：$currentVersion -> $targetVersion｜web=$targetWebSha256"
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
    Set-Location -LiteralPath $originalLocation
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
