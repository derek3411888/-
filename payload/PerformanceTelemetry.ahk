#Requires AutoHotkey v2.0+

; Low-overhead performance collection runs in a separate, low-priority
; PowerShell process.  The farming thread only reads one atomically replaced
; JSON file during the existing self-hosted heartbeat.
global PERF_TELEMETRY_PID := 0
global PERF_TELEMETRY_PROCESS_HANDLE := 0
global PERF_TELEMETRY_PARENT_PID := 0
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

PerformanceTelemetry_LaunchWorker() {
    global PERF_TELEMETRY_PID, PERF_TELEMETRY_PARENT_PID, PERF_TELEMETRY_PROCESS_HANDLE
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
    }
    if (PERF_TELEMETRY_PID > 0 && ProcessExist(PERF_TELEMETRY_PID)) {
        if PerformanceTelemetry_IsOwnedWorker(PERF_TELEMETRY_PID)
            return true
        ; WMI 無法驗證，或 PID 已被 Windows 重用時安全失敗：
        ; 不關閉、不另開一個可能重複的 worker。
        return false
    }

    workerPath := A_ScriptDir "\PerformanceTelemetryWorker.ps1"
    if !FileExist(workerPath)
        return false
    PERF_TELEMETRY_WORKER_PATH := workerPath

    PERF_TELEMETRY_ROOT := RuntimeFiles_ProgramRoot() "\效能分析"
    PERF_TELEMETRY_HEARTBEAT_PATH := PERF_TELEMETRY_ROOT "\heartbeat.json"
    PERF_TELEMETRY_FIRESTORE_PATH := PERF_TELEMETRY_ROOT "\firestore.json"
    try DirCreate(PERF_TELEMETRY_ROOT)
    catch
        return false

    psExe := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
    if !FileExist(psExe)
        psExe := "powershell.exe"

    PERF_TELEMETRY_PARENT_PID := DllCall("GetCurrentProcessId")
    cmd := '"' psExe '" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass'
        . ' -File "' workerPath '"'
        . ' -OutputRoot "' PERF_TELEMETRY_ROOT '"'
        . ' -ParentPid ' PERF_TELEMETRY_PARENT_PID
        . ' -SampleIntervalSeconds 2'
    if (PERF_TELEMETRY_CONFIG_PATH != "")
        cmd .= ' -ConfigPath "' PERF_TELEMETRY_CONFIG_PATH '"'

    workerPid := 0
    workerHandle := 0
    PERF_TELEMETRY_LAST_RESTART_TICK := PerformanceTelemetry_MonotonicMs()
    if (PERF_TELEMETRY_STOPPED || !PERF_TELEMETRY_WANTED)
        return false
    try {
        Run(cmd, A_ScriptDir, "Hide", &workerPid)
        if (workerPid <= 0)
            return false
        PERF_TELEMETRY_PID := workerPid
        ; 對 Run() 剛回傳的子程式立即開啟可等待／終止的 handle。
        ; handle 綁定 process object，PID 後續被重用也不會誤殺新程式。
        workerHandle := DllCall("Kernel32\OpenProcess", "uint", 0x00100001,
            "int", false, "uint", workerPid, "ptr")
        PERF_TELEMETRY_PROCESS_HANDLE := workerHandle
        if (!workerHandle) {
            ; 無法取得精確 handle 時不把此次啟動回報為成功。
            ; 後續只可經由完整命令列驗證管理這個 PID。
            return false
        }
        PERF_TELEMETRY_STARTED_TICK := PerformanceTelemetry_MonotonicMs()
        ; Run() 期間 STOP 可能中斷這個 AHK thread。新 PID 取得後
        ; 再檢查一次，STOP 已發生時只關閉剛建立的精確 worker。
        if (PERF_TELEMETRY_STOPPED || !PERF_TELEMETRY_WANTED) {
            PerformanceTelemetry_StopOwnedWorker(2000)
            return false
        }
        try ProcessSetPriority("Low", workerPid)
        return true
    } catch {
        PerformanceTelemetry_CloseWorkerHandle()
        PERF_TELEMETRY_PID := 0
        PERF_TELEMETRY_STARTED_TICK := 0
        return false
    }
}

PerformanceTelemetry_Stop(waitMs := 3500) {
    global PERF_TELEMETRY_PID, PERF_TELEMETRY_PARENT_PID, PERF_TELEMETRY_ROOT
    global PERF_TELEMETRY_WANTED, PERF_TELEMETRY_STOPPED
    global PERF_TELEMETRY_STARTED_TICK

    ; 先關閉 watchdog 意圖，再等 worker；即使 PID 早已消失，後續心跳
    ; 讀取也不能把 STOP 當成異常而重啟。
    PERF_TELEMETRY_WANTED := false
    PERF_TELEMETRY_STOPPED := true
    stopped := PerformanceTelemetry_StopOwnedWorker(waitMs)
    if stopped {
        PERF_TELEMETRY_PID := 0
        PERF_TELEMETRY_STARTED_TICK := 0
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

PerformanceTelemetry_NormalizeCommandPath(path) {
    return StrLower(RTrim(StrReplace(Trim(String(path), ' "`t`r`n'), "/", "\"), "\"))
}

PerformanceTelemetry_IsAlternatePowerShellMode(flag) {
    value := StrLower(Trim(String(flag), " `t`r`n"))
    if (value = "--%")
        return true
    if (StrLen(value) < 2)
        return false
    for fullName in ["-command", "-commandwithargs", "-encodedcommand", "-encodedarguments"] {
        ; PowerShell 接受參數名縮寫，-c／-co／-e／-enc 都必須拒絕。
        if (InStr(fullName, value) = 1)
            return true
    }
    return false
}

PerformanceTelemetry_CommandLineMatchesWorker(commandLine, workerPath, outputRoot, parentPid) {
    expectedWorker := PerformanceTelemetry_NormalizeCommandPath(workerPath)
    expectedRoot := PerformanceTelemetry_NormalizeCommandPath(outputRoot)
    expectedParent := 0
    try expectedParent := Integer(parentPid)
    if (expectedWorker = "" || expectedRoot = "" || expectedParent <= 0)
        return false

    args := PerformanceTelemetry_ParseCommandLine(commandLine)
    if (args.Length = 0)
        return false
    fileModeIndex := 0
    for argIndex, argValue in args {
        modeFlag := StrLower(Trim(String(argValue), " `t`r`n"))
        if (modeFlag = "-file") {
            fileModeIndex := argIndex
            break
        }
        if PerformanceTelemetry_IsAlternatePowerShellMode(modeFlag)
            return false
    }
    if (fileModeIndex = 0)
        return false
    fileMatches := 0
    rootMatches := 0
    parentMatches := 0
    idx := 1
    while (idx <= args.Length) {
        flag := StrLower(Trim(String(args[idx]), " `t`r`n"))
        if (flag = "-file" || flag = "-outputroot" || flag = "-parentpid") {
            if (idx >= args.Length)
                return false
            value := String(args[idx + 1])
            if (flag = "-file") {
                if (PerformanceTelemetry_NormalizeCommandPath(value) != expectedWorker)
                    return false
                fileMatches += 1
            } else if (flag = "-outputroot") {
                if (PerformanceTelemetry_NormalizeCommandPath(value) != expectedRoot)
                    return false
                rootMatches += 1
            } else {
                actualParent := 0
                if !(Trim(value) ~= "^\d+$")
                    return false
                try actualParent := Integer(Trim(value))
                if (actualParent != expectedParent)
                    return false
                parentMatches += 1
            }
            idx += 2
            continue
        }
        idx += 1
    }
    ; 每個識別參數只能出現一次，避免 PowerShell 對重複參數
    ; 的解釋與我們的所有權判定不一致。
    return fileMatches = 1 && rootMatches = 1 && parentMatches = 1
}

PerformanceTelemetry_IsOwnedWorker(pid) {
    global PERF_TELEMETRY_WORKER_PATH, PERF_TELEMETRY_PARENT_PID, PERF_TELEMETRY_ROOT
    safePid := 0
    try safePid := Integer(pid)
    if (safePid <= 0 || !ProcessExist(safePid))
        return false

    try {
        query := "Select Name,CommandLine from Win32_Process where ProcessId=" safePid
        for proc in ComObjGet("winmgmts:").ExecQuery(query) {
            processName := ""
            commandLine := ""
            try processName := StrLower(String(proc.Name))
            try commandLine := StrLower(String(proc.CommandLine))
            return RegExMatch(processName, "i)^(powershell|pwsh)\.exe$")
                && PerformanceTelemetry_CommandLineMatchesWorker(commandLine,
                    PERF_TELEMETRY_WORKER_PATH, PERF_TELEMETRY_ROOT,
                    PERF_TELEMETRY_PARENT_PID)
        }
    }
    return false
}

PerformanceTelemetry_StopOwnedWorker(waitMs := 2000) {
    global PERF_TELEMETRY_PID, PERF_TELEMETRY_PARENT_PID, PERF_TELEMETRY_ROOT
    global PERF_TELEMETRY_PROCESS_HANDLE
    pid := PERF_TELEMETRY_PID
    stopPath := PERF_TELEMETRY_ROOT "\stop_" PERF_TELEMETRY_PARENT_PID ".flag"
    try FileAppend("stop", stopPath, "UTF-8")

    handle := PERF_TELEMETRY_PROCESS_HANDLE
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
            return true
        }
        return false
    }

    if (pid <= 0 || !ProcessExist(pid)) {
        PERF_TELEMETRY_PID := 0
        return true
    }
    if !PerformanceTelemetry_IsOwnedWorker(pid) {
        ; PID 已重用或無法驗證時安全失敗，絕不關閉別的 PowerShell。
        return false
    }

    deadline := PerformanceTelemetry_MonotonicMs() + Max(0, Integer(waitMs))
    while ProcessExist(pid) && PerformanceTelemetry_MonotonicMs() < deadline
        Sleep 100
    if ProcessExist(pid) && PerformanceTelemetry_IsOwnedWorker(pid)
        try ProcessClose(pid)
    closeDeadline := PerformanceTelemetry_MonotonicMs() + 1000
    while ProcessExist(pid) && PerformanceTelemetry_MonotonicMs() < closeDeadline
        Sleep 50
    if ProcessExist(pid)
        return false
    PERF_TELEMETRY_PID := 0
    return true
}

PerformanceTelemetry_Watchdog(probePath := "") {
    global PERF_TELEMETRY_PID, PERF_TELEMETRY_HEARTBEAT_PATH
    global PERF_TELEMETRY_PROCESS_HANDLE
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
        ; PID 存在不代表仍是本主程式建立的 worker；驗證命令列與
        ; ParentPid。若 WMI 無法驗證，安全失敗而不誤關或製造重複 worker。
        if (PERF_TELEMETRY_PROCESS_HANDLE) {
            pidAlive := PerformanceTelemetry_WorkerHandleAlive()
            if !pidAlive {
                PerformanceTelemetry_CloseWorkerHandle()
                PERF_TELEMETRY_PID := 0
            }
        } else {
            pidExists := pid > 0 && ProcessExist(pid)
            if (pidExists && !PerformanceTelemetry_IsOwnedWorker(pid))
                return false
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
