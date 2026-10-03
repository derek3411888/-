#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameMaintenance.ahk
GMTest_Run(TestDaySkip)
TestDaySkip() {
    ; 2026-09-30 00:00/04:00/11:00/24:00 Asia/Taipei, hand-derived UTC ms.
    midnight := 1790697600000, start := 1790712000000, open := 1790737200000
    input := GMTest_Input(midnight), state := GM_DefaultState()
    input.maintenancePolicy := "skip_update_day", input.runCycle := "", input.elapsedMs := 20000
    input.notice := 0
    input.install.identityVerified := true
    input.upcomingNotice := {eventId:"update-3.7",revision:"r1",startsAt:start,expectedOpenAt:open,
        gameVersion:"3.7",sourceUrl:"https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/1"}
    for now in [midnight, start, open, midnight + 86399999] {
        input.nowUtcMs := now
        d := GM_Evaluate(state,input)
        GMTest_Assert(d.phase = "SKIPPED_UPDATE_DAY" && d.effect.type = "none","whole Taiwan update date skips before and after opening")
    }
    input.skipEventId := "update-3.7", input.delayEventId := "update-3.7", input.delayUntilUtc := midnight+86400000
    GMTest_Assert(GM_Evaluate(state,input).phase = "SKIPPED_UPDATE_DAY","old skip/delay settings cannot bypass new whole-day policy")
    input.nowUtcMs := midnight-1
    GMTest_Assert(GM_Evaluate(state,input).phase = "NORMAL","previous Taiwan day remains normal")
    state := d.state, input.nowUtcMs := midnight+86400000, input.upcomingNotice := 0
    GMTest_Assert(GM_Evaluate(state,input).phase = "NORMAL","old persisted update event must not trap next day")
    input.nowUtcMs := open, input.noticeState := "unavailable"
    GMTest_Assert(GM_Evaluate(state,input).phase = "SKIPPED_UPDATE_DAY","known update day remains blocked during notice outage")
    input.desiredState := "STOP"
    GMTest_Assert(GM_Evaluate(state,input).phase = "STOPPED","STOP wins over skip")
    input.desiredState := "PAUSE"
    GMTest_Assert(GM_Evaluate(state,input).overlay = "PAUSE","PAUSE is not silently cleared")
    input.desiredState := "RUN", input.clockStable := false
    GMTest_Assert(GM_Evaluate(state,input).effect.type != "resume_flow","untrusted clock never launches")
    TestSkipNotification(d)
    TestReloadSkippedDay(d,open)
    input := GMTest_Input(midnight+86400000), input.maintenancePolicy := "skip_update_day"
    input.enabled := false, input.notice := 0, input.noticeState := "pending", input.install := {provider:"unknown"}
    GMTest_Assert(GM_Evaluate(GM_DefaultState(),input).phase = "CHECKING_INSTALL","disabled schedule still waits for installation identity before cleanup")
    input.elapsedMs := 60000
    GMTest_Assert(GM_Evaluate(GM_DefaultState(),input).phase = "NEEDS_ATTENTION","installation discovery has a bounded failure instead of guessing an entry")
}
TestReloadSkippedDay(d,nowMs) {
    dir := TestRuntime_NewCaseDir("skip-reload"), state := GM_CopyState(d.state), calls := []
    state.notificationKeys := ""
    GM_NotifyStage(state,dir "\state.ini",d,(stage,detail) => (calls.Push(stage),{ok:true}))
    c := GM_CreateController(dir "\state.ini",{newTask:true,maintenancePolicy:"skip_update_day",runCycle:"new-cycle",nowUtcMs:nowMs},{})
    input := GMTest_Input(nowMs), input.maintenancePolicy := "skip_update_day", input.notice := 0, input.noticeState := "unavailable"
    input.elapsedMs := 30000, input.runCycle := "new-cycle"
    result := GM_Evaluate(c.state,input)
    GMTest_Assert(result.phase = "SKIPPED_UPDATE_DAY","fresh external launch retains known update day during source outage")
    GM_NotifyStage(result.state,c.journalPath,result,(stage,detail) => (calls.Push(stage),{ok:true}))
    GMTest_Assert(calls.Length = 1,"fresh external launch does not duplicate today's skip email")
    later := nowMs+28*86400000
    next := GM_CreateController(dir "\state.ini",{newTask:true,maintenancePolicy:"skip_update_day",runCycle:"next-version",nowUtcMs:later},{})
    GMTest_Assert(next.state.eventId = "" && next.state.notificationKeys != "","next version must not pin a past event, but retains notification dedup history")
    input.nowUtcMs := later, input.runCycle := "next-version", input.noticeState := "valid"
    input.notice := {eventId:"update-next",startsAt:d.state.startsAt+28*86400000,expectedOpenAt:d.state.expectedOpenAt+28*86400000,revision:"next"}
    GMTest_Assert(GM_Evaluate(next.state,input).phase = "SKIPPED_UPDATE_DAY","next version update day is selected instead of old cached event")
}
TestSkipNotification(d) {
    dir := TestRuntime_NewCaseDir("day-skip-mail"), calls := [], state := d.state
    deliver := (stage,detail) => (calls.Push(stage), {ok:true})
    GM_NotifyStage(state,dir "\state.ini",d,deliver)
    GM_NotifyStage(state,dir "\state.ini",d,deliver)
    state.revision := "changed-announcement"
    GM_NotifyStage(state,dir "\state.ini",d,deliver)
    GMTest_Assert(calls.Length = 1 && calls[1] = "skipped_day","one skip mail per event/date across revised announcements")
    failed := GM_CopyState(d.state), failed.notificationKeys := ""
    result := GM_NotifyStage(failed,dir "\failed.ini",d,(*) => {ok:false})
    GMTest_Assert(!result.ok && failed.notificationKeys = "","failed delivery must not be recorded as notified")
    try GM_NotifyStage(failed,dir "\failed.ini",d,TestMailFailure)
    catch {
    }
    GMTest_Assert(failed.notificationKeys = "" && GM_LoadJournal(dir "\failed.ini").notificationKeys = "","throwing mail sender also restores durable notification state")
}
TestMailFailure(*) {
    throw Error("isolated mail failure")
}
