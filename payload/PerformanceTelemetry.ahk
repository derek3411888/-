#Requires AutoHotkey v2.0+

; Low-overhead performance collection runs in a separate, low-priority
; PowerShell process.  The farming thread only reads one atomically replaced
; JSON file during the existing self-hosted heartbeat.
global PERF_TELEMETRY_PID := 0
global PERF_TELEMETRY_PARENT_PID := 0
global PERF_TELEMETRY_ROOT := ""
global PERF_TELEMETRY_HEARTBEAT_PATH := ""

PerformanceTelemetry_Start(cfgPath := "") {
    global PERF_TELEMETRY_PID, PERF_TELEMETRY_PARENT_PID
    global PERF_TELEMETRY_ROOT, PERF_TELEMETRY_HEARTBEAT_PATH

    if (PERF_TELEMETRY_PID > 0 && ProcessExist(PERF_TELEMETRY_PID))
        return true

    workerPath := A_ScriptDir "\PerformanceTelemetryWorker.ps1"
    if !FileExist(workerPath)
        return false

    PERF_TELEMETRY_ROOT := RuntimeFiles_ProgramRoot() "\效能分析"
    PERF_TELEMETRY_HEARTBEAT_PATH := PERF_TELEMETRY_ROOT "\heartbeat.json"
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
    if (cfgPath != "")
        cmd .= ' -ConfigPath "' cfgPath '"'

    try {
        Run(cmd, A_ScriptDir, "Hide", &workerPid)
        if (workerPid <= 0)
            return false
        PERF_TELEMETRY_PID := workerPid
        try ProcessSetPriority("Low", workerPid)
        return true
    } catch {
        PERF_TELEMETRY_PID := 0
        return false
    }
}

PerformanceTelemetry_Stop(waitMs := 3500) {
    global PERF_TELEMETRY_PID, PERF_TELEMETRY_PARENT_PID, PERF_TELEMETRY_ROOT
    if (PERF_TELEMETRY_PID <= 0)
        return

    stopPath := PERF_TELEMETRY_ROOT "\stop_" PERF_TELEMETRY_PARENT_PID ".flag"
    try FileAppend("stop", stopPath, "UTF-8")
    deadline := A_TickCount + Max(0, waitMs)
    while ProcessExist(PERF_TELEMETRY_PID) && A_TickCount < deadline
        Sleep 100
    ; Only terminate the exact child worker created by this AHK process.  The
    ; worker's finally block normally closes its own PresentMon child first.
    if ProcessExist(PERF_TELEMETRY_PID)
        try ProcessClose(PERF_TELEMETRY_PID)
    PERF_TELEMETRY_PID := 0
}

PerformanceTelemetry_ReadHeartbeatJson() {
    global PERF_TELEMETRY_HEARTBEAT_PATH
    path := PERF_TELEMETRY_HEARTBEAT_PATH
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
