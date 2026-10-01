#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\RestartRecovery.ahk
GMTest_Run(TestRestartRecovery)
TestRestartRecovery() {
    ; The real orchestration policy, with process/clock/network at explicit boundaries.
    for scenario in ["success","transient","exhausted","paused","stopped","retry","stop-during-prepare","publish-failed","pause-during-prepare","stop-after-arm"] {
        f := {scenario:scenario, attempts:0, waits:0, reports:[], retry:0, now:0, cancelled:0}
        hooks := {Read:RecoveryInput.Bind(f),Prepare:RecoveryPrepare.Bind(f),
            Wait:RecoveryWait.Bind(f),Publish:RecoveryPublish.Bind(f),
            Commit:RecoveryCommit.Bind(f),Cancel:RecoveryCancel.Bind(f)}
        result := RestartRecovery_Run(hooks)
        switch scenario {
            case "success": GMTest_Assert(result = "armed" && f.attempts = 1,"exactly one successful handoff")
            case "transient": GMTest_Assert(result = "armed" && f.attempts = 2,"transient exit drains then arms once")
            case "exhausted": GMTest_Assert(result = "stopped" && f.attempts = 3 && f.waits >= 8,"three failures retain the owner alive until STOP")
            case "paused": GMTest_Assert(result = "armed" && f.attempts = 1 && f.waits >= 2,"PAUSE never starts cleanup or a worker")
            case "stopped": GMTest_Assert(result = "stopped" && f.attempts = 0,"STOP prevents any prepare")
            case "retry": GMTest_Assert(result = "armed" && f.attempts = 4,"new explicit RUN may retry held handoff without re-entering restart accounting")
            case "stop-during-prepare": GMTest_Assert(result = "stopped" && f.attempts = 1,"STOP during failed preparation never retries")
            case "publish-failed": GMTest_Assert(result = "armed" && f.attempts = 1,"status publication cannot invalidate or duplicate armed worker")
            case "pause-during-prepare": GMTest_Assert(result = "armed" && f.attempts = 2 && f.cancelled = 1,"PAUSE during arming cancels old worker before rearming after RUN")
            case "stop-after-arm": GMTest_Assert(result = "stopped" && f.attempts = 1 && f.cancelled = 1,"STOP after arming cancels without ever committing handoff")
        }
        GMTest_Assert(f.reports.Length > 0,"waiting/failure/success state is observable")
    }
}
RecoveryInput(f) {
    if f.scenario = "stopped" || (f.scenario = "exhausted" && f.waits >= 8)
        || ((f.scenario = "stop-during-prepare" || f.scenario = "stop-after-arm") && f.attempts > 0)
        return {state:"STOP",retry:f.retry}
    if f.scenario = "paused" && f.waits < 2
        return {state:"PAUSE",retry:f.retry}
    if f.scenario = "pause-during-prepare" && f.attempts > 0 && f.waits < 2
        return {state:"PAUSE",retry:f.retry}
    if f.scenario = "retry" && f.waits >= 8
        f.retry := 1
    return {state:"RUN",retry:f.retry}
}
RecoveryPrepare(f) {
    f.attempts += 1
    if f.scenario = "exhausted" || f.scenario = "stop-during-prepare"
        || (f.scenario = "transient" && f.attempts = 1)
        || (f.scenario = "retry" && f.attempts <= 3)
        throw Error("fixture retained wrapper or unconfirmed worker")
    return "armed"
}
RecoveryWait(f,ms) {
    f.waits += 1
    GMTest_Assert(f.waits < 20,"bounded test detects a stuck recovery policy")
}
RecoveryPublish(f,state,detail,attempts) {
    f.reports.Push(state)
    if f.scenario = "publish-failed"
        throw Error("fixture offline reporting")
}
RecoveryCommit(f) => RecoveryInput(f).state = "RUN"
RecoveryCancel(f) => f.cancelled += 1
