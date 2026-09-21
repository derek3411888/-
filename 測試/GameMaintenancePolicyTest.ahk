#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameMaintenance.ahk
#Include ..\payload\GameMaintenancePolicy.ahk
GMTest_Run(TestMaintenancePolicy)
TestMaintenancePolicy() {
    state := GMTest_State(), input := GMTest_Input()
    decision := GM_Evaluate(state, input)
    GMTest_Assert(decision.phase = "WAIT_OPEN" && decision.effect.type = "none", "not one millisecond early")
    input.nowUtcMs := 10000, input.desiredState := "PAUSE"
    GMTest_Assert(GM_Evaluate(state,input).overlay = "PAUSE", "pause at deadline")
    input.desiredState := "STOP"
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "stop", "stop preempts waiting")
    input.desiredState := "RUN", input.desktopAvailable := false
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "none", "lock forbids update")
    input.desktopAvailable := true, input.clockStable := false
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "check_notice", "clock jump rechecks source")
    input.clockStable := true, input.notice.freshForRelease := false
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "check_notice", "deadline recheck required")
    input.notice.freshForRelease := true
    decision := GM_Evaluate(state,input)
    GMTest_Assert(decision.effect.type = "start_update", "verified deadline releases update")
    input.notice.expectedOpenAt := 20000, input.notice.revision := "r2"
    GMTest_Assert(GM_Evaluate(state,input).phase = "WAIT_OPEN", "extension holds gate")
    state.expectedOpenAt := 20000, state.revision := "r2"
    input.notice.expectedOpenAt := 10000, input.notice.revision := "old"
    GMTest_Assert(GM_Evaluate(state,input).phase = "WAIT_OPEN", "stale deadline cannot shorten persisted wait")
    input := GMTest_Input(20000), state := GMTest_State()
    input.noticeState := "unavailable", input.notice := 0
    state.expectedOpenAt := 30000
    GMTest_Assert(GM_Evaluate(state,input).phase = "WAIT_OPEN", "known event survives outage")
    input.nowUtcMs := 30000
    GMTest_Assert(GM_Evaluate(state,input).phase = "WAIT_NOTICE", "known event not released on source failure")
    state.eventId := "", state.expectedOpenAt := 0, input.elapsedMs := 20000
    GMTest_Assert(GM_Evaluate(state,input).phase = "NORMAL", "unknown-source degraded normal after budget")
    input.noticeErrorCode := "NOTICE_CONFLICT"
    GMTest_Assert(GM_Evaluate(state,input).phase = "WAIT_NOTICE", "conflict is not no-maintenance")
    input := GMTest_Input(10000), state := GMTest_State()
    input.install.provider := "unknown"
    GMTest_Assert(GM_Evaluate(state,input).errorCode = "INSTALL_SOURCE_UNKNOWN", "unknown install never guessed")
    input.install.provider := "steam", input.install.updateAdapterReady := false
    GMTest_Assert(GM_Evaluate(state,input).errorCode = "UPDATE_ADAPTER_UNVERIFIED", "unverified updater cannot run")
    input := GMTest_Input(10000), state.actionId := "persisted-intent", state.actionStage := "intent"
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "observe", "restart reconciles intent rather than resends")
    input.actionElapsedMs := 180000
    GMTest_Assert(GM_Evaluate(state,input).errorCode = "UPDATE_ACTIVITY_UNCONFIRMED", "180 seconds without target activity")
    input.actionElapsedMs := 0, input.observation.phase := "paused_download"
    GMTest_Assert(GM_Evaluate(state,input).phase = "NEEDS_ATTENTION", "explicit Steam download pause needs attention")
    input.observation.phase := "downloading", input.noProgressMs := 1799999
    GMTest_Assert(GM_Evaluate(state,input).phase = "UPDATING", "active download allowed")
    input.noProgressMs := 1800000
    GMTest_Assert(GM_Evaluate(state,input).errorCode = "UPDATE_STALLED", "30 minute real inactivity threshold")
    input.desiredState := "PAUSE"
    GMTest_Assert(GM_Evaluate(state,input).overlay = "PAUSE" && GM_Evaluate(state,input).effect.type = "none", "pause does not spend action timeout")
    input := GMTest_Input(10000), state := GMTest_State()
    input.observation := {phase:"game_running", observedAt:10000}
    GMTest_Assert(GM_Evaluate(state,input).phase != "READY", "process running not game ready")
    input.observation := {phase:"game_ready", observedAt:10000, identityVerified:true, stable:true}
    GMTest_Assert(GM_Evaluate(state,input).phase = "READY", "stable verified main screen is ready")
    input.observation.identityVerified := false
    GMTest_Assert(GM_Evaluate(state,input).phase != "READY", "forged ready rejected")
    input := GMTest_Input(10000), state := GMTest_State(), state.f11InputAttempted := true
    input.observation := {phase:"maintenance", confirmed:true, identityVerified:true, observedAt:10000}
    decision := GM_Evaluate(state,input)
    GMTest_Assert(decision.phase = "WAIT_SERVER" && decision.effect.type = "none", "maintenance after F11 waits")
    state := decision.state, input.observation := {phase:"unknown", observedAt:10000}, input.elapsedMs := 299999
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "none", "no repeated F11 or rapid poll")
    input.elapsedMs := 300000
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "observe", "five-minute server observation")
    input.observation.phase := "login_ready"
    GMTest_Assert(GM_Evaluate(state,input).errorCode = "LOGIN_RESUME_UNCONFIRMED", "do not toggle F11 twice")
    input.observation := {phase:"game_ready", observedAt:10000, identityVerified:true, stable:true}
    GMTest_Assert(GM_Evaluate(state,input).phase = "READY", "post-maintenance main screen needs no F11")
    input.nowUtcMs := 9999
    GMTest_Assert(GM_Evaluate(state,input).phase != "READY", "maintenance recovery cannot skip official deadline")
    state := GMTest_State(), input := GMTest_Input(10000), input.runCycle := "next-day"
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "reconcile_schedule", "04:00 day changes recheck schedule before launch")
    state.cancelled := true, input := GMTest_Input(10000)
    GMTest_Assert(GM_Evaluate(state,input).phase = "STOPPED", "cancel survives ordinary restart")
    input.newTask := true
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "start_update", "explicit new task may restart")
    state := GMTest_State(), input := GMTest_Input(9999), input.skipEventId := state.eventId
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "start_update", "event-scoped manual skip only time gate")
    input.desktopAvailable := false
    GMTest_Assert(GM_Evaluate(state,input).effect.type = "none", "skip cannot bypass desktop guard")
    input := GMTest_Input(10000), state := GMTest_State(), input.delayEventId := state.eventId, input.delayUntilUtc := 20000
    GMTest_Assert(GM_Evaluate(state,input).phase = "WAIT_OPEN", "event-scoped manual delay")
    ; Real effect dispatcher must be silent for all wait overlays, not only policy text.
    journal := TestRuntime_NewCaseDir("gm-policy-spy") "\state.ini"
    calls := []
    for condition in ["before", "pause", "lock", "extension"] {
        state := GMTest_State(), input := GMTest_Input(condition = "before" ? 9999 : 10000)
        if condition = "pause"
            input.desiredState := "PAUSE"
        if condition = "lock"
            input.desktopAvailable := false
        if condition = "extension"
            input.notice.expectedOpenAt := 20000
        decision := GM_Evaluate(state,input)
        result := GM_CommitEffect(state,decision,() => input,journal,(effect) => calls.Push(effect.type))
        GMTest_Assert(!result.committed && calls.Length = 0, "no physical effects while " condition)
    }
}
