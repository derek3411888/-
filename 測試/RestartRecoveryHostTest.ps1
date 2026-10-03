[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'restart-recovery-host'
try {
    $main=[IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $hostSource=[IO.File]::ReadAllText((Join-Path $root 'payload\GameMaintenanceHost.ahk'))
    $functions=''
    foreach($name in @('ResolveManagedTargetExePath','CloseManagedProcessRecord','CloseExactProcessForSelfHealing','PrepareRestartRecoveryAttempt','TryQueueSafeRestartHandoff','ReadRestartRecoveryIntent','ResetRestartTrackingOnFreshStart')) {
        $fn=[regex]::Match($main,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)').Value
        Assert-GMTrue ([bool]$fn) "Missing production function $name"
        $functions+="`n$fn"
    }
    $functions+="`n"+[regex]::Match($hostSource,'(?ms)^GM_PrepareCleanLauncherRestart\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)').Value
    # Inventory is the OS boundary. Policy, path decisions and journal release
    # remain production code; no actual game process is queried or stopped.
    $functions=$functions -replace 'ComObjGet\("winmgmts:"\)\.ExecQuery\([^\r\n]+\)', 'FixtureInventory()'
    Assert-GMTrue ($main -match 'if \(!isRestart && !isNextServerCycle\)\s+ResetRestartTrackingOnFreshStart\(\)') 'Fresh reset must exclude restart and nextserver entries'
    Assert-GMTrue ($main -notmatch 'PreserveRestartTrackingOnFreshStart\(') 'Obsolete fresh counter retention remains wired'
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __ROOT__\測試\GameMaintenanceFixtures.ahk
#Include __ROOT__\payload\GameMaintenance.ahk
global GM_CONTROLLER := 0, CFG_FILE := A_ScriptDir "\budget.ini", inventory := [], killed := []
global AhkExe := A_AhkPath, __RESTART_HANDOFF_LAUNCHED := false, __SCREEN_RECORDING_PID := 0
global __RESTART_RECOVERY_RETRY_ID := 0, REMOTE_STOP_IN_PROGRESS := false, __CLEAN_FINAL_EXIT_REQUESTED := false
global EXITING_FROM_TRAY := false, REMOTE_CONTROL_ACTIVE := false, workers := 0, cancelled := true, missingImage := ""
global restartCount := 6
global pauseAt := "", paused := false, REMOTE_CONTROL_ACTIVE := true
GMTest_Run(TestHost)
TestHost() {
    global GM_CONTROLLER, inventory, killed, workers, cancelled, missingImage, REMOTE_STOP_IN_PROGRESS, CFG_FILE, restartCount, pauseAt
    ResetFixture()
    original := GM_CONTROLLER.state.actionId
    inventory := [{ProcessId:101,ExecutablePath:"C:\fixture\Wuthering Waves.exe",Name:"Wuthering Waves.exe"},
        {ProcessId:102,ExecutablePath:"C:\other\Wuthering Waves.exe",Name:"Wuthering Waves.exe"}]
    detail := ""
    GMTest_Assert(!GM_PrepareCleanLauncherRestart(&detail) && InStr(detail,"pid=101"),"guard explains exact surviving wrapper")
    GMTest_Assert(GM_CONTROLLER.state.actionId = original,"failed gate retains launch intent")
    PrepareRestartRecoveryAttempt("restart resume", "fixture-launcher")
    GMTest_Assert(killed.Length = 1 && killed[1] = 101,"only exact verified installation wrapper is stopped")
    GMTest_Assert(workers = 1 && inventory.Length = 1 && inventory[1].ProcessId = 102,"foreign install remains; exactly one worker armed")
    GMTest_Assert(GM_CONTROLLER.state.actionId = "" && GM_CONTROLLER.state.targetServer = "Asia","verified exit releases launch intent but preserves task target")
    ResetFixture()
    inventory := [{ProcessId:103,ExecutablePath:"",Name:"Wuthering Waves.exe"}]
    GMTest_Assert(!GM_PrepareCleanLauncherRestart(&detail) && InStr(detail,"PROCESS_IMAGE_UNREADABLE"),"unreadable image fails closed with diagnostic reason")
    GMTest_Assert(workers = 0 && killed.Length = 0,"unreadable identity never killed or handed off")
    ResetFixture()
    GM_CONTROLLER.install.identityVerified := false
    GMTest_Assert(!GM_PrepareCleanLauncherRestart(&detail) && detail = "INSTALL_IDENTITY_UNVERIFIED","unknown install is not permission to restart")
    ResetFixture()
    GM_CONTROLLER.state.recoveryUncertain := true
    GMTest_Assert(!GM_PrepareCleanLauncherRestart(&detail) && InStr(detail,"JOURNAL_RELEASE_REJECTED"),"uncertain journal is never bypassed")
    ResetFixture()
    REMOTE_STOP_IN_PROGRESS := true
    try PrepareRestartRecoveryAttempt("restart", "")
    catch {
    }
    GMTest_Assert(workers = 0 && killed.Length = 0,"STOP prevents cleanup and worker creation")
    REMOTE_STOP_IN_PROGRESS := false
    cancelled := false
    try PrepareRestartRecoveryAttempt("restart", "")
    catch {
    }
    GMTest_Assert(workers = 0 && killed.Length = 0,"uncancelled prior worker prevents all new handoff work")
    for stage in ["cancellation", "inventory", "identity"] {
        ResetFixture()
        pauseAt := stage
        inventory := [{ProcessId:104,ExecutablePath:"C:\fixture\Client\Binaries\Win64\Client-Win64-Shipping.exe",Name:"Client-Win64-Shipping.exe"},
            {ProcessId:105,ExecutablePath:"C:\fixture\Wuthering Waves.exe",Name:"Wuthering Waves.exe"}]
        try PrepareRestartRecoveryAttempt("restart", "")
        catch {
        }
        GMTest_Assert(killed.Length = 0 && workers = 0,"PAUSE during " stage " prevents subsequent game termination and handoff")
    }
    IniWrite("6",CFG_FILE,"restart_tracking","auto_restart_count")
    IniWrite("Asia",CFG_FILE,"server_schedule","target")
    IniWrite("123",CFG_FILE,"remote_control","last_processed_nonce")
    ResetRestartTrackingOnFreshStart()
    GMTest_Assert(restartCount = 0 && IniRead(CFG_FILE,"restart_tracking","auto_restart_count") = "0","memory and durable fresh budget both zero")
    GMTest_Assert(IniRead(CFG_FILE,"server_schedule","target") = "Asia" && IniRead(CFG_FILE,"remote_control","last_processed_nonce") = "123","fresh start preserves target and command cursor")
}
ResetFixture() {
    global GM_CONTROLLER, workers, killed, inventory, cancelled, pauseAt, paused, REMOTE_STOP_IN_PROGRESS
    root := TestRuntime_NewCaseDir("restart-host")
    GM_CONTROLLER := GM_CreateController(root "\state.ini",{runCycle:"20261002",nowUtcMs:1790892000000}, {})
    GM_CONTROLLER.state.actionId := "fixture-launch", GM_CONTROLLER.state.targetServer := "Asia"
    GM_CONTROLLER.install := {identityVerified:true,gameRoot:"C:\fixture"}
    workers := 0, killed := [], inventory := [], cancelled := true
    pauseAt := "", paused := false, REMOTE_STOP_IN_PROGRESS := false
}
FixturePause(stage) {
    global paused
    if pauseAt = stage
        paused := true
}
FixtureInventory() {
    FixturePause("inventory")
    return inventory.Clone()
}
GMHost_CanonicalPath(path) => path
ReadManagedProcessRecord(pid) {
    FixturePause("identity")
    for item in inventory
        if item.ProcessId = pid
            return item.ExecutablePath = "" ? 0 : {pid:pid,path:item.ExecutablePath,started:"fixture"}
    return 0
}
MPG_CloseRecord(record,mayTerminate := 0) {
    global inventory, killed
    if IsObject(mayTerminate) && !mayTerminate.Call()
        return false
    for index,item in inventory
        if item.ProcessId = record.pid {
            inventory.RemoveAt(index), killed.Push(record.pid)
            return true
        }
    return false
}
RestartHandoff_ResetCancelled() {
    FixturePause("cancellation")
    return cancelled
}
RestartHandoff_Prepare(args*) {
    global workers
    GMTest_Assert(args[5] = "","internal recovery must not route through network package updater before ACK")
    workers += 1
    return {request:"fixture",workerPid:999}
}
RestartHandoff_RecorderIdentity(args*) => 0
RuntimeFiles_RuntimeDir(args*) => A_ScriptDir
GM_IsMaintenanceStopped() => GM_CONTROLLER.state.cancelled
RC_IsPaused() => paused
IniReadSafe(file,section,key,default) => IniRead(file,section,key,default)
WriteLog(args*) => 0
WriteStep(args*) => 0
__FUNCTIONS__
'@
    $fixture=$fixture.Replace('__ROOT__',$root).Replace('__FUNCTIONS__',$functions)
    $path=Join-Path $context.RunRoot 'restart-recovery-host.ahk'
    [IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $path $context 15
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'Restart recovery real host guard and cleanup policy'
} finally {Complete-ProjectDevelopmentPaths -Context $context}
