[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $projectRoot 'self-hosted-server\windows\CodexSupportBridge.ps1'),
    [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw 'Bridge source must parse before transport tests' }
foreach ($definition in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($definition.Extent.Text))
}

function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message (expected=$Expected actual=$Actual)" }
}

# A hidden scheduled bridge inherits the Windows code page, not necessarily
# UTF-8. The subprocess protocol must override all three redirected streams.
$originalInputEncoding = [Console]::InputEncoding
try {
    [Console]::InputEncoding = [Text.Encoding]::GetEncoding(936)
    $startConfig = [pscustomobject]@{CodexPath=(Get-Process -Id $PID).Path;Workspace=$projectRoot}
    $startInfo = New-CodexReaderStartInfo $startConfig
    if ($null -ne $startInfo.PSObject.Properties['StandardInputEncoding']) {
        Assert-Equal $startInfo.StandardInputEncoding.WebName 'utf-8' 'Chinese reports require UTF-8 even in a hidden process'
        Assert-Equal $startInfo.StandardInputEncoding.GetPreamble().Length 0 'NDJSON transport cannot start with a BOM'
    }
    Assert-Equal $startInfo.StandardOutputEncoding.WebName 'utf-8' 'Read RPC responses as UTF-8'
    Assert-Equal $startInfo.StandardErrorEncoding.WebName 'utf-8' 'Preserve readable transport errors'
    $pipeBytes = [IO.MemoryStream]::new()
    try {
        $fakePipe = [pscustomobject]@{StandardInput=[pscustomobject]@{BaseStream=$pipeBytes}}
        $unicodeLine = @{text=(-join @([char]0x7DB2,[char]0x7AD9))} | ConvertTo-Json -Compress
        Write-CodexRpcLine $fakePipe $unicodeLine
        $wireText = [Text.UTF8Encoding]::new($false,$true).GetString($pipeBytes.ToArray())
        Assert-Equal $wireText ($unicodeLine + "`n") 'PS5-compatible raw stdin must send exact UTF-8 NDJSON without a BOM'
    } finally { $pipeBytes.Dispose() }
} finally { [Console]::InputEncoding = $originalInputEncoding }
Write-Output 'PASS: hidden-process RPC is UTF-8 independent of the Windows console code page'

# The temporary reader may list history / add durable input, never take over a
# Desktop-owned thread. Model the external RPC boundary, not delivery behavior.
$script:submissions = @()
$script:addCount = 0
$script:turnFixture = @()
function Open-CodexAppServerProxy($Config) { return [pscustomobject]@{QueueOnly=$true} }
function Close-CodexAppServerProxy($Session) {}
function Invoke-CodexRpcRequest($Session, [long]$Id, [string]$Method, $Params, [int]$TimeoutMilliseconds = 20000) {
    if ($Params.threadId -cne 'test-thread') { throw 'Wrong thread targeted' }
    switch ($Method) {
        'thread/turns/list' { return (@{result=@{data=$script:turnFixture}} | ConvertTo-Json -Depth 12 | ConvertFrom-Json) }
        'thread/queue/list' { return (@{result=@{data=$script:submissions;nextCursor=$null}} | ConvertTo-Json -Depth 12 | ConvertFrom-Json) }
        'thread/queue/add' {
            $script:addCount++
            $submission = [pscustomobject]@{id='queued-1';clientUserMessageId=$Params.clientUserMessageId;input=$Params.input}
            $script:submissions += $submission
            return (@{result=@{queuedSubmission=$submission}} | ConvertTo-Json -Depth 12 | ConvertFrom-Json)
        }
        default { throw "Temporary reader must not execute $Method on the Desktop-owned thread" }
    }
}

$config = [pscustomobject]@{ThreadId='test-thread'}
$message = 'test report with a stable identity'
$hash = Get-MessageSha256 $message
$result = Invoke-CodexQueuedTurnDelivery $config $hash $message 'test-correlation' $true
Assert-Equal $result.QueuedFound $true 'Durable queue acknowledgement must be returned'
Assert-Equal $result.Delivered $false 'Queue acknowledgement must not claim a started turn'
Assert-Equal $result.ResponseState 'WAITING' 'Queued input must wait for the Desktop owner'
Assert-Equal $result.TurnId '' 'Never fabricate a turn ID'
Assert-Equal $script:addCount 1 'First delivery adds exactly one submission'

$again = Invoke-CodexQueuedTurnDelivery $config $hash $message 'test-correlation' $true
Assert-Equal $again.QueuedFound $true 'Retry must find the retained submission'
Assert-Equal $script:addCount 1 'Retry must not duplicate queued input'

$script:turnFixture = @([pscustomobject]@{
    id='actual-turn';status='inProgress';completedAt=$null
    items=@([pscustomobject]@{type='userMessage';content=@(@{type='inputText';text=$message})})
})
$started = Invoke-CodexQueuedTurnDelivery $config $hash '' '' $false
Assert-Equal $started.Delivered $true 'Actual history evidence confirms delivery'
Assert-Equal $started.TurnId 'actual-turn' 'Use only the observed turn ID'
Assert-Equal $script:addCount 1 'History observation cannot add another submission'

$script:turnFixture = @()
$script:submissions = @()
$missing = Invoke-CodexQueuedTurnDelivery $config $hash '' '' $false
Assert-Equal $missing.Delivered $false 'A missing request is not delivered'
Assert-Equal $missing.QueuedFound $false 'A missing request is not queued'
Assert-Equal $script:addCount 1 'Read-only recovery cannot enqueue a missing request'

Write-Output 'PASS: Desktop queue ownership, exact delivery evidence, deduplication, read-only recovery'

$firstFailure = Get-CodexDeliveryFailure 'failed to connect to socket (os error 10050)' 1 15 $false
Assert-Equal $firstFailure.State 'RETRYING' 'A known pre-delivery connection failure may retry'
Assert-Equal $firstFailure.ErrorCode 'CODEX_CONNECTION_FAILED' 'Connection failures must be distinguishable'
if ($firstFailure.DelayMilliseconds -lt 30000) { throw 'Failed connections must not spin every 15 seconds' }
$lastFailure = Get-CodexDeliveryFailure 'failed to connect to socket (os error 10050)' 3 15 $false
Assert-Equal $lastFailure.State 'FAILED' 'Repeated pre-delivery failures must stop automatically'
Assert-Equal $lastFailure.DelayMilliseconds 0 'Terminal failures must not schedule another retry'
$uncertain = Get-CodexDeliveryFailure 'connection closed after queue/add write' 1 15 $true
Assert-Equal $uncertain.State 'FAILED' 'Uncertain enqueue outcomes require reconciliation'
Assert-Equal $uncertain.ErrorCode 'DISPATCH_RESULT_UNKNOWN' 'Uncertain outcomes must keep duplicate-prevention guards'
$busy = Get-CodexDeliveryFailure 'thread already has an active or pending turn' 10 15 $false
Assert-Equal $busy.State 'RETRYING' 'An active user task must not be treated as broken transport'
if ($busy.DelayMilliseconds -lt 60000) { throw 'Busy-thread waiting must back off' }
$packageFailure = Get-CodexDeliveryFailure (('connection details ' * 40) + ' CLI has no complete local package') 3 15 $false
Assert-Equal $packageFailure.ErrorCode 'CODEX_RUNTIME_UNAVAILABLE' 'Do not truncate the decisive error before classification'
if ($packageFailure.ErrorDetail -notmatch 'no complete local package') { throw 'Keep the decisive error tail visible' }
Write-Output 'PASS: bounded retries, root-cause classification, uncertain-delivery guard'

# Exercise the real Firestore processor and atomic local state writer. Only the
# network boundary is in-memory, so a queue-only receipt cannot be promoted to
# IN_PROGRESS by the processor after the transport itself returned WAITING.
$ExpectedAction = 'QUEUE_MESSAGE_V1'
$LegacyAction = 'FIX_SCRIPT'
$FixedPrompt = 'fixed test prompt'
$BridgeVersion = 'test'
$MaxMessageLength = 1000
$MaxContextLength = 14000
$MaxQueuedMessageLength = 15500
$CodexCorrelationPrefix = 'wuthering-support'
$script:doc = [pscustomobject]@{updateTime='test-version-1';fields=[pscustomobject]@{
    supportRequestNonce=[pscustomobject]@{integerValue='1'}
    supportRequestAction=[pscustomobject]@{stringValue='QUEUE_MESSAGE_V1'}
    supportRequestMessage=[pscustomobject]@{stringValue='fixture report'}
}}
$script:docVersion = 1
function Get-FirestoreDocument($Config) { return $script:doc }
function Set-FirestoreFields($Config, [hashtable]$Values) {
    foreach ($key in $Values.Keys) {
        $field = ConvertTo-FirestoreField $Values[$key] | ConvertTo-Json | ConvertFrom-Json
        $script:doc.fields | Add-Member -NotePropertyName $key -NotePropertyValue $field -Force
    }
    $script:docVersion++
    $script:doc.updateTime = "test-version-$script:docVersion"
}
function Set-FirestoreFieldsAtVersion($Config, [hashtable]$Values, [string]$UpdateTime) {
    if ($UpdateTime -cne $script:doc.updateTime) { throw 'Test CAS version mismatch' }
    Set-FirestoreFields $Config $Values
    return $script:doc
}
$runtime = Join-Path $projectRoot ('.dev-runtime\tests\codex-bridge-transport-' + [Guid]::NewGuid().ToString('N'))
$statePath = Join-Path $runtime 'state.json'
$inflightPath = Join-Path $runtime 'inflight.json'
$logPath = Join-Path $runtime 'bridge.log'
$testConfig = [pscustomobject]@{ThreadId='test-thread';PollSeconds=15;MinimumRequestIntervalSeconds=300}
Invoke-FirestoreQueue $testConfig $statePath $inflightPath @($statePath) $logPath
Assert-Equal (Read-State $statePath).LastStatus 'QUEUED' 'Durably accepted input must not retry as a connection failure'
Assert-Equal (Read-FirestoreField $script:doc 'codexResponseState' '') 'WAITING' 'Website must distinguish queued from started'
Assert-Equal (Read-FirestoreField $script:doc 'codexResponseTurnId' '') '' 'Website must not invent a turn for queued input'
$addsBeforeReplay = $script:addCount
Invoke-FirestoreQueue $testConfig $statePath $inflightPath @($statePath) $logPath
Assert-Equal $script:addCount $addsBeforeReplay 'Polling/restarting an acknowledged report cannot enqueue it twice'
Write-Output 'PASS: real Firestore processor publishes WAITING and persists duplicate protection'

# The saved cursor is already on a complete JSONL boundary. A final reply can
# be the very first appended record and must not be skipped on the next poll.
$CodexQueueMatchEarlyToleranceMs = 120000L
$CodexQueueMatchLateToleranceMs = 604800000L
$script:CodexResponseCursors = @{}
$script:CodexSessionLogPath = Join-Path $runtime 'reply-cursor.jsonl'
$replyQueuedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$replyText = 'queued report for cursor regression'
$replyTarget = [pscustomobject]@{
    Source='firestore';Nonce=22;MessageSha256=(Get-MessageSha256 $replyText)
    TurnId='';QueuedAt=$replyQueuedAt
}
$replyRecords = @(
    @{timestamp=[DateTimeOffset]::FromUnixTimeMilliseconds($replyQueuedAt).ToString('o');type='turn_context';payload=@{turn_id='reply-turn'}}
    @{timestamp=[DateTimeOffset]::FromUnixTimeMilliseconds($replyQueuedAt+1).ToString('o');type='response_item';payload=@{type='message';role='user';content=@(@{type='input_text';text=$replyText})}}
) | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress }
[IO.File]::WriteAllLines($script:CodexSessionLogPath, $replyRecords, [Text.UTF8Encoding]::new($false))
$replyInitial = Find-CodexResponseFromSessionLog $config $replyTarget
Assert-Equal $replyInitial.ResponseState 'IN_PROGRESS' 'Reading the user record must bind the reply cursor'
$replyTarget.TurnId = $replyInitial.TurnId
$finalRecord = @{timestamp=[DateTimeOffset]::FromUnixTimeMilliseconds($replyQueuedAt+2).ToString('o');type='response_item';payload=@{type='message';role='assistant';phase='final_answer';content=@(@{type='output_text';text='REPLY_CURSOR_OK'})}} | ConvertTo-Json -Depth 8 -Compress
[IO.File]::AppendAllText($script:CodexSessionLogPath, $finalRecord + "`n", [Text.UTF8Encoding]::new($false))
$replyFinal = Find-CodexResponseFromSessionLog $config $replyTarget
Assert-Equal $replyFinal.ResponseState 'COMPLETED' 'First appended record may be the final reply'
Assert-Equal $replyFinal.ResponseText 'REPLY_CURSOR_OK' 'The final reply must remain available to the website'
$replyRetry = Find-CodexResponseFromSessionLog $config $replyTarget
Assert-Equal $replyRetry.ResponseState 'COMPLETED' 'A failed website write must not consume the final reply'
Assert-Equal $replyRetry.ResponseText 'REPLY_CURSOR_OK' 'The next poll must be able to publish the same final reply'
Write-Output 'PASS: incremental session reader retains the first newly appended final reply'

$script:selfHostedPosts = @()
$script:selfHostedRequest = [pscustomobject]@{
    nonce=3;claimGeneration=1;dispatcherId='fixture-dispatcher';message='central fixture report';attemptCount=0
}
function Invoke-SelfHostedBridgeRequest($BridgeConfig, [string]$Method, [string]$Path, [hashtable]$Body = @{}) {
    if ($Method -eq 'GET' -and $Path -eq '/internal/codex-support/next') {
        return [pscustomobject]@{request=$script:selfHostedRequest}
    }
    if ($Method -eq 'POST') {
        $script:selfHostedPosts += [pscustomobject]@{Path=$Path;Body=$Body}
        return [pscustomobject]@{ok=$true}
    }
    throw "Unexpected central API request: $Method $Path"
}
$centralConfig = [pscustomobject]@{DispatcherId='fixture-dispatcher'}
$centralState = Join-Path $runtime 'central-state.json'
$centralMarker = Join-Path $runtime 'central-inflight.json'
Invoke-SelfHostedQueue $centralConfig $testConfig $centralState $centralMarker @($centralState) $logPath
Assert-Equal (Read-State $centralState).LastStatus 'QUEUED' 'Central processor must persist queue acknowledgement'
$centralReply = @($script:selfHostedPosts | Where-Object { $_.Path -eq '/internal/codex-support/3/response' })[-1]
Assert-Equal $centralReply.Body.responseState 'WAITING' 'Central website must not claim started from queue acknowledgement'
Assert-Equal $centralReply.Body.codexTurnId '' 'Central website must not fabricate a Turn ID'
$centralAddCount = $script:addCount
Invoke-SelfHostedQueue $centralConfig $testConfig $centralState $centralMarker @($centralState) $logPath
Assert-Equal $script:addCount $centralAddCount 'Central replay cannot duplicate queued input'
Write-Output 'PASS: real central processor publishes WAITING and preserves replay protection'

# A crash after durable failure persistence but before its remote receipt must
# replay that known failure, not misclassify it as uncertain and block retries.
Save-State $centralState 4 'FAILED' 'known connection failure' 0L @{
    AttemptCount=3;ErrorCode='CODEX_CONNECTION_FAILED';ErrorDetail='known transport error'
    ClaimGeneration=1;DispatcherId='fixture-dispatcher'
}
Write-InFlightMarker $centralMarker 'selfhost' 4 3 100 $hash 20 1 'fixture-dispatcher'
Recover-SelfHostedInFlight $centralConfig $centralState $centralMarker $logPath
Assert-Equal $script:selfHostedPosts[-1].Body.errorCode 'CODEX_CONNECTION_FAILED' 'Replay must preserve a known terminal result'
Write-Output 'PASS: restart recovery retains the original known failure reason'
