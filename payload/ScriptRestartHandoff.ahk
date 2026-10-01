#Requires AutoHotkey v2.0+

; The old payload owns shutdown. A separate, non-single-instance worker waits
; for its exact process handle before launching any successor (or updater).
global RestartHandoff_ActiveRequest := ""
global RestartHandoff_WorkerHandle := 0

RestartHandoff_Prepare(ahkPath, scriptPath, mode, root, launcherPath := "", parentWaitMs := 120000, ackWaitMs := 180000, recording := "") {
    global RestartHandoff_ActiveRequest, RestartHandoff_WorkerHandle
    if !RestartHandoff_ValidMode(mode)
        throw ValueError("Invalid restart mode")
    for path in [ahkPath, scriptPath, root, launcherPath] {
        if InStr(path, '"') || InStr(path, "`n") || InStr(path, "`r")
            throw ValueError("Invalid handoff path")
    }
    worker := A_LineFile
    SplitPath(worker, , &moduleDir)
    worker := moduleDir "\ScriptRestartWorker.ahk"
    if !FileExist(ahkPath) || !FileExist(scriptPath) || !FileExist(worker)
        throw Error("Restart runtime, payload or worker is missing")
    if (RestartHandoff_ActiveRequest != "")
        throw Error("A restart handoff is already pending")
    parentWaitMs := Min(600000, Max(100, Integer(parentWaitMs)))
    ackWaitMs := Min(600000, Max(100, Integer(ackWaitMs)))
    pid := DllCall("GetCurrentProcessId", "uint")
    nonce := pid "_" A_Now "_" A_TickCount "_" Random(100000, 999999)
    dir := RTrim(root, "\") "\" nonce
    DirCreate(dir)
    request := dir "\request.ini"
    fields := Map("root", root, "nonce", nonce, "parent_pid", pid,
        "parent_created", RestartHandoff_ProcessCreated(DllCall("GetCurrentProcess", "ptr")),
        "ahk", ahkPath, "script", scriptPath, "mode", mode, "launcher", launcherPath,
        "parent_wait_ms", parentWaitMs, "ack_wait_ms", ackWaitMs)
    if IsObject(recording) {
        fields["recording_pid"] := recording["pid"]
        fields["recording_created"] := recording["created"]
        fields["recording_image"] := recording["image"]
    }
    RestartHandoff_WriteIni(request, "request", fields)
    RestartHandoff_ActiveRequest := request
    try {
        ; Never hold payload as the helper's working directory: the updater
        ; needs to replace that directory after the parent exits.
        workerChild := RestartHandoff_DispatchWorker(ahkPath,
            '"' ahkPath '" /ErrorStdOut=UTF-8 "' worker '" "' request '"', dir)
        workerPid := workerChild.pid
        RestartHandoff_WorkerHandle := workerChild.handle
        deadline := A_TickCount + 5000
        loop {
            state := IniRead(dir "\result.ini", "result", "state", "")
            if (state = "armed")
                return {request: request, workerPid: workerPid}
            if (state = "failed" || state = "cancelled"
                || DllCall("WaitForSingleObject", "ptr", RestartHandoff_WorkerHandle, "uint", 0, "uint") != 258)
                throw Error("Restart worker could not arm: " IniRead(dir "\result.ini", "result", "detail", state))
            if (A_TickCount >= deadline)
                throw Error("Restart worker did not arm within 5 seconds")
            DllCall("Sleep", "uint", 25)
        }
    } catch as prepareError {
        RestartHandoff_Cancel("prepare failed")
        throw prepareError
    }
}

; CreateProcess binds ownership atomically. Run followed by OpenProcess(PID)
; can adopt an unrelated process if a short-lived helper exits and PID is reused.
RestartHandoff_DispatchWorker(ahkPath, command, workingDir) {
    startupInfo := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
    processInfo := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    commandBuffer := Buffer((StrLen(command) + 1) * 2, 0)
    StrPut(command, commandBuffer, "UTF-16")
    NumPut("UInt", startupInfo.Size, startupInfo)
    NumPut("UInt", 1, startupInfo, A_PtrSize = 8 ? 60 : 44) ; STARTF_USESHOWWINDOW
    NumPut("UShort", 0, startupInfo, A_PtrSize = 8 ? 64 : 48) ; SW_HIDE
    if !DllCall("CreateProcessW", "str", ahkPath, "ptr", commandBuffer,
        "ptr", 0, "ptr", 0, "int", false, "uint", 0, "ptr", 0, "str", workingDir,
        "ptr", startupInfo, "ptr", processInfo, "int")
        throw OSError(A_LastError, "CreateProcessW(restart worker)")
    workerChild := {handle:NumGet(processInfo, 0, "ptr"), pid:NumGet(processInfo, 2*A_PtrSize, "uint")}
    DllCall("CloseHandle", "ptr", NumGet(processInfo, A_PtrSize, "ptr"))
    return workerChild
}

RestartHandoff_ValidMode(mode) {
    return mode = "nextserver" || mode = "nextserver remote" || mode = "restart" || mode = "restart resume"
}

RestartHandoff_ProcessCreated(processHandle) {
    times := Buffer(32, 0)
    if !DllCall("GetProcessTimes", "ptr", processHandle, "ptr", times,
        "ptr", times.Ptr + 8, "ptr", times.Ptr + 16, "ptr", times.Ptr + 24)
        throw OSError(A_LastError, "GetProcessTimes")
    return NumGet(times, 0, "Int64")
}

RestartHandoff_WriteIni(path, section, fields) {
    text := "[" section "]`r`n"
    for key, value in fields
        text .= key "=" StrReplace(StrReplace(String(value), "`r", " "), "`n", " ") "`r`n"
    temp := path "." DllCall("GetCurrentProcessId", "uint") ".tmp"
    try {
        if FileExist(temp)
            FileDelete(temp)
        FileAppend(text, temp, "UTF-16")
        ; Readers (including PowerShell diagnostics) may briefly hold the old
        ; file without FILE_SHARE_DELETE. Retry replacement, never expose a
        ; truncated INI and never abandon an already-running handoff silently.
        Loop 50 {
            try {
                if !DllCall("MoveFileExW", "str", temp, "str", path, "uint", 0x9)
                    throw OSError(A_LastError, "Atomic handoff state replacement")
                break
            } catch as replaceError {
                if (A_Index = 50)
                    throw replaceError
                DllCall("Sleep", "uint", 20)
            }
        }
    } finally {
        if FileExist(temp)
            FileDelete(temp)
    }
}

RestartHandoff_Cancel(reason := "manual stop") {
    global RestartHandoff_ActiveRequest, RestartHandoff_WorkerHandle
    if (RestartHandoff_ActiveRequest = "")
        return true
    SplitPath(RestartHandoff_ActiveRequest, , &dir)
    try {
        RestartHandoff_WriteIni(dir "\cancel.ini", "cancel", Map("reason", reason))
        return true
    } catch {
        ; Cancellation must not depend solely on disk writes. This is the held
        ; handle to OUR helper, never a PID/name scan or the game's process.
        if !RestartHandoff_WorkerHandle
            return false
        if (DllCall("WaitForSingleObject", "ptr", RestartHandoff_WorkerHandle, "uint", 0, "uint") != 0) {
            if !DllCall("TerminateProcess", "ptr", RestartHandoff_WorkerHandle, "uint", 1)
                return false
            if (DllCall("WaitForSingleObject", "ptr", RestartHandoff_WorkerHandle, "uint", 5000, "uint") != 0)
                return false
        }
        try RestartHandoff_WriteIni(dir "\result.ini", "result", Map("state", "cancelled",
            "detail", reason "; cancellation file failed, exact worker stopped", "working_directory", dir))
        return true
    }
}

RestartHandoff_CanPreserveRecording() {
    global RestartHandoff_ActiveRequest, RestartHandoff_WorkerHandle
    if (RestartHandoff_ActiveRequest = "" || !RestartHandoff_WorkerHandle)
        return false
    SplitPath(RestartHandoff_ActiveRequest, , &dir)
    return IniRead(dir "\result.ini", "result", "state", "") = "armed"
        && DllCall("WaitForSingleObject", "ptr", RestartHandoff_WorkerHandle, "uint", 0, "uint") = 258
}

RestartHandoff_ResetCancelled() {
    global RestartHandoff_ActiveRequest, RestartHandoff_WorkerHandle
    if RestartHandoff_ActiveRequest = ""
        return true
    if !RestartHandoff_Cancel("retry failed preparation")
        return false
    ; A cancellation file alone is not proof the old worker is gone. Keep the
    ; exact process handle and request until its exit has actually been observed.
    if RestartHandoff_WorkerHandle {
        if DllCall("WaitForSingleObject", "ptr", RestartHandoff_WorkerHandle, "uint", 0, "uint") != 0
            return false
        DllCall("CloseHandle", "ptr", RestartHandoff_WorkerHandle)
    }
    RestartHandoff_WorkerHandle := 0
    RestartHandoff_ActiveRequest := ""
    return true
}

RestartHandoff_Acknowledge(recordingPid := 0) {
    request := EnvGet("WUTHERING_RESTART_REQUEST")
    ; Do not pass the handoff marker to gameplay helpers or future restarts.
    EnvSet("WUTHERING_RESTART_REQUEST", "")
    if (request = "" || !FileExist(request))
        return false
    SplitPath(request, , &dir)
    if (StrLower(IniRead(request, "request", "script", "")) != StrLower(A_ScriptFullPath))
        throw Error("Restart handoff target path mismatch")
    actualMode := ""
    for argument in A_Args
        actualMode .= (actualMode = "" ? "" : " ") argument
    if (actualMode != IniRead(request, "request", "mode", ""))
        throw Error("Restart handoff mode mismatch; refusing a fresh or different task")
    state := IniRead(dir "\result.ini", "result", "state", "")
    if (state != "launching" && state != "started") || FileExist(dir "\cancel.ini")
        return false
    nonce := IniRead(request, "request", "nonce", "")
    if !RegExMatch(nonce, "^\d+_\d{14}_\d+_\d{6}$")
        return false
    expectedRecorder := Integer(IniRead(request, "request", "recording_pid", "0"))
    if (expectedRecorder > 0 && ProcessExist(expectedRecorder) && recordingPid != expectedRecorder)
        throw Error("Restart recorder was not adopted; startup cannot be acknowledged")
    RestartHandoff_WriteIni(dir "\accepted.ini", "accepted", Map("nonce", nonce,
        "pid", DllCall("GetCurrentProcessId", "uint"), "script", A_ScriptFullPath, "at", A_Now,
        "mode", actualMode, "recording_pid", recordingPid))
    return true
}

RestartHandoff_RecorderIdentity(pid) {
    handle := DllCall("OpenProcess", "uint", 0x101000, "int", 0, "uint", pid, "ptr")
    if !handle
        throw OSError(A_LastError, "OpenProcess(recorder identity)")
    try {
        imageBuffer := Buffer(65536, 0)
        size := 32768
        if !DllCall("QueryFullProcessImageNameW", "ptr", handle, "uint", 0, "ptr", imageBuffer, "uint*", &size)
            throw OSError(A_LastError, "Recorder image identity")
        imagePath := StrGet(imageBuffer, size, "UTF-16")
        SplitPath(imagePath, &imageName)
        if (StrLower(imageName) != "ffmpeg.exe")
            throw Error("Handoff recording must be an owned FFmpeg process")
        return Map("pid", pid, "created", RestartHandoff_ProcessCreated(handle), "image", imagePath)
    } finally DllCall("CloseHandle", "ptr", handle)
}

RestartHandoff_FinalizeOrphan(request) {
    recorderPid := Integer(IniRead(request, "request", "recording_pid", "0"))
    if (recorderPid <= 0 || !ProcessExist(recorderPid))
        return "not_running"
    identity := RestartHandoff_RecorderIdentity(recorderPid)
    if (identity["created"] != Integer(IniRead(request, "request", "recording_created", "0"))
        || StrLower(identity["image"]) != StrLower(IniRead(request, "request", "recording_image", "")))
        return "identity_mismatch_not_touched"
    handle := DllCall("OpenProcess", "uint", 0x101001, "int", 0, "uint", recorderPid, "ptr")
    if !handle
        return "open_failed"
    try {
        ; Revalidate on the held handle; a PID recycled between the two opens
        ; must never receive input or termination.
        if (RestartHandoff_ProcessCreated(handle) != identity["created"])
            return "identity_changed_not_touched"
        attached := DllCall("AttachConsole", "uint", recorderPid)
        signaled := false
        if attached {
            DllCall("SetConsoleCtrlHandler", "ptr", 0, "int", true)
            signaled := DllCall("GenerateConsoleCtrlEvent", "uint", 0, "uint", 0)
            DllCall("Sleep", "uint", 120)
            DllCall("FreeConsole")
            DllCall("SetConsoleCtrlHandler", "ptr", 0, "int", false)
        }
        if (DllCall("WaitForSingleObject", "ptr", handle, "uint", 30000, "uint") = 0)
            return signaled ? "gracefully_stopped" : "already_stopped"
        ; Same 30-second graceful grace as the existing recording shutdown.
        ; Stop only the exact inherited recorder to prevent unbounded disk use;
        ; report forced termination honestly, never claim a finalized video.
        if DllCall("TerminateProcess", "ptr", handle, "uint", 1)
            return "forced_stop_file_may_be_incomplete"
        return "stop_failed"
    } finally DllCall("CloseHandle", "ptr", handle)
}
