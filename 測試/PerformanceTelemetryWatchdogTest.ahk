#Requires AutoHotkey v2.0+
#SingleInstance Force

#Include ..\payload\RuntimeFilePaths.ahk
#Include ..\payload\PerformanceTelemetry.ahk

; PerformanceTelemetry_MarkIncident 在正式主腳本由這三個全域
; 狀態提供上下文；獨立回歸測試也必須明確宣告，避免 #Warn
; 把「測試缺少 fixture」誤報成使用者彈窗。
global CURRENT_STEP_NAME := ""
global CURRENT_STEP_DETAIL := ""
global CURRENT_SERVER_TARGET := ""

AssertTelemetryWatchdog(condition, message) {
    if !condition
        throw Error(message)
}

nowMs := 1900000000000
healthy := '{"collector":{"state":"running","version":1,"updatedAt":1899999999000,"error":""}}'
degraded := '{"collector":{"state":"degraded","version":1,"updatedAt":1899999999000,"error":"PresentMon retry"}}'
failed := '{"collector":{"state":"error","version":1,"updatedAt":1899999999000,"error":"collector failed"}}'
stale := '{"collector":{"state":"running","version":1,"updatedAt":1899999900000,"error":""}}'
starting := '{"collector":{"state":"starting","version":1,"updatedAt":1899999900000,"error":""}}'

try {
    expectedWorker := "E:\project with spaces\payload\PerformanceTelemetryWorker.ps1"
    expectedRoot := "E:\project with spaces\.dev-runtime\runtime\效能分析"
    validCommand := '"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"'
        . ' -NoProfile -File "' expectedWorker '" -OutputRoot "' expectedRoot '"'
        . ' -ParentPid 123 -SampleIntervalSeconds 2'
    AssertTelemetryWatchdog(PerformanceTelemetry_CommandLineMatchesWorker(
        validCommand, expectedWorker, expectedRoot, 123),
        "完整 worker 命令列應通過所有權檢查")
    AssertTelemetryWatchdog(!PerformanceTelemetry_CommandLineMatchesWorker(
        StrReplace(validCommand, "-ParentPid 123", "-ParentPid 1234"),
        expectedWorker, expectedRoot, 123),
        "ParentPid 數字前綴不得誤判為相同 PID")
    AssertTelemetryWatchdog(!PerformanceTelemetry_CommandLineMatchesWorker(
        StrReplace(validCommand, expectedWorker, expectedWorker "-other"),
        expectedWorker, expectedRoot, 123),
        "worker 路徑後綴不得通過所有權檢查")
    AssertTelemetryWatchdog(!PerformanceTelemetry_CommandLineMatchesWorker(
        StrReplace(validCommand, expectedRoot, expectedRoot "-other"),
        expectedWorker, expectedRoot, 123),
        "OutputRoot 路徑後綴不得通過所有權檢查")
    AssertTelemetryWatchdog(!PerformanceTelemetry_CommandLineMatchesWorker(
        validCommand ' -ParentPid 123', expectedWorker, expectedRoot, 123),
        "重複 ParentPid 參數不得通過所有權檢查")
    commandMode := StrReplace(validCommand, " -File ", ' -Command "noop" -File ')
    AssertTelemetryWatchdog(!PerformanceTelemetry_CommandLineMatchesWorker(
        commandMode, expectedWorker, expectedRoot, 123),
        "-Command 模式下的 -File token 不得被當成 worker invocation")
    encodedMode := StrReplace(validCommand, " -File ", " -Enc ZQBjAGgAbwAgAHQAZQBzAHQA -File ")
    AssertTelemetryWatchdog(!PerformanceTelemetry_CommandLineMatchesWorker(
        encodedMode, expectedWorker, expectedRoot, 123),
        "-EncodedCommand 縮寫模式不得被當成 worker invocation")

    result := PerformanceTelemetry_EvaluateHealth(healthy, true, 10000, nowMs)
    AssertTelemetryWatchdog(!result.restart, "正常 collector 不應重啟")
    result := PerformanceTelemetry_EvaluateHealth(degraded, true, 10000, nowMs)
    AssertTelemetryWatchdog(!result.restart, "PresentMon 降級不應重啟整個 worker")
    result := PerformanceTelemetry_EvaluateHealth(failed, true, 10000, nowMs)
    AssertTelemetryWatchdog(result.restart && result.reason = "collector-error",
        "collector error 未觸發重啟")
    result := PerformanceTelemetry_EvaluateHealth(stale, true, 100000, nowMs)
    AssertTelemetryWatchdog(result.restart && result.reason = "collector-stale",
        "過期 collector 未觸發重啟")
    result := PerformanceTelemetry_EvaluateHealth(starting, true, 20000, nowMs)
    AssertTelemetryWatchdog(!result.restart, "啟動寬限內不應重啟")
    result := PerformanceTelemetry_EvaluateHealth("", true, 100000, nowMs)
    AssertTelemetryWatchdog(result.restart && result.reason = "collector-missing",
        "長時間無 collector 資料未觸發重啟")
    result := PerformanceTelemetry_EvaluateHealth(healthy, false, 10000, nowMs)
    AssertTelemetryWatchdog(result.restart && result.reason = "worker-exited",
        "worker 消失未觸發重啟")

    PERF_TELEMETRY_WANTED := true
    PERF_TELEMETRY_STOPPED := false
    AssertTelemetryWatchdog(PerformanceTelemetry_WatchdogAllowed(), "RUN 時 watchdog 應啟用")
    PERF_TELEMETRY_WANTED := false
    PERF_TELEMETRY_STOPPED := true
    AssertTelemetryWatchdog(!PerformanceTelemetry_WatchdogAllowed(),
        "STOP 後 watchdog 不得重啟 worker")
    PERF_TELEMETRY_PID := 0
    PERF_TELEMETRY_PROCESS_HANDLE := 0
    PERF_TELEMETRY_LAST_RESTART_TICK := 0
    AssertTelemetryWatchdog(!PerformanceTelemetry_Watchdog(""),
        "STOP 後直接調用 watchdog 仍必須拒絕重啟")
    AssertTelemetryWatchdog(!PerformanceTelemetry_LaunchWorker(),
        "STOP 後直接調用 LaunchWorker 仍必須拒絕啟動")
    AssertTelemetryWatchdog(PERF_TELEMETRY_PID = 0,
        "STOP 後 LaunchWorker 不得建立或篡改 worker PID")
    AssertTelemetryWatchdog(PERF_TELEMETRY_PROCESS_HANDLE = 0,
        "STOP 後 LaunchWorker 不得建立 worker process handle")

    incidentFixture := '{"collector":{"state":"running","updatedAt":1900000000000},'
        . '"current":{"fps":null,"cpuTotalPct":22.5,"gpuPct":27,"gpuTempC":69,'
        . '"ramUsedGb":14.47,"gameRamMb":0,"lrmcRamMb":0,"diskReadMbps":1333.3,'
        . '"recordingActive":true,"recordingFps":37.48,"gameRunning":false,"lrmcRunning":false},'
        . '"minutes":[{"metrics":{"cpuTotalPctMax":67,"gpuPctMax":66,'
        . '"gpuTempCMax":87,"ramUsedGbMax":22.4,"diskReadMbpsMax":249.7}}]}'
    originalHeartbeatPath := PERF_TELEMETRY_HEARTBEAT_PATH
    fixtureRoot := A_ScriptDir "\..\.dev-runtime\tests\performance-incident"
    DirCreate(fixtureRoot)
    PERF_TELEMETRY_HEARTBEAT_PATH := fixtureRoot "\heartbeat.json"
    try FileDelete(PERF_TELEMETRY_HEARTBEAT_PATH)
    FileAppend(incidentFixture, PERF_TELEMETRY_HEARTBEAT_PATH, "UTF-8")
    incidentSummary := PerformanceTelemetry_CurrentIncidentSummary()
    AssertTelemetryWatchdog(InStr(incidentSummary, "fps=-") > 0,
        "事故摘要應正確表示 FPS 無資料")
    AssertTelemetryWatchdog(InStr(incidentSummary, "gameRunning=false") > 0,
        "事故摘要缺少遊戲程序狀態")
    AssertTelemetryWatchdog(InStr(incidentSummary, "tempMaxC=87") > 0,
        "事故摘要缺少上一分鐘最高 GPU 溫度")
    PERF_TELEMETRY_HEARTBEAT_PATH := originalHeartbeatPath
    try FileDelete(fixtureRoot "\heartbeat.json")
    try DirDelete(fixtureRoot)
    FileAppend("performance-telemetry-watchdog=ok`n", "*")
} catch as e {
    FileAppend("performance-telemetry-watchdog=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)

RC_JsonEsc(text) {
    return String(text)
}
