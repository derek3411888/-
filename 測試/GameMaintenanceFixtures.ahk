#Requires AutoHotkey v2.0+
#Warn All, StdOut
FileEncoding("UTF-8")
#Include TestRuntimePaths.ahk

GMTest_Assert(value, message) {
    if !value
        throw Error(message)
}
GMTest_State() {
    return {phase:"WAIT_OPEN", eventId:"fixture-global-1", revision:"r1",
        actionId:"", actionStage:"", f11InputAttempted:false,
        cancelled:false, runCycle:"fixture", targetServer:"Asia"}
}
GMTest_Input(nowMs := 9999) {
    return {nowUtcMs:nowMs, elapsedMs:0, clockStable:true, desiredState:"RUN",
        remoteGeneration:1, desktopAvailable:true, noticeState:"valid",
        notice:{eventId:"fixture-global-1", revision:"r1", startsAt:1000,
            expectedOpenAt:10000, freshForRelease:true},
        install:{provider:"steam", updateAdapterReady:true, fingerprint:"i1"},
        observation:{phase:"not_started", observedAt:nowMs}}
}
GMTest_Run(testFunction) {
    try {
        testFunction.Call()
        FileAppend("PASS: " A_ScriptName "`n", "*")
        ExitApp(0)
    } catch as err {
        FileAppend("FAIL: " err.Message " | " err.File ":" err.Line "`n", "**")
        ExitApp(1)
    }
}
