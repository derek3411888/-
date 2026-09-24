#Requires AutoHotkey v2.0+
#SingleInstance Off
#Warn All, StdOut
#NoTrayIcon
#Include ScriptRestartHandoff.ahk

requestPath := A_Args.Length = 1 ? A_Args[1] : ""
if (requestPath = "" || !FileExist(requestPath))
    ExitApp 1
SplitPath(requestPath, , &requestDir)
workerMutex := 0
parentHandle := 0
workerOwnsRequest := false
recordingGuardReady := false
try {
    SetWorkingDir(requestDir)
    nonce := IniRead(requestPath, "request", "nonce")
    if !RegExMatch(nonce, "^\d+_\d{14}_\d+_\d{6}$")
        throw Error("Invalid handoff nonce")
    workerMutex := DllCall("CreateMutexW", "ptr", 0, "int", 0,
        "str", "Local\WutheringRestart_" nonce, "ptr")
    if !workerMutex
        throw OSError(A_LastError, "CreateMutexW")
    if (A_LastError = 183)
        ExitApp 0
    ; A duplicate worker started after completion must not launch again either.
    if FileExist(requestDir "\result.ini")
        ExitApp 0
    workerOwnsRequest := true
    mode := IniRead(requestPath, "request", "mode")
    if !RestartHandoff_ValidMode(mode)
        throw Error("Invalid restart mode")
    parentPid := Integer(IniRead(requestPath, "request", "parent_pid"))
    parentHandle := DllCall("OpenProcess", "uint", 0x101000, "int", 0, "uint", parentPid, "ptr")
    if !parentHandle
        throw OSError(A_LastError, "OpenProcess(parent)")
    if (RestartHandoff_ProcessCreated(parentHandle) != Integer(IniRead(requestPath, "request", "parent_created")))
        throw Error("Parent process identity changed")
    recordingGuardReady := true
    ahkPath := IniRead(requestPath, "request", "ahk")
    scriptPath := IniRead(requestPath, "request", "script")
    launcherPath := IniRead(requestPath, "request", "launcher", "")
    for path in [ahkPath, scriptPath, launcherPath] {
        if InStr(path, '"') || InStr(path, "`r") || InStr(path, "`n")
            throw Error("Invalid launch path")
    }
    if !FileExist(ahkPath) || !FileExist(scriptPath)
        throw Error("Restart runtime or payload is missing")
    parentWaitMs := Min(600000, Max(100, Integer(IniRead(requestPath, "request", "parent_wait_ms"))))
    ackWaitMs := Min(600000, Max(100, Integer(IniRead(requestPath, "request", "ack_wait_ms"))))
    RestartWorker_Result("armed", "Waiting for old payload to exit; no successor launched")
    deadline := A_TickCount + parentWaitMs
    loop {
        if RestartWorker_Cancelled()
            ExitApp 0
        waitResult := DllCall("WaitForSingleObject", "ptr", parentHandle, "uint", 50, "uint")
        if (waitResult = 0)
            break
        if (waitResult != 258)
            throw Error("Failed waiting for old process")
        if (A_TickCount >= deadline)
            throw Error("Old payload did not exit before timeout; successor NOT launched")
    }
    if RestartWorker_Cancelled()
        ExitApp 0
    RestartWorker_Result("launching", "Old payload exited; starting successor")
    EnvSet("WUTHERING_RESTART_REQUEST", requestPath)
    launchPid := 0
    if (launcherPath != "" && FileExist(launcherPath) && InStr(mode, "restart") = 1) {
        SplitPath(launcherPath, , &launcherDir)
        flag := mode = "restart resume" ? "--resume-current-task" : "--restart-current-task"
        ; Fall back only if launching failed. A missing ACK never launches a
        ; duplicate payload because the updater may still be applying files.
        try Run('"' launcherPath '" ' flag, launcherDir, , &launchPid)
    }
    if !launchPid {
        SplitPath(scriptPath, , &scriptDir)
        Run('"' ahkPath '" /ErrorStdOut=UTF-8 "' scriptPath '" ' mode, scriptDir, "Hide", &launchPid)
    }
    RestartWorker_Result("started", "Successor process started; awaiting payload acknowledgement", launchPid)
    deadline := A_TickCount + ackWaitMs
    loop {
        if RestartWorker_Cancelled()
            ExitApp 0
        if (IniRead(requestDir "\accepted.ini", "accepted", "nonce", "") = nonce) {
            acceptedPid := Integer(IniRead(requestDir "\accepted.ini", "accepted", "pid", "0"))
            if (acceptedPid <= 0 || acceptedPid = parentPid)
                throw Error("Invalid successor acknowledgement")
            if (IniRead(requestDir "\accepted.ini", "accepted", "mode", "") != mode)
                throw Error("Successor acknowledged a different restart mode")
            RestartWorker_Result("accepted", "New payload acknowledged startup; game readiness is verified separately", acceptedPid)
            ExitApp 0
        }
        if (A_TickCount >= deadline)
            throw Error("Successor startup was not acknowledged; no duplicate retry performed")
        DllCall("Sleep", "uint", 50)
    }
} catch as workerError {
    if workerOwnsRequest {
        recordingResult := "ownership_not_validated"
        if recordingGuardReady {
            try {
                if RestartWorker_AcceptedSuccessor()
                    recordingResult := "adopted_by_successor"
                else
                    ; A terminal handoff failure always finalizes its exact
                    ; inherited recorder, even if the old parent is still in
                    ; OnExit. This closes the armed-snapshot/deadline race and
                    ; also covers a parent that never completes shutdown.
                    recordingResult := RestartHandoff_FinalizeOrphan(requestPath)
            } catch as recordingError
                recordingResult := "cleanup_error: " recordingError.Message
        }
        try FileAppend(A_Now " " workerError.Message "`n", requestDir "\failure.log", "UTF-8")
        try RestartWorker_Result("failed", workerError.Message " | recording=" recordingResult)
    }
    ExitApp 1
} finally {
    if parentHandle
        DllCall("CloseHandle", "ptr", parentHandle)
    if workerMutex
        DllCall("CloseHandle", "ptr", workerMutex)
}

RestartWorker_AcceptedSuccessor() {
    global requestDir, requestPath, nonce, mode, parentPid
    acceptedPath := requestDir "\accepted.ini"
    if (IniRead(acceptedPath, "accepted", "nonce", "") != nonce
        || IniRead(acceptedPath, "accepted", "mode", "") != mode)
        return false
    successorPid := Integer(IniRead(acceptedPath, "accepted", "pid", "0"))
    if (successorPid <= 0 || successorPid = parentPid)
        return false
    expectedRecorder := Integer(IniRead(requestPath, "request", "recording_pid", "0"))
    return expectedRecorder = 0 || !ProcessExist(expectedRecorder)
        || Integer(IniRead(acceptedPath, "accepted", "recording_pid", "0")) = expectedRecorder
}

RestartWorker_Result(state, detail, successorPid := 0) {
    global requestDir
    RestartHandoff_WriteIni(requestDir "\result.ini", "result", Map("state", state,
        "detail", detail, "at", A_Now, "worker_pid", DllCall("GetCurrentProcessId", "uint"),
        "successor_pid", successorPid, "working_directory", A_WorkingDir))
}

RestartWorker_Cancelled() {
    global requestDir
    if !FileExist(requestDir "\cancel.ini")
        return false
    RestartWorker_Result("cancelled", IniRead(requestDir "\cancel.ini", "cancel", "reason", "stop"))
    return true
}
