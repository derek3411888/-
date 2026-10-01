$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'runtime-recovery-status'
try {
    $main=[IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $firestore=[IO.File]::ReadAllText((Join-Path $root 'payload\RemoteControlFirestore.ahk'))
    $extracted=''
    foreach($entry in @(
        @($main,'RecordSelfHealingGameplayProgress'), @($main,'ReadSelfHealingRuntimeState'),
        @($main,'IniReadSafe'), @($main,'WriteStep'), @($firestore,'RC_ReadSelfHealingStatus')
    )) {
        $fn=[regex]::Match($entry[0],'(?ms)^'+$entry[1]+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)').Value
        Assert-GMTrue ([bool]$fn) ('Missing runtime function: '+$entry[1])
        $extracted+="`n$fn"
    }
    $transition=[regex]::Match($main,'(?ms)^\s*completionReason := GetRewardMonitorCompletionReason\(state\).*?(?=^\s*if \(state.pendingReason = "" && completionReason != ""\))').Value
    Assert-GMTrue ([bool]$transition) 'Missing real observation-window transition'
    $warmup=[regex]::Match($main,'(?ms)^\s*if \(!warmupFinishedLogged && warmupFinished\) \{.*?(?=^\s*if !WaitRewardMonitorForShutdown\(REWARD_CHECK_INTERVAL_MS)').Value
    Assert-GMTrue ([bool]$warmup) 'Missing real warmup status transition'
    $harness=@"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
#Include $root\payload\SelfHealingPolicy.ahk
#Include $root\payload\RewardMonitorIncidentPolicy.ahk
global CFG_FILE := A_ScriptDir "\recovery.ini", RC_CFG_PATH := CFG_FILE
global RUN_ID := A_Now "@fixture", __REWARD_MONITOR_COMPLETION_PENDING := false
global REWARD_TASK_ABANDON_NEED_COUNT := 5, REWARD_TASK_ABANDON_WINDOW_SEC := 90
global REWARD_INVALID_HWND_NEED_COUNT := 5
global REMOTE_CONTROL_ACTIVE := true, livePaused := false
global STEP_SEQ := 0, CURRENT_STEP_NAME := "", CURRENT_STEP_DETAIL := "", CURRENT_STEP_LEVEL := ""
global reportCalls := 0
global SERVER_SCHEDULE_ENABLED := false, CURRENT_SERVER_TARGET := "Asia", steps := []
GMTest_Run(TestRecoveryStatus)
TestRecoveryStatus() {
    global CFG_FILE, steps, RUN_ID, livePaused, reportCalls
    protected := Map("failure_code","GAME_STARTUP_NO_WINDOW_TIMEOUT", "failure_stage","startup",
        "failure_fingerprint","fixture|startup", "consecutive_count","6",
        "last_failure_at_unix_ms","1790810342906", "action","previous repair",
        "detail","original failure evidence", "category","game")
    for key,value in protected
        IniWrite(value,CFG_FILE,"self_healing",key)
    IniWrite("retrying",CFG_FILE,"self_healing","state")
    IniWrite("1790812142906",CFG_FILE,"self_healing","next_retry_at_unix_ms")
    IniWrite("6",CFG_FILE,"restart_tracking","auto_restart_count")
    IniWrite("119",CFG_FILE,"remote_control","last_nonce")
    bad := FormatTime(,"yyyy-MM-dd HH:mm:ss") ",100 - LRMCAI - INFO - 脚本执行完成!"
    GMTest_Assert(!RecordSelfHealingGameplayProgress(bad),"generic script completion is not gameplay recovery")
    GMTest_Assert(IniRead(CFG_FILE,"self_healing","state") = "retrying","no evidence keeps retry status")
    good := FormatTime(,"yyyy-MM-dd HH:mm:ss") ",200 - LRMCAI - INFO - 到达终点了"
    GMTest_Assert(RecordSelfHealingGameplayProgress(good),"fresh route endpoint marks observed recovery")
    view := RC_ReadSelfHealingStatus()
    GMTest_Assert(view.state = "recovered","heartbeat must publish recovered status")
    GMTest_Assert(view.nextRetryAt = 0,"recovered heartbeat has no stale countdown")
    GMTest_Assert(InStr(view.recoveryDetail,"到达终点了"),"heartbeat includes positive recovery evidence")
    GMTest_Assert(view.recoveredAt = 1790857200000,"recovery has its own timestamp")
    for key,value in protected
        GMTest_Assert(IniRead(CFG_FILE,"self_healing",key) = value,"preserve historical protection: " key)
    GMTest_Assert(IniRead(CFG_FILE,"restart_tracking","auto_restart_count") = "6","recovery cannot renew restart budget")
    GMTest_Assert(IniRead(CFG_FILE,"remote_control","last_nonce") = "119","recovery cannot change command cursor")
    before := FileRead(CFG_FILE)
    GMTest_Assert(!RecordSelfHealingGameplayProgress(good),"repeated progress is idempotent")
    GMTest_Assert(FileRead(CFG_FILE) = before,"no write per high-frequency LRMC line")

    for mode in [{paused:false,warm:true,label:"觀察窗已結束"},
        {paused:true,warm:true,label:"PAUSE"},{paused:false,warm:false,label:"暖機"}] {
        livePaused := mode.paused
        steps := []
        state := {taskAbandonHits:1,taskAbandonLastAt:DateAdd(A_Now,-91,"Seconds"),
            taskAbandonCompletionHeld:true,pendingReason:"",pendingAt:"",completionRecorded:false}
        RunWindowTransition(state,mode.paused,mode.warm)
        GMTest_Assert(!state.taskAbandonCompletionHeld,"expired quiet window releases held flag")
        GMTest_Assert(steps.Length = 1 && InStr(steps[1].detail,mode.label),"published step respects current pause/warmup phase")
        GMTest_Assert(state.taskAbandonHits = 1,"status refresh does not clear abandonment history")
        RunWindowTransition(state,mode.paused,mode.warm)
        GMTest_Assert(steps.Length = 1,"window-end status publishes only once")
    }
    steps := []
    state := {taskAbandonHits:1,taskAbandonLastAt:DateAdd(A_Now,-89,"Seconds"),
        taskAbandonCompletionHeld:true,pendingReason:"",completionRecorded:false}
    RunWindowTransition(state,false,true)
    GMTest_Assert(state.taskAbandonCompletionHeld && steps.Length = 0,"active 90-second window cannot be reported ended")
    state.taskAbandonHits := 5, state.taskAbandonLastAt := DateAdd(A_Now,-91,"Seconds")
    RunWindowTransition(state,false,true)
    GMTest_Assert(state.taskAbandonCompletionHeld && steps.Length = 0,"confirmed burst stays held beyond quiet window")
    state.taskAbandonHits := 1, state.taskAbandonLastAt := DateAdd(A_Now,-91,"Seconds")
    IniWrite("retrying",CFG_FILE,"self_healing","state")
    livePaused := true
    RunWindowTransition(state,true,true,good)
    GMTest_Assert(IniRead(CFG_FILE,"self_healing","state") = "retrying","paused monitor cannot claim recovery")
    livePaused := false
    state.invalidHwndHits := 5
    RunWindowTransition(state,false,true,good)
    GMTest_Assert(IniRead(CFG_FILE,"self_healing","state") = "retrying","window-handle incident takes priority over positive line")
    state.invalidHwndHits := 0, state.taskAbandonHits := 5
    RunWindowTransition(state,false,true,good)
    GMTest_Assert(IniRead(CFG_FILE,"self_healing","state") = "retrying","abandonment incident takes priority over positive line")
    state.taskAbandonHits := 1
    RunWindowTransition(state,false,true,good)
    GMTest_Assert(IniRead(CFG_FILE,"self_healing","state") = "recovered","real monitor transition forwards positive task progress")
    IniWrite("retrying",CFG_FILE,"self_healing","state")
    livePaused := true, steps := [], state.taskAbandonCompletionHeld := true
    RunWindowTransition(state,false,true,good)
    GMTest_Assert(IniRead(CFG_FILE,"self_healing","state") = "retrying","live PAUSE during parsing defeats stale loop snapshot")
    GMTest_Assert(steps.Length = 1 && InStr(steps[1].detail,"PAUSE"),"window-end publication rereads live PAUSE")
    GMTest_Assert(!RecordSelfHealingGameplayProgress(good),"recovery commit independently refuses current PAUSE")
    for hold in [true,false] {
        steps := []
        RunWarmupTransition(state,false,hold)
        GMTest_Assert(steps.Length = 0,"warmup cannot overwrite current PAUSE status")
    }
    livePaused := false, steps := []
    RunWarmupTransition(state,false,true)
    GMTest_Assert(steps.Length = 0,"warmup cannot overwrite an active abandonment hold")
    state.pendingReason := "reward pending", steps := []
    RunWarmupTransition(state,false,false)
    GMTest_Assert(steps.Length = 0,"warmup cannot overwrite a saved completion label")
    state.pendingReason := "", steps := []
    RunWarmupTransition(state,false,false)
    GMTest_Assert(steps.Length = 1,"normal warmup still publishes active monitoring")
    GMTest_Assert(reportCalls >= 4,"real step publications still report heartbeat")
}
RunWindowTransition(state,paused,warmupFinished,progressLine := "") {
    global REWARD_TASK_ABANDON_NEED_COUNT, REWARD_TASK_ABANDON_WINDOW_SEC
    global REWARD_INVALID_HWND_NEED_COUNT
    global SERVER_SCHEDULE_ENABLED, CURRENT_SERVER_TARGET, __REWARD_MONITOR_COMPLETION_PENDING
    global REMOTE_CONTROL_ACTIVE
    if !state.HasOwnProp("invalidHwndHits")
        state.invalidHwndHits := 0
    stateChanged := false
$transition
}
RunWarmupTransition(state,paused,holdCompletion) {
    global REMOTE_CONTROL_ACTIVE
    warmupFinishedLogged := false, warmupFinished := true
$warmup
}
ToIntRange(value,fallback,lower,upper) => Min(upper,Max(lower,Integer(value)))
RC_ToIntRange(args*) => ToIntRange(args*)
RC_IniReadSafe(args*) => IniReadSafe(args*)
RC_UnixMs() => 1790857200000
RC_IsPaused() => livePaused
WriteLog(args*) => 0
ShowTip(args*) => 0
RC_RecordRuntimeEvent(name,detail,level := "INFO") => steps.Push({name:name,detail:detail,level:level})
RC_ReportRuntimeState() {
    global reportCalls
    GMTest_Assert(!A_IsCritical,"remote heartbeat/live-preview I/O cannot run inside the status commit Critical section")
    reportCalls += 1
}
GetRewardMonitorCompletionReason(args*) => ""
UnmarkServerCompletedInCurrentCycle(args*) => false
$extracted
"@
    $testPath=Join-Path $context.RunRoot 'runtime-recovery-status.ahk'
    [IO.File]::WriteAllText($testPath,$harness,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $testPath $context 20
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'Recovery status preserves retry protection and reports real progress'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
