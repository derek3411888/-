[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$serverRoot=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$projectRoot=Split-Path -Parent $serverRoot
$windowsRoot=Join-Path $serverRoot 'windows'
$runtime=(Get-Command pwsh.exe -ErrorAction Stop).Source
$fixture=Join-Path $projectRoot ('.dev-runtime/tests/codex-runtime-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture | Out-Null
$bridgePowerShellPath=$runtime
$installedBootstrap=Join-Path $fixture 'CodexSupportBootstrap.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $windowsRoot 'Install-CodexSupportBridge.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Installer parse failed'}
$resolver=$ast.Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Resolve-CodexBridgeRuntime'
},$true)
if($null -eq $resolver){throw 'Installer is missing explicit PS7 runtime validation'}
. ([scriptblock]::Create($resolver.Extent.Text))
$runtimeConfig=Join-Path $fixture 'runtime-config.json'
[IO.File]::WriteAllText($runtimeConfig,(@{BridgePowerShellPath=$runtime}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
if((Resolve-CodexBridgeRuntime $runtimeConfig) -cne $runtime){throw 'Installer did not preserve configured PS7 runtime'}
foreach($invalidRuntime in @('pwsh.exe',(Join-Path $fixture 'missing-pwsh.exe'),(Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'))) {
    [IO.File]::WriteAllText($runtimeConfig,(@{BridgePowerShellPath=$invalidRuntime}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $rejected=$false
    try { Resolve-CodexBridgeRuntime $runtimeConfig | Out-Null } catch { $rejected=$true }
    if(-not $rejected){throw "Installer accepted invalid runtime: $invalidRuntime"}
}
if((Resolve-CodexBridgeRuntime (Join-Path $fixture 'new-install.json')) -cne $runtime){throw 'New install did not resolve available PS7'}
Write-Output 'PASS: installer preserves and validates configured PS7; new installs resolve PS7 only'
# Execute the real scheduler-binding statements, intercept only the OS API.
# This catches a return to PS5.1 or added policy overrides without registering a task.
function New-ScheduledTaskAction($Execute,$Argument) { [pscustomobject]@{Execute=$Execute;Arguments=$Argument} }
foreach($statement in $ast.FindAll({param($node)
    $node -is [Management.Automation.Language.AssignmentStatementAst] -and
    $node.Left.Extent.Text -in @('$powershellPath','$taskArguments','$action')
},$true)) { . ([scriptblock]::Create($statement.Extent.Text)) }
if($action.Execute -cne $runtime){throw 'Scheduled bootstrap does not use the selected PowerShell 7 runtime'}
if($action.Arguments -match '(?i)ExecutionPolicy|Bypass|EncodedCommand'){throw 'Scheduled bootstrap changes policy or bypasses normal file execution'}
if(-not $action.Arguments.Contains('"'+$installedBootstrap+'"')){throw 'Scheduled bootstrap path must remain quoted'}
Write-Output 'PASS: real task action binds selected PS7 and normal quoted -File arguments'

foreach($name in @('CodexSupportBootstrap.ps1','CodexSupportWatchdog.ps1')) {
    Copy-Item -LiteralPath (Join-Path $windowsRoot $name) -Destination (Join-Path $fixture $name)
}
[IO.File]::WriteAllText((Join-Path $fixture 'CodexSupportBridge.ps1'),'# inert fixture, never executed',[Text.UTF8Encoding]::new($false))
$configPath=Join-Path $fixture 'config.json'
[IO.File]::WriteAllText($configPath,(@{BridgePowerShellPath=$runtime}|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$output=& $runtime -NoProfile -NonInteractive -File $installedBootstrap -ValidateOnly 2>&1
if($LASTEXITCODE -ne 0){throw "Bootstrap validation failed: $output"}
$validation=($output -join "`n")|ConvertFrom-Json
if(-not $validation.Ok -or $validation.PowerShellPath -cne $runtime -or [int]$validation.RuntimeMajor -lt 7){throw 'Bootstrap/watchdog validation did not prove PS7 selection'}
Write-Output 'PASS: actual bootstrap invokes watchdog validation on PS7 without starting bridge'

foreach($badConfig in @(@{},@{BridgePowerShellPath=(Join-Path $fixture 'missing-pwsh.exe')})) {
    [IO.File]::WriteAllText($configPath,($badConfig|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $output=& $runtime -NoProfile -NonInteractive -File $installedBootstrap -ValidateOnly 2>&1
    if($LASTEXITCODE -eq 0){throw 'Invalid runtime configuration silently fell back instead of rejecting'}
}
Write-Output 'PASS: missing or invalid runtime fails closed, with no PS5.1 fallback'

# Exercise the real updater boundary with an inert installer. No scheduled task,
# production config, Docker service, or actual bridge is touched.
$updateFixture=Join-Path $fixture 'server with spaces'
$updateWindows=Join-Path $updateFixture 'windows'
New-Item -ItemType Directory -Path $updateWindows | Out-Null
$fixtureConfig=Join-Path $fixture 'program-data/WutheringAutomation/CodexSupportBridge/config.json'
[IO.Directory]::CreateDirectory((Split-Path $fixtureConfig -Parent)) | Out-Null
$fixtureValues=@{ThreadId='11111111-1111-1111-1111-111111111111';Workspace=$fixture;ProjectId='fixture-project';ApiKey='inert-private-fixture';Collection='fixture-items';PollSeconds=17;MinimumRequestIntervalSeconds=333;BridgePowerShellPath=$runtime}
[IO.File]::WriteAllText($fixtureConfig,($fixtureValues|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
$receipt=Join-Path $updateFixture 'receipt.json'
$fakeInstaller=@'
param($ThreadId,$Workspace,$ProjectId,$ApiKey,$Collection,$SelfHostedBaseUrl,$PollSeconds,$MinimumRequestIntervalSeconds)
#Requires -Version 7.0
if($env:CODEX_TEST_INSTALL_FAILURE -eq '1'){exit 17}
@{Pid=$PID;Major=$PSVersionTable.PSVersion.Major;ThreadId=$ThreadId;Workspace=$Workspace;ProjectId=$ProjectId;Collection=$Collection;SelfHostedBaseUrl=$SelfHostedBaseUrl;PollSeconds=$PollSeconds;MinimumRequestIntervalSeconds=$MinimumRequestIntervalSeconds;SecretPreserved=($ApiKey -ceq 'inert-private-fixture');SecretInCommandLine=([Environment]::CommandLine.Contains('inert-private-fixture'))} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'receipt.json') -Encoding UTF8
'@
[IO.File]::WriteAllText((Join-Path $updateWindows 'Install-CodexSupportBridge.ps1'),$fakeInstaller,[Text.UTF8Encoding]::new($true))
$wrapper=Join-Path $windowsRoot 'Update-CodexSupportBridge.ps1'
if(Test-Path -LiteralPath $wrapper){Copy-Item -LiteralPath $wrapper -Destination $updateWindows}
$updateAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $serverRoot 'Update-Server.ps1'),[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'Server updater parse failed'}
$definitions=@($updateAst.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -in @('Get-OptionalJsonValue','Resolve-CodexUpdateRuntime','Update-InstalledCodexBridge')
},$true) | ForEach-Object {$_.Extent.Text}) -join "`n"
$oldProgramData=$env:ProgramData
$oldLocalAppData=$env:LOCALAPPDATA
$oldServerRoot=$serverRoot
try {
    $env:ProgramData=Join-Path $fixture 'program-data'
    $env:LOCALAPPDATA=Join-Path $fixture 'legacy-data'
    $script:serverRoot=$updateFixture
    . ([scriptblock]::Create($definitions))
    Update-InstalledCodexBridge
    $result=Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    if($result.Pid -eq $PID){throw 'Server updater must invoke the bridge installer in an explicit PS7 child'}
    if($result.Major -lt 7 -or -not $result.SecretPreserved -or $result.SecretInCommandLine){throw 'Installer runtime or secret forwarding is unsafe'}
    foreach($name in @('ThreadId','Workspace','ProjectId','Collection','PollSeconds','MinimumRequestIntervalSeconds')) {
        if([string]$result.$name -cne [string]$fixtureValues[$name]){throw "Update boundary lost $name"}
    }
    if($result.SelfHostedBaseUrl -ne 'http://127.0.0.1:3000'){throw 'Updater changed the loopback endpoint'}
    Write-Output 'PASS: updater invokes PS7 child with existing settings and no secret command-line arguments'

    # This is a synthetic command harness under PS5.1, not execution of a
    # policy-blocked product file. The installer still uses normal PS7 -File.
    $parentCommand=$definitions+"`n"+'$ErrorActionPreference="Stop"; $script:serverRoot='+"'"+$updateFixture.Replace("'","''")+"'; Update-InstalledCodexBridge"
    $ps5=Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    & $ps5 -NoProfile -NonInteractive -Command $parentCommand
    if($LASTEXITCODE -ne 0){throw 'PS5.1 updater parent failed to hand off to PS7'}
    $ps5Result=Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
    if($ps5Result.Major -lt 7 -or $ps5Result.Pid -eq $result.Pid -or $ps5Result.SecretInCommandLine){throw 'PS5.1 parent did not execute a new safe PS7 installer'}
    Write-Output 'PASS: true PS5.1 parent to PS7 -File installer handoff, with no policy override'

    $env:CODEX_TEST_INSTALL_FAILURE='1'
    $rejected=$false
    try {Update-InstalledCodexBridge} catch {$rejected=$_.Exception.Message -match '17'}
    if(-not $rejected){throw 'Updater swallowed installer exit code 17'}
    Write-Output 'PASS: installer failure is returned to updater, not reported as success'
} finally {
    $env:ProgramData=$oldProgramData
    $env:LOCALAPPDATA=$oldLocalAppData
    $env:CODEX_TEST_INSTALL_FAILURE=$null
    $script:serverRoot=$oldServerRoot
}
