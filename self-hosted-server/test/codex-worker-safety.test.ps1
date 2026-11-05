[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$windowsRoot = Join-Path $PSScriptRoot '..\windows'
function Import-Functions([string]$Name) {
    $tokens=$null; $errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $windowsRoot $Name),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "Parse failed: $Name" }
    foreach ($fn in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
        $fn.Extent.Text
    }
}
foreach ($definition in Import-Functions 'CodexSupportBridge.ps1') { . ([scriptblock]::Create($definition)) }
$script:queueId='11111111-2222-4333-8444-555555555555'
$script:turnId='22222222-3333-4444-8555-666666666666'
$message='bounded central request'
$hash=Get-MessageSha256 $message
$config=[pscustomobject]@{ThreadId='fixture-thread';FirestoreSupportEnabled=$false}
$script:rpcCalls=[Collections.Generic.List[string]]::new()
$script:history=@()
$script:nextCursor=$null
$script:openCount=0
function Open-CodexAppServerProxy { $script:openCount++; [pscustomobject]@{} }
function Close-CodexAppServerProxy {}
function Write-BridgeLog {}
function Invoke-CodexRpcRequest($Session,$Id,$Method,$Params,$TimeoutMilliseconds) {
    $script:rpcCalls.Add($Method)
    if ($Params.threadId -cne 'fixture-thread') { throw 'Wrong thread' }
    switch ($Method) {
        'thread/turns/list' { return [pscustomobject]@{result=[pscustomobject]@{data=$script:history}} }
        'thread/queue/list' { return [pscustomobject]@{result=[pscustomobject]@{data=$script:queue;nextCursor=$script:nextCursor}} }
        'thread/resume' { return [pscustomobject]@{result=[pscustomobject]@{thread=[pscustomobject]@{id='fixture-thread'}}} }
        'thread/queue/start' {
            if ($Params.queuedSubmissionId -cne $script:queueId) { throw 'Wrong submission' }
            return [pscustomobject]@{result=[pscustomobject]@{turn=[pscustomobject]@{id=$script:turnId;status='completed'}}}
        }
        default { throw "Unexpected RPC $Method" }
    }
}
function New-Entry([string]$Id,[string]$Source,[string]$Text=$message) {
    [pscustomobject]@{id=$Id;clientUserMessageId=$Source;input=@([pscustomobject]@{type='text';text=$Text})}
}
$cases=@(
    @{name='retired target';items=@(New-Entry $script:queueId 'wuthering-support/firestore/1')},
    @{name='retired sibling';items=@((New-Entry $script:queueId 'wuthering-support/selfhost/2'),(New-Entry 'aaaaaaaa-2222-4333-8444-555555555555' 'wuthering-support/firestore/1'))},
    @{name='manual sibling';items=@((New-Entry $script:queueId 'wuthering-support/selfhost/2'),(New-Entry 'aaaaaaaa-2222-4333-8444-555555555555' 'manual'))},
    @{name='mismatched hash';items=@(New-Entry $script:queueId 'wuthering-support/selfhost/2' 'changed')},
    @{name='paginated queue';items=@(New-Entry $script:queueId 'wuthering-support/selfhost/2');cursor='more'}
)
foreach ($case in $cases) {
    $script:queue=$case.items; $script:nextCursor=if ($case.ContainsKey('cursor')) {$case.cursor} else {$null}; $script:rpcCalls.Clear()
    try { Invoke-CodexQueueWorker $config $script:queueId $hash '' } catch { }
    if ($script:rpcCalls.Contains('thread/resume') -or $script:rpcCalls.Contains('thread/queue/start')) {
        throw "Unsafe queue caused a mutating RPC before rejection: $($case.name)"
    }
}
# Current Codex queue/update can change input under the same ID, while
# queue/start has no expected hash/revision. No snapshot can make that atomic.
$script:queue=@(New-Entry $script:queueId 'wuthering-support/selfhost/2')
$script:nextCursor=$null; $script:rpcCalls.Clear(); $script:openCount=0
$deferred=$false
try { Invoke-CodexQueueWorker $config $script:queueId $hash '' } catch {
    $deferred=$_.Exception.Message -match 'CODEX_NATIVE_QUEUE_OWNER_REQUIRED'
}
if (-not $deferred) { throw 'Automatic worker must defer until an atomic activation contract is available' }
if ($script:rpcCalls.Count -or $script:openCount) { throw 'Retired worker must not open an app-server or perform any RPC' }
function Start-Process { throw 'Automatic worker must not be spawned' }
[void](Start-CodexQueueWorkerProcess $config $script:queueId $hash '')
Write-Output 'PASS: automatic worker disabled before RPC/spawn; mutable queue remains owned by native Desktop'

foreach ($definition in Import-Functions 'Install-CodexSupportBridge.ps1') { . ([scriptblock]::Create($definition)) }
$script:processes=@(
    [pscustomobject]@{Name='pwsh.exe';ProcessId=101;CommandLine='pwsh -File "C:\fixture\CodexSupportBridge.ps1"'},
    [pscustomobject]@{Name='pwsh.exe';ProcessId=102;CommandLine='pwsh -File "C:\fixture\CodexSupportBridge.ps1" -QueueWorker'},
    [pscustomobject]@{Name='pwsh.exe';ProcessId=103;CommandLine='pwsh -File "C:\other\CodexSupportBridge.ps1" -QueueWorker'}
)
function Get-CimInstance { $script:processes }
$main=@(Get-ScriptProcesses 'C:\fixture\CodexSupportBridge.ps1')
if ($main.Count -ne 1 -or $main[0].ProcessId -ne 101) { throw 'Installer stop selection includes an active worker or unrelated process' }
$deferred=$false
try { Assert-NoCodexQueueWorkers @('C:\fixture\CodexSupportBridge.ps1') } catch { $deferred=$true }
if (-not $deferred) { throw 'Installer must defer when an exact-path worker is active' }
$script:processes=@($script:processes | Where-Object {$_.ProcessId -ne 102})
Assert-NoCodexQueueWorkers @('C:\fixture\CodexSupportBridge.ps1')
Write-Output 'PASS: installer defers active workers and never includes workers in its stop list'

# Only a correlated terminal record can open retry; temporary readers can lie.
$script:published=@()
$script:reportedStatus='interrupted'
$script:reportedTurn=$script:turnId
$script:requestState='IN_PROGRESS'
$script:boundTurn=$script:turnId
function Invoke-SelfHostedBridgeRequest {
    [pscustomobject]@{requests=@([pscustomobject]@{
        nonce=2;messageSha256=$hash;responseState=$script:requestState;codexTurnId=$script:boundTurn;codexTurnStatus='inProgress';queuedAt=1L
    })}
}
function Get-CodexThreadTurns {
    @([pscustomobject]@{id=$script:reportedTurn;status=$script:reportedStatus;completedAt=$null;items=@(
        [pscustomobject]@{type='userMessage';content=@([pscustomobject]@{type='inputText';text=$message})},
        $(if ($script:reportedStatus -eq 'completed') { [pscustomobject]@{type='agentMessage';text='verified final';phase='final_answer'} })
    )})
}
function Find-CodexResponseFromSessionLog { New-CodexResponseMatch $false 'WAITING' '' 0L '' '' '' }
function Publish-SelfHostedCodexResponse($Bridge,$Target,$Match) { $script:published+=,$Match }
Sync-CodexResponses $config ([pscustomobject]@{}) ''
if ($script:published.Count) { throw 'Transient interrupted without local abort must not publish a terminal state' }
$script:reportedStatus='completed'; $script:reportedTurn='aaaaaaaa-2222-4333-8444-555555555555'
Sync-CodexResponses $config ([pscustomobject]@{}) ''
if ($script:published.Count) { throw 'Other turn with identical input cannot complete a bound request' }
$script:reportedTurn=$script:turnId
Sync-CodexResponses $config ([pscustomobject]@{}) ''
if ($script:published.Count -ne 1 -or $script:published[0].ResponseState -ne 'COMPLETED') { throw 'Exact completed turn must remain publishable' }
Write-Output 'PASS: missing local evidence does not trust transient abort or unrelated completion'

$script:requestState='WAITING'; $script:boundTurn=''
$script:published=@(); $script:history=@(); $script:queue=@()
$CodexTurnStartEvidenceTimeoutMs=180000L
Sync-CodexResponses $config ([pscustomobject]@{}) ''
if ($script:published.Count) { throw 'Bounded history/queue absence cannot prove notStarted or open resend' }
$script:history=@([pscustomobject]@{
    id=$script:turnId;status='interrupted';completedAt=$null;items=@(
        [pscustomobject]@{type='userMessage';content=@([pscustomobject]@{type='inputText';text=$message})}
    )
})
Sync-CodexResponses $config ([pscustomobject]@{}) ''
if ($script:published.Count) { throw 'WAITING recovery cannot publish transient reader abort without local evidence' }
$script:history[0].status='failed'
Sync-CodexResponses $config ([pscustomobject]@{}) ''
if ($script:published.Count) { throw 'WAITING recovery cannot publish transient reader failure without local evidence' }
Write-Output 'PASS: WAITING requests remain pending on uncertain/missing/temporary terminal evidence'
