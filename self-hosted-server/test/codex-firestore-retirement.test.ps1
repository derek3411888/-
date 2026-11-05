[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null; $errors = $null
$source = Join-Path $PSScriptRoot '..\windows\CodexSupportBridge.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Bridge must parse' }
foreach ($fn in $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
$script:networkCalls = 0
function Invoke-WebRequest { $script:networkCalls++; throw 'Unexpected Firestore network request' }
function Invoke-RestMethod { $script:networkCalls++; throw 'Unexpected Firestore network request' }
function Read-InFlightMarker { throw 'Retired Firestore markers must not be resumed or removed' }
function Repair-FirestoreInvalidCodexResponse { throw 'Retired Firestore responses must not be read or repaired' }
$script:LastFirestoreDocument = [pscustomobject]@{fields='stale-cached-response'}
foreach ($config in @([pscustomobject]@{}, [pscustomobject]@{FirestoreSupportEnabled=$false})) {
    if (Test-FirestoreSupportEnabled $config) { throw 'Firestore must be opt-in, not implicitly enabled' }
    Invoke-FirestoreQueue $config '' '' @() ''
    Recover-FirestoreInFlight $config '' '' ''
    Sync-CodexResponses $config $null ''
    if ($null -ne (Get-FirestoreDocument $config)) { throw 'Retired Firestore read returned data' }
    Set-FirestoreFields $config @{a=1}
    Set-FirestoreFieldsAtVersion $config @{a=1} 'stale-version'
    Publish-CodexQueueWorkerFirestoreMatch $config 'retired' $null ''
}
if ($script:networkCalls) { throw 'Retirement performed network I/O' }
if (Test-FirestoreSupportEnabled ([pscustomobject]@{FirestoreSupportEnabled='false'})) { throw 'String false must not enable Firestore' }
if (-not (Test-FirestoreSupportEnabled ([pscustomobject]@{FirestoreSupportEnabled=$true}))) { throw 'Explicit legacy compatibility setting must still parse' }
$script:centralReads = 0
function Invoke-SelfHostedBridgeRequest { $script:centralReads++; return [pscustomobject]@{requests=@()} }
Sync-CodexResponses ([pscustomobject]@{FirestoreSupportEnabled=$false}) ([pscustomobject]@{DispatcherId='test'}) ''
if ($script:centralReads -ne 1) { throw 'Retirement must not disable central reply polling' }
Write-Output 'PASS: Firestore ingress, recovery, cached egress and raw HTTP disabled; central response polling retained'
$installer = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\windows\Install-CodexSupportBridge.ps1') -Raw -Encoding UTF8
$lookup = $installer.IndexOf("`$SelfHostedBridgeToken = Read-EnvValue")
$failure = $installer.IndexOf("if (-not `$FirestoreSupportEnabled) { throw")
if ($lookup -lt 0 -or $failure -lt $lookup) { throw 'Existing central token lookup must precede missing-token rejection' }
foreach ($name in @('Install-CodexSupportBridge.ps1','CodexSupportWatchdog.ps1')) {
    $text = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\windows\$name") -Raw -Encoding UTF8
    if ($text -match '-ExecutionPolicy\s+Bypass') { throw "Bridge startup must honor configured ExecutionPolicy: $name" }
}
Write-Output 'PASS: installer resolves existing token before validation and honors system ExecutionPolicy'
