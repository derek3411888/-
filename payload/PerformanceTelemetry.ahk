#Requires AutoHotkey v2.0+

; Low-overhead performance collection runs in a separate, low-priority native
; worker.  The farming thread only reads one atomically replaced JSON file
; during the existing self-hosted heartbeat.
global PERF_TELEMETRY_PID := 0
global PERF_TELEMETRY_PROCESS_HANDLE := 0
global PERF_TELEMETRY_WORKER_CREATION_FILETIME := 0
global PERF_TELEMETRY_PARENT_PID := 0
global PERF_TELEMETRY_PARENT_CREATION_FILETIME := 0
global PERF_TELEMETRY_PARENT_EXE_PATH := ""
global PERF_TELEMETRY_ROOT := ""
global PERF_TELEMETRY_HEARTBEAT_PATH := ""
global PERF_TELEMETRY_FIRESTORE_PATH := ""
global PERF_TELEMETRY_WORKER_PATH := ""
global PERF_TELEMETRY_CONFIG_PATH := ""
global PERF_TELEMETRY_WANTED := false
global PERF_TELEMETRY_STOPPED := true
global PERF_TELEMETRY_STARTED_TICK := 0
global PERF_TELEMETRY_LAST_RESTART_TICK := 0
global PERF_TELEMETRY_WATCHDOG_ACTIVE := false
global PERF_TELEMETRY_RESTART_COOLDOWN_MS := 30000
global PERF_TELEMETRY_STALE_MS := 45000
global PERF_TELEMETRY_STARTUP_GRACE_MS := 90000

PerformanceTelemetry_Start(cfgPath := "") {
    global PERF_TELEMETRY_CONFIG_PATH, PERF_TELEMETRY_WANTED, PERF_TELEMETRY_STOPPED
    PERF_TELEMETRY_CONFIG_PATH := String(cfgPath)
    PERF_TELEMETRY_WANTED := true
    PERF_TELEMETRY_STOPPED := false
    return PerformanceTelemetry_LaunchWorker()
}

PerformanceTelemetry_MonotonicMs() {
    ; A_TickCount 在長時間開機環境可能 rollover；watchdog 與關閉
    ; deadline 使用 Windows 64-bit monotonic tick。
    return DllCall("Kernel32\GetTickCount64", "UInt64")
}

PerformanceTelemetry_CloseWorkerHandle() {
    global PERF_TELEMETRY_PROCESS_HANDLE
    handle := PERF_TELEMETRY_PROCESS_HANDLE
    PERF_TELEMETRY_PROCESS_HANDLE := 0
    if (handle)
        try DllCall("Kernel32\CloseHandle", "ptr", handle)
}

PerformanceTelemetry_WorkerHandleAlive() {
    global PERF_TELEMETRY_PROCESS_HANDLE
    handle := PERF_TELEMETRY_PROCESS_HANDLE
    if (!handle)
        return false
    ; WAIT_TIMEOUT (0x102) 表示這個精確 process object 仍在執行。
    return DllCall("Kernel32\WaitForSingleObject", "ptr", handle, "uint", 0, "uint") = 0x102
}

PerformanceTelemetry_CanonicalPath(path) {
    path := Trim(String(path), ' "`t`r`n')
    if (path = "")
        return ""
    fullPathBuffer := Buffer(32768 * 2, 0)
    length := DllCall("Kernel32\GetFullPathNameW", "str", path, "uint", 32768,
        "ptr", fullPathBuffer, "ptr", 0, "uint")
    if (length <= 0 || length >= 32768)
        return ""
    return StrLower(RTrim(StrGet(fullPathBuffer, length, "UTF-16"), "\"))
}

PerformanceTelemetry_ReadProcessIdentity(processHandle, pid) {
    safePid := 0
    try safePid := Integer(pid)
    if (!processHandle || safePid <= 0)
        return 0
    if (DllCall("Kernel32\WaitForSingleObject", "ptr", processHandle,
        "uint", 0, "uint") != 0x102)
        return 0
    times := Buffer(32, 0)
    if !DllCall("Kernel32\GetProcessTimes", "ptr", processHandle,
        "ptr", times, "ptr", times.Ptr + 8, "ptr", times.Ptr + 16,
        "ptr", times.Ptr + 24)
        return 0
    pathBuffer := Buffer(32768 * 2, 0)
    chars := 32768
    if !DllCall("Kernel32\QueryFullProcessImageNameW", "ptr", processHandle,
        "uint", 0, "ptr", pathBuffer, "uint*", &chars)
        return 0
    creationFileTime := NumGet(times, 0, "Int64")
    exePath := PerformanceTelemetry_CanonicalPath(
        StrGet(pathBuffer, chars, "UTF-16"))
    if (creationFileTime <= 0 || exePath = "")
        return 0
    return {pid: safePid, creationFileTime: creationFileTime, exePath: exePath}
}

PerformanceTelemetry_ProcessIdentityMatches(record, expectedPid,
    expectedCreationFileTime, expectedExePath) {
    safePid := 0
    safeCreation := 0
    try safePid := Integer(expectedPid)
    try safeCreation := Integer(expectedCreationFileTime)
    expectedExe := PerformanceTelemetry_CanonicalPath(expectedExePath)
    if (!IsObject(record) || safePid <= 0 || safeCreation <= 0 || expectedExe = "")
        return false
    if (!record.HasOwnProp("pid") || !record.HasOwnProp("creationFileTime")
        || !record.HasOwnProp("exePath"))
        return false
    actualPid := 0
    actualCreation := 0
    try actualPid := Integer(record.pid)
    try actualCreation := Integer(record.creationFileTime)
    return actualPid = safePid && actualCreation = safeCreation
        && PerformanceTelemetry_CanonicalPath(record.exePath) = expectedExe
}

PerformanceTelemetry_QuoteArgument(value) {
    value := String(value)
    if InStr(value, '"') || InStr(value, "`r") || InStr(value, "`n")
        throw ValueError("Telemetry argument contains a forbidden character")
    return '"' value '"'
}

PerformanceTelemetry_CreateWorker(workerPath, commandLine, workingDirectory) {
    startupInfo := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
    processInfo := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    commandBuffer := Buffer((StrLen(commandLine) + 1) * 2, 0)
    StrPut(commandLine, commandBuffer, "UTF-16")
    NumPut("UInt", startupInfo.Size, startupInfo)
    NumPut("UInt", 1, startupInfo, A_PtrSize = 8 ? 60 : 44)
    NumPut("UShort", 0, startupInfo, A_PtrSize = 8 ? 64 : 48)
    if !DllCall("Kernel32\CreateProcessW", "str", workerPath,
        "ptr", commandBuffer, "ptr", 0, "ptr", 0, "int", false,
        "uint", 0x08000000, "ptr", 0, "str", workingDirectory,
        "ptr", startupInfo, "ptr", processInfo, "int")
        throw OSError(A_LastError, "CreateProcessW(PerformanceTelemetryWorker)")
    return {handle: NumGet(processInfo, 0, "ptr"),
        thread: NumGet(processInfo, A_PtrSize, "ptr"),
        pid: NumGet(processInfo, 2 * A_PtrSize, "uint")}
}

PerformanceTelemetry_LaunchWorker() {
    global PERF_TELEMETRY_PID, PERF_TELEMETRY_PARENT_PID, PERF_TELEMETRY_PROCESS_HANDLE
    global PERF_TELEMETRY_WORKER_CREATION_FILETIME
    global PERF_TELEMETRY_PARENT_CREATION_FILETIME, PERF_TELEMETRY_PARENT_EXE_PATH
    global PERF_TELEMETRY_ROOT, PERF_TELEMETRY_HEARTBEAT_PATH, PERF_TELEMETRY_FIRESTORE_PATH
    global PERF_TELEMETRY_WORKER_PATH, PERF_TELEMETRY_CONFIG_PATH
    global PERF_TELEMETRY_WANTED, PERF_TELEMETRY_STOPPED
    global PERF_TELEMETRY_STARTED_TICK, PERF_TELEMETRY_LAST_RESTART_TICK

    if (PERF_TELEMETRY_STOPPED || !PERF_TELEMETRY_WANTED)
        return false

    if (PERF_TELEMETRY_PROCESS_HANDLE) {
        if PerformanceTelemetry_WorkerHandleAlive()
            return true
        PerformanceTelemetry_CloseWorkerHandle()
        PERF_TELEMETRY_PID := 0
        PERF_TELEMETRY_WORKER_CREATION_FILETIME := 0
    }
    if (PERF_TELEMETRY_PID > 0 && ProcessExist(PERF_TELEMETRY_PID)) {
        adoptedHandle := PerformanceTelemetry_OpenOwnedWorkerHandle(PERF_TELEMETRY_PID)
        if adoptedHandle {
            PERF_TELEMETRY_PROCESS_HANDLE := adoptedHandle
            return true
        }
        ; WMI 無法驗證，或 PID 已被 Windows 重用時安全失敗：
        ; 不關閉、不另開一個可能重複的 worker。
        return false
    }

    workerPath := A_ScriptDir "\PerformanceTelemetryWorker.exe"
    if !FileExist(workerPath)
        return false
    PERF_TELEMETRY_WORKER_PATH := workerPath

    PERF_TELEMETRY_ROOT := RuntimeFiles_ProgramRoot() "\效能分析"
    PERF_TELEMETRY_HEARTBEAT_PATH := PERF_TELEMETRY_ROOT "\heartbeat.json"
    PERF_TELEMETRY_FIRESTORE_PATH := PERF_TELEMETRY_ROOT "\firestore.json"
    try DirCreate(PERF_TELEMETRY_ROOT)
    catch
        return false

    PERF_TELEMETRY_PARENT_PID := DllCall("Kernel32\GetCurrentProcessId", "uint")
    parentHandle := DllCall("Kernel32\GetCurrentProcess", "ptr")
    parentIdentity := PerformanceTelemetry_ReadProcessIdentity(
        parentHandle, PERF_TELEMETRY_PARENT_PID)
    if !IsObject(parentIdentity)
        return false
    PERF_TELEMETRY_PARENT_CREATION_FILETIME := parentIdentity.creationFileTime
    PERF_TELEMETRY_PARENT_EXE_PATH := parentIdentity.exePath
    cmd := PerformanceTelemetry_QuoteArgument(workerPath)
        . ' -OutputRoot ' PerformanceTelemetry_QuoteArgument(PERF_TELEMETRY_ROOT)
        . ' -ParentPid ' PERF_TELEMETRY_PARENT_PID
        . ' -ParentCreationFileTime ' PERF_TELEMETRY_PARENT_CREATION_FILETIME
        . ' -ParentExe ' PerformanceTelemetry_QuoteArgument(PERF_TELEMETRY_PARENT_EXE_PATH)
        . ' -SampleIntervalSeconds 2'
    if (PERF_TELEMETRY_CONFIG_PATH != "")
        cmd .= ' -ConfigPath ' PerformanceTelemetry_QuoteArgument(PERF_TELEMETRY_CONFIG_PATH)

    workerPid := 0
    workerHandle := 0
    child := 0
    PERF_TELEMETRY_LAST_RESTART_TICK := PerformanceTelemetry_MonotonicMs()
    if (PERF_TELEMETRY_STOPPED || !PERF_TELEMETRY_WANTED)
        return false
    try {
        child := PerformanceTelemetry_CreateWorker(workerPath, cmd, A_ScriptDir)
        workerPid := child.pid
        workerHandle := child.handle
        DllCall("Kernel32\CloseHandle", "ptr", child.thread)
        child.thread := 0
        workerIdentity := PerformanceTelemetry_ReadProcessIdentity(workerHandle, workerPid)
        if !PerformanceTelemetry_ProcessIdentityMatches(workerIdentity,
            workerPid, workerIdentity.creationFileTime, workerPath)
            throw Error("Native telemetry worker image identity mismatch")
        PERF_TELEMETRY_PID := workerPid
        PERF_TELEMETRY_PROCESS_HANDLE := workerHandle
        PERF_TELEMETRY_WORKER_CREATION_FILETIME := workerIdentity.creationFileTime
        child.handle := 0
        PERF_TELEMETRY_STARTED_TICK := PerformanceTelemetry_MonotonicMs()
        ; CreateProcessW 期間 STOP 可能中斷這個 AHK thread。新 PID 取得後
        ; 再檢查一次，STOP 已發生時只關閉剛建立的精確 worker。
        if (PERF_TELEMETRY_STOPPED || !PERF_TELEMETRY_WANTED) {
            PerformanceTelemetry_StopOwnedWorker(2000)
            return false
        }
        try ProcessSetPriority("Low", workerPid)
        return true
    } catch {
        if IsObject(child) {
            if child.HasOwnProp("thread") && child.thread
                try DllCall("Kernel32\CloseHandle", "ptr", child.thread)
            if child.HasOwnProp("handle") && child.handle {
                try DllCall("Kernel32\TerminateProcess", "ptr", child.handle, "uint", 1)
                try DllCall("Kernel32\WaitForSingleObject", "ptr", child.handle, "uint", 1000)
                try DllCall("Kernel32\CloseHandle", "ptr", child.handle)
            }
        }
        PerformanceTelemetry_CloseWorkerHandle()
        PERF_TELEMETRY_PID := 0
        PERF_TELEMETRY_WORKER_CREATION_FILETIME := 0
        PERF_TELEMETRY_STARTED_TICK := 0
        return false
    }
}

PerformanceTelemetry_Stop(waitMs := 3500) {
    global PERF_TELEMETRY_PID, PERF_TELEMETRY_PARENT_PID, PERF_TELEMETRY_ROOT
    global PERF_TELEMETRY_WANTED, PERF_TELEMETRY_STOPPED
    global PERF_TELEMETRY_STARTED_TICK, PERF_TELEMETRY_WORKER_CREATION_FILETIME

    ; 先關閉 watchdog 意圖，再等 worker；即使 PID 早已消失，後續心跳
    ; 讀取也不能把 STOP 當成異常而重啟。
    PERF_TELEMETRY_WANTED := false
    PERF_TELEMETRY_STOPPED := true
    stopped := PerformanceTelemetry_StopOwnedWorker(waitMs)
    if stopped {
        PERF_TELEMETRY_PID := 0
        PERF_TELEMETRY_STARTED_TICK := 0
        PERF_TELEMETRY_WORKER_CREATION_FILETIME := 0
    }
}

PerformanceTelemetry_ReadHeartbeatJson() {
    global PERF_TELEMETRY_HEARTBEAT_PATH
    path := PERF_TELEMETRY_HEARTBEAT_PATH
    PerformanceTelemetry_Watchdog(path)
    if (path = "" || !FileExist(path))
        return ""
    try {
        if (FileGetSize(path) <= 2 || FileGetSize(path) > 262144)
            return ""
        json := Trim(FileRead(path, "UTF-8"), " `t`r`n")
        if (SubStr(json, 1, 1) != "{" || SubStr(json, -1) != "}")
            return ""
        return json
    } catch {
        return ""
    }
}

PerformanceTelemetry_ReadFirestoreJson() {
    global PERF_TELEMETRY_FIRESTORE_PATH
    path := PERF_TELEMETRY_FIRESTORE_PATH
    if (path = "")
        path := RuntimeFiles_ProgramRoot() "\效能分析\firestore.json"
    PerformanceTelemetry_Watchdog(path)
    if !FileExist(path)
        return ""
    try {
        ; Firestore client 文件上限為 1 MiB；這份檔案只保留最近 60 個
        ; 每分鐘彙整點，並在本機先設更嚴格的 32 KiB 上限，保護免費
        ; 額度的網路傳輸量。
        size := FileGetSize(path)
        if (size <= 2 || size > 32768)
            return ""
        json := Trim(FileRead(path, "UTF-8"), " `t`r`n")
        if (SubStr(json, 1, 1) != "{" || SubStr(json, -1) != "}")
            return ""
        return json
    } catch {
        return ""
    }
}

PerformanceTelemetry_UnixMs() {
    return DateDiff(A_NowUTC, "19700101000000", "Seconds") * 1000 + A_MSec
}

PerformanceTelemetry_InspectCollector(json) {
    result := {valid: false, state: "", updatedAt: 0, error: ""}
    collectorMatch := ""
    if (json = "" || !RegExMatch(json, 'i)"collector"\s*:\s*\{([^{}]*)\}', &collectorMatch))
        return result

    collectorText := String(collectorMatch[1])
    stateMatch := ""
    if RegExMatch(collectorText, 'i)"state"\s*:\s*"([^"]*)"', &stateMatch)
        result.state := StrLower(Trim(String(stateMatch[1]), " `t`r`n"))

    updatedMatch := ""
    updatedRaw := ""
    updatedAt := 0
    if RegExMatch(collectorText, 'i)"updatedAt"\s*:\s*(\d+)', &updatedMatch) {
        updatedRaw := String(updatedMatch[1])
        try updatedAt := Integer(updatedRaw)
    }
    result.updatedAt := Max(0, updatedAt)

    errorMatch := ""
    if RegExMatch(collectorText, 'i)"error"\s*:\s*"([^"]*)"', &errorMatch)
        result.error := String(errorMatch[1])
    result.valid := result.state != "" && result.updatedAt > 0
    return result
}

PerformanceTelemetry_EvaluateHealth(json, pidAlive, startAgeMs, nowMs := 0) {
    global PERF_TELEMETRY_STALE_MS, PERF_TELEMETRY_STARTUP_GRACE_MS
    result := {restart: false, reason: "", state: "", updatedAt: 0}
    safeStartAge := 0
    safeNowMs := 0
    try safeStartAge := Max(0, Integer(startAgeMs))
    try safeNowMs := nowMs > 0 ? Integer(nowMs) : PerformanceTelemetry_UnixMs()
    if (safeNowMs <= 0)
        safeNowMs := PerformanceTelemetry_UnixMs()

    if !pidAlive {
        result.restart := true
        result.reason := "worker-exited"
        return result
    }

    collector := PerformanceTelemetry_InspectCollector(json)
    result.state := collector.state
    result.updatedAt := collector.updatedAt
    if !collector.valid {
        if (safeStartAge >= PERF_TELEMETRY_STARTUP_GRACE_MS) {
            result.restart := true
            result.reason := "collector-missing"
        }
        return result
    }
    if (collector.state = "error") {
        result.restart := true
        result.reason := "collector-error"
        return result
    }
    if (collector.state = "starting" && safeStartAge < PERF_TELEMETRY_STARTUP_GRACE_MS)
        return result
    if (safeNowMs - collector.updatedAt > PERF_TELEMETRY_STALE_MS) {
        result.restart := true
        result.reason := "collector-stale"
    }
    return result
}

PerformanceTelemetry_WatchdogAllowed() {
    global PERF_TELEMETRY_WANTED, PERF_TELEMETRY_STOPPED
    return PERF_TELEMETRY_WANTED && !PERF_TELEMETRY_STOPPED
}

PerformanceTelemetry_ReadProbeJson(path) {
    text := ""
    if (path = "" || !FileExist(path))
        return ""
    try {
        size := FileGetSize(path)
        if (size <= 2 || size > 262144)
            return ""
        text := Trim(FileRead(path, "UTF-8"), " `t`r`n")
        if (SubStr(text, 1, 1) != "{" || SubStr(text, -1) != "}")
            return ""
        return text
    }
    return ""
}

PerformanceTelemetry_ParseCommandLine(commandLine) {
    args := []
    argc := 0
    argv := DllCall("Shell32\CommandLineToArgvW", "str", String(commandLine),
        "int*", &argc, "ptr")
    if (!argv || argc <= 0)
        return args
    try {
        Loop argc {
            argPtr := NumGet(argv, (A_Index - 1) * A_PtrSize, "ptr")
            args.Push(argPtr ? StrGet(argPtr, "UTF-16") : "")
        }
    } finally {
        DllCall("Kernel32\LocalFree", "ptr", argv, "ptr")
    }
    return args
}

PerformanceTelemetry_CommandLineMatchesWorker(commandLine, workerPath,
    outputRoot, parentPid, parentCreationFileTime, parentExePath,
    configPath := "") {
    expectedWorker := PerformanceTelemetry_CanonicalPath(workerPath)
    expectedRoot := PerformanceTelemetry_CanonicalPath(outputRoot)
    expectedParentExe := PerformanceTelemetry_CanonicalPath(parentExePath)
    expectedParent := 0
    expectedCreation := 0
    try expectedParent := Integer(parentPid)
    try expectedCreation := Integer(parentCreationFileTime)
    if (expectedWorker = "" || expectedRoot = "" || expectedParentExe = ""
        || expectedParent <= 0 || expectedCreation <= 0)
        return false

    args := PerformanceTelemetry_ParseCommandLine(commandLine)
    expectedCount := configPath = "" ? 11 : 13
    if (args.Length != expectedCount)
        return false
    if (PerformanceTelemetry_CanonicalPath(args[1]) != expectedWorker
        || StrLower(String(args[2])) != "-outputroot"
        || PerformanceTelemetry_CanonicalPath(args[3]) != expectedRoot
        || StrLower(String(args[4])) != "-parentpid"
        || !(Trim(String(args[5])) ~= "^\d+$")
        || Integer(Trim(String(args[5]))) != expectedParent
        || StrLower(String(args[6])) != "-parentcreationfiletime"
        || !(Trim(String(args[7])) ~= "^\d+$")
        || Integer(Trim(String(args[7]))) != expectedCreation
        || StrLower(String(args[8])) != "-parentexe"
        || PerformanceTelemetry_CanonicalPath(args[9]) != expectedParentExe
        || StrLower(String(args[10])) != "-sampleintervalseconds"
        || Trim(String(args[11])) != "2")
        return false
    if (configPath != "")
        return StrLower(String(args[12])) = "-configpath"
            && PerformanceTelemetry_CanonicalPath(args[13])
                = PerformanceTelemetry_CanonicalPath(configPath)
    return true
}

PerformanceTelemetry_OpenOwnedWorkerHandle(pid) {
    global PERF_TELEMETRY_WORKER_PATH, PERF_TELEMETRY_PARENT_PID, PERF_TELEMETRY_ROOT
    global PERF_TELEMETRY_WORKER_CREATION_FILETIME
    global PERF_TELEMETRY_PARENT_CREATION_FILETIME, PERF_TELEMETRY_PARENT_EXE_PATH
    global PERF_TELEMETRY_CONFIG_PATH
    safePid := 0
    try safePid := Integer(pid)
    if (safePid <= 0 || PERF_TELEMETRY_WORKER_CREATION_FILETIME <= 0
        || !ProcessExist(safePid))
        return 0

    handle := DllCall("Kernel32\OpenProcess", "uint", 0x00101001,
        "int", false, "uint", safePid, "ptr")
    if !handle
        return 0
    try {
        identity := PerformanceTelemetry_ReadProcessIdentity(handle, safePid)
        if !PerformanceTelemetry_ProcessIdentityMatches(identity, safePid,
            PERF_TELEMETRY_WORKER_CREATION_FILETIME, PERF_TELEMETRY_WORKER_PATH)
            return 0
        query := "Select CommandLine from Win32_Process where ProcessId=" safePid
        for proc in ComObjGet("winmgmts:").ExecQuery(query) {
            commandLine := ""
            try commandLine := String(proc.CommandLine)
            if !PerformanceTelemetry_CommandLineMatchesWorker(commandLine,
                    PERF_TELEMETRY_WORKER_PATH, PERF_TELEMETRY_ROOT,
                    PERF_TELEMETRY_PARENT_PID,
                    PERF_TELEMETRY_PARENT_CREATION_FILETIME,
                    PERF_TELEMETRY_PARENT_EXE_PATH,
                    PERF_TELEMETRY_CONFIG_PATH)
                return 0
            if (DllCall("Kernel32\WaitForSingleObject", "ptr", handle,
                "uint", 0, "uint") != 0x102)
                return 0
            ownedHandle := handle
            handle := 0
            return ownedHandle
        }
    } catch {
        return 0
    } finally {
        if handle
            DllCall("Kernel32\CloseHandle", "ptr", handle)
    }
    return 0
}

PerformanceTelemetry_IsOwnedWorker(pid) {
    handle := PerformanceTelemetry_OpenOwnedWorkerHandle(pid)
    if !handle
        return false
    DllCall("Kernel32\CloseHandle", "ptr", handle)
    return true
}

PerformanceTelemetry_StopOwnedWorker(waitMs := 2000) {
    global PERF_TELEMETRY_PID, PERF_TELEMETRY_PARENT_PID, PERF_TELEMETRY_ROOT
    global PERF_TELEMETRY_PROCESS_HANDLE, PERF_TELEMETRY_WORKER_CREATION_FILETIME
    pid := PERF_TELEMETRY_PID
    stopPath := PERF_TELEMETRY_ROOT "\stop_" PERF_TELEMETRY_PARENT_PID ".flag"
    try FileAppend("stop", stopPath, "UTF-8")

    handle := PERF_TELEMETRY_PROCESS_HANDLE
    if (!handle && pid > 0 && ProcessExist(pid)) {
        handle := PerformanceTelemetry_OpenOwnedWorkerHandle(pid)
        if !handle
            return false
        PERF_TELEMETRY_PROCESS_HANDLE := handle
    }
    if (handle) {
        safeWait := 0
        try safeWait := Max(0, Integer(waitMs))
        waitResult := DllCall("Kernel32\WaitForSingleObject", "ptr", handle,
            "uint", safeWait, "uint")
        if (waitResult = 0x102) {
            try DllCall("Kernel32\TerminateProcess", "ptr", handle, "uint", 1)
            waitResult := DllCall("Kernel32\WaitForSingleObject", "ptr", handle,
                "uint", 1000, "uint")
        }
        if (waitResult = 0) {
            PerformanceTelemetry_CloseWorkerHandle()
            PERF_TELEMETRY_PID := 0
            PERF_TELEMETRY_WORKER_CREATION_FILETIME := 0
            return true
        }
        return false
    }

    if (pid <= 0 || !ProcessExist(pid)) {
        PERF_TELEMETRY_PID := 0
        PERF_TELEMETRY_WORKER_CREATION_FILETIME := 0
        return true
    }
    return false
}

PerformanceTelemetry_Watchdog(probePath := "") {
    global PERF_TELEMETRY_PID, PERF_TELEMETRY_HEARTBEAT_PATH
    global PERF_TELEMETRY_PROCESS_HANDLE, PERF_TELEMETRY_WORKER_CREATION_FILETIME
    global PERF_TELEMETRY_STARTED_TICK, PERF_TELEMETRY_LAST_RESTART_TICK
    global PERF_TELEMETRY_WATCHDOG_ACTIVE, PERF_TELEMETRY_RESTART_COOLDOWN_MS
    global PERF_TELEMETRY_STARTUP_GRACE_MS

    if !PerformanceTelemetry_WatchdogAllowed() || PERF_TELEMETRY_WATCHDOG_ACTIVE
        return false
    nowTick := PerformanceTelemetry_MonotonicMs()
    if (PERF_TELEMETRY_LAST_RESTART_TICK > 0
        && nowTick - PERF_TELEMETRY_LAST_RESTART_TICK < PERF_TELEMETRY_RESTART_COOLDOWN_MS)
        return false

    PERF_TELEMETRY_WATCHDOG_ACTIVE := true
    try {
        pid := PERF_TELEMETRY_PID
        ; PID 存在不代表仍是本主程式建立的 worker；無 retained handle
        ; 時同時驗證 creation time、image、命令列與 parent identity。
        ; 查詢無法完成時安全失敗，不誤關或製造重複 worker。
        if (PERF_TELEMETRY_PROCESS_HANDLE) {
            pidAlive := PerformanceTelemetry_WorkerHandleAlive()
            if !pidAlive {
                PerformanceTelemetry_CloseWorkerHandle()
                PERF_TELEMETRY_PID := 0
                PERF_TELEMETRY_WORKER_CREATION_FILETIME := 0
            }
        } else {
            pidExists := pid > 0 && ProcessExist(pid)
            if pidExists {
                adoptedHandle := PerformanceTelemetry_OpenOwnedWorkerHandle(pid)
                if !adoptedHandle
                    return false
                PERF_TELEMETRY_PROCESS_HANDLE := adoptedHandle
            }
            pidAlive := pidExists
        }
        healthPath := probePath
        if (healthPath = "")
            healthPath := PERF_TELEMETRY_HEARTBEAT_PATH
        json := PerformanceTelemetry_ReadProbeJson(healthPath)
        startAge := PERF_TELEMETRY_STARTED_TICK > 0
            ? Max(0, nowTick - PERF_TELEMETRY_STARTED_TICK)
            : PERF_TELEMETRY_STARTUP_GRACE_MS + 1
        health := PerformanceTelemetry_EvaluateHealth(
            json, pidAlive, startAge, PerformanceTelemetry_UnixMs())
        if !health.restart
            return false

        ; 先登記本次嘗試，不論重啟成功與否都至少退避 30 秒。
        PERF_TELEMETRY_LAST_RESTART_TICK := nowTick
        if (pidAlive && !PerformanceTelemetry_StopOwnedWorker(2000))
            return false
        PERF_TELEMETRY_PID := 0
        return PerformanceTelemetry_LaunchWorker()
    } finally {
        PERF_TELEMETRY_WATCHDOG_ACTIVE := false
    }
}

PerformanceTelemetry_FfmpegProgressArgs(kind := "recording") {
    global PERF_TELEMETRY_ROOT
    root := PERF_TELEMETRY_ROOT
    if (root = "")
        root := RuntimeFiles_ProgramRoot() "\效能分析"
    try DirCreate(root)
    safeKind := RegExReplace(StrLower(Trim(kind)), "[^a-z0-9_-]", "_")
    if (safeKind = "")
        safeKind := "ffmpeg"
    progressPath := root "\" safeKind "_progress.txt"
    try FileDelete(progressPath)
    return ' -stats_period 2 -progress "' progressPath '"'
}

PerformanceTelemetry_JsonScalar(json, key, preferLast := false) {
    safeKey := RegExReplace(String(key), "[^A-Za-z0-9_-]", "")
    if (safeKey = "")
        return ""
    pattern := 'i)"' safeKey '"\s*:\s*(null|true|false|-?\d+(?:\.\d+)?|"(?:\\.|[^"\\])*")'
    result := ""
    startAt := 1
    while (startAt <= StrLen(json) && RegExMatch(json, pattern, &match, startAt)) {
        result := String(match[1])
        if !preferLast
            break
        nextAt := match.Pos(0) + Max(1, match.Len(0))
        if (nextAt <= startAt)
            break
        startAt := nextAt
    }
    if (result = "null")
        return "-"
    if (SubStr(result, 1, 1) = '"' && SubStr(result, -1) = '"')
        result := SubStr(result, 2, -1)
    return result
}

PerformanceTelemetry_CurrentIncidentSummary() {
    json := PerformanceTelemetry_ReadHeartbeatJson()
    if (json = "")
        return "telemetry=unavailable"

    currentText := ""
    if RegExMatch(json, 'i)"current"\s*:\s*\{([^{}]*)\}', &currentMatch)
        currentText := String(currentMatch[1])
    if (currentText = "")
        return "telemetry=current-missing"

    parts := []
    for field in [
        ["fps", "fps"], ["cpu", "cpuTotalPct"], ["gpu", "gpuPct"],
        ["tempC", "gpuTempC"], ["ramGb", "ramUsedGb"],
        ["gameRamMb", "gameRamMb"], ["lrmcRamMb", "lrmcRamMb"],
        ["diskRead", "diskReadMbps"], ["recording", "recordingActive"],
        ["recordingFps", "recordingFps"], ["gameRunning", "gameRunning"],
        ["lrmcRunning", "lrmcRunning"]
    ] {
        value := PerformanceTelemetry_JsonScalar(currentText, field[2])
        if (value = "")
            value := "-"
        parts.Push(field[1] "=" value)
    }

    summary := "current{"
    for index, item in parts
        summary .= (index > 1 ? "," : "") item
    summary .= "}"

    previousParts := []
    for field in [
        ["cpuMax", "cpuTotalPctMax"], ["gpuMax", "gpuPctMax"],
        ["tempMaxC", "gpuTempCMax"], ["ramMaxGb", "ramUsedGbMax"],
        ["diskReadMax", "diskReadMbpsMax"]
    ] {
        value := PerformanceTelemetry_JsonScalar(json, field[2], true)
        if (value != "" && value != "-")
            previousParts.Push(field[1] "=" value)
    }
    if (previousParts.Length > 0) {
        summary .= " previousMinute{"
        for index, item in previousParts
            summary .= (index > 1 ? "," : "") item
        summary .= "}"
    }
    return SubStr(summary, 1, 900)
}

PerformanceTelemetry_MarkIncident(code, stage := "", detail := "") {
    global PERF_TELEMETRY_ROOT, CURRENT_STEP_NAME, CURRENT_STEP_DETAIL, CURRENT_SERVER_TARGET
    root := PERF_TELEMETRY_ROOT
    if (root = "")
        root := RuntimeFiles_ProgramRoot() "\效能分析"
    try DirCreate(root)
    nowMs := DateDiff(A_NowUTC, "19700101000000", "Seconds") * 1000
    json := "{"
    json .= '"at":' nowMs ","
    json .= '"code":"' RC_JsonEsc(SubStr(code, 1, 160)) '",'
    json .= '"stage":"' RC_JsonEsc(SubStr(stage, 1, 240)) '",'
    json .= '"detail":"' RC_JsonEsc(SubStr(detail, 1, 1200)) '",'
    json .= '"step":"' RC_JsonEsc(SubStr(CURRENT_STEP_NAME, 1, 200)) '",'
    json .= '"stepDetail":"' RC_JsonEsc(SubStr(CURRENT_STEP_DETAIL, 1, 600)) '",'
    json .= '"server":"' RC_JsonEsc(SubStr(CURRENT_SERVER_TARGET, 1, 160)) '"}'
    try FileAppend(json "`n", root "\incidents.ndjson", "UTF-8")
}
