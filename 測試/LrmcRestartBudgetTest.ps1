$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'lrmc-restart-budget'
try {
    $source=[IO.File]::ReadAllText((Join-Path $root 'payload\開啟LRMC.ahk'))
    $initializer=[regex]::Match($source,'(?ms)^(?<name>(?:Initialize|Reset)RestartCounter)\(\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)')
    Assert-GMTrue $initializer.Success 'Missing restart-budget initializer'
    $extracted=$initializer.Value
    foreach($name in @('CheckRestartCounter','IncrementRestartCounter','IniReadSafe')) {
        $function=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)').Value
        Assert-GMTrue ([bool]$function) "Missing restart-budget function $name"
        # Do not include auto-execute startup statements following these functions.
        $function=($function -split '(?m)^Hotkey\(|^; ===== 原流程',2)[0]
        $extracted+="`n$function"
    }
    $initName=$initializer.Groups['name'].Value
    $testPath=Join-Path $context.RunRoot 'lrmc-restart-budget.ahk'
    $harness=@"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
global CFG_FILE := A_ScriptDir "\restart-budget.ini", RESTART_COUNT_KEY := "LRMC_restart_count"
global SCRIPT_START_TIME := "20261001083000", MAX_RESTART_ATTEMPTS := 3
GMTest_Run(TestBudget)
TestBudget() {
    global CFG_FILE, RESTART_COUNT_KEY, SCRIPT_START_TIME
    IniWrite("2",CFG_FILE,"restart_tracking",RESTART_COUNT_KEY)
    IniWrite("20260930235900",CFG_FILE,"restart_tracking",RESTART_COUNT_KEY "_time")
    IniWrite("Asia",CFG_FILE,"server_schedule","target")
    $initName()
    GMTest_Assert(CheckRestartCounter() = 2,"relaunch preserves the two previously consumed restart attempts")
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking",RESTART_COUNT_KEY "_time") = "20260930235900","relaunch preserves the original failure timestamp")
    GMTest_Assert(IncrementRestartCounter() = 3,"third recorded failure exhausts the existing budget")
    $initName()
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking",RESTART_COUNT_KEY) = "3","relaunch cannot bypass an exhausted restart budget")
    GMTest_Assert(IniRead(CFG_FILE,"server_schedule","target") = "Asia","restart budget does not change the scheduled server")
    CFG_FILE := A_ScriptDir "\fresh-budget.ini"
    $initName()
    GMTest_Assert(CheckRestartCounter() = 0,"first installation starts with an unused budget")
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking",RESTART_COUNT_KEY "_time") = SCRIPT_START_TIME,"first installation initializes its timestamp")
}
Log(args*) => 0
$extracted
"@
    [IO.File]::WriteAllText($testPath,$harness,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $testPath $context 20
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'LRMCAI restart budget persists across relaunch'

    # The real cap must exit before any caller can continue; suppress only the UI dialog.
    $capPath=Join-Path $context.RunRoot 'lrmc-cap.ahk'
    $capCode=$extracted -replace '(?m)^\s*MsgBox .*$', '        Log("limit dialog suppressed by isolated test")'
    $capHarness=@"
#Requires AutoHotkey v2.0
global CFG_FILE := A_ScriptDir "\cap-budget.ini", RESTART_COUNT_KEY := "LRMC_restart_count"
global SCRIPT_START_TIME := "20261001083000", MAX_RESTART_ATTEMPTS := 3
IniWrite("3",CFG_FILE,"restart_tracking",RESTART_COUNT_KEY)
CheckRestartCounter()
FileAppend("BAD: passed exhausted cap","*")
ExitApp(77)
Log(args*) => 0
$capCode
"@
    [IO.File]::WriteAllText($capPath,$capHarness,[Text.UTF8Encoding]::new($true))
    $capResult=Invoke-GMTestProcess $capPath $context 10
    Assert-GMEqual $capResult.ExitCode 0 'Exhausted child must exit before continuing'
    Assert-GMTrue (-not $capResult.Stdout.Contains('BAD:')) 'Exhausted cap allowed caller continuation'

    # Catch the parent launching an already-exhausted child every 15 seconds.
    # Run/ProcessExist are external boundaries: never operate actual project processes.
    $main=[IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $mainExtracted=''
    foreach($name in @('TryRecoverLrmcDuringRewardMonitor','HandleCycleFinishAndShutdown','RenewLrmcRestartBudgetAfterCompletedCycle','ResetRestartTrackingOnFreshStart','PreserveRestartTrackingOnFreshStart','ResetRestartTrackingAfterCompletedCycle','ResetSelfHealingTracking','IniReadSafe')) {
        $mainExtracted += "`n"+[regex]::Match($main,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)').Value
    }
    $freshEntry=[regex]::Match($main,'(?m)^\s*((?:Reset|Preserve)RestartTrackingOnFreshStart)\(\)').Groups[1].Value
    Assert-GMTrue ([bool]$freshEntry) 'Missing production fresh-start entry'
    $startupCompletion=[regex]::Match($main,'(?ms)ShowTip\("🟢 已啟動 LRMC 管理腳本", 3000\)\s*(.*?)^StartPendingServerSwitchCompletionMonitor\(\)').Groups[1].Value
    Assert-GMTrue ([bool]$startupCompletion) 'Missing production startup-completion block'
    $mainExtracted=$mainExtracted -replace '\bProcessExist\(', 'TestProcessExist(' -replace '(?m)^(\s*)Run\(', '${1}TestRun('
    $resetBody=[regex]::Match($mainExtracted,'(?ms)^ResetRestartTrackingAfterCompletedCycle\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)').Value
    if($resetBody){$mainExtracted=$mainExtracted.Replace($resetBody,($resetBody -replace '\bIniWrite\b','TestBudgetIniWrite'))}
    $parentPath=Join-Path $context.RunRoot 'lrmc-parent-budget.ahk'
    $parentHarness=@"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
global CFG_FILE := A_ScriptDir "\parent-budget.ini", AhkExe := A_AhkPath
global REWARD_LRMCAI_RESTART_COOLDOWN_MS := 15000, __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := 0
global CURRENT_SERVER_TARGET := "Asia", SERVER_SCHEDULE_ENABLED := true
global __NEXTSERVER_RESTART := false, __RESTART_IN_PROGRESS := false
global launches := 0, ticks := 100000, shutdowns := 0
global restartCount := 6, injectBudgetFailure := false, budgetErrors := 0
GMTest_Run(TestParentBudget)
TestParentBudget() {
    global CFG_FILE, launches, ticks, shutdowns, __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK, injectBudgetFailure, budgetErrors
    SeedMainProtection()
    $freshEntry()
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","auto_restart_count") = "0","explicit fresh launch resets yesterday's main retry budget")
    GMTest_Assert(IniRead(CFG_FILE,"lrmc_runtime","run_started") = "1","fresh budget does not erase the interrupted task")
    GMTest_Assert(IniRead(CFG_FILE,"self_healing","last_failure_at_unix_ms") = "1790810342906","fresh budget retains historical failure evidence")
    SeedMainProtection()
    StartupCompletion()
    AssertMainProtection("entering reward monitoring before verified task completion")
    IniWrite("3",CFG_FILE,"restart_tracking","LRMC_restart_count")
    IniWrite("20260930235900",CFG_FILE,"restart_tracking","LRMC_restart_count_time")
    Loop 4 {
        TryRecoverLrmcDuringRewardMonitor()
        ticks += 20000
    }
    GMTest_Assert(launches = 0,"exhausted parent must never redispatch the child")
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","LRMC_restart_count") = "3","waiting cannot clear exhausted budget")
    IniWrite("2",CFG_FILE,"restart_tracking","LRMC_restart_count")
    __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := 0
    GMTest_Assert(TryRecoverLrmcDuringRewardMonitor(),"remaining budget permits child dispatch")
    GMTest_Assert(launches = 1,"parent dispatched exactly once")
    TryRecoverLrmcDuringRewardMonitor()
    GMTest_Assert(launches = 1,"cooldown prevents duplicate child dispatch")
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","LRMC_restart_count") = "2","dispatch is not proof of completed task")
    HandleCycleFinishAndShutdown("2026-10-01 08:45:00")
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","LRMC_restart_count") = "0","confirmed reward-completion renews next task budget")
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","LRMC_restart_count_time") = "20261001084500","actual completion timestamp is normalized for restart tracking")
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","auto_restart_count") = "0","actual completed task renews the parent retry budget")
    GMTest_Assert(IniRead(CFG_FILE,"self_healing","consecutive_count") = "0","actual completed task ends the previous incident streak")
    GMTest_Assert(shutdowns = 1,"completion still closes this cycle exactly once")
    SeedMainProtection()
    IniWrite("3",CFG_FILE,"restart_tracking","LRMC_restart_count")
    HandleCycleFinishAndShutdown("")
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","LRMC_restart_count") = "3","missing completion evidence cannot renew budget")
    AssertMainProtection("missing completion evidence")
    RenewLrmcRestartBudgetAfterCompletedCycle("2026-99-01 08:45:00")
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","LRMC_restart_count") = "3","invalid completion date cannot renew budget")
    IniWrite("broken",CFG_FILE,"restart_tracking","LRMC_restart_count")
    ticks += 20000
    TryRecoverLrmcDuringRewardMonitor()
    GMTest_Assert(launches = 1,"malformed budget fails closed instead of launching or clearing it")
    SeedMainProtection()
    injectBudgetFailure := true
    beforeShutdowns := shutdowns, beforeErrors := budgetErrors
    HandleCycleFinishAndShutdown("2026-10-01 09:00:00")
    GMTest_Assert(shutdowns = beforeShutdowns+1,"budget-write failure cannot skip completed-cycle shutdown")
    GMTest_Assert(budgetErrors = beforeErrors+1,"partial budget-write failure is reported explicitly")
}
TestBudgetIniWrite(value,file,section,key) {
    global injectBudgetFailure
    if injectBudgetFailure && key = "auto_restart_count"
        throw Error("isolated budget write failure")
    IniWrite(value,file,section,key)
}
SeedMainProtection() {
    global CFG_FILE
    IniWrite("6",CFG_FILE,"restart_tracking","auto_restart_count")
    IniWrite("6",CFG_FILE,"self_healing","consecutive_count")
    IniWrite("1790810342906",CFG_FILE,"self_healing","last_failure_at_unix_ms")
    IniWrite("1",CFG_FILE,"lrmc_runtime","run_started")
}
AssertMainProtection(context) {
    global CFG_FILE
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","auto_restart_count") = "6",context " preserves main retry count")
    GMTest_Assert(IniRead(CFG_FILE,"self_healing","consecutive_count") = "6",context " preserves failure streak")
    GMTest_Assert(IniRead(CFG_FILE,"self_healing","last_failure_at_unix_ms") = "1790810342906",context " preserves failure evidence")
    GMTest_Assert(IniRead(CFG_FILE,"lrmc_runtime","run_started") = "1",context " preserves LRMC continuation")
}
StartupCompletion() {
    global CFG_FILE
$startupCompletion
}
SetLrmcRunResumeReady(ready,args*) {
    global CFG_FILE
    IniWrite(ready ? "1" : "0",CFG_FILE,"lrmc_runtime","run_started")
}
RC_UnixMs() => 1790815500000
MonotonicTickMs() => ticks
TestProcessExist(name) => 0
TestRun(command) {
    global launches
    GMTest_Assert(InStr(command,'\開啟LRMC.ahk" resume'),"recovery uses the existing resume child")
    launches += 1
}
WriteLog(message,level := "INFO") {
    global budgetErrors
    if level = "ERROR"
        budgetErrors += 1
}
WriteStep(args*) => 0
ShowTip(args*) => 0
MarkServerCompletedInCurrentCycle(args*) => 0
AdvanceServerScheduleForNextCycle() => false
TryStopScreenRecording(args*) => 0
ShutdownGameLrmcOkww(args*) {
    global shutdowns
    shutdowns += 1
}
$mainExtracted
"@
    [IO.File]::WriteAllText($parentPath,$parentHarness,[Text.UTF8Encoding]::new($true))
    $parentResult=Invoke-GMTestProcess $parentPath $context 10
    if($parentResult.Stdout){Write-Output $parentResult.Stdout}
    if($parentResult.Stderr){Write-Output $parentResult.Stderr}
    Assert-GMEqual $parentResult.ExitCode 0 'Parent recovery respects exhausted budget and completed-task boundary'

    # Run the real terminal-cap branch without any game, UI, sleep or recording operations.
    $restartFn=[regex]::Match($main,'(?ms)^RestartAutoScript\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)').Value
    $capPrefix=($restartFn -split '(?m)^\s*; 儲存重啟計數',2)[0]
    $capPrefix=$capPrefix -replace '\bSleep\b','TestSleep' -replace '\bSetTimer\b','TestSetTimer'
    $mainCapPath=Join-Path $context.RunRoot 'main-terminal-cap.ahk'
    $mainCapHarness=@"
#Requires AutoHotkey v2.0
global CFG_FILE := A_ScriptDir "\main-cap.ini", restartCount := 10, MAX_RESTART_COUNT := 10
global LAST_RESTART_REASON := "fixture", LAST_RESTART_CODE := "fixture", LAST_RESTART_STAGE := "fixture"
global LAST_RESTART_RECOVERY := "resume", LAST_RESTART_PROCESS_SNAPSHOT := "", LAST_RESTART_LRMC_STATE := "keep-task"
global CRASH_RESTART_MODE := true, __RESTART_IN_PROGRESS := false, __NEXTSERVER_RESTART := false
global __RESTART_HANDOFF_LAUNCHED := false, MAIL_NOTIFY_ENABLED := false
IniWrite("10",CFG_FILE,"restart_tracking","auto_restart_count")
IniWrite("1",CFG_FILE,"lrmc_runtime","run_started")
RestartAutoScript("isolated exhausted cap")
ExitApp(77)
WriteLog(args*) => 0
WriteStep(args*) => 0
ShowTip(args*) => 0
TestSleep(args*) => 0
TestSetTimer(args*) => 0
CrashWatcherTick(args*) => 0
SetLrmcRunResumeReady(ready,args*) => IniWrite(ready ? "1" : "0",CFG_FILE,"lrmc_runtime","run_started")
ForceStopManagedScreenRecording(args*) => 0
ReadSelfHealingRuntimeState() => {consecutive:6,category:"game",action:"halt",fingerprint:"fixture",lastAt:1790810342906}
WriteSelfHealingRuntimeState(args*) => 0
$capPrefix
    ExitApp(78)
}
"@
    [IO.File]::WriteAllText($mainCapPath,$mainCapHarness,[Text.UTF8Encoding]::new($true))
    $mainCapResult=Invoke-GMTestProcess $mainCapPath $context 10
    if($mainCapResult.Stderr){Write-Output $mainCapResult.Stderr}
    Assert-GMEqual $mainCapResult.ExitCode 0 'Terminal main cap must exit without handing off'
    $capIni=Get-Content -LiteralPath (Join-Path $context.RunRoot 'main-cap.ini') -Raw
    Assert-GMTrue ($capIni -match '(?m)^auto_restart_count=11\s*$') 'Terminal cap must persist consumed budget, not reset it'
    Assert-GMTrue ($capIni -match '(?m)^run_started=1\s*$') 'Terminal cap preserves interrupted LRMC task continuation'
} finally {Complete-ProjectDevelopmentPaths -Context $context}
