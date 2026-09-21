#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameMaintenance.ahk
#Include ..\payload\GameMaintenancePolicy.ahk
GMTest_Run(TestMaintenancePersistence)
TestMaintenancePersistence() {
    root := TestRuntime_NewCaseDir("gm-journal"), path := root "\state.ini"
    state := GM_DefaultState(), state.phase := "WAIT_OPEN", state.eventId := "fixture-global-1", state.revision := "r1"
    state.expectedOpenAt := 10000, state.desiredState := "PAUSE", state.targetServer := "Asia"
    GM_SaveJournal(path,state)
    saved := GM_LoadJournal(path)
    GMTest_Assert(saved.desiredState = "PAUSE" && saved.targetServer = "Asia", "pause and target durable")
    GMTest_Assert(GM_HasActiveContinuation(saved,9999), "journal protects pause before fresh-run logic")
    GMTest_Assert(!GM_HasActiveContinuation(saved,172900001), "expired no-action event not permanent blocker")
    state.desiredState := "RUN", state.actionId := "update-fixture", state.actionStage := "intent"
    GM_SaveJournal(path,state)
    FileDelete(path), FileAppend("[state]`nschemaVersion=1`nphase=READY",path,"UTF-8")
    saved := GM_LoadJournal(path)
    GMTest_Assert(saved.desiredState = "PAUSE", "torn primary recovers valid previous journal")
    FileAppend("uncommitted",path ".abandoned.tmp","UTF-8")
    GMTest_Assert(GM_LoadJournal(path).phase = "WAIT_OPEN", "stray temp never treated as current")
    FileDelete(path ".bak")
    failed := false
    try GM_LoadJournal(path)
    catch
        failed := true
    GMTest_Assert(failed, "both invalid cannot guess completed")
    FileDelete(path)
    state := GMTest_State(), input := GMTest_Input(10000), decision := GM_Evaluate(state,input), calls := []
    result := GM_CommitEffect(state,decision,() => input,path,(effect) => calls.Push(effect.type),FailMaintenanceJournal)
    GMTest_Assert(!result.committed && result.errorCode = "JOURNAL_WRITE_FAILED" && calls.Length = 0, "disk failure cannot act")
    input.remoteGeneration := 2
    result := GM_CommitEffect(state,decision,() => input,path,(effect) => calls.Push(effect.type))
    GMTest_Assert(!result.committed && calls.Length = 0, "remote generation revalidated immediately before action")
    input := GMTest_Input(10000), input.notice.revision := "r2", input.notice.expectedOpenAt := 20000
    result := GM_CommitEffect(state,decision,() => input,path,(effect) => calls.Push(effect.type))
    GMTest_Assert(!result.committed && calls.Length = 0, "new extension invalidates stale decision")
    input := GMTest_Input(10000), decision := GM_Evaluate(state,input)
    result := GM_CommitEffect(state,decision,() => input,path,(effect) => VerifyIntentBeforeAction(path,effect,calls))
    GMTest_Assert(result.committed && calls.Length = 1, "successful commit applies once")
    recovered := GM_LoadJournal(path)
    GMTest_Assert(recovered.actionStage = "observed" && recovered.actionId != "", "effect attempt persisted")
    decision := GM_Evaluate(recovered,input)
    GMTest_Assert(decision.effect.type = "observe", "no duplicate update after observed result")
    input.desiredState := "STOP", decision := GM_Evaluate(recovered,input)
    result := GM_CommitEffect(recovered,decision,() => input,path,(effect) => calls.Push(effect.type))
    GMTest_Assert(result.committed && GM_LoadJournal(path).cancelled, "stop cancellation durable")
    GMTest_Assert(!GM_HasActiveContinuation(GM_LoadJournal(path),10000), "STOP not mistaken as active continuation")
    input.desiredState := "RUN"
    GMTest_Assert(GM_Evaluate(GM_LoadJournal(path),input).phase = "STOPPED", "ordinary restart cannot revive cancelled actions")
    state := GMTest_State(), input := GMTest_Input(10000), decision := GM_Evaluate(state,input), calls := []
    result := GM_CommitEffect(state,decision,() => input,path,(effect) => calls.Push(effect.type),
        (file,next) => SaveThenChangeMaintenanceIntent(file,next,input))
    GMTest_Assert(!result.committed && calls.Length = 0 && result.errorCode = "INTENT_CHANGED_AFTER_JOURNAL", "revalidate again after durable write")
    input := GMTest_Input(10000)
    GMTest_Assert(GM_Evaluate(GM_LoadJournal(path),input).effect.type = "observe", "interrupted intent reconciles before repeating action")
}
SaveThenChangeMaintenanceIntent(path,state,input) {
    GM_SaveJournal(path,state)
    input.desiredState := "STOP", input.remoteGeneration += 1
}
FailMaintenanceJournal(path,state) {
    throw Error("simulated disk failure")
}
VerifyIntentBeforeAction(path,effect,calls) {
    before := GM_LoadJournal(path)
    GMTest_Assert(before.actionStage = "intent" && before.actionId = effect.actionId, "intent exists before external effect")
    calls.Push(effect.type)
    return {ok:true}
}
