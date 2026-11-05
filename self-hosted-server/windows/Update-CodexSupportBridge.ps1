[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ConfigPath)
#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

# Called by Update-Server.ps1 under its validated PS7 runtime, including when
# the outer release/updater runs under Windows PowerShell 5.1.
$config = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
function Get-UpdateValue([string]$Name, $Fallback) {
    $property = $config.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Fallback }
    return $property.Value
}
$threadId = [string](Get-UpdateValue 'ThreadId' '')
if ($threadId -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Existing bridge ThreadId is invalid.' }
$installer = Join-Path $PSScriptRoot 'Install-CodexSupportBridge.ps1'
$global:LASTEXITCODE = 0
& $installer `
    -ThreadId $threadId `
    -Workspace ([string](Get-UpdateValue 'Workspace' (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))) `
    -ProjectId ([string](Get-UpdateValue 'ProjectId' 'ww-control-a3988')) `
    -ApiKey ([string](Get-UpdateValue 'ApiKey' '')) `
    -Collection ([string](Get-UpdateValue 'Collection' 'ahk_clients')) `
    -SelfHostedBaseUrl 'http://127.0.0.1:3000' `
    -PollSeconds ([int](Get-UpdateValue 'PollSeconds' 15)) `
    -MinimumRequestIntervalSeconds ([int](Get-UpdateValue 'MinimumRequestIntervalSeconds' 300))
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
