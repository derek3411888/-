[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'WutheringAutomation\CodexSupportBridge\config.json'),
    [switch]$Once,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$ExpectedAction = 'QUEUE_MESSAGE_V1'
$LegacyAction = 'FIX_SCRIPT'
$FixedPrompt = '現在腳本有問題，請你找出問題並修正'
$BridgeVersion = '1.1.0'
$MaxMessageLength = 1000

function Read-JsonFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { throw "找不到 Codex 橋接設定：$Path" }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Assert-Config($Config) {
    if ([string]$Config.ProjectId -notmatch '^[A-Za-z0-9._-]{3,120}$') { throw 'ProjectId 格式無效。' }
    if ([string]::IsNullOrWhiteSpace([string]$Config.ApiKey)) { throw 'ApiKey 不可空白。' }
    if ([string]$Config.Collection -notmatch '^[A-Za-z0-9._-]{1,120}$') { throw 'Collection 格式無效。' }
    if ([string]$Config.DocumentId -ne '__codex_support') { throw '只允許固定的 __codex_support 文件。' }
    if ([string]$Config.ThreadId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Codex ThreadId 格式無效。' }
    if (-not (Test-Path -LiteralPath ([string]$Config.Workspace) -PathType Container)) { throw 'Codex 工作區不存在。' }
    $poll = [int]$Config.PollSeconds
    if ($poll -lt 10 -or $poll -gt 300) { throw 'PollSeconds 必須介於 10 到 300 秒。' }
    $cooldown = [int]$Config.MinimumRequestIntervalSeconds
    if ($cooldown -lt 60 -or $cooldown -gt 3600) { throw 'MinimumRequestIntervalSeconds 必須介於 60 到 3600 秒。' }
}

function Find-CodexExecutable($Config) {
    $configured = [string]$Config.CodexPath
    if ($configured -and (Test-Path -LiteralPath $configured -PathType Leaf)) { return $configured }

    $command = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($command -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { return $command.Source }

    $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    $candidate = Get-ChildItem -LiteralPath $binRoot -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($candidate) { return $candidate.FullName }
    throw '找不到 Codex CLI；請先安裝或啟動 Codex 桌面版。'
}

function Get-FirestoreBaseUrl($Config) {
    $project = [Uri]::EscapeDataString([string]$Config.ProjectId)
    $collection = [Uri]::EscapeDataString([string]$Config.Collection)
    $document = [Uri]::EscapeDataString([string]$Config.DocumentId)
    return "https://firestore.googleapis.com/v1/projects/$project/databases/(default)/documents/$collection/$document"
}

function Get-FirestoreDocument($Config) {
    $url = "$(Get-FirestoreBaseUrl $Config)?key=$([Uri]::EscapeDataString([string]$Config.ApiKey))"
    try {
        return Invoke-RestMethod -Method Get -Uri $url -TimeoutSec 15
    } catch {
        $response = $_.Exception.Response
        if ($null -ne $response -and [int]$response.StatusCode -eq 404) { return $null }
        throw
    }
}

function ConvertTo-FirestoreField($Value) {
    if ($Value -is [bool]) { return @{ booleanValue = [bool]$Value } }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or
        $Value -is [int64] -or $Value -is [uint16] -or $Value -is [uint32]) {
        return @{ integerValue = ([Convert]::ToInt64($Value)).ToString([Globalization.CultureInfo]::InvariantCulture) }
    }
    return @{ stringValue = [string]$Value }
}

function Set-FirestoreFields($Config, [hashtable]$Values) {
    $fields = @{}
    foreach ($name in $Values.Keys) { $fields[$name] = ConvertTo-FirestoreField $Values[$name] }
    $query = New-Object Collections.Generic.List[string]
    $query.Add("key=$([Uri]::EscapeDataString([string]$Config.ApiKey))")
    foreach ($name in ($Values.Keys | Sort-Object)) {
        $query.Add("updateMask.fieldPaths=$([Uri]::EscapeDataString([string]$name))")
    }
    $url = "$(Get-FirestoreBaseUrl $Config)?$($query -join '&')"
    $body = @{ fields = $fields } | ConvertTo-Json -Depth 8 -Compress
    Invoke-RestMethod -Method Patch -Uri $url -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 15 | Out-Null
}

function Read-FirestoreField($Document, [string]$Name, $Fallback = $null) {
    if ($null -eq $Document -or $null -eq $Document.fields) { return $Fallback }
    $property = $Document.fields.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Fallback }
    $field = $property.Value
    foreach ($kind in @('integerValue', 'stringValue', 'booleanValue', 'timestampValue')) {
        $valueProperty = $field.PSObject.Properties[$kind]
        if ($null -ne $valueProperty) {
            if ($kind -eq 'integerValue') { return [long]$valueProperty.Value }
            return $valueProperty.Value
        }
    }
    return $Fallback
}

function Read-OptionalProperty($Object, [string]$Name, $Fallback) {
    if ($null -eq $Object) { return $Fallback }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Fallback }
    return $property.Value
}

function Read-MetadataValue([hashtable]$Metadata, [string]$Name, $Fallback) {
    if ($Metadata.ContainsKey($Name)) { return $Metadata[$Name] }
    return $Fallback
}

function Read-State([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            LastHandledNonce = 0L
            LastStatus = ''
            LastDetail = ''
            LastQueuedAt = 0L
            LastReceivedAt = 0L
            LastValidatedAt = 0L
            LastAttemptCount = 0
            LastAttemptAt = 0L
            LastMessageSha256 = ''
            LastMessageLength = 0
            LastErrorCode = ''
            LastErrorDetail = ''
        }
    }
    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            LastHandledNonce = [long](Read-OptionalProperty $state 'LastHandledNonce' 0L)
            LastStatus = [string](Read-OptionalProperty $state 'LastStatus' '')
            LastDetail = [string](Read-OptionalProperty $state 'LastDetail' '')
            LastQueuedAt = [long](Read-OptionalProperty $state 'LastQueuedAt' 0L)
            LastReceivedAt = [long](Read-OptionalProperty $state 'LastReceivedAt' 0L)
            LastValidatedAt = [long](Read-OptionalProperty $state 'LastValidatedAt' 0L)
            LastAttemptCount = [int](Read-OptionalProperty $state 'LastAttemptCount' 0)
            LastAttemptAt = [long](Read-OptionalProperty $state 'LastAttemptAt' 0L)
            LastMessageSha256 = [string](Read-OptionalProperty $state 'LastMessageSha256' '')
            LastMessageLength = [int](Read-OptionalProperty $state 'LastMessageLength' 0)
            LastErrorCode = [string](Read-OptionalProperty $state 'LastErrorCode' '')
            LastErrorDetail = [string](Read-OptionalProperty $state 'LastErrorDetail' '')
        }
    } catch {
        throw "Codex 橋接狀態檔損壞：$Path"
    }
}

function Save-State(
    [string]$Path,
    [long]$Nonce,
    [string]$Status,
    [string]$Detail,
    [long]$QueuedAt,
    [hashtable]$Metadata = @{}
) {
    $directory = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $tempPath = "$Path.$PID.tmp"
    $payload = [ordered]@{
        LastHandledNonce = $Nonce
        LastStatus = $Status
        LastDetail = $Detail
        LastQueuedAt = $QueuedAt
        LastReceivedAt = [long](Read-MetadataValue $Metadata 'ReceivedAt' 0L)
        LastValidatedAt = [long](Read-MetadataValue $Metadata 'ValidatedAt' 0L)
        LastAttemptCount = [int](Read-MetadataValue $Metadata 'AttemptCount' 0)
        LastAttemptAt = [long](Read-MetadataValue $Metadata 'AttemptAt' 0L)
        LastMessageSha256 = [string](Read-MetadataValue $Metadata 'MessageSha256' '')
        LastMessageLength = [int](Read-MetadataValue $Metadata 'MessageLength' 0)
        LastErrorCode = [string](Read-MetadataValue $Metadata 'ErrorCode' '')
        LastErrorDetail = [string](Read-MetadataValue $Metadata 'ErrorDetail' '')
        UpdatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($tempPath, $payload, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Write-BridgeLog([string]$Path, [string]$Level, [string]$Message) {
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

function Publish-RequestStatus(
    $Config,
    [long]$Nonce,
    [string]$State,
    [string]$Detail,
    [long]$QueuedAt = 0L,
    [hashtable]$Extra = @{}
) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $safeDetail = [string]$Detail
    if ($safeDetail.Length -gt 500) { $safeDetail = $safeDetail.Substring(0, 500) }
    $values = @{
        bridgeState = $State
        bridgeStatusNonce = $Nonce
        bridgeDetail = $safeDetail
        bridgeUpdatedAt = $now
        bridgeHeartbeatAt = $now
        bridgeHost = [string]$env:COMPUTERNAME
        bridgeVersion = $BridgeVersion
    }
    if ($QueuedAt -gt 0) { $values.bridgeQueuedAt = $QueuedAt }
    foreach ($name in $Extra.Keys) { $values[$name] = $Extra[$name] }
    Set-FirestoreFields $Config $values
}

function Normalize-RequestMessage([string]$Value) {
    $normalized = $Value -replace "`r`n", "`n" -replace "`r", "`n"
    $normalized = $normalized -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ''
    return $normalized.Trim()
}

function Get-MessageSha256([string]$Message) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Message)
        return (($algorithm.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    } finally {
        $algorithm.Dispose()
    }
}

function Get-ReplayMetadata($State) {
    return @{
        bridgeReceivedAt = [long]$State.LastReceivedAt
        bridgeValidatedAt = [long]$State.LastValidatedAt
        bridgeAttemptCount = [int]$State.LastAttemptCount
        bridgeLastAttemptAt = [long]$State.LastAttemptAt
        bridgeNextRetryAt = 0L
        bridgeMessageSha256 = [string]$State.LastMessageSha256
        bridgeMessageLength = [int]$State.LastMessageLength
        bridgeErrorCode = [string]$State.LastErrorCode
        bridgeErrorDetail = [string]$State.LastErrorDetail
    }
}

$config = Read-JsonFile $ConfigPath
Assert-Config $config
$codexPath = Find-CodexExecutable $config
$installRoot = Split-Path -Parent $ConfigPath
$statePath = Join-Path $installRoot 'state.json'
$logPath = Join-Path $installRoot 'bridge.log'

if ($ValidateOnly) {
    $version = @(& $codexPath --version 2>&1) -join ' '
    if ($LASTEXITCODE -ne 0) { throw "Codex CLI 驗證失敗：$version" }
    $document = Get-FirestoreDocument $config
    [pscustomobject]@{
        Ok = $true
        BridgeVersion = $BridgeVersion
        CodexVersion = $version.Trim()
        ThreadId = [string]$config.ThreadId
        FirestoreReachable = $true
        SupportDocumentExists = ($null -ne $document)
        PollSeconds = [int]$config.PollSeconds
        SupportsCustomMessage = $true
        MaxMessageLength = $MaxMessageLength
    } | ConvertTo-Json -Depth 4
    exit 0
}

$mutex = [Threading.Mutex]::new($false, 'Local\WutheringCodexSupportBridge')
if (-not $mutex.WaitOne(0)) { exit 0 }

try {
    Write-BridgeLog $logPath 'INFO' "Codex bridge $BridgeVersion started"
    $lastHeartbeat = 0L
    do {
        try {
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            if ($now - $lastHeartbeat -ge 90000) {
                Set-FirestoreFields $config @{
                    bridgeHeartbeatAt = $now
                    bridgeHost = [string]$env:COMPUTERNAME
                    bridgeVersion = $BridgeVersion
                }
                $lastHeartbeat = $now
            }

            $document = Get-FirestoreDocument $config
            $nonce = [long](Read-FirestoreField $document 'supportRequestNonce' 0L)
            $action = [string](Read-FirestoreField $document 'supportRequestAction' '')
            $state = Read-State $statePath

            if ($nonce -gt 0 -and $nonce -le $state.LastHandledNonce) {
                $remoteStatusNonce = [long](Read-FirestoreField $document 'bridgeStatusNonce' 0L)
                $remoteState = [string](Read-FirestoreField $document 'bridgeState' '')
                if ($remoteStatusNonce -ne $nonce -or $remoteState -ne $state.LastStatus) {
                    Publish-RequestStatus $config $nonce $state.LastStatus $state.LastDetail $state.LastQueuedAt (Get-ReplayMetadata $state)
                }
            } elseif ($nonce -gt $state.LastHandledNonce) {
                $remoteStatusNonce = [long](Read-FirestoreField $document 'bridgeStatusNonce' 0L)
                $previousReceivedAt = if ($remoteStatusNonce -eq $nonce) {
                    [long](Read-FirestoreField $document 'bridgeReceivedAt' 0L)
                } else { 0L }
                $previousAttemptCount = if ($remoteStatusNonce -eq $nonce) {
                    [int](Read-FirestoreField $document 'bridgeAttemptCount' 0)
                } else { 0 }
                $previousAttemptAt = if ($remoteStatusNonce -eq $nonce) {
                    [long](Read-FirestoreField $document 'bridgeLastAttemptAt' 0L)
                } else { 0L }
                $receivedAt = if ($previousReceivedAt -gt 0) {
                    $previousReceivedAt
                } else { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
                Publish-RequestStatus $config $nonce 'RECEIVED' '家中主機已收到請求，準備驗證訊息' 0L @{
                    bridgeReceivedAt = $receivedAt
                    bridgeValidatedAt = 0L
                    bridgeAttemptCount = $previousAttemptCount
                    bridgeLastAttemptAt = $previousAttemptAt
                    bridgeNextRetryAt = 0L
                    bridgeQueuedAt = 0L
                    bridgeMessageSha256 = ''
                    bridgeMessageLength = 0
                    bridgeErrorCode = ''
                    bridgeErrorDetail = ''
                }

                Publish-RequestStatus $config $nonce 'VALIDATING' '正在檢查請求類型、訊息長度與內容' 0L @{
                    bridgeReceivedAt = $receivedAt
                }

                $rawMessage = ''
                if ($action -eq $LegacyAction) {
                    $rawMessage = $FixedPrompt
                } elseif ($action -eq $ExpectedAction) {
                    $rawMessage = [string](Read-FirestoreField $document 'supportRequestMessage' '')
                } else {
                    $detail = '已拒絕：不支援的請求類型'
                    $errorCode = 'UNSUPPORTED_ACTION'
                    $metadata = @{ ReceivedAt = $receivedAt; ErrorCode = $errorCode; ErrorDetail = $detail }
                    Save-State $statePath $nonce 'REJECTED' $detail $state.LastQueuedAt $metadata
                    Publish-RequestStatus $config $nonce 'REJECTED' $detail 0L @{
                        bridgeReceivedAt = $receivedAt
                        bridgeErrorCode = $errorCode
                        bridgeErrorDetail = $detail
                    }
                    Write-BridgeLog $logPath 'WARN' "Rejected unsupported action for nonce=$nonce"
                    continue
                }

                if ($rawMessage.Length -gt $MaxMessageLength) {
                    $detail = "已拒絕：訊息超過 $MaxMessageLength 字元"
                    $errorCode = 'MESSAGE_TOO_LONG'
                    $metadata = @{ ReceivedAt = $receivedAt; ErrorCode = $errorCode; ErrorDetail = $detail; MessageLength = $rawMessage.Length }
                    Save-State $statePath $nonce 'REJECTED' $detail $state.LastQueuedAt $metadata
                    Publish-RequestStatus $config $nonce 'REJECTED' $detail 0L @{
                        bridgeReceivedAt = $receivedAt
                        bridgeMessageLength = $rawMessage.Length
                        bridgeErrorCode = $errorCode
                        bridgeErrorDetail = $detail
                    }
                    Write-BridgeLog $logPath 'WARN' "Rejected overlength message for nonce=$nonce length=$($rawMessage.Length)"
                    continue
                }

                $message = Normalize-RequestMessage $rawMessage
                if ([string]::IsNullOrWhiteSpace($message)) {
                    $detail = '已拒絕：訊息不可空白'
                    $errorCode = 'EMPTY_MESSAGE'
                    $metadata = @{ ReceivedAt = $receivedAt; ErrorCode = $errorCode; ErrorDetail = $detail }
                    Save-State $statePath $nonce 'REJECTED' $detail $state.LastQueuedAt $metadata
                    Publish-RequestStatus $config $nonce 'REJECTED' $detail 0L @{
                        bridgeReceivedAt = $receivedAt
                        bridgeErrorCode = $errorCode
                        bridgeErrorDetail = $detail
                    }
                    Write-BridgeLog $logPath 'WARN' "Rejected empty message for nonce=$nonce"
                    continue
                }

                $validatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                $messageHash = Get-MessageSha256 $message
                if ($state.LastQueuedAt -gt 0 -and
                    $now - $state.LastQueuedAt -lt ([int]$config.MinimumRequestIntervalSeconds * 1000)) {
                    $remaining = [Math]::Ceiling((([int]$config.MinimumRequestIntervalSeconds * 1000) - ($now - $state.LastQueuedAt)) / 1000)
                    $detail = "已限制重複送出；請在 $remaining 秒後再按一次"
                    $errorCode = 'RATE_LIMITED'
                    $metadata = @{
                        ReceivedAt = $receivedAt; ValidatedAt = $validatedAt; MessageSha256 = $messageHash
                        MessageLength = $message.Length; ErrorCode = $errorCode; ErrorDetail = $detail
                    }
                    Save-State $statePath $nonce 'RATE_LIMITED' $detail $state.LastQueuedAt $metadata
                    Publish-RequestStatus $config $nonce 'RATE_LIMITED' $detail 0L @{
                        bridgeReceivedAt = $receivedAt
                        bridgeValidatedAt = $validatedAt
                        bridgeMessageSha256 = $messageHash
                        bridgeMessageLength = $message.Length
                        bridgeErrorCode = $errorCode
                        bridgeErrorDetail = $detail
                    }
                    Write-BridgeLog $logPath 'WARN' "Rate limited nonce=$nonce"
                    continue
                }

                $attemptCount = $previousAttemptCount + 1
                $attemptAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                Publish-RequestStatus $config $nonce 'QUEUEING' "已驗證訊息，正在進行第 $attemptCount 次 Codex 佇列嘗試" 0L @{
                    bridgeReceivedAt = $receivedAt
                    bridgeValidatedAt = $validatedAt
                    bridgeAttemptCount = $attemptCount
                    bridgeLastAttemptAt = $attemptAt
                    bridgeNextRetryAt = 0L
                    bridgeMessageSha256 = $messageHash
                    bridgeMessageLength = $message.Length
                    bridgeErrorCode = ''
                    bridgeErrorDetail = ''
                }

                Push-Location -LiteralPath ([string]$config.Workspace)
                try {
                    $output = @(& $codexPath queue --thread ([string]$config.ThreadId) --message $message 2>&1) -join ' '
                    $exitCode = $LASTEXITCODE
                } finally {
                    Pop-Location
                }
                if ($exitCode -eq 0) {
                    $queuedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                    $detail = '已排入目前 Codex 任務；這只代表佇列已接收，不代表已開始或完成'
                    $metadata = @{
                        ReceivedAt = $receivedAt; ValidatedAt = $validatedAt; AttemptCount = $attemptCount
                        AttemptAt = $attemptAt; MessageSha256 = $messageHash; MessageLength = $message.Length
                    }
                    # 本機狀態先落盤，再回寫 Firestore；即使回寫失敗也不會重複送入 Codex。
                    Save-State $statePath $nonce 'QUEUED' $detail $queuedAt $metadata
                    Publish-RequestStatus $config $nonce 'QUEUED' $detail $queuedAt @{
                        bridgeReceivedAt = $receivedAt
                        bridgeValidatedAt = $validatedAt
                        bridgeAttemptCount = $attemptCount
                        bridgeLastAttemptAt = $attemptAt
                        bridgeNextRetryAt = 0L
                        bridgeMessageSha256 = $messageHash
                        bridgeMessageLength = $message.Length
                        bridgeErrorCode = ''
                        bridgeErrorDetail = ''
                    }
                    Write-BridgeLog $logPath 'INFO' "Queued support message nonce=$nonce length=$($message.Length) sha256=$messageHash"
                } else {
                    $retryAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ([int]$config.PollSeconds * 1000)
                    $safeOutput = ($output -replace '[\r\n]+', ' ').Trim()
                    if ($safeOutput.Length -gt 240) { $safeOutput = $safeOutput.Substring(0, 240) }
                    $errorCode = "CODEX_QUEUE_EXIT_$exitCode"
                    $errorDetail = if ($safeOutput) { $safeOutput } else { 'Codex CLI 未提供錯誤內容' }
                    $detail = "第 $attemptCount 次未排入，會在 $(Get-Date ([DateTimeOffset]::FromUnixTimeMilliseconds($retryAt).LocalDateTime) -Format 'HH:mm:ss') 自動重試"
                    Publish-RequestStatus $config $nonce 'RETRYING' $detail 0L @{
                        bridgeReceivedAt = $receivedAt
                        bridgeValidatedAt = $validatedAt
                        bridgeAttemptCount = $attemptCount
                        bridgeLastAttemptAt = $attemptAt
                        bridgeNextRetryAt = $retryAt
                        bridgeMessageSha256 = $messageHash
                        bridgeMessageLength = $message.Length
                        bridgeErrorCode = $errorCode
                        bridgeErrorDetail = $errorDetail
                    }
                    Write-BridgeLog $logPath 'WARN' "Codex queue failed nonce=$nonce attempt=$attemptCount exit=$exitCode"
                }
            }
        } catch {
            Write-BridgeLog $logPath 'ERROR' $_.Exception.Message
        }

        if (-not $Once) { Start-Sleep -Seconds ([int]$config.PollSeconds) }
    } while (-not $Once)
} finally {
    try { $mutex.ReleaseMutex() } catch {}
    $mutex.Dispose()
}
