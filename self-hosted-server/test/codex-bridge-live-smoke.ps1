[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:ProgramData 'WutheringAutomation\CodexSupportBridge\config.json'),
    [string]$InstalledScript = (Join-Path $env:ProgramData 'WutheringAutomation\CodexSupportBridge\CodexSupportBridge.ps1')
)

$ErrorActionPreference = 'Stop'

function Read-Field($Document, [string]$Name, $Fallback = $null) {
    $property = $Document.fields.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Fallback }
    foreach ($kind in @('integerValue', 'stringValue', 'booleanValue', 'timestampValue')) {
        $value = $property.Value.PSObject.Properties[$kind]
        if ($null -ne $value) {
            if ($kind -eq 'integerValue') { return [long]$value.Value }
            return $value.Value
        }
    }
    return $Fallback
}

function ConvertTo-Field($Value) {
    if ($Value -is [bool]) { return @{ booleanValue = [bool]$Value } }
    if ($Value -is [byte] -or $Value -is [int16] -or $Value -is [int32] -or $Value -is [int64]) {
        return @{ integerValue = ([long]$Value).ToString([Globalization.CultureInfo]::InvariantCulture) }
    }
    return @{ stringValue = [string]$Value }
}

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "找不到設定：$ConfigPath" }
if (-not (Test-Path -LiteralPath $InstalledScript -PathType Leaf)) { throw "找不到橋接程式：$InstalledScript" }
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
$baseUrl = "https://firestore.googleapis.com/v1/projects/$($config.ProjectId)/databases/(default)/documents/$($config.Collection)/$($config.DocumentId)"
$apiKey = [string]$config.ApiKey

function Get-SupportDocument {
    $url = "$baseUrl`?key=$([Uri]::EscapeDataString($apiKey))"
    return Invoke-RestMethod -Method Get -Uri $url -TimeoutSec 15
}

function Set-SupportFields([hashtable]$Values) {
    $fields = @{}
    $query = New-Object Collections.Generic.List[string]
    $query.Add("key=$([Uri]::EscapeDataString($apiKey))")
    foreach ($name in ($Values.Keys | Sort-Object)) {
        $fields[$name] = ConvertTo-Field $Values[$name]
        $query.Add("updateMask.fieldPaths=$([Uri]::EscapeDataString([string]$name))")
    }
    $body = @{ fields = $fields } | ConvertTo-Json -Depth 8 -Compress
    Invoke-RestMethod -Method Patch -Uri "$baseUrl`?$($query -join '&')" `
        -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 15 | Out-Null
}

$original = Get-SupportDocument
$nonce = [long](Read-Field $original 'supportRequestNonce' 0L)
$originalState = [string](Read-Field $original 'bridgeState' '')
if ($nonce -le 0) { throw '支援文件沒有可用 nonce，停止測試。' }
if ($originalState -in @('PENDING', 'RECEIVED', 'VALIDATING', 'QUEUEING', 'RETRYING')) {
    throw "目前有尚未完成的請求（$originalState），停止測試。"
}

$fieldDefaults = [ordered]@{
    supportRequestAction = ''
    supportRequestMessage = ''
    bridgeStatusNonce = $nonce
    bridgeState = $originalState
    bridgeDetail = ''
    bridgeUpdatedAt = 0L
    bridgeReceivedAt = 0L
    bridgeValidatedAt = 0L
    bridgeAttemptCount = 0
    bridgeLastAttemptAt = 0L
    bridgeNextRetryAt = 0L
    bridgeQueuedAt = 0L
    bridgeMessageSha256 = ''
    bridgeMessageLength = 0
    bridgeErrorCode = ''
    bridgeErrorDetail = ''
}
$restore = @{}
foreach ($name in $fieldDefaults.Keys) {
    $restore[$name] = Read-Field $original $name $fieldDefaults[$name]
}

$installRoot = Split-Path -Parent $InstalledScript
$running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -like "*$InstalledScript*" })
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codex-bridge-live-smoke-" + [guid]::NewGuid().ToString('N'))
$tempConfig = Join-Path $tempRoot 'config.json'
$result = $null

try {
    foreach ($process in $running) { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop }
    if ($running.Count -gt 0) { Start-Sleep -Milliseconds 700 }

    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    Copy-Item -LiteralPath $ConfigPath -Destination $tempConfig
    Set-SupportFields @{
        supportRequestNonce = $nonce
        supportRequestAction = 'QUEUE_MESSAGE_V1'
        supportRequestMessage = " `t`r`n "
        bridgeStatusNonce = $nonce
        bridgeState = 'PENDING'
        bridgeDetail = 'Codex 橋接安全驗證測試'
        bridgeUpdatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $InstalledScript -ConfigPath $tempConfig -Once
    if ($LASTEXITCODE -ne 0) { throw "橋接測試程序退出碼：$LASTEXITCODE" }

    $checked = Get-SupportDocument
    $state = [string](Read-Field $checked 'bridgeState' '')
    $errorCode = [string](Read-Field $checked 'bridgeErrorCode' '')
    $receivedAt = [long](Read-Field $checked 'bridgeReceivedAt' 0L)
    if ($state -ne 'REJECTED' -or $errorCode -ne 'EMPTY_MESSAGE' -or $receivedAt -le 0) {
        throw "橋接拒絕測試失敗：state=$state error=$errorCode receivedAt=$receivedAt"
    }
    $result = [ordered]@{
        EmptyMessageRejected = $true
        State = $state
        ErrorCode = $errorCode
        ReceivedAtRecorded = $true
    }
} finally {
    Set-SupportFields $restore
    foreach ($name in @('state.json', 'bridge.log', 'config.json')) {
        $path = Join-Path $tempRoot $name
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Force }

    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScript`" -ConfigPath `"$ConfigPath`""
    Start-Process -FilePath $powershellPath -ArgumentList $arguments -WorkingDirectory $installRoot -WindowStyle Hidden
}

Start-Sleep -Seconds 3
$processCount = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { [string]$_.CommandLine -like "*$InstalledScript*" }).Count
if ($processCount -ne 1) { throw "橋接測試後常駐程序數量不正確：$processCount" }
$result.BridgeProcessCount = $processCount
[pscustomobject]$result | ConvertTo-Json -Depth 4
