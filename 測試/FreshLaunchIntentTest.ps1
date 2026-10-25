[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$run=Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\20261025-fresh-start-takeover\intent-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($run)
$context=[pscustomobject]@{ProjectRoot=$project;Root=(Join-Path $project '.dev-runtime');RunRoot=$run}
$source=[IO.File]::ReadAllText((Join-Path $project 'payload\全自動.ahk'))
$block=[regex]::Match($source,'(?ms)^if \(REMOTE_CONTROL_ACTIVE && !remoteContinuationLaunch\) \{.*?^\}').Value
Assert-GMTrue ([bool]$block) 'Actual fresh RUN intent boundary exists'
$fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include *i __PROJECT__\payload\FreshLaunchIntent.ahk
global REMOTE_CONTROL_ACTIVE := true, remoteContinuationLaunch := false
global CFG_FILE := A_ScriptDir "\config\config.ini"
DirCreate(A_ScriptDir "\config")
IniWrite("__CURRENT__",CFG_FILE,"remote_control","last_nonce")
EnvSet("PACK_FRESH_INSTALL",A_ScriptDir)
EnvSet("PACK_FRESH_COMMAND_NONCE","10")
RC_AcquirePersistedDesiredStateMutex(*) => 1
RC_ReleasePersistedDesiredStateMutex(*) => 0
RC_BeginFreshRunCycle(*) {
    FileAppend("RUN_RESET", "*")
    return true
}
WriteLog(*) => 0
__BLOCK__
ExitApp(0)
'@
foreach($scenario in @(@{Name='newer-stop';Current='11';Allow=$false},@{Name='same-command';Current='10';Allow=$true},@{Name='invalid-journal';Current='broken';Allow=$false})){
    $dir=Join-Path $run $scenario.Name
    [void][IO.Directory]::CreateDirectory($dir)
    $path=Join-Path $dir 'intent.ahk'
    [IO.File]::WriteAllText($path,$fixture.Replace('__PROJECT__',$project).Replace('__CURRENT__',$scenario.Current).Replace('__BLOCK__',$block),[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess -ScriptPath $path -Context $context
    Assert-GMTrue ($result.Stdout.Contains('RUN_RESET') -eq $scenario.Allow) ('Fresh startup must honor newer stop/pause or unreadable intent: '+$scenario.Name)
    if($scenario.Allow){Assert-GMEqual $result.ExitCode 0 $result.Stderr}
}
Write-Output 'PASS actual fresh RUN boundary preserves newer command generation and denies invalid journal'
$captureFixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include __PROJECT__\payload\FreshLaunchIntent.ahk
Check(value,message) {
    if !value
        throw Error(message)
}
try {
    root := A_ScriptDir "\install", cfg := root "\config\config.ini"
    DirCreate(root "\config")
    EnvSet("PACK_FRESH_INSTALL",""), EnvSet("PACK_FRESH_COMMAND_NONCE","")
    IniWrite("10",cfg,"remote_control","last_nonce")
    FLI_Capture(root)
    Check(EnvGet("PACK_FRESH_COMMAND_NONCE") = "10","initial fresh intent captured")
    IniWrite("11",cfg,"remote_control","last_nonce")
    ; A relocation child inherits the same intent, not a new user request.
    FLI_Capture(root)
    Check(EnvGet("PACK_FRESH_COMMAND_NONCE") = "10","relocation must retain original command generation")
    Check(!FLI_AllowsFresh(cfg),"relocation may not override a newer STOP/PAUSE")
    denied := false
    try FLI_Capture(root "-other")
    catch
        denied := true
    Check(denied,"inherited intent for another installation is not fresh authority")
    EnvSet("PACK_FRESH_COMMAND_NONCE","broken"), denied := false
    try FLI_Capture(root)
    catch
        denied := true
    Check(denied,"damaged inherited intent must not be refreshed")
    FileAppend("PASS relocation retains original intent and rejects malformed or foreign capture`n","*")
} catch as err {
    FileAppend(err.Message "`n" err.Stack,"**")
    ExitApp(1)
}
ExitApp(0)
'@
$capturePath=Join-Path $run 'capture.ahk'
[IO.File]::WriteAllText($capturePath,$captureFixture.Replace('__PROJECT__',$project),[Text.UTF8Encoding]::new($true))
$captureResult=Invoke-GMTestProcess -ScriptPath $capturePath -Context $context
Write-Output $captureResult.Stdout
Assert-GMEqual $captureResult.ExitCode 0 $captureResult.Stderr
