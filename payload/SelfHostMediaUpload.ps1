[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('sync', 'finalize')]
    [string]$Mode,

    [Parameter(Mandatory = $true)]
    [string]$SessionDir
)

$ErrorActionPreference = 'Stop'

function Read-IniFile([string]$Path) {
    $result = @{}
    $section = ''
    # StreamReader-backed overload detects UTF-8/UTF-16 BOM, matching AHK IniWrite
    # as well as existing hand-edited UTF-8 configuration files.
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) { continue }
        if ($trimmed -match '^\[(.+)\]$') {
            $section = $matches[1].Trim().ToLowerInvariant()
            if (-not $result.ContainsKey($section)) { $result[$section] = @{} }
            continue
        }
        if ($section -and $trimmed.Contains('=')) {
            $name, $value = $trimmed -split '=', 2
            $result[$section][$name.Trim().ToLowerInvariant()] = $value.Trim()
        }
    }
    return $result
}

function Get-IniValue($Ini, [string]$Section, [string]$Name, [string]$Default = '') {
    $sectionKey = $Section.ToLowerInvariant()
    $nameKey = $Name.ToLowerInvariant()
    if ($Ini.ContainsKey($sectionKey) -and $Ini[$sectionKey].ContainsKey($nameKey)) {
        return [string]$Ini[$sectionKey][$nameKey]
    }
    return $Default
}

function Invoke-Json([string]$Method, [string]$Path, $Body = $null) {
    $headers = @{ Authorization = "Bearer $script:DeviceToken"; Accept = 'application/json' }
    $parameters = @{
        Uri = "$script:ServerUrl$Path"
        Method = $Method
        Headers = $headers
        UseBasicParsing = $true
        TimeoutSec = 45
    }
    if ($null -ne $Body) {
        $parameters.ContentType = 'application/json; charset=utf-8'
        $parameters.Body = ($Body | ConvertTo-Json -Depth 8 -Compress)
    }
    $response = Invoke-WebRequest @parameters
    if ([string]::IsNullOrWhiteSpace($response.Content)) { return $null }
    return $response.Content | ConvertFrom-Json
}

function Get-LiveUploadRate([int]$ConfiguredMbps) {
    try {
        $control = Invoke-Json 'GET' '/api/v1/device/control'
        if ($control.live.active) { return [Math]::Min($ConfiguredMbps, 2) }
    } catch {
        # Live status is an optimization only; upload retries remain authoritative.
    }
    return $ConfiguredMbps
}

function Assert-SyncNotPreempted {
    if ($Mode -eq 'sync' -and (Test-Path -LiteralPath (Join-Path $resolvedSession '.finalize_requested'))) {
        throw [OperationCanceledException]::new('錄影已要求收尾，既有同步上傳主動讓位。')
    }
}

function Send-WorkerStatus([string]$State, [string]$Detail, [long]$Current, [long]$Total, [switch]$Force) {
    if ($Mode -ne 'finalize') { return }
    $now = [Environment]::TickCount64
    if (-not $Force -and $now - $script:LastStatusTick -lt 3000) { return }
    $script:LastStatusTick = $now
    try {
        Invoke-Json 'PUT' '/api/v1/device/recording/status' @{
            state = $State
            detail = $Detail
            active = $false
            baseName = $baseName
            resultPath = ''
            failureStorage = $resolvedSession
            progressCurrent = [Math]::Max(0, $Current)
            progressTotal = [Math]::Max(0, $Total)
            progressUnit = 'bytes'
        } | Out-Null
    } catch {
        # 狀態回報只是可觀測性；上傳本身的回應才是權威結果。
    }
}

function Send-Segment([IO.FileInfo]$File, [int]$Index, [string]$SessionId, [int]$ConfiguredMbps) {
    $hash = (Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    $segment = Invoke-Json 'POST' "/api/v1/device/recordings/sessions/$SessionId/segments" @{
        index = $Index
        name = $File.Name
        sizeBytes = [long]$File.Length
        sha256 = $hash
    }
    $segmentId = [string]$segment.id
    if (-not $segmentId) { throw "伺服器未回傳片段 ID：$($File.Name)" }
    if ([string]$segment.state -eq 'READY') { return }
    if ([string]$segment.state -eq 'ERROR') {
        Invoke-Json 'POST' "/api/v1/device/recordings/segments/$segmentId/retry" @{} | Out-Null
    }

    $state = Invoke-Json 'GET' "/api/v1/device/recordings/segments/$segmentId"
    $offset = [long]$state.received_bytes
    if ($offset -lt 0 -or $offset -gt $File.Length) { throw "伺服器續傳位置無效：$offset" }
    if ($offset -eq $File.Length) { return }

    $chunkBytes = 1MB
    $uploadedThisRun = 0L
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $rateMbps = Get-LiveUploadRate $ConfiguredMbps
    $stream = [IO.File]::Open($File.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $stream.Position = $offset
        $buffer = New-Object byte[] $chunkBytes
        while ($offset -lt $File.Length) {
            Assert-SyncNotPreempted
            $remaining = [long]$File.Length - $offset
            $wanted = [int][Math]::Min($buffer.Length, $remaining)
            $read = $stream.Read($buffer, 0, $wanted)
            if ($read -le 0) { throw "讀取片段中途結束：$($File.Name)" }
            if ($read -eq $buffer.Length) { $body = $buffer } else {
                $body = New-Object byte[] $read
                [Array]::Copy($buffer, $body, $read)
            }
            $end = $offset + $read - 1
            $headers = @{
                Authorization = "Bearer $script:DeviceToken"
                Accept = 'application/json'
                'Content-Range' = "bytes $offset-$end/$($File.Length)"
            }
            Invoke-WebRequest -Uri "$script:ServerUrl/api/v1/device/recordings/segments/$segmentId" `
                -Method Put -Headers $headers -ContentType 'application/octet-stream' -Body $body `
                -UseBasicParsing -TimeoutSec 120 | Out-Null
            $offset += $read
            $uploadedThisRun += $read
            Send-WorkerStatus 'central_uploading' `
                "正在加密續傳第 $($Index + 1) 段" `
                ($script:ProgressBaseBytes + $offset) $script:ExpectedBytes

            $bytesPerSecond = [Math]::Max(125000, $rateMbps * 125000)
            $targetMs = [double]$uploadedThisRun / $bytesPerSecond * 1000
            $waitMs = [int][Math]::Floor($targetMs - $clock.Elapsed.TotalMilliseconds)
            if ($waitMs -gt 0) { Start-Sleep -Milliseconds ([Math]::Min($waitMs, 10000)) }
        }
    } finally {
        $stream.Dispose()
    }
}

$resolvedSession = [IO.Path]::GetFullPath($SessionDir)
$leaf = Split-Path -Leaf $resolvedSession
if ($leaf -notmatch '^wuthering_auto_recording_\d{8}_\d{6}(?:_\d+)?$') {
    throw '拒絕處理不安全的錄影工作階段路徑。'
}
$sessionIniPath = Join-Path $resolvedSession 'session.ini'
$markerPath = Join-Path $resolvedSession '.wuthering_recording_session'
if (-not (Test-Path -LiteralPath $sessionIniPath) -or -not (Test-Path -LiteralPath $markerPath)) {
    throw '錄影工作階段缺少安全標記或 session.ini。'
}

$sessionIni = Read-IniFile $sessionIniPath
$configPath = Get-IniValue $sessionIni 'recording' 'config_path'
$baseName = Get-IniValue $sessionIni 'recording' 'base_name'
if (-not (Test-Path -LiteralPath $configPath)) { throw '找不到主程式設定檔。' }
if ($baseName -notmatch '^wuthering_auto_recording_\d{8}_\d{6}$') { throw 'base_name 格式無效。' }

$config = Read-IniFile $configPath
$script:ServerUrl = (Get-IniValue $config 'self_hosted' 'server_url').TrimEnd('/')
$selfHostedMode = (Get-IniValue $config 'self_hosted' 'mode' 'shadow').ToLowerInvariant()
$protectedToken = Get-IniValue $config 'self_hosted' 'device_token_dpapi'
if (-not $script:ServerUrl -or $selfHostedMode -eq 'disabled') { exit 0 }
if ($script:ServerUrl -notmatch '^https://[A-Za-z0-9.-]+(?::\d+)?$' -and
    $script:ServerUrl -notmatch '^http://(?:localhost|127\.0\.0\.1)(?::\d+)?$') {
    throw '自架伺服器 URL 不符合安全規則。'
}
if (-not $protectedToken) { throw '尚未取得自架裝置憑證。' }

$protectedBytes = [Convert]::FromBase64String($protectedToken)
Add-Type -AssemblyName System.Security
$plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
    $protectedBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
$script:DeviceToken = [Text.Encoding]::UTF8.GetString($plainBytes)
if ($script:DeviceToken -notmatch '^[A-Za-z0-9_-]{40,180}$') { throw '解密後的裝置憑證格式無效。' }

$limitMbps = 8
[void][int]::TryParse((Get-IniValue $config 'self_hosted' 'upload_limit_mbps' '8'), [ref]$limitMbps)
$limitMbps = [Math]::Max(1, [Math]::Min(100, $limitMbps))
$allSegments = @(Get-ChildItem -LiteralPath $resolvedSession -Filter 'segment_*.mkv' -File | Sort-Object Name)
if (-not $allSegments.Count) { exit 0 }
$expectedBytes = [long]0
foreach ($segmentFile in $allSegments) { $expectedBytes += [long]$segmentFile.Length }
$script:ExpectedBytes = $expectedBytes
$script:ProgressBaseBytes = [long]0
$script:LastStatusTick = [long]0

$sessionBody = @{
    clientSessionId = $leaf
    baseName = $baseName
    startedAt = Get-IniValue $sessionIni 'recording' 'started_at'
}
if ($Mode -eq 'finalize') {
    $sessionBody.expectedSegments = $allSegments.Count
    $sessionBody.expectedBytes = $expectedBytes
}
$session = Invoke-Json 'POST' '/api/v1/device/recordings/sessions' $sessionBody
$sessionId = [string]$session.id
if (-not $sessionId) { throw '伺服器未回傳錄影工作階段 ID。' }

$uploadCount = if ($Mode -eq 'finalize') { $allSegments.Count } else { [Math]::Max(0, $allSegments.Count - 1) }
Send-WorkerStatus 'central_uploading' "準備續傳 $uploadCount 個封口片段" 0 $expectedBytes -Force
for ($index = 0; $index -lt $uploadCount; $index++) {
    Assert-SyncNotPreempted
    Send-Segment $allSegments[$index] $index $sessionId $limitMbps
    $script:ProgressBaseBytes += [long]$allSegments[$index].Length
    Send-WorkerStatus 'central_uploading' `
        "中央已接收第 $($index + 1)/$uploadCount 段" `
        $script:ProgressBaseBytes $expectedBytes -Force
}

if ($Mode -eq 'finalize') {
    Send-WorkerStatus 'central_processing' '全部片段已送達，中央正在轉換與合併' `
        $expectedBytes $expectedBytes -Force
    Invoke-Json 'POST' "/api/v1/device/recordings/sessions/$sessionId/complete" @{
        expectedSegments = $allSegments.Count
        expectedBytes = $expectedBytes
    } | Out-Null
}
