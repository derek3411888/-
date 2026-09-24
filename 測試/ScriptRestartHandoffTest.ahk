#Requires AutoHotkey v2.0
#SingleInstance Off
#Warn All, StdOut
#Include *i ..\payload\ScriptRestartHandoff.ahk

try {
    if !IsSet(RestartHandoff_Prepare)
        throw Error("Missing safe restart handoff: the successor must wait for the old process to exit")
    root := A_Args[1]
    mode := A_Args.Length > 1 ? A_Args[2] : "nextserver"
    scenario := A_Args.Length > 2 ? A_Args[3] : "slow"
    fixture := A_ScriptDir "\fixtures\RestartHandoffFixture.ahk"
    launcher := A_Args.Length > 3 ? A_Args[4] : ""
    recording := ""
    if InStr(scenario, "recording") {
        Run('"' A_Args[5] '" "' root '\recorder-state.txt"', root, "Hide", &testRecorderPid)
        testRecorderHandle := DllCall("OpenProcess", "uint", 0x101000, "int", 0, "uint", testRecorderPid, "ptr")
        recording := Map("pid", testRecorderPid, "created", RestartHandoff_ProcessCreated(testRecorderHandle), "image", A_Args[5])
        DllCall("CloseHandle", "ptr", testRecorderHandle)
    }
    if (scenario = "invalid") {
        rejected := false
        try RestartHandoff_Prepare(A_AhkPath, fixture, "nextserver & invalid", root)
        catch
            rejected := true
        if !rejected
            throw Error("Invalid restart mode was accepted")
        FileAppend("PASS invalid mode rejected`n", "*")
        ExitApp 0
    }
    ; This test owns this parent process only. Five seconds models slow shutdown
    ; without opening games, touching recording, or changing Windows settings.
    OnExit(RestartTest_OnExit.Bind(scenario))
    waitMs := scenario = "boundary-recording" ? 1000 : (InStr(scenario, "timeout") = 1 ? 400 : 15000)
    IniWrite(scenario, root "\fixture.ini", "test", "scenario")
    result := RestartHandoff_Prepare(A_AhkPath, fixture, mode, root, launcher, waitMs,
        InStr(scenario, "noack") = 1 || scenario = "wrong-mode" ? 400 : 10000, recording)
    FileAppend(result.request, root "\request-path.txt", "UTF-8")
    if (scenario = "cancel")
        RestartHandoff_Cancel("test stop")
    if (scenario = "cancel-write-blocked") {
        SplitPath(result.request, , &requestDir)
        DirCreate(requestDir "\cancel.ini")
        RestartHandoff_Cancel("test cancellation write failure")
    }
    if (scenario = "duplicate")
        Run('"' A_AhkPath '" /ErrorStdOut=UTF-8 "' A_ScriptDir
            '\..\payload\ScriptRestartWorker.ahk" "' result.request '"', , "Hide")
    FileAppend("PASS handoff armed`n", "*")
    ExitApp 0
} catch as e {
    FileAppend("FAIL " e.Message "`n", "*")
    ExitApp 1
}

RestartTest_OnExit(testScenario, *) {
    global RestartHandoff_ActiveRequest
    if (testScenario = "boundary-recording") {
        if !RestartHandoff_CanPreserveRecording()
            throw Error("Boundary fixture must observe a healthy handoff before its delay")
        ; Parent has already decided to preserve, but exits after the worker
        ; deadline. No parent-side finalization: worker must close this race.
    }
    DllCall("Sleep", "uint", 5000)
    if (testScenario = "timeout-recording") {
        if RestartHandoff_CanPreserveRecording()
            return
        RestartHandoff_FinalizeOrphan(RestartHandoff_ActiveRequest)
    }
}
