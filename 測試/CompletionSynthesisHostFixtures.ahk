#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\RewardMonitorIncidentPolicy.ahk
global CFG_FILE := "", REWARD_MONITOR_STATE_SECTION := "reward_monitor_runtime"
global REMOTE_STOP_IN_PROGRESS := false, EXITING_FROM_TRAY := false, __RESTART_IN_PROGRESS := false
global REMOTE_CONTROL_ACTIVE := true, paused := false, __REWARD_MONITOR_COMPLETION_PENDING := true
global SERVER_SCHEDULE_ENABLED := true, CURRENT_SERVER_TARGET := "Asia", SERVER_COMPLETED_CYCLE_MAP := Map()
global __NEXTSERVER_RESTART := false, isRestart := false, isNextServerCycle := false
global activeKey := "20261023|Asia|fixture.log", outcomeValue := "success", during := ""
global journal := Map(), launches := 0, advances := 0, shutdowns := 0, fixtureSeq := 0
global failedWrite := "", droppedWrite := "", forbidPendingRewrite := false, crashAtShutdown := false
global REWARD_TASK_ABANDON_NEED_COUNT := 5, REWARD_TASK_ABANDON_WINDOW_SEC := 90
GMTest_Run(TestDurableFinish)
TestDurableFinish() {
    global CFG_FILE, journal, launches, advances, shutdowns, failedWrite, droppedWrite, during
    global paused, REMOTE_STOP_IN_PROGRESS, __RESTART_IN_PROGRESS, SERVER_COMPLETED_CYCLE_MAP
    global forbidPendingRewrite, crashAtShutdown, SERVER_SCHEDULE_ENABLED, isRestart, activeKey
    global __REWARD_MONITOR_COMPLETION_PENDING, outcomeValue
    state := Seed()
    failedWrite := "reward_monitor_runtime:pending_at"
    GMTest_Assert(RewardMonitorFinishWithSynthesis(state) = "failed" && launches = 0 && advances = 0,
        "pending write failure must prevent child input and schedule advance")
    state := Seed(), droppedWrite := "reward_monitor_runtime:pending_at"
    GMTest_Assert(RewardMonitorFinishWithSynthesis(state) = "failed" && launches = 0,
        "silent missing pending write must be caught by readback before synthesis")
    for control in ["PAUSE","STOP","RESTART"] {
        state := Seed(), during := control
        GMTest_Assert(RewardMonitorFinishWithSynthesis(state) != "completed" && launches = 1 && advances = 0,
            "control changed after synthesis leaves durable pending and no advance: " control)
        GMTest_Assert(IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_at","") = "2026-10-23 10:00:00",
            "original completion time survives control interruption")
    }
    state := Seed(), failedWrite := "server_completed:Asia"
    GMTest_Assert(RewardMonitorFinishWithSynthesis(state) = "failed" && !SERVER_COMPLETED_CYCLE_MAP.Has("Asia") && advances = 0,
        "failed server mark cannot appear completed in memory or advance")
    failedWrite := "", forbidPendingRewrite := true
    GMTest_Assert(RewardMonitorFinishWithSynthesis(state) = "completed" && launches = 1 && advances = 1,
        "cached synthesis replays mark commit without input or rewriting original pending")
    GMTest_Assert(IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"completion_recorded","") = "1"
        && IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_at","") = "2026-10-23 10:00:00"
        && __REWARD_MONITOR_COMPLETION_PENDING,"completed pending is retained through shutdown")
    forbidPendingRewrite := false
    GMTest_Assert(!ClearRewardMonitorRuntimeState(state.key)
        && IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_at","") = state.pendingAt,
        "generic incident cleanup cannot erase recorded plus exact successful synthesis")
    state.taskAbandonHits := 5
    GMTest_Assert(!HostHoldCompletion(state),"late task-abandon log cannot roll back recorded exact synthesis success")
    state.completionRecorded := false
    GMTest_Assert(HostHoldCompletion(state),"unrecorded pending retains original 90-second/burst protection")
    state := Seed(), droppedWrite := "server_completed:Asia"
    GMTest_Assert(RewardMonitorFinishWithSynthesis(state) = "failed" && !SERVER_COMPLETED_CYCLE_MAP.Has("Asia") && advances = 0,
        "mark readback mismatch cannot populate memory or advance")
    state := Seed()
    SaveRewardMonitorRuntimeState(state)
    failedWrite := "reward_monitor_runtime:completion_recorded"
    GMTest_Assert(RewardMonitorFinishWithSynthesis(state) = "failed" && advances = 0,
        "completion-record write failure cannot advance schedule")
    failedWrite := ""
    GMTest_Assert(RewardMonitorFinishWithSynthesis(state) = "completed" && launches = 1,
        "completion-record failure replays cached synthesis without a second child")
    state := Seed(), crashAtShutdown := true, caught := false
    try RewardMonitorFinishWithSynthesis(state)
    catch
        caught := true
    GMTest_Assert(caught && IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"completion_recorded","") = "1",
        "crash at shutdown preserves durable completed pending")
    crashAtShutdown := false, SERVER_COMPLETED_CYCLE_MAP := Map(), isRestart := true
    restored := LoadRewardMonitorRuntimeState("fixture.log",0)
    GMTest_Assert(restored.pendingAt = "2026-10-23 10:00:00" && restored.completionRecorded,
        "restart restores original pending time and completion record")
    forbidPendingRewrite := true
    GMTest_Assert(RewardMonitorFinishWithSynthesis(restored) = "completed" && launches = 1,
        "restart after child success only replays commit, never synthesis")
    forbidPendingRewrite := false
    GMTest_Assert(!ClearCompletedRewardPendingOnFreshStart(true,false)
        && !ClearCompletedRewardPendingOnFreshStart(false,true),"restart and nextserver never clear pending at startup")
    GMTest_Assert(ClearCompletedRewardPendingOnFreshStart(false,false)
        && IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_reason","bad") = "",
        "explicit fresh launch clears only recorded plus matching successful synthesis")
    state := Seed(), outcomeValue := "failed"
    SaveRewardMonitorRuntimeState(state)
    IniWrite("1",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"completion_recorded")
    journal[state.key "|" state.pendingAt] := "running"
    GMTest_Assert(!ClearCompletedRewardPendingOnFreshStart(false,false)
        && IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_at","") = state.pendingAt,
        "fresh launch cannot clear failed, unknown or running synthesis")
    activeKey := "20261024|Asia|new.log", isRestart := true
    restored := LoadRewardMonitorRuntimeState("new.log",0)
    GMTest_Assert(restored.key = state.key && restored.pendingAt = state.pendingAt,
        "cross-day restart retains pending identity instead of minting another synthesis key")
    state := Seed()
    SaveRewardMonitorRuntimeState(state)
    changed := state.Clone(), changed.pendingAt := "2026-10-23 11:00:00"
    GMTest_Assert(RewardMonitorFinishWithSynthesis(changed) = "failed" && launches = 0,
        "changed pending time cannot overwrite unfinished journal before input")
    state := Seed(), SERVER_SCHEDULE_ENABLED := false
    GMTest_Assert(RewardMonitorFinishWithSynthesis(state) = "completed"
        && IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"completion_recorded","") = "1",
        "single mode also retains durable completed pending")
    activeKey := "20261024|HMT|new.log", isRestart := false
    next := LoadRewardMonitorRuntimeState("new.log",0)
    GMTest_Assert(next.key = activeKey && next.pendingReason = "",
        "verified completed previous server/day permits a legitimate new monitor")
    GMTest_Assert(SaveRewardMonitorRuntimeState(next),"completed old cycle cannot permanently block a new cycle")
}
Seed() {
    global CFG_FILE, fixtureSeq, journal, launches, advances, shutdowns, failedWrite, droppedWrite
    global forbidPendingRewrite, crashAtShutdown, SERVER_COMPLETED_CYCLE_MAP, paused, during
    global REMOTE_STOP_IN_PROGRESS, __RESTART_IN_PROGRESS, SERVER_SCHEDULE_ENABLED, isRestart, isNextServerCycle
    global activeKey, __REWARD_MONITOR_COMPLETION_PENDING, outcomeValue
    fixtureSeq += 1, CFG_FILE := A_ScriptDir "\durable-" fixtureSeq ".ini"
    journal := Map(), launches := 0, advances := 0, shutdowns := 0, failedWrite := "", droppedWrite := ""
    forbidPendingRewrite := false, crashAtShutdown := false, SERVER_COMPLETED_CYCLE_MAP := Map()
    paused := false, during := "", REMOTE_STOP_IN_PROGRESS := false, __RESTART_IN_PROGRESS := false
    SERVER_SCHEDULE_ENABLED := true, isRestart := false, isNextServerCycle := false
    activeKey := "20261023|Asia|fixture.log", __REWARD_MONITOR_COMPLETION_PENDING := true, outcomeValue := "success"
    state := LoadRewardMonitorRuntimeState("fixture.log",0)
    state.pendingReason := "verified reward", state.pendingAt := "2026-10-23 10:00:00"
    return state
}
CS_CompleteReward(state) {
    global launches, journal, outcomeValue, during, paused, REMOTE_STOP_IN_PROGRESS, __RESTART_IN_PROGRESS
    key := state.key "|" state.pendingAt
    if !journal.Has(key) {
        launches += 1
        journal[key] := outcomeValue
    }
    if during = "PAUSE"
        paused := true
    if during = "STOP"
        REMOTE_STOP_IN_PROGRESS := true
    if during = "RESTART"
        __RESTART_IN_PROGRESS := true
    return journal[key]
}
CS_RewardSynthesisStatus(key,time) => journal.Has(key "|" time) ? journal[key "|" time] : "none"
CS_RewardAlreadySucceeded(key,time) => CS_RewardSynthesisStatus(key,time) = "success"
HostIniWrite(value,file,section,key) {
    global failedWrite, droppedWrite, forbidPendingRewrite
    if section ":" key = failedWrite
        throw Error("isolated persistence write failure")
    if section ":" key = droppedWrite
        return
    if forbidPendingRewrite && section = "reward_monitor_runtime" && (key = "state_key" || key = "pending_at" || key = "pending_reason")
        throw Error("original pending must never be rewritten after synthesis")
    IniWrite(value,file,section,key)
}
GetRewardMonitorStateKey(path) => activeKey
RC_IsPaused() => paused
WriteLog(args*) => 0
RenewLrmcRestartBudgetAfterCompletedCycle(args*) => true
ResetRestartTrackingAfterCompletedCycle() => 0
AdvanceServerScheduleForNextCycle() {
    global advances
    advances += 1
    return false
}
TryStopScreenRecording(args*) => 0
ShutdownGameLrmcOkww(args*) {
    global shutdowns, crashAtShutdown
    shutdowns += 1
    if crashAtShutdown
        throw Error("isolated crash before final process exit")
}
