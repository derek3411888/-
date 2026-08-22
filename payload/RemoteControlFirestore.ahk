; Firestore-based remote control MVP for AHK v2
; This module is intentionally self-contained and optional.

global RC_ENABLED := false
global RC_PROJECT_ID := ""
global RC_API_KEY := ""
global RC_COLLECTION := "ahk_clients"
global RC_CFG_PATH := ""
global RC_UID := ""
global RC_DISPLAY_NAME := ""
global RC_DEVICE_ALIAS := ""
global RC_HEARTBEAT_INTERVAL_MS := 90000
global RC_POLL_INTERVAL_MS := 10000
global RC_TIMEOUT_MS := 2500
global RC_LAST_NONCE := 0
global RC_REMOTE_DESIRED_STATE := "RUN"
global RC_REMOTE_PAUSED := false
global RC_LAST_HEARTBEAT_OK := 0
global RC_LAST_ERROR_MSG := ""
global RC_ON_STATE_CHANGED := ""
global RC_RECENT_EVENTS := []
global RC_RECENT_EVENT_LIMIT := 50
global RC_LAST_EVENT_AT := 0

RC_Init(cfgPath, onStateChangedCallback := "") {
    global RC_ENABLED, RC_PROJECT_ID, RC_API_KEY, RC_COLLECTION, RC_CFG_PATH, RC_UID, RC_DISPLAY_NAME, RC_DEVICE_ALIAS
    global RC_HEARTBEAT_INTERVAL_MS, RC_POLL_INTERVAL_MS, RC_TIMEOUT_MS
    global RC_ON_STATE_CHANGED, RC_REMOTE_DESIRED_STATE

    RC_EnsureRemoteControlDefaults(cfgPath)
    RC_CFG_PATH := cfgPath

    enabled := RC_ParseBool01(RC_IniReadSafe(cfgPath, "remote_control", "enabled", "0"), 0)
    RC_ENABLED := enabled ? true : false
    RC_ON_STATE_CHANGED := onStateChangedCallback

    if !RC_ENABLED
        return false

    RC_PROJECT_ID := Trim(RC_IniReadSafe(cfgPath, "remote_control", "project_id", ""), " `t`r`n")
    RC_API_KEY := Trim(RC_IniReadSafe(cfgPath, "remote_control", "api_key", ""), " `t`r`n")
    RC_COLLECTION := Trim(RC_IniReadSafe(cfgPath, "remote_control", "collection", "ahk_clients"), " `t`r`n")
    if (RC_COLLECTION = "")
        RC_COLLECTION := "ahk_clients"

    ; 免費額度保護：心跳至少 60 秒、命令輪詢至少 10 秒。
    ; 一般命令平均約 5 秒、最慢約 10 秒收到，不再以 5 秒頻率整天讀取文件。
    RC_HEARTBEAT_INTERVAL_MS := RC_ToIntRange(RC_IniReadSafe(cfgPath, "remote_control", "heartbeat_interval_ms", "90000"), 90000, 60000, 300000)
    RC_POLL_INTERVAL_MS := RC_ToIntRange(RC_IniReadSafe(cfgPath, "remote_control", "poll_interval_ms", "10000"), 10000, 10000, 30000)
    RC_TIMEOUT_MS := RC_ToIntRange(RC_IniReadSafe(cfgPath, "remote_control", "http_timeout_ms", "2500"), 2500, 800, 10000)
    try IniWrite(RC_HEARTBEAT_INTERVAL_MS, cfgPath, "remote_control", "heartbeat_interval_ms")
    try IniWrite(RC_POLL_INTERVAL_MS, cfgPath, "remote_control", "poll_interval_ms")

    RC_UID := Trim(RC_IniReadSafe(cfgPath, "remote_control", "uid", ""), " `t`r`n")
    if (RC_UID = "") {
        RC_UID := RC_BuildClientUid()
        try IniWrite(RC_UID, cfgPath, "remote_control", "uid")
    }

    RC_DEVICE_ALIAS := Trim(RC_IniReadSafe(cfgPath, "remote_control", "device_alias", ""), " `t`r`n")

    RC_DISPLAY_NAME := Trim(RC_IniReadSafe(cfgPath, "remote_control", "display_name", ""), " `t`r`n")
    if (RC_DISPLAY_NAME = "") {
        RC_DISPLAY_NAME := RC_BuildFriendlyDisplayName(RC_DEVICE_ALIAS)
        try IniWrite(RC_DISPLAY_NAME, cfgPath, "remote_control", "display_name")
    }

    RC_REMOTE_DESIRED_STATE := "RUN"
    RC_LAST_NONCE := RC_ToIntRange(RC_IniReadSafe(cfgPath, "remote_control", "last_nonce", "0"), 0, 0, 2147483647)

    RC_StartupDefaultRun()

    RC_Log("RemoteControl initialized. uid=" RC_UID " display=" RC_DISPLAY_NAME " collection=" RC_COLLECTION
        " poll=" RC_POLL_INTERVAL_MS "ms heartbeat=" RC_HEARTBEAT_INTERVAL_MS "ms")
    RC_Start()
    return true
}

RC_StartupDefaultRun() {
    global RC_LAST_NONCE, RC_REMOTE_DESIRED_STATE, RC_CFG_PATH

    ; 每次啟動都先回到 RUN，且把現有文件 nonce 視為已讀，避免重放舊命令。
    RC_REMOTE_DESIRED_STATE := "RUN"
    RC_SetPausedFlag(false)

    resp := RC_FirestoreGetClientDoc()
    if (resp != "") {
        docNonce := RC_JsonGetInteger(resp, "nonce", 0)
        if (docNonce > RC_LAST_NONCE)
            RC_LAST_NONCE := docNonce
    }

    try IniWrite(RC_LAST_NONCE, RC_CFG_PATH, "remote_control", "last_nonce")
    RC_Log("Startup default RUN. command cursor=" RC_LAST_NONCE)
}

RC_Start() {
    global RC_ENABLED, RC_HEARTBEAT_INTERVAL_MS, RC_POLL_INTERVAL_MS
    if !RC_ENABLED
        return

    RC_HeartbeatTick()
    RC_CleanupLegacyMediaFields()
    RC_PollCommandTick()
    SetTimer(RC_HeartbeatTick, RC_HEARTBEAT_INTERVAL_MS)
    SetTimer(RC_PollCommandTick, RC_POLL_INTERVAL_MS)
}

RC_Shutdown() {
    global RC_ENABLED
    if !RC_ENABLED
        return

    try SetTimer(RC_HeartbeatTick, 0)
    try SetTimer(RC_PollCommandTick, 0)
    RC_PatchClientState("OFFLINE", true)
}

RC_HeartbeatTick() {
    RC_PatchClientState(RC_REMOTE_PAUSED ? "PAUSE" : "RUN", false)
}

RC_ReportRuntimeState() {
    global RC_REMOTE_PAUSED

    RC_PatchClientState(RC_REMOTE_PAUSED ? "PAUSE" : "RUN", false)
}

RC_RecordRuntimeEvent(name, detail := "", level := "INFO") {
    global RC_RECENT_EVENTS, RC_RECENT_EVENT_LIMIT, RC_LAST_EVENT_AT

    nowMs := RC_UnixMs()
    eventName := Trim(name, " `t`r`n")
    eventDetail := Trim(detail, " `t`r`n")
    eventLevel := StrUpper(Trim(level, " `t`r`n"))
    if (eventName = "")
        eventName := "事件"
    if (eventLevel != "WARN" && eventLevel != "ERROR")
        eventLevel := "INFO"

    ; 避免單一 OCR/例外訊息把 Firestore 文件撐大。
    if (StrLen(eventDetail) > 600)
        eventDetail := SubStr(eventDetail, 1, 600) "…"

    RC_RECENT_EVENTS.Push({at: nowMs, name: eventName, detail: eventDetail, level: eventLevel})
    while (RC_RECENT_EVENTS.Length > RC_RECENT_EVENT_LIMIT)
        RC_RECENT_EVENTS.RemoveAt(1)
    RC_LAST_EVENT_AT := nowMs
}

RC_BuildRecentEventsJson() {
    global RC_RECENT_EVENTS
    json := "["
    for idx, item in RC_RECENT_EVENTS {
        if (idx > 1)
            json .= ","
        json .= "{"
        json .= '"at":' item.at ","
        json .= '"name":"' RC_JsonEsc(item.name) '",'
        json .= '"detail":"' RC_JsonEsc(item.detail) '",'
        json .= '"level":"' RC_JsonEsc(item.level) '"'
        json .= "}"
    }
    return json "]"
}

RC_PublishRuntimeSnapshot(dataUri, capturedAt, reason := "", width := 0, height := 0) {
    global RC_ENABLED, RC_UID
    if !RC_ENABLED
        return false
    if (dataUri = "" || StrLen(dataUri) > 300000) {
        RC_Log("Runtime snapshot skipped: empty or too large (chars=" StrLen(dataUri) ")", "WARN")
        return false
    }

    body := "{"
    body .= '"fields":{'
    body .= '"docKind":{"stringValue":"media"},'
    body .= '"clientUid":{"stringValue":"' RC_JsonEsc(RC_UID) '"},'
    body .= '"latestScreenshotDataUri":{"stringValue":"' RC_JsonEsc(dataUri) '"},'
    body .= '"latestScreenshotAt":{"integerValue":"' capturedAt '"},'
    body .= '"latestScreenshotReason":{"stringValue":"' RC_JsonEsc(reason) '"},'
    body .= '"latestScreenshotWidth":{"integerValue":"' width '"},'
    body .= '"latestScreenshotHeight":{"integerValue":"' height '"}'
    body .= "}"
    body .= "}"

    url := RC_ClientMediaDocUrl()
    url .= "&updateMask.fieldPaths=docKind"
    url .= "&updateMask.fieldPaths=clientUid"
    url .= "&updateMask.fieldPaths=latestScreenshotDataUri"
    url .= "&updateMask.fieldPaths=latestScreenshotAt"
    url .= "&updateMask.fieldPaths=latestScreenshotReason"
    url .= "&updateMask.fieldPaths=latestScreenshotWidth"
    url .= "&updateMask.fieldPaths=latestScreenshotHeight"
    ; PATCH 回應只取時間戳，避免伺服器把剛上傳的整張 JPEG 再傳回來。
    url .= "&mask.fieldPaths=latestScreenshotAt"
    r := RC_HttpRequest("PATCH", url, body)
    if !r.ok {
        RC_Log("Runtime snapshot patch failed: " r.msg, "WARN")
        return false
    }
    return true
}

RC_PublishRuntimeVideoPreview(dataUri, capturedAt, durationSec := 6, width := 0, height := 0, sizeBytes := 0) {
    ; 網路影片功能暫停實作。保留函式只為相容舊呼叫，永遠不送出資料。
    return false
}

RC_CleanupLegacyMediaFields() {
    ; 4.36 曾把 JPEG／MP4 Base64 放在控制文件。新版第一次啟動即刪除這些欄位，
    ; 否則即使停止上傳，Firestore 仍會在網頁監聽或 PATCH 回應中傳送舊內容。
    body := '{"fields":{"mediaSchemaVersion":{"integerValue":"2"}}}'
    url := RC_ClientDocUrl()
    for fieldName in [
        "latestScreenshotDataUri", "latestScreenshotAt", "latestScreenshotReason",
        "latestScreenshotWidth", "latestScreenshotHeight",
        "latestVideoPreviewDataUri", "latestVideoPreviewAt", "latestVideoPreviewDurationSec",
        "latestVideoPreviewWidth", "latestVideoPreviewHeight", "latestVideoPreviewBytes",
        "mediaSchemaVersion"
    ]
        url .= "&updateMask.fieldPaths=" fieldName
    url .= "&mask.fieldPaths=mediaSchemaVersion"
    r := RC_HttpRequest("PATCH", url, body)
    if !r.ok {
        RC_Log("Legacy media cleanup failed: " r.msg, "WARN")
        return false
    }
    RC_Log("Legacy Firestore media fields cleared; screenshot now uses companion media document")
    return true
}

RC_PollCommandTick() {
    global RC_ENABLED, RC_LAST_NONCE, RC_LAST_ERROR_MSG
    if !RC_ENABLED
        return

    resp := RC_FirestoreGetClientDoc()
    if (resp = "")
        return

    desired := RC_JsonGetString(resp, "desiredState")
    if (desired = "")
        desired := "RUN"

    nonce := RC_JsonGetInteger(resp, "nonce", 0)
    if (nonce <= RC_LAST_NONCE)
        return

    RC_LAST_NONCE := nonce
    RC_ApplyRemoteState(desired, nonce)
}

RC_ApplyRemoteState(desired, nonce) {
    global RC_REMOTE_DESIRED_STATE, RC_ON_STATE_CHANGED, RC_CFG_PATH
    d := StrUpper(Trim(desired, " `t`r`n"))
    if (d != "RUN" && d != "PAUSE" && d != "STOP")
        d := "RUN"

    RC_REMOTE_DESIRED_STATE := d
    RC_SetPausedFlag(d = "PAUSE")

    ; 命令套用後立即同步狀態，避免要等下一次心跳才反映在網頁。
    RC_PatchClientState(d, false)

    ; 命令游標持久化，避免重啟後重新套用舊命令。
    try IniWrite(nonce, RC_CFG_PATH, "remote_control", "last_nonce")

    ; 先回 ACK，避免 STOP 直接觸發退出時遺失回覆。
    RC_PatchCommandAck(nonce, d)

    if (RC_ON_STATE_CHANGED != "") {
        try %RC_ON_STATE_CHANGED%(d)
    }

    RC_Log("Remote command applied: state=" d " nonce=" nonce)
}

RC_SetPausedFlag(paused) {
    global RC_REMOTE_PAUSED
    RC_REMOTE_PAUSED := paused ? true : false
}

RC_IsPaused() {
    global RC_REMOTE_PAUSED
    return RC_REMOTE_PAUSED
}

RC_BuildClientUid() {
    mac := RC_GetPrimaryMacAddress()
    if (mac = "")
        mac := Format("{:X}", A_TickCount)
    return A_ComputerName "_" mac
}

RC_BuildFriendlyDisplayName(alias := "") {
    shortCode := RC_BuildShortMachineCode()
    if (alias != "")
        return alias "@" A_ComputerName "-" shortCode
    return A_ComputerName "-" shortCode
}

RC_BuildShortMachineCode() {
    mac := RC_GetPrimaryMacAddress()
    if (mac != "" && StrLen(mac) >= 4)
        return StrUpper(SubStr(mac, -3))
    return Format("{:04X}", Mod(A_TickCount, 65536))
}

RC_GetPrimaryMacAddress() {
    try {
        wmi := ComObjGet("winmgmts:")
        for item in wmi.ExecQuery("SELECT MACAddress FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled=True") {
            v := Trim(item.MACAddress, " `t`r`n")
            if (v != "") {
                v := StrReplace(v, ":", "")
                v := StrReplace(v, "-", "")
                return StrLower(v)
            }
        }
    }
    return ""
}

RC_ReadRecordingStatus() {
    localBase := Trim(EnvGet("LOCALAPPDATA"), ' "`t`r`n')
    if (localBase = "")
        localBase := A_Temp
    stagingRoot := RTrim(StrReplace(localBase, "/", "\"), "\") "\WutheringAuto\recording_staging"
    statusPath := stagingRoot "\recording_status.ini"
    available := FileExist(statusPath) ? true : false
    if !available {
        return {
            available: false, state: "", detail: "", updatedMs: 0,
            localSessionDir: "", destinationDir: "", destinationSegmentsDir: "",
            finalPath: "", resultPath: "", failureStorage: "", workerLogPath: stagingRoot "\recording_worker.log",
            baseName: "", autoMerge: true, captureActive: false
        }
    }

    return {
        available: true,
        state: RC_IniReadSafe(statusPath, "recording", "state", ""),
        detail: RC_IniReadSafe(statusPath, "recording", "state_detail", ""),
        updatedMs: RC_ToIntRange(RC_IniReadSafe(statusPath, "recording", "state_updated_unix_ms", "0"), 0, 0, 9999999999999),
        localSessionDir: RC_IniReadSafe(statusPath, "recording", "local_session_dir", ""),
        destinationDir: RC_IniReadSafe(statusPath, "recording", "destination_dir", ""),
        destinationSegmentsDir: RC_IniReadSafe(statusPath, "recording", "destination_segments_dir", ""),
        finalPath: RC_IniReadSafe(statusPath, "recording", "final_path", ""),
        resultPath: RC_IniReadSafe(statusPath, "recording", "result_path", ""),
        failureStorage: RC_IniReadSafe(statusPath, "recording", "failure_storage", ""),
        workerLogPath: RC_IniReadSafe(statusPath, "recording", "worker_log_path", stagingRoot "\recording_worker.log"),
        baseName: RC_IniReadSafe(statusPath, "recording", "base_name", ""),
        autoMerge: RC_IniReadSafe(statusPath, "recording", "auto_merge", "1") = "1",
        captureActive: RC_IniReadSafe(statusPath, "recording", "capture_active", "0") = "1"
    }
}

RC_PatchClientState(state, isShutdown) {
    global RC_LAST_HEARTBEAT_OK, RC_LAST_ERROR_MSG
    global RC_LAST_EVENT_AT, RC_RECENT_EVENTS
    global CURRENT_STEP_NAME, CURRENT_STEP_DETAIL, CURRENT_STEP_LEVEL
    global CURRENT_SERVER_TARGET, SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_INDEX, SERVER_SCHEDULE_LIST
    global SCREEN_RECORDING_ENABLED, __SCREEN_RECORDING_ACTIVE
    nowMs := RC_UnixMs()

    currentStepName := Trim(CURRENT_STEP_NAME, " `t`r`n")
    currentStepDetail := Trim(CURRENT_STEP_DETAIL, " `t`r`n")
    currentStepLevel := Trim(CURRENT_STEP_LEVEL, " `t`r`n")

    currentServer := Trim(CURRENT_SERVER_TARGET, " `t`r`n")
    serverIndex := (SERVER_SCHEDULE_ENABLED && SERVER_SCHEDULE_INDEX > 0 ? SERVER_SCHEDULE_INDEX : 0)
    serverTotal := (SERVER_SCHEDULE_ENABLED ? SERVER_SCHEDULE_LIST.Length : 0)
    currentServerLabel := currentServer
    if (serverTotal > 1 && currentServer != "")
        currentServerLabel := serverIndex "/" serverTotal " | " currentServer
    recentEventsJson := RC_BuildRecentEventsJson()
    recording := RC_ReadRecordingStatus()
    recordingActive := __SCREEN_RECORDING_ACTIVE ? true : false
    recordingDetail := SubStr(recording.detail, 1, 1000)

    body := "{"
    body .= '"fields":{'
    body .= '"docKind":{"stringValue":"client"},'
    body .= '"schemaVersion":{"integerValue":"2"},'
    body .= '"uid":{"stringValue":"' RC_JsonEsc(RC_UID) '"},'
    body .= '"displayName":{"stringValue":"' RC_JsonEsc(RC_DISPLAY_NAME) '"},'
    body .= '"computerName":{"stringValue":"' RC_JsonEsc(A_ComputerName) '"},'
    body .= '"status":{"stringValue":"' RC_JsonEsc(state) '"},'
    body .= '"currentStep":{"stringValue":"' RC_JsonEsc(currentStepName) '"},'
    body .= '"currentStepDetail":{"stringValue":"' RC_JsonEsc(currentStepDetail) '"},'
    body .= '"currentStepLevel":{"stringValue":"' RC_JsonEsc(currentStepLevel) '"},'
    body .= '"currentServer":{"stringValue":"' RC_JsonEsc(currentServer) '"},'
    body .= '"currentServerLabel":{"stringValue":"' RC_JsonEsc(currentServerLabel) '"},'
    body .= '"currentServerIndex":{"integerValue":"' serverIndex '"},'
    body .= '"currentServerTotal":{"integerValue":"' serverTotal '"},'
    body .= '"lastHeartbeat":{"integerValue":"' nowMs '"},'
    body .= '"updatedAt":{"integerValue":"' nowMs '"},'
    body .= '"recentEventsJson":{"stringValue":"' RC_JsonEsc(recentEventsJson) '"},'
    body .= '"recentEventCount":{"integerValue":"' RC_RECENT_EVENTS.Length '"},'
    body .= '"lastRuntimeEventAt":{"integerValue":"' RC_LAST_EVENT_AT '"},'
    body .= '"recordingStatusAvailable":{"booleanValue":' (recording.available ? "true" : "false") '},'
    body .= '"recordingEnabled":{"booleanValue":' (SCREEN_RECORDING_ENABLED ? "true" : "false") '},'
    body .= '"recordingActive":{"booleanValue":' (recordingActive ? "true" : "false") '},'
    body .= '"recordingState":{"stringValue":"' RC_JsonEsc(recording.state) '"},'
    body .= '"recordingStateDetail":{"stringValue":"' RC_JsonEsc(recordingDetail) '"},'
    body .= '"recordingStateUpdatedAt":{"integerValue":"' recording.updatedMs '"},'
    body .= '"recordingLocalSessionDir":{"stringValue":"' RC_JsonEsc(recording.localSessionDir) '"},'
    body .= '"recordingDestinationDir":{"stringValue":"' RC_JsonEsc(recording.destinationDir) '"},'
    body .= '"recordingDestinationSegmentsDir":{"stringValue":"' RC_JsonEsc(recording.destinationSegmentsDir) '"},'
    body .= '"recordingFinalPath":{"stringValue":"' RC_JsonEsc(recording.finalPath) '"},'
    body .= '"recordingResultPath":{"stringValue":"' RC_JsonEsc(recording.resultPath) '"},'
    body .= '"recordingFailureStorage":{"stringValue":"' RC_JsonEsc(recording.failureStorage) '"},'
    body .= '"recordingWorkerLogPath":{"stringValue":"' RC_JsonEsc(recording.workerLogPath) '"},'
    body .= '"recordingBaseName":{"stringValue":"' RC_JsonEsc(recording.baseName) '"},'
    body .= '"recordingAutoMerge":{"booleanValue":' (recording.autoMerge ? "true" : "false") '}'
    body .= "}"
    body .= "}"

    url := RC_ClientDocUrl()
    url .= "&updateMask.fieldPaths=docKind"
    url .= "&updateMask.fieldPaths=schemaVersion"
    url .= "&updateMask.fieldPaths=uid"
    url .= "&updateMask.fieldPaths=displayName"
    url .= "&updateMask.fieldPaths=computerName"
    url .= "&updateMask.fieldPaths=status"
    url .= "&updateMask.fieldPaths=currentStep"
    url .= "&updateMask.fieldPaths=currentStepDetail"
    url .= "&updateMask.fieldPaths=currentStepLevel"
    url .= "&updateMask.fieldPaths=currentServer"
    url .= "&updateMask.fieldPaths=currentServerLabel"
    url .= "&updateMask.fieldPaths=currentServerIndex"
    url .= "&updateMask.fieldPaths=currentServerTotal"
    url .= "&updateMask.fieldPaths=lastHeartbeat"
    url .= "&updateMask.fieldPaths=updatedAt"
    url .= "&updateMask.fieldPaths=recentEventsJson"
    url .= "&updateMask.fieldPaths=recentEventCount"
    url .= "&updateMask.fieldPaths=lastRuntimeEventAt"
    url .= "&updateMask.fieldPaths=recordingStatusAvailable"
    url .= "&updateMask.fieldPaths=recordingEnabled"
    url .= "&updateMask.fieldPaths=recordingActive"
    url .= "&updateMask.fieldPaths=recordingState"
    url .= "&updateMask.fieldPaths=recordingStateDetail"
    url .= "&updateMask.fieldPaths=recordingStateUpdatedAt"
    url .= "&updateMask.fieldPaths=recordingLocalSessionDir"
    url .= "&updateMask.fieldPaths=recordingDestinationDir"
    url .= "&updateMask.fieldPaths=recordingDestinationSegmentsDir"
    url .= "&updateMask.fieldPaths=recordingFinalPath"
    url .= "&updateMask.fieldPaths=recordingResultPath"
    url .= "&updateMask.fieldPaths=recordingFailureStorage"
    url .= "&updateMask.fieldPaths=recordingWorkerLogPath"
    url .= "&updateMask.fieldPaths=recordingBaseName"
    url .= "&updateMask.fieldPaths=recordingAutoMerge"
    ; PATCH 只需要確認 updatedAt，不下載整份狀態文件。
    url .= "&mask.fieldPaths=updatedAt"

    r := RC_HttpRequest("PATCH", url, body)
    if (r.ok) {
        RC_LAST_HEARTBEAT_OK := nowMs
        return true
    }

    RC_LAST_ERROR_MSG := r.msg
    if isShutdown
        RC_Log("RemoteControl shutdown patch failed: " r.msg, "WARN")
    else
        RC_Log("RemoteControl heartbeat failed: " r.msg, "WARN")
    return false
}

RC_PatchCommandAck(nonce, stateApplied) {
    nowMs := RC_UnixMs()
    body := "{"
    body .= '"fields":{'
    body .= '"lastAckNonce":{"integerValue":"' nonce '"},'
    body .= '"lastAckState":{"stringValue":"' RC_JsonEsc(stateApplied) '"},'
    body .= '"lastAckAt":{"integerValue":"' nowMs '"}'
    body .= "}"
    body .= "}"

    url := RC_ClientDocUrl()
    url .= "&updateMask.fieldPaths=lastAckNonce"
    url .= "&updateMask.fieldPaths=lastAckState"
    url .= "&updateMask.fieldPaths=lastAckAt"
    url .= "&mask.fieldPaths=lastAckAt"

    r := RC_HttpRequest("PATCH", url, body)
    if !r.ok
        RC_Log("RemoteControl ack patch failed: " r.msg, "WARN")
}

RC_FirestoreGetClientDoc() {
    ; 輪詢命令只需要兩個欄位，使用 field mask 保持每次回應極小。
    url := RC_ClientDocUrl()
    url .= "&mask.fieldPaths=desiredState"
    url .= "&mask.fieldPaths=nonce"
    r := RC_HttpRequest("GET", url, "")
    if !r.ok {
        RC_Log("RemoteControl poll failed: " r.msg, "WARN")
        return ""
    }
    return r.body
}

RC_ClientDocUrl() {
    global RC_PROJECT_ID, RC_API_KEY, RC_COLLECTION, RC_UID
    return "https://firestore.googleapis.com/v1/projects/" RC_PROJECT_ID "/databases/(default)/documents/" RC_COLLECTION "/" RC_UID "?key=" RC_API_KEY
}

RC_ClientMediaDocUrl() {
    global RC_PROJECT_ID, RC_API_KEY, RC_COLLECTION, RC_UID
    return "https://firestore.googleapis.com/v1/projects/" RC_PROJECT_ID "/databases/(default)/documents/" RC_COLLECTION "/" RC_UID "__media?key=" RC_API_KEY
}

RC_HttpRequest(method, url, body := "") {
    global RC_TIMEOUT_MS
    result := { ok: false, status: 0, body: "", msg: "" }
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.SetTimeouts(RC_TIMEOUT_MS, RC_TIMEOUT_MS, RC_TIMEOUT_MS, RC_TIMEOUT_MS)
        http.Open(method, url, false)
        http.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
        http.SetRequestHeader("Cache-Control", "no-cache")
        http.SetRequestHeader("Pragma", "no-cache")
        if (body != "")
            http.Send(body)
        else
            http.Send()

        result.status := http.Status + 0
        result.body := http.ResponseText
        result.ok := (result.status >= 200 && result.status < 300)
        if !result.ok
            result.msg := "HTTP " result.status " " result.body
        return result
    } catch as e {
        result.msg := e.Message
        return result
    }
}

RC_JsonGetString(jsonText, fieldName) {
    p1 := '"' fieldName '"\s*:\s*\{[^\}]*"stringValue"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"'
    if RegExMatch(jsonText, p1, &m) {
        v := m[1]
        v := StrReplace(v, '\"', '"')
        v := StrReplace(v, "\\", "\")
        return v
    }
    return ""
}

RC_JsonGetInteger(jsonText, fieldName, defaultVal := 0) {
    p := '"' fieldName '"\s*:\s*\{[^\}]*"integerValue"\s*:\s*"?(\d+)"?'
    if RegExMatch(jsonText, p, &m) {
        try return Integer(m[1])
    }
    return defaultVal
}

RC_JsonEsc(txt) {
    s := txt
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return s
}

RC_UnixMs() {
    ft := Buffer(8, 0)
    DllCall("GetSystemTimeAsFileTime", "ptr", ft.Ptr)
    t := NumGet(ft, 0, "Int64")
    return (t // 10000) - 11644473600000
}

RC_IniReadSafe(file, section, key, default := "") {
    try {
        return IniRead(file, section, key, default)
    } catch {
        return default
    }
}

RC_EnsureRemoteControlDefaults(cfgPath) {
    defaults := Map(
        "enabled", "1",
        "project_id", "ww-control-a3988",
        "api_key", "AIzaSyDqWHdBixVQPt4OiTi50hseInFxPtk0hf0",
        "collection", "ahk_clients",
        "uid", "",
        "device_alias", "",
        "display_name", "",
        "heartbeat_interval_ms", "90000",
        "poll_interval_ms", "10000",
        "http_timeout_ms", "2500",
        "delete_on_exit", "0",
        "last_nonce", "0"
    )

    wrote := 0
    sentinel := "__RC_MISSING__"
    for key, defaultVal in defaults {
        cur := RC_IniReadSafe(cfgPath, "remote_control", key, sentinel)
        if (cur = sentinel) {
            try {
                IniWrite(defaultVal, cfgPath, "remote_control", key)
                wrote += 1
            }
        }
    }

    if (wrote > 0)
        RC_Log("首次啟動：已自動補齊 remote_control 設定項目=" wrote)
}

RC_ParseBool01(val, defaultVal := 0) {
    s := StrLower(Trim(val, " `t`r`n"))
    if (s = "1" || s = "true" || s = "yes" || s = "on")
        return 1
    if (s = "0" || s = "false" || s = "no" || s = "off")
        return 0
    return defaultVal
}

RC_ToIntRange(val, defaultVal, minVal, maxVal) {
    n := defaultVal
    try n := Integer(Trim(val, " `t`r`n"))
    if (n < minVal)
        n := minVal
    if (n > maxVal)
        n := maxVal
    return n
}

RC_Log(msg, level := "INFO") {
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    try WriteLog("[RemoteControl] " msg, level)
    catch {
        try FileAppend(ts " [" level "] [RemoteControl] " msg "`r`n", A_ScriptDir "\\remote_fallback.log", "UTF-8")
    }
}
