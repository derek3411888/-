$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'lrmc-task-abandon-resume'
try {
    $main = [IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $extracted = ''
    foreach ($name in @('RequestRestart','IsLrmcRunResumeReady','GetLrmcRunStateSummary',
        'SetLrmcRunResumeReady','ClearRewardMonitorRuntimeState','IniReadSafe')) {
        $fn = [regex]::Match($main, '(?ms)^'+$name+'\([^\r\n]*\) \{.*?^\}').Value
        Assert-GMTrue ([bool]$fn) "Missing runtime function: $name"
        $extracted += "`n$fn"
    }
    $burst = [regex]::Match($main, '(?ms)^\s*activeAllowed := !\(REMOTE_CONTROL_ACTIVE && RC_IsPaused\(\)\).*?(?=^\s*if \(activeAllowed && state.invalidHwndHits)').Value
    Assert-GMTrue ([bool]$burst) 'Missing production task-abandon recovery branch'
    # Window inventory is external; never inspect or activate the live game.
    $burst = $burst -replace '\bWinGetTitle\(', 'TestWindowText(' -replace '\bWinGetProcessName\(', 'TestWindowText('
    $lrmcLaunch = [regex]::Match($main, '(?ms)^lrmcCmd := .*?^Run\(lrmcCmd\)').Value
    Assert-GMTrue ([bool]$lrmcLaunch) 'Missing LRMC child command builder'
    $lrmcLaunch = $lrmcLaunch -replace '\bRun\(', 'TestDispatch('
    $harness = @"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
#Include $root\payload\RewardMonitorIncidentPolicy.ahk
global CFG_FILE := A_ScriptDir "\resume.ini", REWARD_MONITOR_STATE_SECTION := "reward_monitor_runtime"
global REMOTE_CONTROL_ACTIVE := true, livePaused := false, allowRecovery := true
global REWARD_TASK_ABANDON_NEED_COUNT := 5, REWARD_TASK_ABANDON_WINDOW_SEC := 90
global CRASH_RESTART_MODE := false, LAST_RESTART_REASON := "", LAST_RESTART_CODE := ""
global LAST_RESTART_STAGE := "", LAST_RESTART_RECOVERY := "", LAST_RESTART_PROCESS_SNAPSHOT := "", LAST_RESTART_LRMC_STATE := ""
global LAST_INPUT_ACTIVATION_BLOCKER_KIND := "", LAST_INPUT_ACTIVATION_BLOCKER_DETAIL := ""
global restarts := 0, lastCommand := "", AhkExe := A_AhkPath
GMTest_Run(TestTaskAbandonRecovery)
TestTaskAbandonRecovery() {
    global CFG_FILE, REWARD_MONITOR_STATE_SECTION, livePaused, allowRecovery
    global restarts, CRASH_RESTART_MODE, LAST_RESTART_RECOVERY, LAST_RESTART_CODE, lastCommand
    Seed()
    state := BurstState(4)
    Recover(state)
    GMTest_Assert(restarts = 0, "four abandoned tasks must not restart")
    state := BurstState(5)
    livePaused := true
    Recover(state)
    GMTest_Assert(restarts = 0, "PAUSE must defer burst recovery")
    GMTest_Assert(IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_reason") = "old reward", "PAUSE preserves pending state")
    livePaused := false
    Recover(state)
    GMTest_Assert(restarts = 1, "five tasks in 80 seconds request one recovery")
    GMTest_Assert(CRASH_RESTART_MODE, "task-abandon recovery must resume instead of restarting the task list")
    GMTest_Assert(LAST_RESTART_CODE = "LRMCAI_TASK_ABANDON_BURST", "retain the incident identity")
    GMTest_Assert(InStr(LAST_RESTART_RECOVERY,"LRMCAI快捷鍵接續"), "recovery status reports actual continuation")
    GMTest_Assert(IniRead(CFG_FILE,"lrmc_runtime","run_started") = "1", "resume-ready marker survives recovery")
    GMTest_Assert(IniRead(CFG_FILE,"lrmc_runtime","run_started_time") = "20261007122711", "original task timestamp survives recovery")
    GMTest_Assert(IniRead(CFG_FILE,"lrmc_runtime","start_mode") = "resume", "original task mode survives recovery")
    GMTest_Assert(IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_reason") = "", "untrusted reward evidence must still be cleared")
    for key in ["completion_recorded","pending_at","seen_daily_reward_success","seen_no_reward","seen_click_reward","click_reward_hits"]
        GMTest_Assert(IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,key) = "", "stale completion field must be cleared: " key)
    DispatchLrmc()
    GMTest_Assert(SubStr(lastCommand,-7) = ' resume', "LRMC receives resume and does not take the fresh folder-selection path")
    AssertProtectedState()

    Seed()
    state := BurstState(4)
    RewardMonitor_RecordTaskAbandon(state,"2026-10-07 13:37:42,000 - LRMCAI - INFO - 传送重试次数过多，放弃该任务!",90)
    Recover(state)
    GMTest_Assert(restarts = 1, "fifth abandoned task outside 90 seconds must not trigger recovery")

    Seed()
    allowRecovery := false
    Recover(BurstState(5))
    GMTest_Assert(restarts = 1, "cancelled cooldown must not dispatch a restart")
    GMTest_Assert(IniRead(CFG_FILE,"lrmc_runtime","run_started") = "1", "cancelled recovery retains continuation")
    allowRecovery := true

    for marker in ["0", "invalid", "missing"] {
        Seed()
        if marker = "missing"
            IniDelete(CFG_FILE,"lrmc_runtime","run_started")
        else
            IniWrite(marker,CFG_FILE,"lrmc_runtime","run_started")
        Recover(BurstState(5))
        GMTest_Assert(!CRASH_RESTART_MODE, "no valid started marker must not fabricate resume: " marker)
        GMTest_Assert(InStr(LAST_RESTART_RECOVERY,"要求接續但無有效已開始標記"), "fallback must be explicit: " marker)
        DispatchLrmc()
        GMTest_Assert(!InStr(lastCommand,' resume'), "invalid marker retains existing normal fallback: " marker)
        AssertProtectedState()
    }
}
Seed() {
    global CFG_FILE, REWARD_MONITOR_STATE_SECTION
    IniWrite("1",CFG_FILE,"lrmc_runtime","run_started")
    IniWrite("20261007122711",CFG_FILE,"lrmc_runtime","run_started_time")
    IniWrite("resume",CFG_FILE,"lrmc_runtime","start_mode")
    IniWrite("fixture",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"state_key")
    IniWrite("old reward",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_reason")
    IniWrite("1",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"completion_recorded")
    IniWrite("20261007133731",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_at")
    IniWrite("1",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"seen_daily_reward_success")
    IniWrite("1",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"seen_no_reward")
    IniWrite("1",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"seen_click_reward")
    IniWrite("2",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"click_reward_hits")
    IniWrite("6",CFG_FILE,"restart_tracking","auto_restart_count")
    IniWrite("2",CFG_FILE,"server_schedule","current_index")
    IniWrite("20261007120000",CFG_FILE,"server_completed","HMT")
}
AssertProtectedState() {
    global CFG_FILE
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","auto_restart_count") = "6", "request cannot reset restart budget")
    GMTest_Assert(IniRead(CFG_FILE,"server_schedule","current_index") = "2", "request cannot change target server")
    GMTest_Assert(IniRead(CFG_FILE,"server_completed","HMT") = "20261007120000", "request cannot erase completed servers")
}
BurstState(count) {
    state := {key:"fixture",taskAbandonHits:0,taskAbandonFirstAt:"",taskAbandonLastAt:"",lastTaskAbandonLine:""}
    times := ["13:36:11","13:36:31","13:36:51","13:37:11","13:37:31"]
    Loop count
        RewardMonitor_RecordTaskAbandon(state,"2026-10-07 " times[A_Index] ",000 - LRMCAI - INFO - 传送重试次数过多，放弃该任务!",90)
    return state
}
Recover(state) {
    global REMOTE_CONTROL_ACTIVE, REWARD_TASK_ABANDON_NEED_COUNT, REWARD_TASK_ABANDON_WINDOW_SEC
$burst
}
DispatchLrmc() {
    global CRASH_RESTART_MODE, AhkExe
$lrmcLaunch
}
TestDispatch(command) {
    global lastCommand
    lastCommand := command
}
RestartAutoScript(args*) {
    global restarts
    restarts += 1
}
RC_IsPaused() => livePaused
CS_RewardAlreadySucceeded(args*) => false
WaitForSelfHealingCooldown(args*) => allowRecovery
PrepareSelfHealingPolicy(args*) => {action:"isolated recovery",consecutive:1}
PerformSafeSelfHealing(args*) => "no external effects in test"
ResetForegroundInputFailureStreak(args*) => 0
IsForegroundInputFailureCode(args*) => false
IncrementForegroundInputFailureStreak(args*) => 0
ForegroundBlockerShouldWaitWithoutRecreate(args*) => false
NotifyUiInputBlockedOnce(args*) => 0
WaitForInteractiveDesktopBeforeRestart(args*) => false
CaptureRestartProcessSnapshot() => "isolated fixture"
PerformanceTelemetry_MarkIncident(args*) => 0
WriteStep(args*) => 0
WriteLog(args*) => 0
ShowTip(args*) => 0
TestWindowText(args*) => "fixture"
$extracted
"@
    $testPath = Join-Path $context.RunRoot 'task-abandon-resume.ahk'
    [IO.File]::WriteAllText($testPath,$harness,[Text.UTF8Encoding]::new($true))
    $result = Invoke-GMTestProcess $testPath $context 20
    if ($result.Stdout) { Write-Output $result.Stdout }
    if ($result.Stderr) { Write-Output $result.Stderr }
    Assert-GMEqual $result.ExitCode 0 'Task-abandon recovery preserves the interrupted LRMC task'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
