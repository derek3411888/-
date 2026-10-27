[CmdletBinding()]
param([ValidateSet('legacy','current')][string]$Mode='current',[switch]$MissingWorkflowImage,[switch]$MissingWorkflowCommand,[switch]$StaleWorkflowCreation)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$run=Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\20261025-fresh-start-takeover\native-'+[Guid]::NewGuid().ToString('N'))
$install=Join-Path $run 'isolated-install'
[void][IO.Directory]::CreateDirectory((Join-Path $install 'payload'))
$context=[pscustomobject]@{ProjectRoot=$project;Root=(Join-Path $project '.dev-runtime');RunRoot=$run}
$runtime=Join-Path $install 'AutoHotkey64.exe'
Copy-Item -LiteralPath (Join-Path $project 'AutoHotkey64.exe') -Destination $runtime
$gameRoot=Join-Path $install 'fixture-game'
$nativePath=Join-Path $gameRoot 'Client\Binaries\Win64\Client-Win64-Shipping.exe'
[void][IO.Directory]::CreateDirectory((Split-Path $nativePath -Parent))
[void][IO.Directory]::CreateDirectory((Join-Path $install 'config'))
Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\ping.exe') -Destination $nativePath
Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\ping.exe') -Destination (Join-Path $gameRoot 'Wuthering Waves.exe')
[IO.File]::WriteAllText((Join-Path $install 'config\config.ini'),("[paths]`r`nWUTHERING="+(Join-Path $gameRoot 'Wuthering Waves.exe')+"`r`n"),[Text.UnicodeEncoding]::new($false,$true))
$native=Start-Process -FilePath $nativePath -ArgumentList '-t 127.0.0.1' -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $run 'native.stdout') -RedirectStandardError (Join-Path $run 'native.stderr')
[void]$native.Handle
$mainPath=Join-Path $install 'payload\全自動.ahk'
$childText=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include __LOCK__
#Include __PROJECT__\payload\GameMaintenance.ahk
FileEncoding("UTF-8")
global lock := InstallStartupLock_AcquireRuntime("__INSTALL__")
if lock <= 0
    ExitApp(9)
; Legacy mode deliberately has NO OnMessage override: exercise the actual
; interpreter-default File Exit path rather than faking the new close hook.
state := GM_DefaultState(), state.phase := "UPDATING", state.provider := "kuro"
state.actionId := "old-attempt", state.actionStage := "observed"
state.notificationKeys := "old-mail-history"
GM_SaveJournal("__INSTALL__\config\game-maintenance\state.ini",state)
OnExit(FinishFixture)
CloseFixture(*) {
    FileAppend("close", "__INSTALL__\close-requested")
    ExitApp()
}
FinishFixture(reason,*) {
    Sleep 200
    FileAppend("recording-finalized", "__INSTALL__\closed")
    FileAppend(reason, "__INSTALL__\exit-reason")
}
FileAppend("ready", "__INSTALL__\ready")
Persistent
'@
if($Mode -eq 'current'){
    $hostSource=[IO.File]::ReadAllText((Join-Path $project 'payload\全自動.ahk'))
    $closeHook=[regex]::Match($hostSource,'(?ms)^OnFreshLauncherClose\([^\r\n]*\) \{.*?^\}').Value
    Assert-GMTrue ([bool]$closeHook) 'Current main exposes its graceful full-shutdown callback'
    $childText=$childText.Replace('OnExit(FinishFixture)','OnMessage(0x10,OnFreshLauncherClose)' + "`nOnMessage(0x111,OnFreshLauncherClose)`nOnExit(FinishFixture)")+"`nExitFromTrayNow(*) => CloseFixture()`n"+$closeHook
}
[IO.File]::WriteAllText($mainPath,$childText.Replace('__LOCK__',(Join-Path $project 'payload\InstallStartupLock.ahk')).Replace('__INSTALL__',$install).Replace('__PROJECT__',$project),[Text.UTF8Encoding]::new($true))
$source=[IO.File]::ReadAllText((Join-Path $project '打包啟動器.ahk'))
$start=$source.IndexOf('; BEGIN LAUNCHER RUNTIME RESERVATION')
$end=$source.IndexOf('autoFolderName :=', $start)
Assert-GMTrue ($start -ge 0 -and $end -gt $start) 'Actual launcher installation admission is available'
$admission=$source.Substring($start,$end-$start)
$parentText=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include __PROJECT__\payload\InstallStartupLock.ahk
#Include __PROJECT__\LauncherStartupGuard.ahk
#Include *i __PROJECT__\LauncherFreshStart.ahk
#Include __PROJECT__\payload\GameMaintenance.ahk
; Query real WMI records but limit this non-elevated test to its retained
; fixture PID. Production elevated AHK is never an inventory/action target.
ComObjGet(*) => FixtureInventory()
class FixtureInventory {
    ExecQuery(query) {
        service := ComObject("WbemScripting.SWbemLocator").ConnectServer(".","root\cimv2")
        ; Group the original WHERE conditions before adding the fixture scope.
        query := RegExReplace(query,"i) where "," where (")
        records := []
        for proc in service.ExecQuery(query ") AND (ProcessId=__CHILD_PID__ OR ProcessId=__NATIVE_PID__)") {
            if (__MASK_WORKFLOW_IMAGE__ || __MASK_WORKFLOW_COMMAND__ || __STALE_WORKFLOW_CREATION__) && proc.ProcessId = __NATIVE_PID__ {
                ; Real retained ping fixture; omit only the WMI image as seen
                ; on MYDESKPC. Native image/time queries remain unmodified.
                masked := {}
                for field in ["ProcessId","Name","CommandLine","CreationDate","ExecutablePath"]
                    masked.%field% := proc.%field%
                if __MASK_WORKFLOW_IMAGE__
                    masked.ExecutablePath := ""
                if __MASK_WORKFLOW_COMMAND__
                    masked.CommandLine := ""
                if __STALE_WORKFLOW_CREATION__
                    masked.CreationDate := "20000101000000.000000+000"
                records.Push(masked)
            } else
                records.Push(proc)
        }
        return records
    }
}
LauncherProjectRoot() => "__INSTALL__"
LauncherHasArg(*) => false
WriteLog(text,level := "INFO") => FileAppend(level ": " text "`n","*")
WriteStep(name,detail := "",level := "INFO") => WriteLog(name " | " detail,level)
global PACK_MAIN_MUTEX_HANDLE := InstallStartupLock_Acquire(LauncherProjectRoot())
if PACK_MAIN_MUTEX_HANDLE <= 0
    ExitApp(8)
__ADMISSION__
if !FileExist("__INSTALL__\closed")
    throw Error("installation writes allowed before old cleanup finished")
if ProcessExist(__NATIVE_PID__)
    throw Error("owned gameplay child survives legacy/current main exit before update")
if GM_HasActiveContinuation("__INSTALL__\config\config.ini",0)
    throw Error("old maintenance attempt is still an active continuation on fresh launch")
state := GM_LoadJournal("__INSTALL__\config\game-maintenance\state.ini")
if state.notificationKeys != "old-mail-history"
    throw Error("fresh launch lost maintenance notification history")
FileAppend("NEXT_PHASE", "*")
ExitApp(0)
'@
$parent=Join-Path $run 'isolated-launcher.ahk'
$child=Start-Process -FilePath $runtime -ArgumentList ('/ErrorStdOut=UTF-8 "'+$mainPath+'"') -WorkingDirectory $install -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $run 'child.stdout') -RedirectStandardError (Join-Path $run 'child.stderr')
[void]$child.Handle
[IO.File]::WriteAllText($parent,$parentText.Replace('__PROJECT__',$project).Replace('__INSTALL__',$install).Replace('__ADMISSION__',$admission).Replace('__CHILD_PID__',[string]$child.Id).Replace('__NATIVE_PID__',[string]$native.Id).Replace('__MASK_WORKFLOW_IMAGE__',[string][int][bool]$MissingWorkflowImage).Replace('__MASK_WORKFLOW_COMMAND__',[string][int][bool]$MissingWorkflowCommand).Replace('__STALE_WORKFLOW_CREATION__',[string][int][bool]$StaleWorkflowCreation),[Text.UTF8Encoding]::new($true))
try {
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    while(!(Test-Path -LiteralPath (Join-Path $install 'ready')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 50}
    Assert-GMTrue (Test-Path -LiteralPath (Join-Path $install 'ready')) 'Isolated old main owns the real runtime mutex'
    $result=Invoke-GMTestProcess -ScriptPath $parent -Context $context -TimeoutSeconds 15
    if($StaleWorkflowCreation) {
        Assert-GMEqual $result.ExitCode 1 'Stale WMI creation must block real native termination and update'
        Assert-GMTrue ($result.Stdout.Contains('reason=creation-mismatch')) 'Rejection must come from the original-to-native creation guard'
        Assert-GMTrue (!$native.HasExited) 'Stale snapshot must not terminate the harmless native process'
        Assert-GMTrue (!$result.Stdout.Contains('NEXT_PHASE')) 'Stale native identity must not admit installation'
        Write-Output 'PASS stale original WMI creation: live native process retained and update blocked'
        return
    }
    Assert-GMEqual $result.ExitCode 0 ('Fresh launcher admission failed: '+$result.Stdout+$result.Stderr)
    Assert-GMTrue ($result.Stdout.Contains('NEXT_PHASE')) 'Fresh launch must close old owned main before update instead of exiting at its runtime lock'
    Assert-GMTrue ($child.WaitForExit(2000)) 'Old retained process must actually exit'
    if($Mode -eq 'current') {
        Assert-GMTrue (Test-Path -LiteralPath (Join-Path $install 'close-requested')) 'Current main must use full normal shutdown hook'
    } else {
        Assert-GMEqual ([IO.File]::ReadAllText((Join-Path $install 'exit-reason'))) 'Menu' 'Legacy default File Exit must reach OnExit normally'
    }
    Assert-GMTrue ($native.WaitForExit(2000)) 'Retained harmless native gameplay fixture actually exited'
    Write-Output ('PASS actual fresh launcher admission ('+$Mode+', missingImage='+[bool]$MissingWorkflowImage+'): normal main close, native child drain, maintenance archive/reset, runtime ownership')
} finally {
    if(!$child.HasExited){$child.Kill();[void]$child.WaitForExit(3000)}
    $child.Dispose()
    if(!$native.HasExited){$native.Kill();[void]$native.WaitForExit(3000)}
    $native.Dispose()
}
