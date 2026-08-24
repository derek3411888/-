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
global RC_ON_SETTINGS_CHANGED := ""
global RC_LAST_SETTINGS_SEEN_REVISION := 0
global RC_LAST_SETTINGS_APPLIED_REVISION := 0
global RC_RECENT_EVENTS := []
global RC_RECENT_EVENT_LIMIT := 50
global RC_LAST_EVENT_AT := 0
global RC_CLEAR_SNAPSHOT_ON_CLEAN_EXIT := true

RC_Init(cfgPath, onStateChangedCallback := "", onSettingsChangedCallback := "") {
    global RC_ENABLED, RC_PROJECT_ID, RC_API_KEY, RC_COLLECTION, RC_CFG_PATH, RC_UID, RC_DISPLAY_NAME, RC_DEVICE_ALIAS
    global RC_HEARTBEAT_INTERVAL_MS, RC_POLL_INTERVAL_MS, RC_TIMEOUT_MS
    global RC_ON_STATE_CHANGED, RC_ON_SETTINGS_CHANGED, RC_REMOTE_DESIRED_STATE, RC_CLEAR_SNAPSHOT_ON_CLEAN_EXIT
    global RC_LAST_SETTINGS_SEEN_REVISION, RC_LAST_SETTINGS_APPLIED_REVISION

    RC_EnsureRemoteControlDefaults(cfgPath)
    RC_CFG_PATH := cfgPath

    enabled := RC_ParseBool01(RC_IniReadSafe(cfgPath, "remote_control", "enabled", "0"), 0)
    RC_ENABLED := enabled ? true : false
    RC_ON_STATE_CHANGED := onStateChangedCallback
    RC_ON_SETTINGS_CHANGED := onSettingsChangedCallback

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
    RC_CLEAR_SNAPSHOT_ON_CLEAN_EXIT := RC_ParseBool01(
        RC_IniReadSafe(cfgPath, "remote_control", "clear_snapshot_on_clean_exit", "1"), 1) ? true : false
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
    RC_LAST_SETTINGS_SEEN_REVISION := RC_ToIntRange(
        RC_IniReadSafe(cfgPath, "remote_control", "last_settings_seen_revision", "0"), 0, 0, 2147483647)
    RC_LAST_SETTINGS_APPLIED_REVISION := RC_ToIntRange(
        RC_IniReadSafe(cfgPath, "remote_control", "applied_settings_revision", "0"), 0, 0, 2147483647)

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
        RC_ProcessRemoteSettings(resp)
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

RC_Shutdown(cleanFinalExit := false) {
    global RC_ENABLED, RC_CLEAR_SNAPSHOT_ON_CLEAN_EXIT
    if !RC_ENABLED
        return

    try SetTimer(RC_HeartbeatTick, 0)
    try SetTimer(RC_PollCommandTick, 0)
    RC_PatchClientState("OFFLINE", true)
    if (cleanFinalExit && RC_CLEAR_SNAPSHOT_ON_CLEAN_EXIT)
        RC_DeleteRuntimeSnapshot()
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

RC_BuildStringArrayJson(values) {
    json := "["
    if IsObject(values) {
        for idx, value in values {
            if (idx > 1)
                json .= ","
            json .= '"' RC_JsonEsc(Trim(value, " `t`r`n")) '"'
        }
    }
    return json "]"
}

RC_PublishRuntimeSnapshot(dataUri, capturedAt, reason := "", width := 0, height := 0) {
    global RC_ENABLED, RC_UID
    if !RC_ENABLED
        return false
    ; 單張硬上限配合每 60 秒節流，讓單一可見總覽頁即使全天開啟，
    ; 仍對 Firestore 免費層每月 10 GiB outbound 留有餘裕。
    if (dataUri = "" || StrLen(dataUri) > 140000) {
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

RC_DeleteRuntimeSnapshot() {
    global RC_ENABLED
    if !RC_ENABLED
        return false

    r := RC_HttpRequest("DELETE", RC_ClientMediaDocUrl())
    ; 文件原本就不存在也視為已清理，避免正常關閉出現假警告。
    if (r.ok || r.status = 404) {
        RC_Log("Clean shutdown: latest Firestore snapshot removed")
        return true
    }

    RC_Log("Clean shutdown snapshot cleanup failed: " r.msg, "WARN")
    return false
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

    ; 遠端設定是持久 desired revision，不依賴一次性 command nonce。
    ; 因此裝置離線時儲存的設定，下一次啟動仍會套用。
    RC_ProcessRemoteSettings(resp)

    desired := RC_JsonGetString(resp, "desiredState")
    if (desired = "")
        desired := "RUN"

    nonce := RC_JsonGetInteger(resp, "nonce", 0)
    if (nonce <= RC_LAST_NONCE)
        return

    requestedServerIndex := RC_JsonGetInteger(resp, "requestedServerIndex", 0)
    requestedServerName := RC_JsonGetString(resp, "requestedServerName")
    RC_LAST_NONCE := nonce
    RC_ApplyRemoteState(desired, nonce, {
        serverIndex: requestedServerIndex,
        serverName: requestedServerName
    })
}

RC_ProcessRemoteSettings(resp) {
    global RC_ON_SETTINGS_CHANGED, RC_CFG_PATH
    global RC_LAST_SETTINGS_SEEN_REVISION, RC_LAST_SETTINGS_APPLIED_REVISION

    revision := RC_JsonGetInteger(resp, "desiredSettingsRevision", 0)
    if (revision <= 0 || revision <= RC_LAST_SETTINGS_SEEN_REVISION)
        return

    settings := {
        revision: revision,
        schemaVersion: RC_JsonGetInteger(resp, "desiredSettingsSchemaVersion", 1),
        serverScheduleEnabled: RC_JsonGetBoolean(resp, "desiredServerScheduleEnabled", false),
        serverScheduleList: RC_JsonGetString(resp, "desiredServerScheduleList"),
        mailNotifyEnabled: RC_JsonGetBoolean(resp, "desiredMailNotifyEnabled", false),
        runtimeDiagnosticsEnabled: RC_JsonGetBoolean(resp, "desiredRuntimeDiagnosticsEnabled", true),
        runtimeDiagnosticsIntervalSec: RC_JsonGetInteger(resp, "desiredRuntimeDiagnosticsIntervalSec", 60),
        runtimeDiagnosticsErrorKeepCount: RC_JsonGetInteger(resp, "desiredRuntimeDiagnosticsErrorKeepCount", 30),
        maxRestartCount: RC_JsonGetInteger(resp, "desiredMaxRestartCount", 10)
    }

    resultCode := "REJECTED"
    resultDetail := "裝置未完成遠端設定處理"
    applied := false
    Critical "On"
    try {
        if (settings.schemaVersion != 1) {
            resultCode := "UNSUPPORTED_SCHEMA"
            resultDetail := "不支援的遠端設定格式版本：" settings.schemaVersion
        } else if (RC_ON_SETTINGS_CHANGED = "") {
            resultCode := "NO_HANDLER"
            resultDetail := "裝置未註冊遠端設定處理器"
        } else {
            try callbackResult := %RC_ON_SETTINGS_CHANGED%(settings)
            catch as e
                callbackResult := { code: "HANDLER_ERROR", detail: e.Message, applied: false }

            if IsObject(callbackResult) {
                if callbackResult.HasOwnProp("code") && Trim(callbackResult.code, " `t`r`n") != ""
                    resultCode := StrUpper(Trim(callbackResult.code, " `t`r`n"))
                if callbackResult.HasOwnProp("detail") && Trim(callbackResult.detail, " `t`r`n") != ""
                    resultDetail := Trim(callbackResult.detail, " `t`r`n")
                if callbackResult.HasOwnProp("applied")
                    applied := callbackResult.applied ? true : false
            }
        }

        RC_LAST_SETTINGS_SEEN_REVISION := revision
        try IniWrite(revision, RC_CFG_PATH, "remote_control", "last_settings_seen_revision")
        if applied {
            RC_LAST_SETTINGS_APPLIED_REVISION := revision
            try IniWrite(revision, RC_CFG_PATH, "remote_control", "applied_settings_revision")
        }
        ackAt := RC_UnixMs()
        safeDetail := SubStr(StrReplace(StrReplace(resultDetail, "`r", " "), "`n", " "), 1, 800)
        try IniWrite(revision, RC_CFG_PATH, "remote_control", "last_settings_ack_revision")
        try IniWrite(resultCode, RC_CFG_PATH, "remote_control", "last_settings_ack_result")
        try IniWrite(safeDetail, RC_CFG_PATH, "remote_control", "last_settings_ack_detail")
        try IniWrite(applied ? 1 : 0, RC_CFG_PATH, "remote_control", "last_settings_ack_applied")
        try IniWrite(ackAt, RC_CFG_PATH, "remote_control", "last_settings_ack_at")
        RC_PatchSettingsAck(revision, resultCode, safeDetail, applied, ackAt)
    } finally {
        Critical "Off"
    }
    RC_Log("Remote settings handled: revision=" revision " result=" resultCode " applied=" (applied ? "1" : "0") " detail=" resultDetail)
}

RC_ApplyRemoteState(desired, nonce, command := "") {
    global RC_REMOTE_DESIRED_STATE, RC_ON_STATE_CHANGED, RC_CFG_PATH
    d := StrUpper(Trim(desired, " `t`r`n"))
    if (d != "RUN" && d != "PAUSE" && d != "STOP" && d != "SWITCH_SERVER")
        d := "RUN"

    RC_REMOTE_DESIRED_STATE := d

    ; 命令游標先持久化，避免切服重啟後重新套用同一筆動作命令。
    try IniWrite(nonce, RC_CFG_PATH, "remote_control", "last_nonce")

    if (d = "SWITCH_SERVER") {
        ; 切服是一次性動作，不把 client 執行狀態改成 SWITCH_SERVER。
        ; callback 只負責驗證、落盤並排程延後切服；ACK 必須在真正關閉前送出。
        resultCode := "HANDLER_ERROR"
        resultDetail := "裝置未完成切服命令處理"
        Critical "On"
        try {
            if (RC_ON_STATE_CHANGED = "") {
                resultCode := "NO_HANDLER"
                resultDetail := "裝置未註冊切服處理器"
            } else {
                try result := %RC_ON_STATE_CHANGED%(d, command)
                catch as e
                    result := { code: "HANDLER_ERROR", detail: e.Message }

                if IsObject(result) {
                    if result.HasOwnProp("code") && Trim(result.code, " `t`r`n") != ""
                        resultCode := StrUpper(Trim(result.code, " `t`r`n"))
                    if result.HasOwnProp("detail") && Trim(result.detail, " `t`r`n") != ""
                        resultDetail := Trim(result.detail, " `t`r`n")
                }
            }

            serverIndex := IsObject(command) && command.HasOwnProp("serverIndex") ? command.serverIndex : 0
            serverName := IsObject(command) && command.HasOwnProp("serverName") ? command.serverName : ""
            RC_PatchCommandAck(nonce, d, resultCode, resultDetail, serverIndex, serverName)
        } finally {
            Critical "Off"
        }
        RC_Log("Remote switch command handled: nonce=" nonce " result=" resultCode " detail=" resultDetail)
        return
    }

    RC_SetPausedFlag(d = "PAUSE")

    ; 命令套用後立即同步狀態，避免要等下一次心跳才反映在網頁。
    RC_PatchClientState(d, false)

    ; 先回 ACK，避免 STOP 直接觸發退出時遺失回覆。
    RC_PatchCommandAck(nonce, d, "APPLIED", "命令已套用")

    if (RC_ON_STATE_CHANGED != "") {
        try %RC_ON_STATE_CHANGED%(d, command)
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

RC_ReadEffectiveRemoteSettings() {
    global RC_CFG_PATH, RC_LAST_SETTINGS_APPLIED_REVISION

    mailPass := Trim(RC_IniReadSafe(RC_CFG_PATH, "mail_notify", "smtp_pass", ""), " `t`r`n")
    if (mailPass = "")
        mailPass := Trim(RC_IniReadSafe(RC_CFG_PATH, "mail_notify", "smtp_password", ""), " `t`r`n")
    mailConfigured := (
        Trim(RC_IniReadSafe(RC_CFG_PATH, "mail_notify", "smtp_host", ""), " `t`r`n") != ""
        && Trim(RC_IniReadSafe(RC_CFG_PATH, "mail_notify", "smtp_port", ""), " `t`r`n") ~= "^\d+$"
        && Trim(RC_IniReadSafe(RC_CFG_PATH, "mail_notify", "smtp_user", ""), " `t`r`n") != ""
        && mailPass != ""
        && Trim(RC_IniReadSafe(RC_CFG_PATH, "mail_notify", "from", ""), " `t`r`n") != ""
        && Trim(RC_IniReadSafe(RC_CFG_PATH, "mail_notify", "to", ""), " `t`r`n") != ""
    )

    return {
        revision: RC_LAST_SETTINGS_APPLIED_REVISION,
        serverScheduleEnabled: RC_ParseBool01(
            RC_IniReadSafe(RC_CFG_PATH, "server_schedule", "enabled", "0"), 0) ? true : false,
        serverScheduleList: Trim(
            RC_IniReadSafe(RC_CFG_PATH, "server_schedule", "list", ""), " `t`r`n"),
        mailNotifyEnabled: RC_ParseBool01(
            RC_IniReadSafe(RC_CFG_PATH, "mail_notify", "send_enabled", "1"), 1) ? true : false,
        mailNotifyConfigured: mailConfigured ? true : false,
        runtimeDiagnosticsEnabled: RC_ParseBool01(
            RC_IniReadSafe(RC_CFG_PATH, "runtime_diagnostics", "enabled", "1"), 1) ? true : false,
        runtimeDiagnosticsIntervalSec: RC_ToIntRange(
            RC_IniReadSafe(RC_CFG_PATH, "runtime_diagnostics", "snapshot_interval_sec", "60"), 60, 60, 600),
        runtimeDiagnosticsErrorKeepCount: RC_ToIntRange(
            RC_IniReadSafe(RC_CFG_PATH, "runtime_diagnostics", "error_keep_count", "30"), 30, 5, 200),
        maxRestartCount: RC_ToIntRange(
            RC_IniReadSafe(RC_CFG_PATH, "restart_tracking", "max_restart_count", "10"), 10, 1, 50),
        lastAckRevision: RC_ToIntRange(
            RC_IniReadSafe(RC_CFG_PATH, "remote_control", "last_settings_ack_revision", "0"), 0, 0, 2147483647),
        lastAckResult: Trim(
            RC_IniReadSafe(RC_CFG_PATH, "remote_control", "last_settings_ack_result", ""), " `t`r`n"),
        lastAckDetail: Trim(
            RC_IniReadSafe(RC_CFG_PATH, "remote_control", "last_settings_ack_detail", ""), " `t`r`n"),
        lastAckApplied: RC_ParseBool01(
            RC_IniReadSafe(RC_CFG_PATH, "remote_control", "last_settings_ack_applied", "0"), 0) ? true : false,
        lastAckAt: RC_ToIntRange(
            RC_IniReadSafe(RC_CFG_PATH, "remote_control", "last_settings_ack_at", "0"), 0, 0, 9999999999999)
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
    serverScheduleJson := RC_BuildStringArrayJson(SERVER_SCHEDULE_LIST)
    currentServerLabel := currentServer
    if (serverTotal > 1 && currentServer != "")
        currentServerLabel := serverIndex "/" serverTotal " | " currentServer
    recentEventsJson := RC_BuildRecentEventsJson()
    recording := RC_ReadRecordingStatus()
    effectiveSettings := RC_ReadEffectiveRemoteSettings()
    recordingActive := __SCREEN_RECORDING_ACTIVE ? true : false
    recordingDetail := SubStr(recording.detail, 1, 1000)

    body := "{"
    body .= '"fields":{'
    body .= '"docKind":{"stringValue":"client"},'
    body .= '"schemaVersion":{"integerValue":"4"},'
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
    body .= '"serverScheduleEnabled":{"booleanValue":' (SERVER_SCHEDULE_ENABLED ? "true" : "false") '},'
    body .= '"serverScheduleJson":{"stringValue":"' RC_JsonEsc(serverScheduleJson) '"},'
    body .= '"remoteSettingsSchemaVersion":{"integerValue":"1"},'
    body .= '"effectiveSettingsRevision":{"integerValue":"' effectiveSettings.revision '"},'
    body .= '"effectiveServerScheduleEnabled":{"booleanValue":' (effectiveSettings.serverScheduleEnabled ? "true" : "false") '},'
    body .= '"effectiveServerScheduleList":{"stringValue":"' RC_JsonEsc(effectiveSettings.serverScheduleList) '"},'
    body .= '"effectiveMailNotifyEnabled":{"booleanValue":' (effectiveSettings.mailNotifyEnabled ? "true" : "false") '},'
    body .= '"mailNotifyConfigured":{"booleanValue":' (effectiveSettings.mailNotifyConfigured ? "true" : "false") '},'
    body .= '"effectiveRuntimeDiagnosticsEnabled":{"booleanValue":' (effectiveSettings.runtimeDiagnosticsEnabled ? "true" : "false") '},'
    body .= '"effectiveRuntimeDiagnosticsIntervalSec":{"integerValue":"' effectiveSettings.runtimeDiagnosticsIntervalSec '"},'
    body .= '"effectiveRuntimeDiagnosticsErrorKeepCount":{"integerValue":"' effectiveSettings.runtimeDiagnosticsErrorKeepCount '"},'
    body .= '"effectiveMaxRestartCount":{"integerValue":"' effectiveSettings.maxRestartCount '"},'
    body .= '"lastSettingsAckRevision":{"integerValue":"' effectiveSettings.lastAckRevision '"},'
    body .= '"lastSettingsAckResult":{"stringValue":"' RC_JsonEsc(effectiveSettings.lastAckResult) '"},'
    body .= '"lastSettingsAckDetail":{"stringValue":"' RC_JsonEsc(effectiveSettings.lastAckDetail) '"},'
    body .= '"lastSettingsAckApplied":{"booleanValue":' (effectiveSettings.lastAckApplied ? "true" : "false") '},'
    body .= '"lastSettingsAckAt":{"integerValue":"' effectiveSettings.lastAckAt '"},'
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
    url .= "&updateMask.fieldPaths=serverScheduleEnabled"
    url .= "&updateMask.fieldPaths=serverScheduleJson"
    url .= "&updateMask.fieldPaths=remoteSettingsSchemaVersion"
    url .= "&updateMask.fieldPaths=effectiveSettingsRevision"
    url .= "&updateMask.fieldPaths=effectiveServerScheduleEnabled"
    url .= "&updateMask.fieldPaths=effectiveServerScheduleList"
    url .= "&updateMask.fieldPaths=effectiveMailNotifyEnabled"
    url .= "&updateMask.fieldPaths=mailNotifyConfigured"
    url .= "&updateMask.fieldPaths=effectiveRuntimeDiagnosticsEnabled"
    url .= "&updateMask.fieldPaths=effectiveRuntimeDiagnosticsIntervalSec"
    url .= "&updateMask.fieldPaths=effectiveRuntimeDiagnosticsErrorKeepCount"
    url .= "&updateMask.fieldPaths=effectiveMaxRestartCount"
    url .= "&updateMask.fieldPaths=lastSettingsAckRevision"
    url .= "&updateMask.fieldPaths=lastSettingsAckResult"
    url .= "&updateMask.fieldPaths=lastSettingsAckDetail"
    url .= "&updateMask.fieldPaths=lastSettingsAckApplied"
    url .= "&updateMask.fieldPaths=lastSettingsAckAt"
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

RC_PatchCommandAck(nonce, stateApplied, resultCode := "APPLIED", resultDetail := "", serverIndex := 0, serverName := "") {
    nowMs := RC_UnixMs()
    safeServerIndex := 0
    try safeServerIndex := Max(0, Integer(serverIndex))
    body := "{"
    body .= '"fields":{'
    body .= '"lastAckNonce":{"integerValue":"' nonce '"},'
    body .= '"lastAckState":{"stringValue":"' RC_JsonEsc(stateApplied) '"},'
    body .= '"lastAckResult":{"stringValue":"' RC_JsonEsc(resultCode) '"},'
    body .= '"lastAckDetail":{"stringValue":"' RC_JsonEsc(SubStr(resultDetail, 1, 600)) '"},'
    body .= '"lastAckServerIndex":{"integerValue":"' safeServerIndex '"},'
    body .= '"lastAckServerName":{"stringValue":"' RC_JsonEsc(serverName) '"},'
    body .= '"lastAckAt":{"integerValue":"' nowMs '"}'
    body .= "}"
    body .= "}"

    url := RC_ClientDocUrl()
    url .= "&updateMask.fieldPaths=lastAckNonce"
    url .= "&updateMask.fieldPaths=lastAckState"
    url .= "&updateMask.fieldPaths=lastAckResult"
    url .= "&updateMask.fieldPaths=lastAckDetail"
    url .= "&updateMask.fieldPaths=lastAckServerIndex"
    url .= "&updateMask.fieldPaths=lastAckServerName"
    url .= "&updateMask.fieldPaths=lastAckAt"
    url .= "&mask.fieldPaths=lastAckAt"

    r := RC_HttpRequest("PATCH", url, body)
    if !r.ok
        RC_Log("RemoteControl ack patch failed: " r.msg, "WARN")
}

RC_PatchSettingsAck(revision, resultCode, resultDetail, applied, ackAt := 0) {
    global RC_LAST_SETTINGS_APPLIED_REVISION
    global CURRENT_SERVER_TARGET, SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_INDEX, SERVER_SCHEDULE_LIST
    nowMs := (ackAt > 0 ? ackAt : RC_UnixMs())
    effectiveSettings := RC_ReadEffectiveRemoteSettings()
    currentServer := Trim(CURRENT_SERVER_TARGET, " `t`r`n")
    serverIndex := (SERVER_SCHEDULE_ENABLED && SERVER_SCHEDULE_INDEX > 0 ? SERVER_SCHEDULE_INDEX : 0)
    serverTotal := (SERVER_SCHEDULE_ENABLED ? SERVER_SCHEDULE_LIST.Length : 0)
    currentServerLabel := currentServer
    if (serverTotal > 1 && serverIndex > 0 && currentServer != "")
        currentServerLabel := serverIndex "/" serverTotal " | " currentServer
    serverScheduleJson := RC_BuildStringArrayJson(SERVER_SCHEDULE_LIST)
    body := "{"
    body .= '"fields":{'
    body .= '"lastSettingsAckRevision":{"integerValue":"' revision '"},'
    body .= '"lastSettingsAckResult":{"stringValue":"' RC_JsonEsc(resultCode) '"},'
    body .= '"lastSettingsAckDetail":{"stringValue":"' RC_JsonEsc(SubStr(resultDetail, 1, 800)) '"},'
    body .= '"lastSettingsAckApplied":{"booleanValue":' (applied ? "true" : "false") '},'
    body .= '"lastSettingsAckAt":{"integerValue":"' nowMs '"},'
    body .= '"effectiveSettingsRevision":{"integerValue":"' RC_LAST_SETTINGS_APPLIED_REVISION '"},'
    body .= '"effectiveServerScheduleEnabled":{"booleanValue":' (effectiveSettings.serverScheduleEnabled ? "true" : "false") '},'
    body .= '"effectiveServerScheduleList":{"stringValue":"' RC_JsonEsc(effectiveSettings.serverScheduleList) '"},'
    body .= '"effectiveMailNotifyEnabled":{"booleanValue":' (effectiveSettings.mailNotifyEnabled ? "true" : "false") '},'
    body .= '"mailNotifyConfigured":{"booleanValue":' (effectiveSettings.mailNotifyConfigured ? "true" : "false") '},'
    body .= '"effectiveRuntimeDiagnosticsEnabled":{"booleanValue":' (effectiveSettings.runtimeDiagnosticsEnabled ? "true" : "false") '},'
    body .= '"effectiveRuntimeDiagnosticsIntervalSec":{"integerValue":"' effectiveSettings.runtimeDiagnosticsIntervalSec '"},'
    body .= '"effectiveRuntimeDiagnosticsErrorKeepCount":{"integerValue":"' effectiveSettings.runtimeDiagnosticsErrorKeepCount '"},'
    body .= '"effectiveMaxRestartCount":{"integerValue":"' effectiveSettings.maxRestartCount '"},'
    body .= '"serverScheduleEnabled":{"booleanValue":' (SERVER_SCHEDULE_ENABLED ? "true" : "false") '},'
    body .= '"serverScheduleJson":{"stringValue":"' RC_JsonEsc(serverScheduleJson) '"},'
    body .= '"currentServerIndex":{"integerValue":"' serverIndex '"},'
    body .= '"currentServerTotal":{"integerValue":"' serverTotal '"},'
    body .= '"currentServerLabel":{"stringValue":"' RC_JsonEsc(currentServerLabel) '"}'
    body .= "}"
    body .= "}"

    url := RC_ClientDocUrl()
    url .= "&updateMask.fieldPaths=lastSettingsAckRevision"
    url .= "&updateMask.fieldPaths=lastSettingsAckResult"
    url .= "&updateMask.fieldPaths=lastSettingsAckDetail"
    url .= "&updateMask.fieldPaths=lastSettingsAckApplied"
    url .= "&updateMask.fieldPaths=lastSettingsAckAt"
    url .= "&updateMask.fieldPaths=effectiveSettingsRevision"
    url .= "&updateMask.fieldPaths=effectiveServerScheduleEnabled"
    url .= "&updateMask.fieldPaths=effectiveServerScheduleList"
    url .= "&updateMask.fieldPaths=effectiveMailNotifyEnabled"
    url .= "&updateMask.fieldPaths=mailNotifyConfigured"
    url .= "&updateMask.fieldPaths=effectiveRuntimeDiagnosticsEnabled"
    url .= "&updateMask.fieldPaths=effectiveRuntimeDiagnosticsIntervalSec"
    url .= "&updateMask.fieldPaths=effectiveRuntimeDiagnosticsErrorKeepCount"
    url .= "&updateMask.fieldPaths=effectiveMaxRestartCount"
    url .= "&updateMask.fieldPaths=serverScheduleEnabled"
    url .= "&updateMask.fieldPaths=serverScheduleJson"
    url .= "&updateMask.fieldPaths=currentServerIndex"
    url .= "&updateMask.fieldPaths=currentServerTotal"
    url .= "&updateMask.fieldPaths=currentServerLabel"
    url .= "&mask.fieldPaths=lastSettingsAckAt"

    r := RC_HttpRequest("PATCH", url, body)
    if !r.ok
        RC_Log("RemoteControl settings ack patch failed: " r.msg, "WARN")
}

RC_FirestoreGetClientDoc() {
    ; 命令與遠端設定共用原有這一次 GET，不增加 Firestore 讀取次數。
    url := RC_ClientDocUrl()
    url .= "&mask.fieldPaths=desiredState"
    url .= "&mask.fieldPaths=nonce"
    url .= "&mask.fieldPaths=requestedServerIndex"
    url .= "&mask.fieldPaths=requestedServerName"
    url .= "&mask.fieldPaths=desiredSettingsRevision"
    url .= "&mask.fieldPaths=desiredSettingsSchemaVersion"
    url .= "&mask.fieldPaths=desiredServerScheduleEnabled"
    url .= "&mask.fieldPaths=desiredServerScheduleList"
    url .= "&mask.fieldPaths=desiredMailNotifyEnabled"
    url .= "&mask.fieldPaths=desiredRuntimeDiagnosticsEnabled"
    url .= "&mask.fieldPaths=desiredRuntimeDiagnosticsIntervalSec"
    url .= "&mask.fieldPaths=desiredRuntimeDiagnosticsErrorKeepCount"
    url .= "&mask.fieldPaths=desiredMaxRestartCount"
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

RC_JsonGetBoolean(jsonText, fieldName, defaultVal := false) {
    p := '"' fieldName '"\s*:\s*\{[^\}]*"booleanValue"\s*:\s*(true|false)'
    if RegExMatch(jsonText, p, &m)
        return StrLower(m[1]) = "true"
    return defaultVal ? true : false
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
        "clear_snapshot_on_clean_exit", "1",
        "last_nonce", "0",
        "last_settings_seen_revision", "0",
        "applied_settings_revision", "0",
        "last_settings_ack_revision", "0",
        "last_settings_ack_result", "",
        "last_settings_ack_detail", "",
        "last_settings_ack_applied", "0",
        "last_settings_ack_at", "0"
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
