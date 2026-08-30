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
global RC_COMMAND_PROCESSING_READY := false
global RC_STARTUP_PENDING_COMMAND := ""
global RC_POLL_IN_PROGRESS := false
global RC_PENDING_COMMAND_ACK := ""
global RC_ACK_RETRY_IN_PROGRESS := false
global RC_PENDING_COMMAND_CLAIM := ""
global RC_COMMAND_APPLY_IN_PROGRESS := false
global RC_ACTIVE_STOP_ACK := ""
global RC_ACTIVE_STOP_SIDE_EFFECTS_COMPLETE := false
global RC_PERSISTED_DESIRED_STATE := ""

RC_Init(cfgPath, onStateChangedCallback := "", onSettingsChangedCallback := "") {
    global RC_ENABLED, RC_PROJECT_ID, RC_API_KEY, RC_COLLECTION, RC_CFG_PATH, RC_UID, RC_DISPLAY_NAME, RC_DEVICE_ALIAS
    global RC_HEARTBEAT_INTERVAL_MS, RC_POLL_INTERVAL_MS, RC_TIMEOUT_MS
    global RC_ON_STATE_CHANGED, RC_ON_SETTINGS_CHANGED, RC_REMOTE_DESIRED_STATE, RC_CLEAR_SNAPSHOT_ON_CLEAN_EXIT
    global RC_LAST_NONCE, RC_LAST_SETTINGS_SEEN_REVISION, RC_LAST_SETTINGS_APPLIED_REVISION
    global RC_COMMAND_PROCESSING_READY, RC_STARTUP_PENDING_COMMAND, RC_PENDING_COMMAND_ACK
    global RC_PENDING_COMMAND_CLAIM, RC_PERSISTED_DESIRED_STATE

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

    RC_COMMAND_PROCESSING_READY := false
    RC_STARTUP_PENDING_COMMAND := ""
    RC_LAST_NONCE := RC_ToIntRange(RC_IniReadSafe(cfgPath, "remote_control", "last_nonce", "0"), 0, 0, 2147483647)
    RC_PERSISTED_DESIRED_STATE := RC_LoadPersistedDesiredState()
    if IsObject(RC_PERSISTED_DESIRED_STATE) {
        RC_REMOTE_DESIRED_STATE := RC_PERSISTED_DESIRED_STATE.state
        if (RC_PERSISTED_DESIRED_STATE.nonce > RC_LAST_NONCE)
            RC_PersistCommandCursorThrough(
                RC_PERSISTED_DESIRED_STATE.nonce, "startup-desired-state")
    } else {
        RC_REMOTE_DESIRED_STATE := "RUN"
        ; 首次升級沒有 journal 時，以既有啟動契約 RUN 建立 durable baseline。
        RC_SavePersistedDesiredState("RUN", RC_LAST_NONCE, "init-default")
    }
    ; runtime-ready 前不可啟動 pause-aware Sleep 閘門；否則初始化尚未開始就會
    ; 卡住，連新的 RUN nonce 都無法走到 callback。ready 時再原子啟用恢復狀態。
    RC_SetPausedFlag(false)
    RC_LAST_SETTINGS_SEEN_REVISION := RC_ToIntRange(
        RC_IniReadSafe(cfgPath, "remote_control", "last_settings_seen_revision", "0"), 0, 0, 2147483647)
    RC_LAST_SETTINGS_APPLIED_REVISION := RC_ToIntRange(
        RC_IniReadSafe(cfgPath, "remote_control", "applied_settings_revision", "0"), 0, 0, 2147483647)
    RC_PENDING_COMMAND_ACK := RC_LoadPendingCommandAck()
    RC_PENDING_COMMAND_CLAIM := RC_LoadCommandClaimJournal()
    RC_ReconcileFinalizedCommandClaimFromLocalAck("startup")

    ; 自架端沿用相同 UID、nonce journal 與 callback。初次 URL／模式由下方
    ; Firestore discovery 欄位自動帶入，不要求使用者到執行端配對。
    RCSH_Init(cfgPath)

    RC_StartupRestoreDesiredState()

    RC_Log("RemoteControl initialized. uid=" RC_UID " display=" RC_DISPLAY_NAME " collection=" RC_COLLECTION
        " poll=" RC_POLL_INTERVAL_MS "ms heartbeat=" RC_HEARTBEAT_INTERVAL_MS "ms")
    RC_Start()
    return true
}

RC_StartupRestoreDesiredState() {
    global RC_LAST_NONCE, RC_REMOTE_DESIRED_STATE, RC_CFG_PATH, RC_STARTUP_PENDING_COMMAND
    global RC_PERSISTED_DESIRED_STATE

    ; 重啟先恢復本機 durable desired state；真正的 PAUSE 閘門延到 runtime-ready。
    ; 雲端若有較新 nonce，仍排隊到伺服器排程載入後覆蓋這個狀態。
    if IsObject(RC_PERSISTED_DESIRED_STATE)
        RC_REMOTE_DESIRED_STATE := RC_PERSISTED_DESIRED_STATE.state
    else
        RC_REMOTE_DESIRED_STATE := "RUN"
    RC_SetPausedFlag(false)

    firestoreResp := RCSH_ShouldReadFirestore(true) ? RC_FirestoreGetClientDoc() : ""
    resp := RCSH_SelectControlResponse(firestoreResp)
    if (resp != "") {
        RC_ProcessRemoteSettings(resp)
        RC_QueuePendingCommandFromResponse(resp, "startup")
    }

    pendingText := IsObject(RC_STARTUP_PENDING_COMMAND)
        ? " pending=" RC_STARTUP_PENDING_COMMAND.state "#" RC_STARTUP_PENDING_COMMAND.nonce
        : ""
    RC_Log("Startup restored desired state=" RC_REMOTE_DESIRED_STATE
        " (pause gate deferred until runtime-ready). processed command cursor="
        RC_LAST_NONCE pendingText)
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
    ; STOP 的尾端 marker 會當場把 ACK durable stage；OnExit 這裡是失敗重試
    ; 與雲端 flush。提前 Reload／替換／關機沒有 marker 時仍只保留 claim。
    try RC_FinalizeActiveStopAck("shutdown", false)
    try RC_TryFlushPendingCommandAck("shutdown")
    RC_PatchClientState("OFFLINE", true)
    try RCSH_Shutdown()
    if (cleanFinalExit && RC_CLEAR_SNAPSHOT_ON_CLEAN_EXIT)
        RC_DeleteRuntimeSnapshot()
}

RC_HeartbeatTick() {
    global RC_COMMAND_PROCESSING_READY, RC_REMOTE_DESIRED_STATE, RC_REMOTE_PAUSED
    reportedState := (!RC_COMMAND_PROCESSING_READY && RC_REMOTE_DESIRED_STATE = "PAUSE")
        ? "PAUSE" : (RC_REMOTE_PAUSED ? "PAUSE" : "RUN")
    RC_PatchClientState(reportedState, false)
    RC_TryFlushPendingCommandAck("heartbeat")
}

RC_ReportRuntimeState() {
    global RC_COMMAND_PROCESSING_READY, RC_REMOTE_DESIRED_STATE, RC_REMOTE_PAUSED

    reportedState := (!RC_COMMAND_PROCESSING_READY && RC_REMOTE_DESIRED_STATE = "PAUSE")
        ? "PAUSE" : (RC_REMOTE_PAUSED ? "PAUSE" : "RUN")
    RC_PatchClientState(reportedState, false)
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

RC_PublishRuntimeSnapshot(dataUri, capturedAt, reason := "", width := 0, height := 0, level := "INFO") {
    global RC_ENABLED, RC_UID
    if !RC_ENABLED
        return false
    selfHostedOk := RCSH_IsAvailable()
        ? RCSH_PublishRuntimeSnapshot(dataUri, capturedAt, reason, width, height, level) : false
    if RCSH_IsPrimary()
        return selfHostedOk

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

    if RCSH_IsPrimary()
        return true ; 中央快照依 7 天離線保留規則清理，不在正常退出時刪除。

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
    if RCSH_IsPrimary() && !RCSH_ShouldWriteFirestore()
        return true
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
    global RC_POLL_IN_PROGRESS

    ; 此函式同時由 timer、RC_Start() 與 runtime-ready 啟用點直接呼叫。
    ; HTTP 等待期間不可讓另一個 poll 插入並重複套用同一個動作 nonce。
    acquired := false
    previousCritical := Critical("On")
    try {
        if !RC_POLL_IN_PROGRESS {
            RC_POLL_IN_PROGRESS := true
            acquired := true
        }
    } finally {
        Critical(previousCritical)
    }
    if !acquired
        return
    try RC_PollCommandTickCore()
    finally {
        previousCritical := Critical("On")
        try RC_POLL_IN_PROGRESS := false
        finally Critical(previousCritical)
    }
}

RC_PollCommandTickCore() {
    global RC_ENABLED, RC_LAST_NONCE, RC_LAST_ERROR_MSG, RC_COMMAND_PROCESSING_READY
    global __RESTART_IN_PROGRESS, __NEXTSERVER_RESTART
    if !RC_ENABLED
        return

    ; 只有存在未送達 ACK 時才多做一次 PATCH；一般情況不增加 Firestore 用量。
    RC_TryFlushPendingCommandAck("poll")

    ; 舊程序已進入重啟／切服關閉階段時，不可再把新命令抓下來回 BUSY 並推進 nonce。
    ; 保留雲端命令給接手的新程序，由啟動排隊機制在排程載入後執行。
    if (__RESTART_IN_PROGRESS || __NEXTSERVER_RESTART)
        return

    firestoreResp := RCSH_ShouldReadFirestore(false) ? RC_FirestoreGetClientDoc() : ""
    resp := RCSH_SelectControlResponse(firestoreResp)
    if (resp = "")
        return

    ; 遠端設定是持久 desired revision，不依賴一次性 command nonce。
    ; 因此裝置離線時儲存的設定，下一次啟動仍會套用。
    RC_ProcessRemoteSettings(resp)

    ; Firestore 的 ACK 是跨安裝／設定檔回復後仍可信的已處理基準。
    ; 先與本機游標對帳，避免已 ACK 的舊 STOP／PAUSE／切服命令被重新套用。
    RC_ReconcileCommandCursorFromResponse(resp, "poll")

    ; GET 是可讓出執行緒的網路操作。若等待回應期間已進入重啟／切服，
    ; 舊程序不可再排隊、claim 或 ACK 新命令，必須留給接手的新程序。
    if (__RESTART_IN_PROGRESS || __NEXTSERVER_RESTART) {
        RC_Log("Skipped command after GET because process entered restart handoff")
        return
    }

    if !RC_COMMAND_PROCESSING_READY {
        RC_QueuePendingCommandFromResponse(resp, "startup-wait")
        return
    }

    desired := RC_JsonGetString(resp, "desiredState")
    if (desired = "")
        desired := "RUN"

    nonce := RC_JsonGetInteger(resp, "nonce", 0)
    if (nonce <= RC_LAST_NONCE) {
        recovery := RC_GetRecoverableCommandClaim(resp, "runtime-poll")
        if IsObject(recovery) {
            RC_Log("Recovering claimed command after interrupted process: state="
                recovery.state " nonce=" recovery.nonce, "WARN")
            RC_ApplyRemoteState(recovery.state, recovery.nonce, {
                serverIndex: recovery.serverIndex,
                serverName: recovery.serverName
            }, true)
        }
        return
    }

    requestedServerIndex := RC_JsonGetInteger(resp, "requestedServerIndex", 0)
    requestedServerName := RC_JsonGetString(resp, "requestedServerName")
    RC_ApplyRemoteState(desired, nonce, {
        serverIndex: requestedServerIndex,
        serverName: requestedServerName
    })
}

RC_QueuePendingCommandFromResponse(resp, source := "startup") {
    global RC_LAST_NONCE, RC_STARTUP_PENDING_COMMAND

    RC_ReconcileCommandCursorFromResponse(resp, source)
    recovery := RC_GetRecoverableCommandClaim(resp, source)
    if IsObject(recovery) {
        RC_STARTUP_PENDING_COMMAND := recovery
        RC_Log("Queued interrupted claimed command for recovery: source=" source
            " state=" recovery.state " nonce=" recovery.nonce, "WARN")
        return true
    }
    nonce := RC_JsonGetInteger(resp, "nonce", 0)
    if (nonce <= RC_LAST_NONCE)
        return false
    if (IsObject(RC_STARTUP_PENDING_COMMAND) && RC_STARTUP_PENDING_COMMAND.nonce >= nonce)
        return true

    desired := RC_JsonGetString(resp, "desiredState")
    if (desired = "")
        desired := "RUN"
    RC_STARTUP_PENDING_COMMAND := {
        state: desired,
        nonce: nonce,
        serverIndex: RC_JsonGetInteger(resp, "requestedServerIndex", 0),
        serverName: RC_JsonGetString(resp, "requestedServerName"),
        recoverClaim: false
    }
    RC_Log("Queued command until runtime ready: source=" source " state=" desired " nonce=" nonce)
    return true
}

RC_ReconcileCommandCursorFromResponse(resp, source := "poll") {
    global RC_LAST_NONCE

    remoteNonce := RC_JsonGetInteger(resp, "nonce", 0)
    ackNonce := RC_JsonGetInteger(resp, "lastAckNonce", 0)

    ; lastAckNonce 理論上不得超過目前命令 nonce。若雲端資料不一致，不把
    ; 本機游標推到未存在的命令之後，避免吞掉下一筆有效命令。
    if (ackNonce > remoteNonce) {
        RC_Log("Ignored invalid cloud ACK cursor: source=" source
            " ack=" ackNonce " command=" remoteNonce " local=" RC_LAST_NONCE, "WARN")
        return false
    }

    RC_ReconcileCommandClaimFromCloud(resp, source)
    if (ackNonce <= 0)
        return false

    ; 即使本機已經 claim 同一 nonce，也要先用有效的雲端 ACK 清掉 pending。
    ; 可處理 PATCH 已在伺服器成功、但客戶端遺失回應的情況，避免永久重送。
    pendingCleared := RC_ReconcilePendingCommandAckFromCloud(resp, ackNonce, source)
    if (ackNonce <= RC_LAST_NONCE)
        return pendingCleared

    oldNonce := RC_LAST_NONCE
    cursorPersisted := RC_PersistCommandCursorThrough(ackNonce, source "-cloud-ack")
    RC_Log("Command cursor reconciled from cloud ACK: source=" source
        " local=" oldNonce " ack=" ackNonce " command=" remoteNonce
        " durable=" (cursorPersisted ? "1" : "0"), cursorPersisted ? "INFO" : "ERROR")
    return cursorPersisted
}

RC_PersistedDesiredStateJournalPath() {
    global RC_CFG_PATH
    return RC_CFG_PATH ".remote_desired_state.ini"
}

RC_NormalizePersistedDesiredState(state, nonce := 0, updatedAt := 0) {
    normalizedState := StrUpper(Trim(state, " `t`r`n"))
    if (normalizedState != "RUN" && normalizedState != "PAUSE")
        return ""
    safeUpdatedAt := updatedAt
    try safeUpdatedAt := Integer(updatedAt)
    if (safeUpdatedAt <= 0)
        safeUpdatedAt := RC_UnixMs()
    return {
        state: normalizedState,
        nonce: RC_ToIntRange(nonce, 0, 0, 2147483647),
        updatedAt: safeUpdatedAt
    }
}

RC_LoadPersistedDesiredState() {
    path := RC_PersistedDesiredStateJournalPath()
    if !FileExist(path)
        return ""
    section := "desired_state"
    return RC_NormalizePersistedDesiredState(
        RC_IniReadSafe(path, section, "state", ""),
        RC_IniReadSafe(path, section, "nonce", "0"),
        RC_IniReadSafe(path, section, "updated_at", "0"))
}

RC_AcquirePersistedDesiredStateMutex(timeoutMs := 3000) {
    global RC_UID
    safeUid := RegExReplace(RC_UID, "[^A-Za-z0-9_-]", "_")
    if (safeUid = "")
        safeUid := "default"
    mutexName := "Local\OKWW_RemoteDesired_" SubStr(safeUid, 1, 120)
    hMutex := DllCall("kernel32\CreateMutexW", "ptr", 0, "int", false,
        "str", mutexName, "ptr")
    if !hMutex
        return 0
    waitResult := DllCall("kernel32\WaitForSingleObject", "ptr", hMutex,
        "uint", Max(0, timeoutMs), "uint")
    if (waitResult = 0 || waitResult = 0x80) ; WAIT_OBJECT_0 / WAIT_ABANDONED
        return hMutex
    DllCall("kernel32\CloseHandle", "ptr", hMutex)
    return 0
}

RC_ReleasePersistedDesiredStateMutex(hMutex) {
    if !hMutex
        return
    try DllCall("kernel32\ReleaseMutex", "ptr", hMutex)
    try DllCall("kernel32\CloseHandle", "ptr", hMutex)
}

RC_SavePersistedDesiredState(state, nonce := 0, source := "command") {
    global RC_PERSISTED_DESIRED_STATE

    desired := RC_NormalizePersistedDesiredState(state, nonce)
    if !IsObject(desired)
        return false

    path := RC_PersistedDesiredStateJournalPath()
    tempPath := path ".tmp_" DllCall("kernel32\GetCurrentProcessId", "uint")
        . "_" A_TickCount
    section := "desired_state"
    hMutex := RC_AcquirePersistedDesiredStateMutex()
    if !hMutex {
        RC_Log("Timed out acquiring desired-state mutex: source=" source
            " state=" desired.state " nonce=" desired.nonce, "ERROR")
        return false
    }
    previousCritical := Critical("On")
    try {
        diskDesired := RC_LoadPersistedDesiredState()
        allowEqualOverride := InStr(source, "fresh") > 0
        if IsObject(diskDesired) {
            if (desired.nonce < diskDesired.nonce
                || (desired.nonce = diskDesired.nonce
                    && desired.state != diskDesired.state && !allowEqualOverride)) {
                RC_PERSISTED_DESIRED_STATE := diskDesired
                RC_Log("Refused stale desired-state overwrite: source=" source
                    " incoming=" desired.state "#" desired.nonce
                    " current=" diskDesired.state "#" diskDesired.nonce, "WARN")
                return false
            }
        }
        try FileDelete(tempPath)
        IniWrite desired.state, tempPath, section, "state"
        IniWrite desired.updatedAt, tempPath, section, "updated_at"
        ; nonce 最後提交；只會原子替換完整 journal。
        IniWrite desired.nonce, tempPath, section, "nonce"
        FileMove(tempPath, path, 1)
        RC_PERSISTED_DESIRED_STATE := desired
        RC_Log("Persisted desired state: source=" source " state=" desired.state
            " nonce=" desired.nonce)
        return true
    } catch as e {
        try FileDelete(tempPath)
        RC_Log("Failed to persist desired state; command claim retained: source=" source
            " state=" desired.state " nonce=" desired.nonce " error=" e.Message, "ERROR")
        return false
    } finally {
        Critical(previousCritical)
        RC_ReleasePersistedDesiredStateMutex(hMutex)
    }
}

RC_IsDesiredStateGenerationCurrent(state, nonce := 0) {
    global RC_PERSISTED_DESIRED_STATE
    normalizedState := StrUpper(Trim(state, " `t`r`n"))
    safeNonce := RC_ToIntRange(nonce, 0, 0, 2147483647)
    ; UI 輸入前必須讀 shared journal，而不只信本程序記憶體；重啟 handoff 的
    ; 新程序可能已提交較新 generation，舊程序的 timer 必須立即失效。
    diskDesired := RC_LoadPersistedDesiredState()
    if IsObject(diskDesired) {
        previousCritical := Critical("On")
        try RC_PERSISTED_DESIRED_STATE := diskDesired
        finally Critical(previousCritical)
    }
    return (IsObject(diskDesired)
        && diskDesired.state = normalizedState
        && diskDesired.nonce = safeNonce)
}

RC_BeginFreshRunCycle(source := "fresh-cycle") {
    global RC_LAST_NONCE, RC_REMOTE_DESIRED_STATE
    global RC_PENDING_COMMAND_CLAIM, RC_STARTUP_PENDING_COMMAND

    ; 沒有 restart／nextserver handoff 的全新使用者啟動，是明確解除舊 PAUSE 的
    ; 本機操作。先 durable 改成 RUN，成功後才更新記憶體與 pause gate。
    diskDesired := RC_LoadPersistedDesiredState()
    freshNonce := RC_LAST_NONCE
    if (IsObject(diskDesired) && diskDesired.nonce > freshNonce)
        freshNonce := diskDesired.nonce
    if !RC_SavePersistedDesiredState("RUN", freshNonce, source)
        return false
    if (freshNonce > RC_LAST_NONCE)
        RC_LAST_NONCE := freshNonce
    if (freshNonce > 0 && !RC_PersistCommandCursorThrough(freshNonce, source))
        RC_Log("Fresh RUN is durable but command cursor persistence is pending: nonce="
            freshNonce, "ERROR")
    previousCritical := Critical("On")
    try {
        RC_REMOTE_DESIRED_STATE := "RUN"
        RC_SetPausedFlag(false)
    } finally {
        Critical(previousCritical)
    }

    ; 若上一程序已 durable 保存 RUN/PAUSE、但在 ACK／清 claim 前崩潰，這次
    ; 使用者明確開始新日循環就是對舊狀態命令的本機 supersede。留下 durable
    ; 結果後清掉舊 claim，避免 runtime-ready 永遠重試同 nonce 並被 RUN journal 擋住。
    if (IsObject(RC_PENDING_COMMAND_CLAIM)
        && (RC_PENDING_COMMAND_CLAIM.state = "RUN"
            || RC_PENDING_COMMAND_CLAIM.state = "PAUSE")
        && RC_PENDING_COMMAND_CLAIM.nonce <= RC_LAST_NONCE) {
        supersededClaim := RC_PENDING_COMMAND_CLAIM
        if RC_PatchCommandAck(supersededClaim.nonce, supersededClaim.state,
            "SUPERSEDED_BY_FRESH_RUN", "使用者正常啟動全新日循環，已明確解除先前 RUN/PAUSE 狀態") {
            cursorPersisted := RC_PersistCommandCursorThrough(
                supersededClaim.nonce, source "-superseded")
            if cursorPersisted
                RC_ClearCommandClaimThrough(supersededClaim.nonce, source "-superseded")
            else
                RC_Log("Fresh RUN supersede ACK is durable but cursor is not; claim retained for startup reconciliation: nonce="
                    supersededClaim.nonce, "ERROR")
            if (IsObject(RC_STARTUP_PENDING_COMMAND)
                && RC_STARTUP_PENDING_COMMAND.nonce = supersededClaim.nonce)
                RC_STARTUP_PENDING_COMMAND := ""
        }
    }
    RC_Log("Fresh run cycle explicitly cleared persisted PAUSE: source=" source
        " nonce=" freshNonce)
    return true
}

RC_ActivatePersistedDesiredStateAtRuntimeReady() {
    global RC_PERSISTED_DESIRED_STATE, RC_REMOTE_DESIRED_STATE, RC_REMOTE_PAUSED
    global RC_ON_STATE_CHANGED

    diskDesired := RC_LoadPersistedDesiredState()
    if IsObject(diskDesired)
        RC_PERSISTED_DESIRED_STATE := diskDesired
    if !IsObject(RC_PERSISTED_DESIRED_STATE)
        return false
    desired := RC_PERSISTED_DESIRED_STATE
    wasPaused := RC_REMOTE_PAUSED
    previousCritical := Critical("On")
    try {
        RC_REMOTE_DESIRED_STATE := desired.state
        RC_SetPausedFlag(desired.state = "PAUSE")
    } finally {
        Critical(previousCritical)
    }

    ; 新 nonce 在 fresh poll 中若已套用 PAUSE，callback 已經排過 hook；只有從
    ; 前一程序 journal 恢復、pause gate 原本尚未啟用時才補排一次 convergence。
    if (desired.state = "PAUSE" && !wasPaused && RC_ON_STATE_CHANGED != "") {
        try %RC_ON_STATE_CHANGED%("PAUSE", {
            remoteNonce: desired.nonce,
            remoteState: desired.state,
            recoveredDesired: true
        })
        catch as e
            RC_Log("Persisted PAUSE restored but background hook scheduling failed: nonce="
                desired.nonce " error=" e.Message, "WARN")
    }
    RC_Log("Activated persisted desired state at runtime-ready: state=" desired.state
        " nonce=" desired.nonce)
    return true
}

RC_NormalizeCommandClaim(nonce, state, serverIndex := 0, serverName := "", claimedAt := 0) {
    safeIndex := 0
    try safeIndex := Max(0, Integer(serverIndex))
    safeAt := claimedAt
    try safeAt := Integer(claimedAt)
    if (safeAt <= 0)
        safeAt := RC_UnixMs()
    return {
        nonce: RC_ToIntRange(nonce, 0, 0, 2147483647),
        state: SubStr(StrUpper(Trim(state, " `t`r`n")), 1, 40),
        serverIndex: safeIndex,
        serverName: SubStr(Trim(serverName, " `t`r`n"), 1, 160),
        claimedAt: safeAt
    }
}

RC_CommandClaimJournalPath() {
    global RC_CFG_PATH
    return RC_CFG_PATH ".remote_command_claim.ini"
}

RC_LoadCommandClaimJournal() {
    path := RC_CommandClaimJournalPath()
    if !FileExist(path)
        return ""
    section := "command_claim"
    nonce := RC_ToIntRange(RC_IniReadSafe(path, section, "nonce", "0"), 0, 0, 2147483647)
    if (nonce <= 0)
        return ""
    return RC_NormalizeCommandClaim(
        nonce,
        RC_IniReadSafe(path, section, "state", ""),
        RC_IniReadSafe(path, section, "server_index", "0"),
        RC_IniReadSafe(path, section, "server_name", ""),
        RC_IniReadSafe(path, section, "claimed_at", "0"))
}

RC_SaveCommandClaimJournal(nonce, state, command := "") {
    global RC_PENDING_COMMAND_CLAIM
    serverIndex := IsObject(command) && command.HasOwnProp("serverIndex") ? command.serverIndex : 0
    serverName := IsObject(command) && command.HasOwnProp("serverName") ? command.serverName : ""
    claim := RC_NormalizeCommandClaim(nonce, state, serverIndex, serverName)
    if (claim.nonce <= 0)
        return false

    path := RC_CommandClaimJournalPath()
    tempPath := path ".tmp_" DllCall("kernel32\GetCurrentProcessId", "uint") "_" A_TickCount
    section := "command_claim"
    hMutex := RC_AcquirePersistedDesiredStateMutex()
    if !hMutex {
        RC_Log("Timed out acquiring remote journal mutex for command claim: nonce="
            claim.nonce " state=" claim.state, "ERROR")
        return false
    }
    previousCritical := Critical("On")
    try {
        ; restart handoff 期間舊程序不得覆寫新程序已 claim 的較新命令。
        ; 每次都在跨程序 mutex 內重讀磁碟，不信任各程序過期的 global。
        diskClaim := RC_LoadCommandClaimJournal()
        if IsObject(diskClaim) {
            if (diskClaim.nonce >= claim.nonce) {
                RC_PENDING_COMMAND_CLAIM := diskClaim
                identity := RC_CommandClaimMatches(
                    diskClaim, claim.state, claim.nonce, claim) ? "same" : "different"
                RC_Log("Refused to overwrite occupied/newer command claim: incoming="
                    claim.state "#" claim.nonce " disk=" diskClaim.state "#" diskClaim.nonce,
                    "WARN")
                RC_Log("Command claim collision identity=" identity
                    "; existing owner must finish or a replacement process must recover it", "WARN")
                return false
            }
        }
        try FileDelete(tempPath)
        IniWrite claim.state, tempPath, section, "state"
        IniWrite claim.serverIndex, tempPath, section, "server_index"
        IniWrite claim.serverName, tempPath, section, "server_name"
        IniWrite claim.claimedAt, tempPath, section, "claimed_at"
        IniWrite claim.nonce, tempPath, section, "nonce"
        FileMove(tempPath, path, 1)
        RC_PENDING_COMMAND_CLAIM := claim
        return true
    } catch as e {
        try FileDelete(tempPath)
        RC_Log("Failed to persist command claim; command not consumed: nonce=" claim.nonce
            " state=" claim.state " error=" e.Message, "ERROR")
        return false
    } finally {
        Critical(previousCritical)
        RC_ReleasePersistedDesiredStateMutex(hMutex)
    }
}

RC_CommandClaimMatches(claim, state, nonce, command := "") {
    if !IsObject(claim) || claim.nonce != nonce || claim.state != StrUpper(state)
        return false
    if (claim.state != "SWITCH_SERVER" && claim.state != "COMPLETE_SERVER")
        return true
    serverIndex := IsObject(command) && command.HasOwnProp("serverIndex") ? command.serverIndex : 0
    serverName := IsObject(command) && command.HasOwnProp("serverName") ? command.serverName : ""
    return (claim.serverIndex = serverIndex && claim.serverName = serverName)
}

RC_ClearCommandClaimThrough(nonce, source := "complete") {
    global RC_PENDING_COMMAND_CLAIM
    path := RC_CommandClaimJournalPath()
    hMutex := RC_AcquirePersistedDesiredStateMutex()
    if !hMutex {
        RC_Log("Timed out acquiring remote journal mutex to clear command claim: source="
            source " through=" nonce, "WARN")
        return false
    }
    previousCritical := Critical("On")
    try {
        diskClaim := RC_LoadCommandClaimJournal()
        if (IsObject(diskClaim) && diskClaim.nonce > nonce) {
            RC_PENDING_COMMAND_CLAIM := diskClaim
            RC_Log("Refused to clear newer command claim from an older process: source=" source
                " through=" nonce " disk=" diskClaim.nonce, "WARN")
            return false
        }
        if (IsObject(RC_PENDING_COMMAND_CLAIM)
            && RC_PENDING_COMMAND_CLAIM.nonce > nonce) {
            ; 記憶體已知道更新且尚未落盤的 claim 時也不可向後清除。
            return false
        }
        clearedNonce := IsObject(diskClaim) ? diskClaim.nonce
            : (IsObject(RC_PENDING_COMMAND_CLAIM) ? RC_PENDING_COMMAND_CLAIM.nonce : 0)
        if FileExist(path)
            FileDelete(path)
        RC_PENDING_COMMAND_CLAIM := ""
        if (clearedNonce > 0)
            RC_Log("Cleared command claim: source=" source " nonce=" clearedNonce)
        return true
    } catch as e {
        RC_Log("Failed to clear command claim; retained for recovery: source=" source
            " error=" e.Message, "WARN")
        return false
    } finally {
        Critical(previousCritical)
        RC_ReleasePersistedDesiredStateMutex(hMutex)
    }
}

RC_ReconcileCommandClaimFromCloud(resp, source := "cloud") {
    global RC_PENDING_COMMAND_CLAIM
    if !IsObject(RC_PENDING_COMMAND_CLAIM)
        return false
    remoteNonce := RC_JsonGetInteger(resp, "nonce", 0)
    ackNonce := RC_JsonGetInteger(resp, "lastAckNonce", 0)
    if (ackNonce = RC_PENDING_COMMAND_CLAIM.nonce) {
        ackState := StrUpper(RC_JsonGetString(resp, "lastAckState"))
        ackResult := StrUpper(RC_JsonGetString(resp, "lastAckResult"))
        ackCommand := {
            serverIndex: RC_JsonGetInteger(resp, "lastAckServerIndex", 0),
            serverName: RC_JsonGetString(resp, "lastAckServerName")
        }
        if !RC_CommandClaimMatches(RC_PENDING_COMMAND_CLAIM, ackState, ackNonce, ackCommand) {
            RC_Log("Cloud ACK nonce matches claim but full command identity differs; claim retained: source="
                source " nonce=" ackNonce " ackState=" ackState, "WARN")
            return false
        }
        if ((ackState = "RUN" || ackState = "PAUSE")
            && InStr(ackResult, "ACCEPTED") = 1
            && !RC_IsDesiredStateGenerationCurrent(ackState, ackNonce)) {
            RC_Log("Cloud ACCEPTED matches claim but durable desired state does not; claim retained: source="
                source " state=" ackState " nonce=" ackNonce, "ERROR")
            return false
        }
        return RC_ClearCommandClaimThrough(ackNonce, source "-acked")
    }
    if (ackNonce > RC_PENDING_COMMAND_CLAIM.nonce)
        return RC_ClearCommandClaimThrough(ackNonce, source "-acked-newer")
    if (remoteNonce > RC_PENDING_COMMAND_CLAIM.nonce)
        return RC_ClearCommandClaimThrough(remoteNonce, source "-superseded")
    return false
}

RC_GetRecoverableCommandClaim(resp, source := "startup") {
    global RC_PENDING_COMMAND_CLAIM, RC_PENDING_COMMAND_ACK
    if !IsObject(RC_PENDING_COMMAND_CLAIM)
        return ""
    claim := RC_PENDING_COMMAND_CLAIM
    ; pending ACK 一律在 callback 已接收／錯誤結果確立後才落盤；因此相同命令
    ; 已有 durable receipt 時，即使前次恰好在刪 claim 前中斷也不可重播。
    ; PAUSE/RUN 的 ACCEPTED 只承諾軟狀態已同步、背景 UI hook 已排程，不承諾
    ; hook 已完成；但 toggle 類輸入無法在程序崩潰後判定是否已送出，重播反而
    ; 可能把狀態切反。因此協定刻意採 durable receipt，而不是假稱 exactly-once。
    if RC_IsFinalizedCommandAckForClaim(RC_PENDING_COMMAND_ACK, claim)
        return ""
    remoteNonce := RC_JsonGetInteger(resp, "nonce", 0)
    ackNonce := RC_JsonGetInteger(resp, "lastAckNonce", 0)
    if (remoteNonce != claim.nonce || ackNonce > claim.nonce)
        return ""
    if (ackNonce = claim.nonce) {
        cloudAckState := StrUpper(RC_JsonGetString(resp, "lastAckState"))
        cloudAckResult := StrUpper(RC_JsonGetString(resp, "lastAckResult"))
        cloudAckCommand := {
            serverIndex: RC_JsonGetInteger(resp, "lastAckServerIndex", 0),
            serverName: RC_JsonGetString(resp, "lastAckServerName")
        }
        if !RC_CommandClaimMatches(claim, cloudAckState, ackNonce, cloudAckCommand)
            return ""
        ; 雲端已收到 ACCEPTED、但本機 desired journal 遺失／不匹配時，receipt
        ; 本身不足以恢復狀態。允許同 claim 再走一次「先 durable desired、後 callback」；
        ; 其他完整 ACK 仍視為完成，不重播 UI 或一次性副作用。
        if !((claim.state = "RUN" || claim.state = "PAUSE")
            && InStr(cloudAckResult, "ACCEPTED") = 1
            && !RC_IsDesiredStateGenerationCurrent(claim.state, claim.nonce))
            return ""
    }
    desired := RC_JsonGetString(resp, "desiredState")
    if (desired = "")
        desired := "RUN"
    command := {
        serverIndex: RC_JsonGetInteger(resp, "requestedServerIndex", 0),
        serverName: RC_JsonGetString(resp, "requestedServerName")
    }
    if !RC_CommandClaimMatches(claim, desired, remoteNonce, command) {
        RC_Log("Command claim does not match current cloud payload; recovery withheld: source="
            source " claim=" claim.state "#" claim.nonce " cloud=" desired "#" remoteNonce, "ERROR")
        return ""
    }
    return {
        state: desired,
        nonce: remoteNonce,
        serverIndex: command.serverIndex,
        serverName: command.serverName,
        recoverClaim: true
    }
}

RC_EnableCommandProcessing() {
    global RC_COMMAND_PROCESSING_READY, RC_STARTUP_PENDING_COMMAND, RC_LAST_NONCE

    RC_COMMAND_PROCESSING_READY := true
    pending := IsObject(RC_STARTUP_PENDING_COMMAND) ? RC_STARTUP_PENDING_COMMAND : ""
    RC_STARTUP_PENDING_COMMAND := ""

    ; 啟用瞬間先重新讀一次：
    ; 1) 已被其他程序 ACK 的 pending 會被雲端 ACK 游標淘汰；
    ; 2) 排程載入期間送來的較新命令會取代較舊 pending。
    RC_PollCommandTick()

    ; GET 暫時失敗時仍保留啟動時已抓到的真正未處理命令，避免離線空窗吞令。
    if (IsObject(pending) && (pending.nonce > RC_LAST_NONCE
        || (pending.HasOwnProp("recoverClaim") && pending.recoverClaim))) {
        RC_Log("Applying queued startup command after fresh poll fallback: state="
            pending.state " nonce=" pending.nonce)
        RC_ApplyRemoteState(pending.state, pending.nonce, {
            serverIndex: pending.serverIndex,
            serverName: pending.serverName
        }, pending.HasOwnProp("recoverClaim") && pending.recoverClaim)
    }

    ; fresh poll／queued command 都完成後，才啟動由前一程序恢復的 PAUSE gate。
    ; 若其間已有較新 RUN nonce，durable desired journal 已被覆寫成 RUN，這裡不會暫停。
    RC_ActivatePersistedDesiredStateAtRuntimeReady()
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
        maxRestartCount: RC_JsonGetInteger(resp, "desiredMaxRestartCount", 10),
        liveQualityProfile: RCSH_NormalizeLiveQualityProfile(
            RC_JsonGetString(resp, "desiredLiveQualityProfile"))
    }

    resultCode := "REJECTED"
    resultDetail := "裝置未完成遠端設定處理"
    applied := false
    previousSettingsCritical := Critical("On")
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
        Critical(previousSettingsCritical)
    }
    RC_Log("Remote settings handled: revision=" revision " result=" resultCode " applied=" (applied ? "1" : "0") " detail=" resultDetail)
}

RC_ApplyRemoteState(desired, nonce, command := "", recoverClaim := false) {
    global RC_REMOTE_DESIRED_STATE, RC_REMOTE_PAUSED, RC_ON_STATE_CHANGED, RC_CFG_PATH, RC_LAST_NONCE
    global RC_PENDING_COMMAND_CLAIM, RC_COMMAND_APPLY_IN_PROGRESS
    global RC_ACTIVE_STOP_ACK, RC_ACTIVE_STOP_SIDE_EFFECTS_COMPLETE
    global __RESTART_IN_PROGRESS, __NEXTSERVER_RESTART
    d := StrUpper(Trim(desired, " `t`r`n"))
    if (d != "RUN" && d != "PAUSE" && d != "STOP" && d != "SWITCH_SERVER" && d != "COMPLETE_SERVER")
        d := "RUN"

    ; 在任何 callback／ACK／狀態副作用之前，以短 Critical 原子重驗並 claim nonce。
    ; 即使 timer 與啟動 fresh poll 在 HTTP 讓出期間交錯，也只有第一個執行緒能套用。
    claimed := false
    recoveredClaim := false
    skippedForRestart := false
    skippedForActiveApply := false
    previousCritical := Critical("On")
    try {
        if RC_COMMAND_APPLY_IN_PROGRESS {
            skippedForActiveApply := true
        } else if (__RESTART_IN_PROGRESS || __NEXTSERVER_RESTART) {
            skippedForRestart := true
        } else if (recoverClaim && nonce >= RC_LAST_NONCE
            && RC_CommandClaimMatches(RC_PENDING_COMMAND_CLAIM, d, nonce, command)) {
            if (nonce > RC_LAST_NONCE)
                RC_PersistCommandCursorThrough(nonce, "recover-claim")
            claimed := true
            recoveredClaim := true
        } else if (nonce > RC_LAST_NONCE) {
            ; journal 必須先於 last_nonce 與任何 callback 落盤；若中途硬崩，
            ; 新程序可辨識這筆未完成 claim 並安全重播，不再永久吞掉命令。
            if RC_SaveCommandClaimJournal(nonce, d, command) {
                RC_PersistCommandCursorThrough(nonce, "new-claim")
                claimed := true
            }
        }
        if claimed
            RC_COMMAND_APPLY_IN_PROGRESS := true
    } finally {
        Critical(previousCritical)
    }
    if !claimed {
        if skippedForActiveApply {
            RC_Log("Deferred duplicate command recovery while another command handler is active: state=" d
                " nonce=" nonce " cursor=" RC_LAST_NONCE)
            return false
        }
        if skippedForRestart {
            RC_Log("Deferred remote command to replacement process during restart handoff: state=" d
                " nonce=" nonce " cursor=" RC_LAST_NONCE)
            return false
        }
        RC_Log("Skipped duplicate/stale remote command before side effects: state=" d
            " nonce=" nonce " cursor=" RC_LAST_NONCE, "WARN")
        return false
    }
    try {
        if recoveredClaim
            RC_Log("Replaying interrupted claimed command: state=" d " nonce=" nonce, "WARN")

    if (d = "SWITCH_SERVER" || d = "COMPLETE_SERVER") {
        ; 切服與標記今日完成都是一次性動作，不把 client 執行狀態改成動作名稱。
        ; callback 負責驗證與持久化；切服 ACK 必須在真正關閉前送出。
        resultCode := "HANDLER_ERROR"
        resultDetail := "裝置未完成伺服器命令處理"
        previousActionCritical := Critical("On")
        try {
            if (RC_ON_STATE_CHANGED = "") {
                resultCode := "NO_HANDLER"
                resultDetail := "裝置未註冊伺服器命令處理器"
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

            if (recoveredClaim && d = "SWITCH_SERVER" && resultCode = "ALREADY_CURRENT") {
                resultCode := "RECOVERED_ALREADY_CURRENT"
                resultDetail := "中斷前的切服設定已生效；目前已位於指定伺服器，視為恢復完成"
            }

            serverIndex := IsObject(command) && command.HasOwnProp("serverIndex") ? command.serverIndex : 0
            serverName := IsObject(command) && command.HasOwnProp("serverName") ? command.serverName : ""
            if RC_PatchCommandAck(nonce, d, resultCode, resultDetail, serverIndex, serverName)
                RC_ClearCommandClaimThrough(nonce, "server-action-ack-staged")
        } finally {
            Critical(previousActionCritical)
        }
        RC_Log("Remote server action handled: state=" d " nonce=" nonce " result=" resultCode " detail=" resultDetail)
        return true
    }

    if (d = "STOP") {
        ; STOP handler 會在完整關閉流程尾端直接 ExitApp。callback 前只把最終 ACK
        ; 留在記憶體；不可先落盤、送雲端或清 claim。若此時硬崩，只有 claim 仍在，
        ; 新程序會安全重播 STOP；正常 OnExit 才把 APPLIED ACK durable finalize。
        if (RC_ON_STATE_CHANGED = "") {
            if RC_PatchCommandAck(nonce, d, "NO_HANDLER", "裝置未註冊停止命令處理器")
                RC_ClearCommandClaimThrough(nonce, "stop-no-handler-ack-staged")
            RC_Log("Remote STOP rejected: no handler nonce=" nonce, "WARN")
            return false
        }

        RC_REMOTE_DESIRED_STATE := d
        RC_SetPausedFlag(false)
        RC_PatchClientState(d, false)
        RC_ACTIVE_STOP_SIDE_EFFECTS_COMPLETE := false
        RC_ACTIVE_STOP_ACK := RC_NormalizeCommandAck(
            nonce, d, "APPLIED", "完整關閉流程已完成")
        try {
            %RC_ON_STATE_CHANGED%(d, command)
        } catch as e {
            RC_ACTIVE_STOP_ACK := ""
            RC_ACTIVE_STOP_SIDE_EFFECTS_COMPLETE := false
            if RC_PatchCommandAck(nonce, d, "HANDLER_ERROR", "停止處理器失敗：" e.Message)
                RC_ClearCommandClaimThrough(nonce, "stop-error-ack-staged")
            RC_Log("Remote STOP handler failed: nonce=" nonce " error=" e.Message, "ERROR")
            return false
        }
        ; 任意 callback return 不等於完整關閉已完成。正式 handler 在真正尾端會呼叫
        ; RC_MarkActiveStopSideEffectsComplete；重入防護也可能在沒有任何副作用時直接 return。
        ; 因此保留 active ACK 與 claim，等待明確尾端 marker durable finalize，絕不假報 APPLIED。
        RC_Log("Remote STOP handler returned before explicit shutdown-tail marker; "
            "active ACK and claim retained: nonce=" nonce, "WARN")
        return true
    }

    resultCode := "ACCEPTED"
    resultDetail := "RUN/PAUSE 軟狀態已持久保存；LRMCAI 背景同步已排程（不代表快捷鍵已完成）"
    applied := false
    desiredAlreadyActive := (recoverClaim
        && RC_IsDesiredStateGenerationCurrent(d, nonce)
        && RC_REMOTE_DESIRED_STATE = d
        && RC_REMOTE_PAUSED = (d = "PAUSE"))

    ; ACCEPTED 的 durable completion point 是 desired journal，而不是 SetTimer 或
    ; SendEvent。journal 必須先於記憶體狀態、callback 與 ACK 原子落盤；失敗時
    ; 不送 ACK、不清 claim，下一輪／下一程序才可安全重試同一 nonce。
    if !RC_SavePersistedDesiredState(d, nonce, "state-command") {
        RC_Log("Remote state command not acknowledged because desired state was not durable: state="
            d " nonce=" nonce, "ERROR")
        return false
    }

    RC_REMOTE_DESIRED_STATE := d
    RC_SetPausedFlag(d = "PAUSE")
    applied := true
    callbackCommand := IsObject(command) ? command : {}
    try callbackCommand.remoteNonce := nonce
    try callbackCommand.remoteState := d

    if desiredAlreadyActive {
        ; 同一存活程序可能只因 pending ACK 寫入失敗而在下一個 poll 進入 recovery。
        ; desired 與 pause gate 都已是同一 generation 時，只補 durable ACK，不重排
        ; F9／Ctrl+F1；新程序的 PAUSE gate 尚未啟用，因此不會誤走此捷徑。
        resultDetail := "RUN/PAUSE 軟狀態已持久保存；補送 ACK（背景同步不重複排程）"
    } else if (RC_ON_STATE_CHANGED = "") {
        resultCode := "ACCEPTED_NO_HOOK"
        resultDetail := "軟狀態已持久保存；裝置未註冊 LRMCAI 背景同步處理器"
    } else {
        try {
            callbackResult := %RC_ON_STATE_CHANGED%(d, callbackCommand)
            if IsObject(callbackResult) {
                if callbackResult.HasOwnProp("code") && Trim(callbackResult.code, " `t`r`n") != ""
                    resultCode := StrUpper(Trim(callbackResult.code, " `t`r`n"))
                if callbackResult.HasOwnProp("detail") && Trim(callbackResult.detail, " `t`r`n") != ""
                    resultDetail := Trim(callbackResult.detail, " `t`r`n")
                ; desired journal 已是 durable commit；handler 的 applied=false 只能描述
                ; 非同步 UI hook，不能回滾已保存的 RUN／PAUSE 或讓 claim 重播 toggle。
                if (callbackResult.HasOwnProp("applied") && !callbackResult.applied) {
                    resultCode := "ACCEPTED_HOOK_DEFERRED"
                    if (resultDetail = "")
                        resultDetail := "軟狀態已持久保存；LRMCAI 背景同步尚未完成"
                }
            }
        } catch as e {
            resultCode := "ACCEPTED_HOOK_ERROR"
            resultDetail := "軟狀態已持久保存；LRMCAI 背景同步排程失敗：" e.Message
        }
    }

    ; PAUSE/RUN 的 UI hook 是非同步；ACK 只確認 desired state durable，
    ; 不誤稱 F9／Ctrl+F1 已完成，也不把 callback 後的硬崩當作可安全重播點。
    RC_PatchClientState(d, false)
    if RC_PatchCommandAck(nonce, d, resultCode, resultDetail)
        RC_ClearCommandClaimThrough(nonce, "state-command-ack-staged")
    RC_Log("Remote command handled: state=" d " nonce=" nonce
        " result=" resultCode " applied=" (applied ? "1" : "0") " detail=" resultDetail,
        applied ? "INFO" : "WARN")
    return applied
    } finally {
        previousCritical := Critical("On")
        try RC_COMMAND_APPLY_IN_PROGRESS := false
        finally Critical(previousCritical)
    }
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
    stagingRoot := RuntimeFiles_RecordingStagingDir()
    statusPath := stagingRoot "\recording_status.ini"
    legacyRoot := RuntimeFiles_LegacyRecordingStagingDir()
    legacyStatus := legacyRoot != "" ? legacyRoot "\recording_status.ini" : ""
    if (legacyStatus != "" && FileExist(legacyStatus)) {
        useLegacy := !FileExist(statusPath)
        if !useLegacy {
            try useLegacy := FileGetTime(legacyStatus, "M") > FileGetTime(statusPath, "M")
        }
        if useLegacy {
            stagingRoot := legacyRoot
            statusPath := legacyStatus
        }
    }
    available := FileExist(statusPath) ? true : false
    if !available {
        return {
            available: false, state: "", detail: "", updatedMs: 0,
            localSessionDir: "", destinationDir: "", destinationSegmentsDir: "",
            finalPath: "", resultPath: "", failureStorage: "", workerLogPath: stagingRoot "\recording_worker.log",
            baseName: "", autoMerge: true, captureActive: false,
            progressCurrent: 0, progressTotal: 0, progressPercent: -1, progressUnit: ""
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
        captureActive: RC_IniReadSafe(statusPath, "recording", "capture_active", "0") = "1",
        progressCurrent: RC_ToIntRange(RC_IniReadSafe(statusPath, "recording", "progress_current", "0"), 0, 0, 9999999999999),
        progressTotal: RC_ToIntRange(RC_IniReadSafe(statusPath, "recording", "progress_total", "0"), 0, 0, 9999999999999),
        progressPercent: RC_ToIntRange(RC_IniReadSafe(statusPath, "recording", "progress_percent", "-1"), -1, -1, 100),
        progressUnit: RC_IniReadSafe(statusPath, "recording", "progress_unit", "")
    }
}

RC_ReadSelfHealingStatus() {
    global RC_CFG_PATH
    section := "self_healing"
    return {
        state: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "state", "healthy"), " `t`r`n"),
        code: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "failure_code", ""), " `t`r`n"),
        stage: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "failure_stage", ""), " `t`r`n"),
        consecutive: RC_ToIntRange(RC_IniReadSafe(RC_CFG_PATH, section,
            "consecutive_count", "0"), 0, 0, 100),
        category: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "category", ""), " `t`r`n"),
        action: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "action", ""), " `t`r`n"),
        detail: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "detail", ""), " `t`r`n"),
        nextRetryAt: RC_ToIntRange(RC_IniReadSafe(RC_CFG_PATH, section,
            "next_retry_at_unix_ms", "0"), 0, 0, 9999999999999),
        updatedAt: RC_ToIntRange(RC_IniReadSafe(RC_CFG_PATH, section,
            "updated_at_unix_ms", "0"), 0, 0, 9999999999999)
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
        liveQualityProfile: RCSH_NormalizeLiveQualityProfile(
            RC_IniReadSafe(RC_CFG_PATH, "self_hosted", "live_quality_profile", "balanced")),
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

RC_ReadServerProgress() {
    global SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_LIST

    completed := []
    cycleKey := ""
    try completed := GetCompletedServerNamesInCurrentCycle()
    try cycleKey := GetCurrentServerCycleKey()
    total := SERVER_SCHEDULE_ENABLED ? SERVER_SCHEDULE_LIST.Length : 0
    return {
        cycleKey: cycleKey,
        completed: completed,
        completedJson: RC_BuildStringArrayJson(completed),
        completedCount: completed.Length,
        allCompleted: (total > 0 && completed.Length >= total) ? true : false
    }
}

RC_ReadServerSwitchNotifyStatus() {
    global RC_CFG_PATH
    section := "server_switch_notify"
    return {
        pending: RC_IniReadSafe(RC_CFG_PATH, section, "pending", "0") = "1",
        pendingTarget: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "pending_target", ""), " `t`r`n"),
        pendingIndex: RC_ToIntRange(RC_IniReadSafe(RC_CFG_PATH, section, "pending_index", "0"), 0, 0, 100),
        pendingSource: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "pending_source", ""), " `t`r`n"),
        lastTarget: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "last_completed_target", ""), " `t`r`n"),
        lastIndex: RC_ToIntRange(RC_IniReadSafe(RC_CFG_PATH, section, "last_completed_index", "0"), 0, 0, 100),
        lastTotal: RC_ToIntRange(RC_IniReadSafe(RC_CFG_PATH, section, "last_completed_total", "0"), 0, 0, 100),
        lastSource: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "last_completed_source", ""), " `t`r`n"),
        lastCompletedAt: RC_ToIntRange(
            RC_IniReadSafe(RC_CFG_PATH, section, "last_completed_at_unix_ms", "0"), 0, 0, 9999999999999),
        lastMailResult: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "last_mail_result", ""), " `t`r`n"),
        lastMailDetail: Trim(RC_IniReadSafe(RC_CFG_PATH, section, "last_mail_detail", ""), " `t`r`n")
    }
}

RC_PatchClientState(state, isShutdown) {
    global RC_LAST_HEARTBEAT_OK, RC_LAST_ERROR_MSG
    global RC_LAST_EVENT_AT, RC_RECENT_EVENTS
    global CURRENT_STEP_NAME, CURRENT_STEP_DETAIL, CURRENT_STEP_LEVEL
    global CURRENT_SERVER_TARGET, SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_INDEX, SERVER_SCHEDULE_LIST
    global SCREEN_RECORDING_ENABLED, __SCREEN_RECORDING_ACTIVE
    nowMs := RC_UnixMs()
    recentLog := SupportLog_CurrentSummary()
    selfHostedOk := RCSH_IsAvailable() ? RCSH_SendHeartbeat(state, recentLog) : false
    if (RCSH_IsPrimary() && !RCSH_ShouldWriteFirestore())
        return selfHostedOk

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
    serverProgress := RC_ReadServerProgress()
    switchNotify := RC_ReadServerSwitchNotifyStatus()
    recordingActive := __SCREEN_RECORDING_ACTIVE ? true : false
    recordingDetail := SubStr(recording.detail, 1, 1000)
    performanceJson := PerformanceTelemetry_ReadFirestoreJson()
    performanceAvailable := performanceJson != ""

    body := "{"
    body .= '"fields":{'
    body .= '"docKind":{"stringValue":"client"},'
    body .= '"schemaVersion":{"integerValue":"7"},'
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
    body .= '"serverProgressSchemaVersion":{"integerValue":"1"},'
    body .= '"serverCycleKey":{"stringValue":"' RC_JsonEsc(serverProgress.cycleKey) '"},'
    body .= '"serverCompletedCycleJson":{"stringValue":"' RC_JsonEsc(serverProgress.completedJson) '"},'
    body .= '"serverCompletedCount":{"integerValue":"' serverProgress.completedCount '"},'
    body .= '"serverAllCompletedToday":{"booleanValue":' (serverProgress.allCompleted ? "true" : "false") '},'
    body .= '"serverSwitchNotifyPending":{"booleanValue":' (switchNotify.pending ? "true" : "false") '},'
    body .= '"pendingServerSwitchName":{"stringValue":"' RC_JsonEsc(switchNotify.pendingTarget) '"},'
    body .= '"pendingServerSwitchIndex":{"integerValue":"' switchNotify.pendingIndex '"},'
    body .= '"pendingServerSwitchSource":{"stringValue":"' RC_JsonEsc(switchNotify.pendingSource) '"},'
    body .= '"lastServerSwitchCompletedName":{"stringValue":"' RC_JsonEsc(switchNotify.lastTarget) '"},'
    body .= '"lastServerSwitchCompletedIndex":{"integerValue":"' switchNotify.lastIndex '"},'
    body .= '"lastServerSwitchCompletedTotal":{"integerValue":"' switchNotify.lastTotal '"},'
    body .= '"lastServerSwitchCompletedSource":{"stringValue":"' RC_JsonEsc(switchNotify.lastSource) '"},'
    body .= '"lastServerSwitchCompletedAt":{"integerValue":"' switchNotify.lastCompletedAt '"},'
    body .= '"lastServerSwitchMailResult":{"stringValue":"' RC_JsonEsc(switchNotify.lastMailResult) '"},'
    body .= '"lastServerSwitchMailDetail":{"stringValue":"' RC_JsonEsc(switchNotify.lastMailDetail) '"},'
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
    body .= '"effectiveLiveQualityProfile":{"stringValue":"' RC_JsonEsc(effectiveSettings.liveQualityProfile) '"},'
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
    body .= '"recentLogSchemaVersion":{"integerValue":"1"},'
    body .= '"recentLogAvailable":{"booleanValue":' (recentLog.available ? "true" : "false") '},'
    body .= '"recentLogFileName":{"stringValue":"' RC_JsonEsc(recentLog.fileName) '"},'
    body .= '"recentLogExcerpt":{"stringValue":"' RC_JsonEsc(recentLog.excerpt) '"},'
    body .= '"recentLogCapturedAt":{"integerValue":"' nowMs '"},'
    body .= '"recentLogTruncated":{"booleanValue":' (recentLog.truncated ? "true" : "false") '},'
    body .= '"recentLogSourceBytes":{"integerValue":"' recentLog.sourceBytes '"},'
    body .= '"performanceSchemaVersion":{"integerValue":"1"},'
    body .= '"performanceStatusAvailable":{"booleanValue":' (performanceAvailable ? "true" : "false") '},'
    body .= '"performanceJson":{"stringValue":"' RC_JsonEsc(performanceJson) '"},'
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
    url .= "&updateMask.fieldPaths=serverProgressSchemaVersion"
    url .= "&updateMask.fieldPaths=serverCycleKey"
    url .= "&updateMask.fieldPaths=serverCompletedCycleJson"
    url .= "&updateMask.fieldPaths=serverCompletedCount"
    url .= "&updateMask.fieldPaths=serverAllCompletedToday"
    url .= "&updateMask.fieldPaths=serverSwitchNotifyPending"
    url .= "&updateMask.fieldPaths=pendingServerSwitchName"
    url .= "&updateMask.fieldPaths=pendingServerSwitchIndex"
    url .= "&updateMask.fieldPaths=pendingServerSwitchSource"
    url .= "&updateMask.fieldPaths=lastServerSwitchCompletedName"
    url .= "&updateMask.fieldPaths=lastServerSwitchCompletedIndex"
    url .= "&updateMask.fieldPaths=lastServerSwitchCompletedTotal"
    url .= "&updateMask.fieldPaths=lastServerSwitchCompletedSource"
    url .= "&updateMask.fieldPaths=lastServerSwitchCompletedAt"
    url .= "&updateMask.fieldPaths=lastServerSwitchMailResult"
    url .= "&updateMask.fieldPaths=lastServerSwitchMailDetail"
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
    url .= "&updateMask.fieldPaths=effectiveLiveQualityProfile"
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
    url .= "&updateMask.fieldPaths=recentLogSchemaVersion"
    url .= "&updateMask.fieldPaths=recentLogAvailable"
    url .= "&updateMask.fieldPaths=recentLogFileName"
    url .= "&updateMask.fieldPaths=recentLogExcerpt"
    url .= "&updateMask.fieldPaths=recentLogCapturedAt"
    url .= "&updateMask.fieldPaths=recentLogTruncated"
    url .= "&updateMask.fieldPaths=recentLogSourceBytes"
    url .= "&updateMask.fieldPaths=performanceSchemaVersion"
    url .= "&updateMask.fieldPaths=performanceStatusAvailable"
    url .= "&updateMask.fieldPaths=performanceJson"
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

RC_NormalizeCommandAck(nonce, stateApplied, resultCode := "APPLIED", resultDetail := "",
    serverIndex := 0, serverName := "", ackAt := 0) {
    safeNonce := RC_ToIntRange(nonce, 0, 0, 2147483647)
    safeServerIndex := 0
    try safeServerIndex := Max(0, Integer(serverIndex))
    safeAckAt := ackAt
    try safeAckAt := Integer(ackAt)
    if (safeAckAt <= 0)
        safeAckAt := RC_UnixMs()
    return {
        nonce: safeNonce,
        state: SubStr(StrUpper(Trim(stateApplied, " `t`r`n")), 1, 40),
        result: SubStr(StrUpper(Trim(resultCode, " `t`r`n")), 1, 80),
        detail: SubStr(StrReplace(StrReplace(resultDetail, "`r", " "), "`n", " "), 1, 600),
        serverIndex: safeServerIndex,
        serverName: SubStr(Trim(serverName, " `t`r`n"), 1, 160),
        ackAt: safeAckAt
    }
}

RC_IsFinalizedCommandAckForClaim(ack, claim) {
    if (!IsObject(ack) || !IsObject(claim)
        || ack.nonce <= 0 || ack.ackAt <= 0 || ack.result = "")
        return false
    ; Claim 的完整命令身分包含 nonce/state；切服類命令另含 serverIndex/name。
    ; ACCEPTED 也是刻意的 terminal durable receipt，但 RUN／PAUSE 必須同時存在
    ; 完整匹配的 desired journal。只有 ACK、claim、desired 三方一致，才能證明
    ; 軟狀態在 ACK 前已 durable；背景 UI hook 仍不是 exactly-once 完成點。
    if ((ack.state = "RUN" || ack.state = "PAUSE")
        && InStr(ack.result, "ACCEPTED") = 1
        && !RC_IsDesiredStateGenerationCurrent(ack.state, ack.nonce))
        return false
    return RC_CommandClaimMatches(claim, ack.state, ack.nonce, ack)
}

RC_IsFinalizedStopAckForClaim(ack, claim) {
    return (RC_IsFinalizedCommandAckForClaim(ack, claim)
        && ack.state = "STOP" && ack.result = "APPLIED")
}

RC_ReconcileFinalizedCommandClaimFromLocalAck(source := "local") {
    global RC_PENDING_COMMAND_ACK, RC_PENDING_COMMAND_CLAIM
    if !RC_IsFinalizedCommandAckForClaim(RC_PENDING_COMMAND_ACK, RC_PENDING_COMMAND_CLAIM)
        return false
    nonce := RC_PENDING_COMMAND_ACK.nonce
    state := RC_PENDING_COMMAND_ACK.state
    ; pending ACK 已是 durable completion record，但 claim-time 的 last_nonce IniWrite 可能
    ; 恰好失敗。先把消費游標向前落盤並讀回驗證，再刪 claim；否則下一次啟動可能把
    ; 同一 nonce 當成新命令，繞過 recover-claim 路徑而重做 UI／關閉副作用。
    if !RC_PersistCommandCursorThrough(nonce, source "-finalized-command") {
        RC_Log("Finalized command ACK exists but durable nonce cursor could not be advanced; "
            "claim retained: source=" source " state=" state " nonce=" nonce, "ERROR")
        return true
    }
    cleared := RC_ClearCommandClaimThrough(nonce, source "-finalized-command")
    if !cleared {
        ; 即使 claim journal 暫時無法刪除，recovery 端仍會用同一份 pending ACK
        ; 禁止重播；不能讓 toggle 類副作用因清檔失敗而執行兩次。
        RC_Log("Finalized command ACK exists but claim journal could not be cleared: source="
            source " state=" state " nonce=" nonce, "WARN")
    }
    return true
}

RC_PersistCommandCursorThrough(nonce, source := "local") {
    global RC_LAST_NONCE, RC_CFG_PATH

    safeNonce := RC_ToIntRange(nonce, 0, 0, 2147483647)
    if (safeNonce <= 0 || RC_CFG_PATH = "")
        return false

    hMutex := RC_AcquirePersistedDesiredStateMutex()
    if !hMutex {
        if (safeNonce > RC_LAST_NONCE)
            RC_LAST_NONCE := safeNonce
        RC_Log("Timed out acquiring remote journal mutex for command cursor: source="
            source " nonce=" safeNonce, "ERROR")
        return false
    }
    previousCritical := Critical("On")
    try {
        storedNonce := RC_ToIntRange(
            RC_IniReadSafe(RC_CFG_PATH, "remote_control", "last_nonce", "0"),
            0, 0, 2147483647)
        ; 舊 handoff 程序不得把共用 config 的較新游標倒寫成較小值。
        targetNonce := Max(safeNonce, RC_LAST_NONCE, storedNonce)
        RC_LAST_NONCE := targetNonce
        if (storedNonce >= targetNonce)
            return true
        IniWrite(targetNonce, RC_CFG_PATH, "remote_control", "last_nonce")
        storedNonce := RC_ToIntRange(
            RC_IniReadSafe(RC_CFG_PATH, "remote_control", "last_nonce", "0"),
            0, 0, 2147483647)
        if (storedNonce >= targetNonce)
            return true
        RC_Log("Command cursor write-back verification failed: source=" source
            " required=" targetNonce " stored=" storedNonce, "ERROR")
    } catch as e {
        RC_Log("Failed to persist command cursor: source=" source " nonce=" safeNonce
            " error=" e.Message, "ERROR")
    } finally {
        Critical(previousCritical)
        RC_ReleasePersistedDesiredStateMutex(hMutex)
    }
    return false
}

; 保留舊名稱供既有診斷 harness 使用；正式啟動流程已改走泛化對帳。
RC_ReconcileFinalizedStopClaimFromLocalAck(source := "local") {
    global RC_PENDING_COMMAND_ACK, RC_PENDING_COMMAND_CLAIM
    if !RC_IsFinalizedStopAckForClaim(RC_PENDING_COMMAND_ACK, RC_PENDING_COMMAND_CLAIM)
        return false
    return RC_ReconcileFinalizedCommandClaimFromLocalAck(source)
}

RC_MarkActiveStopSideEffectsComplete(source := "handler") {
    global RC_ACTIVE_STOP_ACK, RC_ACTIVE_STOP_SIDE_EFFECTS_COMPLETE

    marked := false
    nonce := 0
    previousCritical := Critical("On")
    try {
        if IsObject(RC_ACTIVE_STOP_ACK) {
            RC_ACTIVE_STOP_SIDE_EFFECTS_COMPLETE := true
            nonce := RC_ACTIVE_STOP_ACK.nonce
            marked := true
        }
    } finally {
        Critical(previousCritical)
    }
    if marked {
        RC_Log("Marked STOP shutdown side effects complete: source=" source " nonce=" nonce)
        ; marker 只會在關閉、通知與錄影封口都完成後呼叫。當場先把
        ; terminal ACK durable stage，再清 claim；不把「marker 到 ExitApp」的結尾等待
        ; 留成硬崩後重播 STOP 副作用的空窗。雲端 flush 仍交給 OnExit。
        if !RC_FinalizeActiveStopAck(source "-marker", false) {
            RC_Log("STOP tail marker could not durably stage its ACK; claim retained: source="
                source " nonce=" nonce, "ERROR")
            return false
        }
    }
    return marked
}

RC_FinalizeActiveStopAck(source := "shutdown", flushNow := true) {
    global RC_ACTIVE_STOP_ACK, RC_ACTIVE_STOP_SIDE_EFFECTS_COMPLETE

    ack := ""
    sideEffectsComplete := false
    previousCritical := Critical("On")
    try {
        if IsObject(RC_ACTIVE_STOP_ACK) {
            ack := RC_ACTIVE_STOP_ACK
            sideEffectsComplete := RC_ACTIVE_STOP_SIDE_EFFECTS_COMPLETE
        }
    } finally {
        Critical(previousCritical)
    }
    if !IsObject(ack)
        return true
    if !sideEffectsComplete {
        ; Reload、#SingleInstance、系統關機或外部 Close 都可能在 STOP handler
        ; 尚未走完時觸發 OnExit。沒有尾端明確 marker 時絕不可假報 APPLIED。
        RC_Log("Active STOP exited before shutdown side effects were marked complete; "
            "claim retained for recovery: source=" source " nonce=" ack.nonce, "WARN")
        return false
    }

    ; pending journal 是「handler 已走完」的 durable completion record。
    ; journal 成功前不能清 active ACK 或 command claim。
    if !RC_SavePendingCommandAck(ack) {
        RC_Log("Failed to finalize active STOP ACK; claim retained for recovery: source="
            source " nonce=" ack.nonce, "ERROR")
        return false
    }

    previousCritical := Critical("On")
    try {
        if (IsObject(RC_ACTIVE_STOP_ACK)
            && RC_CommandAckEquals(RC_ACTIVE_STOP_ACK, ack)) {
            RC_ACTIVE_STOP_ACK := ""
            RC_ACTIVE_STOP_SIDE_EFFECTS_COMPLETE := false
        }
    } finally {
        Critical(previousCritical)
    }

    RC_ClearCommandClaimThrough(ack.nonce, source "-stop-finalized")
    if flushNow
        RC_TryFlushPendingCommandAck(source "-stop-finalized")
    RC_Log("Finalized STOP ACK after shutdown side effects: source=" source
        " nonce=" ack.nonce)
    return true
}

RC_LoadPendingCommandAck() {
    global RC_CFG_PATH
    journalPath := RC_PendingCommandAckJournalPath()
    section := "pending_ack"
    sourcePath := FileExist(journalPath) ? journalPath : RC_CFG_PATH
    sourceSection := FileExist(journalPath) ? section : "remote_control_pending_ack"
    nonce := RC_ToIntRange(RC_IniReadSafe(sourcePath, sourceSection, "nonce", "0"),
        0, 0, 2147483647)
    state := StrUpper(Trim(
        RC_IniReadSafe(sourcePath, sourceSection, "state", ""), " `t`r`n"))
    result := StrUpper(Trim(
        RC_IniReadSafe(sourcePath, sourceSection, "result", ""), " `t`r`n"))
    ackAt := RC_ToIntRange(
        RC_IniReadSafe(sourcePath, sourceSection, "ack_at", "0"),
        0, 0, 9999999999999)
    ; nonce 在 journal 中最後提交。若舊版 section／損壞檔只剩 nonce
    ; 卻沒有完整 terminal receipt，不得用 Normalize 臨時補一個新 ackAt
    ; 把它假裝成 durable ACK。
    if (nonce <= 0 || state = "" || result = "" || ackAt <= 0)
        return ""
    return RC_NormalizeCommandAck(
        nonce,
        state,
        result,
        RC_IniReadSafe(sourcePath, sourceSection, "detail", ""),
        RC_IniReadSafe(sourcePath, sourceSection, "server_index", "0"),
        RC_IniReadSafe(sourcePath, sourceSection, "server_name", ""),
        ackAt)
}

RC_PendingCommandAckJournalPath() {
    global RC_CFG_PATH
    return RC_CFG_PATH ".pending_command_ack.ini"
}

RC_SavePendingCommandAck(ack) {
    global RC_CFG_PATH, RC_PENDING_COMMAND_ACK
    if !IsObject(ack) || ack.nonce <= 0
        return false

    section := "pending_ack"
    journalPath := RC_PendingCommandAckJournalPath()
    tempPath := journalPath ".tmp_" DllCall("kernel32\GetCurrentProcessId", "uint")
        . "_" A_TickCount
    hMutex := RC_AcquirePersistedDesiredStateMutex()
    if !hMutex {
        RC_Log("Timed out acquiring remote journal mutex for pending ACK: nonce="
            ack.nonce, "ERROR")
        return false
    }
    previousCritical := Critical("On")
    try {
        diskPending := RC_LoadPendingCommandAck()
        if IsObject(diskPending) {
            if (diskPending.nonce > ack.nonce) {
                RC_PENDING_COMMAND_ACK := diskPending
                RC_Log("Refused to overwrite newer pending ACK from another process: existing="
                    diskPending.nonce " incoming=" ack.nonce, "WARN")
                return false
            }
            if (diskPending.nonce = ack.nonce) {
                if RC_CommandAckPayloadEquals(diskPending, ack) {
                    ; 同一 terminal receipt 已 durable；沿用磁碟 ackAt，避免
                    ; 舊／新程序為相同結果無限改版並互相 CAS 競爭。
                    RC_PENDING_COMMAND_ACK := diskPending
                    return true
                }
                ; 同 nonce 只允許一個 terminal receipt。若讓過期程序以較新
                ; 毫秒時間覆寫，反而會使 restart overlap 持續倒寫雲端。
                RC_PENDING_COMMAND_ACK := diskPending
                RC_Log("Refused conflicting pending ACK for the same nonce: nonce=" ack.nonce
                    " disk=" diskPending.state "/" diskPending.result
                    " incoming=" ack.state "/" ack.result, "ERROR")
                return false
            }
        }
        if (IsObject(RC_PENDING_COMMAND_ACK)
            && RC_PENDING_COMMAND_ACK.nonce > ack.nonce) {
            RC_Log("Refused to overwrite newer pending ACK: existing="
                RC_PENDING_COMMAND_ACK.nonce " incoming=" ack.nonce, "WARN")
            return false
        }
        try FileDelete(tempPath)
        IniWrite ack.state, tempPath, section, "state"
        IniWrite ack.result, tempPath, section, "result"
        IniWrite ack.detail, tempPath, section, "detail"
        IniWrite ack.serverIndex, tempPath, section, "server_index"
        IniWrite ack.serverName, tempPath, section, "server_name"
        IniWrite ack.ackAt, tempPath, section, "ack_at"
        IniWrite ack.nonce, tempPath, section, "nonce"
        ; 同目錄先完整寫 temp，再原子替換 journal；失敗／斷電不會先破壞舊 pending。
        FileMove(tempPath, journalPath, 1)
        RC_PENDING_COMMAND_ACK := ack
        return true
    } catch as e {
        try FileDelete(tempPath)
        if !IsObject(RC_PENDING_COMMAND_ACK)
            RC_PENDING_COMMAND_ACK := ack
        RC_Log("Failed to persist pending command ACK: nonce=" ack.nonce
            " error=" e.Message, "ERROR")
        return false
    } finally {
        Critical(previousCritical)
        RC_ReleasePersistedDesiredStateMutex(hMutex)
    }
}

RC_DeletePendingCommandAckJournal() {
    global RC_CFG_PATH
    journalPath := RC_PendingCommandAckJournalPath()
    try {
        ; 先使舊版 config section 失效，再刪除新版 journal。任一步中斷時，
        ; 至少仍會保留一份 pending，不會先清記憶體後又在下次啟動復活舊值。
        IniWrite 0, RC_CFG_PATH, "remote_control_pending_ack", "nonce"
        if FileExist(journalPath)
            FileDelete(journalPath)
        return true
    } catch as e {
        RC_Log("Failed to delete pending command ACK journal: " e.Message, "WARN")
        return false
    }
}

RC_CommandAckEquals(left, right) {
    if !IsObject(left) || !IsObject(right)
        return false
    return (left.nonce = right.nonce
        && left.state = right.state
        && left.result = right.result
        && left.detail = right.detail
        && left.serverIndex = right.serverIndex
        && left.serverName = right.serverName
        && left.ackAt = right.ackAt)
}

RC_CommandAckPayloadEquals(left, right) {
    if !IsObject(left) || !IsObject(right)
        return false
    return (left.nonce = right.nonce
        && left.state = right.state
        && left.result = right.result
        && left.detail = right.detail
        && left.serverIndex = right.serverIndex
        && left.serverName = right.serverName)
}

RC_CloudAckMatchesPending(resp, pending) {
    if !IsObject(pending)
        return false
    return (RC_JsonGetInteger(resp, "lastAckNonce", 0) = pending.nonce
        && StrUpper(RC_JsonGetString(resp, "lastAckState")) = pending.state
        && StrUpper(RC_JsonGetString(resp, "lastAckResult")) = pending.result
        && RC_JsonGetString(resp, "lastAckDetail") = pending.detail
        && RC_JsonGetInteger(resp, "lastAckServerIndex", 0) = pending.serverIndex
        && RC_JsonGetString(resp, "lastAckServerName") = pending.serverName
        && RC_JsonGetInteger(resp, "lastAckAt", 0) = pending.ackAt)
}

RC_ReconcilePendingCommandAckFromCloud(resp, ackNonce, source := "cloud") {
    global RC_PENDING_COMMAND_ACK
    if !IsObject(RC_PENDING_COMMAND_ACK)
        return false
    pending := RC_PENDING_COMMAND_ACK
    if (ackNonce > pending.nonce)
        return RC_ClearPendingCommandAckThrough(ackNonce, source "-newer")
    if (ackNonce = pending.nonce && RC_CloudAckMatchesPending(resp, pending))
        return RC_ClearPendingCommandAckIfMatch(pending, source "-exact")
    if (ackNonce = pending.nonce) {
        RC_Log("Cloud ACK nonce matches pending but payload differs; pending retained: source=" source
            " nonce=" ackNonce, "WARN")
    }
    return false
}

RC_ClearPendingCommandAckIfMatch(expected, source := "ack-success") {
    global RC_CFG_PATH, RC_PENDING_COMMAND_ACK
    cleared := false
    hMutex := RC_AcquirePersistedDesiredStateMutex()
    if !hMutex {
        RC_Log("Timed out acquiring remote journal mutex to clear pending ACK: source="
            source " nonce=" expected.nonce, "WARN")
        return false
    }
    previousCritical := Critical("On")
    try {
        diskPending := RC_LoadPendingCommandAck()
        if IsObject(diskPending) {
            RC_PENDING_COMMAND_ACK := diskPending
            if !RC_CommandAckEquals(diskPending, expected) {
                RC_Log("Pending ACK changed in another process before clear; retained: source="
                    source " expected=" expected.nonce " disk=" diskPending.nonce, "WARN")
                return false
            }
            if RC_DeletePendingCommandAckJournal() {
                RC_PENDING_COMMAND_ACK := ""
                cleared := true
            }
        } else if RC_CommandAckEquals(RC_PENDING_COMMAND_ACK, expected) {
            ; 另一程序已清除同一 journal；本程序只需收旂過期記憶體。
            RC_PENDING_COMMAND_ACK := ""
            cleared := true
        }
    } finally {
        Critical(previousCritical)
        RC_ReleasePersistedDesiredStateMutex(hMutex)
    }
    if cleared
        RC_Log("Cleared pending command ACK: source=" source " nonce=" expected.nonce)
    return cleared
}

RC_ClearPendingCommandAckThrough(nonce, source := "cloud") {
    global RC_CFG_PATH, RC_PENDING_COMMAND_ACK
    safeNonce := RC_ToIntRange(nonce, 0, 0, 2147483647)
    clearedNonce := 0
    hMutex := RC_AcquirePersistedDesiredStateMutex()
    if !hMutex {
        RC_Log("Timed out acquiring remote journal mutex to clear pending ACK cursor: source="
            source " through=" safeNonce, "WARN")
        return false
    }
    previousCritical := Critical("On")
    try {
        diskPending := RC_LoadPendingCommandAck()
        if IsObject(diskPending)
            RC_PENDING_COMMAND_ACK := diskPending
        candidate := IsObject(diskPending) ? diskPending : RC_PENDING_COMMAND_ACK
        if (IsObject(candidate) && candidate.nonce <= safeNonce) {
            if RC_DeletePendingCommandAckJournal() {
                clearedNonce := candidate.nonce
                RC_PENDING_COMMAND_ACK := ""
            }
        } else if !IsObject(candidate) {
            ; 已由其他程序清除，視為達成。
            return true
        }
    } finally {
        Critical(previousCritical)
        RC_ReleasePersistedDesiredStateMutex(hMutex)
    }
    if (clearedNonce > 0)
        RC_Log("Cleared pending command ACK through cloud cursor: source=" source
            " pending=" clearedNonce " cloud=" safeNonce)
    return clearedNonce > 0
}

RC_JsonGetDocumentUpdateTime(jsonText) {
    if RegExMatch(jsonText, '"updateTime"\s*:\s*"([^"\\]+)"', &m)
        return m[1]
    return ""
}

RC_EncodeFirestoreUpdateTime(updateTime) {
    value := Trim(updateTime, " `t`r`n")
    ; Firestore document.updateTime 固定為 RFC3339 UTC。驗證後只需編碼 query
    ; 中有特殊語意的百分號、冒號與加號，其餘 timestamp 字元可原樣保留。
    if !RegExMatch(value, "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$")
        return ""
    value := StrReplace(value, "%", "%25")
    value := StrReplace(value, ":", "%3A")
    value := StrReplace(value, "+", "%2B")
    return value
}

RC_IsFirestorePreconditionConflict(result) {
    if !IsObject(result)
        return false
    if (result.status = 409 || result.status = 412)
        return true
    ; Firestore REST 有些端點把 FAILED_PRECONDITION 映射為 HTTP 400。
    return (result.status = 400
        && InStr(StrUpper(result.body " " result.msg), "FAILED_PRECONDITION"))
}

RC_SendCommandAckHttp(ack) {
    ; 命令 ACK 很少發生，最多三次 conditional PATCH；不改固定輪詢頻率。
    ; 第三次衝突後仍再做一次純 GET 對帳，確認競爭者是否已寫入相同／更新 ACK。
    ; currentDocument.updateTime 讓「檢查舊值＋寫入」成為 Firestore 端原子操作，
    ; 重啟交疊時較舊程序不能在 preflight 後倒寫較新的 ACK。
    maxAttempts := 3
    lastConflict := ""
    Loop maxAttempts + 1 {
        attempt := A_Index
        preflightUrl := RC_ClientDocUrl()
        preflightUrl .= "&mask.fieldPaths=lastAckNonce"
        preflightUrl .= "&mask.fieldPaths=lastAckState"
        preflightUrl .= "&mask.fieldPaths=lastAckResult"
        preflightUrl .= "&mask.fieldPaths=lastAckDetail"
        preflightUrl .= "&mask.fieldPaths=lastAckServerIndex"
        preflightUrl .= "&mask.fieldPaths=lastAckServerName"
        preflightUrl .= "&mask.fieldPaths=lastAckAt"
        preflight := RC_HttpRequest("GET", preflightUrl, "")
        if !preflight.ok
            return preflight

        updateTime := RC_JsonGetDocumentUpdateTime(preflight.body)
        encodedUpdateTime := RC_EncodeFirestoreUpdateTime(updateTime)
        if (encodedUpdateTime = "") {
            return { ok: false, status: 0, body: preflight.body,
                msg: "Firestore ACK preflight response has no valid document updateTime" }
        }

        cloudNonce := RC_JsonGetInteger(preflight.body, "lastAckNonce", 0)
        cloudAckAt := RC_JsonGetInteger(preflight.body, "lastAckAt", 0)
        if (cloudNonce > ack.nonce
            || (cloudNonce = ack.nonce && cloudAckAt > ack.ackAt)) {
            return { ok: true, status: 200, body: preflight.body, msg: "",
                skipped: true, skipReason: "cloud_ack_is_newer" }
        }
        if (cloudNonce = ack.nonce && RC_CloudAckMatchesPending(preflight.body, ack)) {
            return { ok: true, status: 200, body: preflight.body, msg: "",
                skipped: true, skipReason: "cloud_ack_already_exact" }
        }
        if (cloudNonce = ack.nonce && cloudAckAt = ack.ackAt && cloudAckAt > 0) {
            ; updateTime precondition 已保證只有一個同版本寫入者能勝出。同 nonce、
            ; 同 ackAt 卻 payload 不同時，以雲端原子勝出版本為準，避免兩端永久互蓋。
            return { ok: true, status: 200, body: preflight.body, msg: "",
                skipped: true, skipReason: "cloud_ack_same_version_won" }
        }

        ; 前三次各自使用剛讀到的 updateTime 嘗試 PATCH；最後一輪只負責
        ; 衝突後對帳。若雲端仍較舊，保留 pending 交給之後的既有 retry。
        if (attempt > maxAttempts)
            break

        body := "{"
        body .= '"fields":{'
        body .= '"lastAckNonce":{"integerValue":"' ack.nonce '"},'
        body .= '"lastAckState":{"stringValue":"' RC_JsonEsc(ack.state) '"},'
        body .= '"lastAckResult":{"stringValue":"' RC_JsonEsc(ack.result) '"},'
        body .= '"lastAckDetail":{"stringValue":"' RC_JsonEsc(ack.detail) '"},'
        body .= '"lastAckServerIndex":{"integerValue":"' ack.serverIndex '"},'
        body .= '"lastAckServerName":{"stringValue":"' RC_JsonEsc(ack.serverName) '"},'
        body .= '"lastAckAt":{"integerValue":"' ack.ackAt '"}'
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
        url .= "&currentDocument.updateTime=" encodedUpdateTime

        patchResult := RC_HttpRequest("PATCH", url, body)
        if patchResult.ok
            return patchResult
        if !RC_IsFirestorePreconditionConflict(patchResult)
            return patchResult

        lastConflict := patchResult
        RC_Log("Firestore ACK conditional PATCH conflict; re-reading before bounded retry: nonce="
            ack.nonce " attempt=" attempt "/" maxAttempts, "WARN")
        if (attempt < maxAttempts)
            DllCall("kernel32\Sleep", "uint", 80)
    }

    conflictMessage := "Firestore ACK conditional PATCH conflicted "
        . maxAttempts
        . " times; pending journal retained for a later retry"
    return {
        ok: false,
        status: IsObject(lastConflict) ? lastConflict.status : 409,
        body: IsObject(lastConflict) ? lastConflict.body : "",
        msg: conflictMessage
    }
}

RC_TryFlushPendingCommandAck(source := "retry") {
    global RC_PENDING_COMMAND_ACK, RC_ACK_RETRY_IN_PROGRESS

    pending := ""
    acquired := false
    previousCritical := Critical("On")
    try {
        if !RC_ACK_RETRY_IN_PROGRESS && IsObject(RC_PENDING_COMMAND_ACK) {
            RC_ACK_RETRY_IN_PROGRESS := true
            pending := RC_PENDING_COMMAND_ACK
            acquired := true
        }
    } finally {
        Critical(previousCritical)
    }
    if !acquired
        return !IsObject(RC_PENDING_COMMAND_ACK)

    requestOk := false
    retryNewer := false
    try {
        r := RCSH_IsPrimary()
            ? RCSH_SendCommandAckHttp(pending)
            : RC_SendCommandAckHttp(pending)
        requestOk := r.ok
        if requestOk {
            cleared := RC_ClearPendingCommandAckIfMatch(pending, source)
            ; HTTP 讓出期間若產生較新的 ACK，舊成功回應不能把它刪掉。
            retryNewer := !cleared && IsObject(RC_PENDING_COMMAND_ACK)
        } else {
            RC_Log("RemoteControl ack patch failed; pending retained: source=" source
                " nonce=" pending.nonce " error=" r.msg, "WARN")
        }
    } catch as e {
        RC_Log("RemoteControl ack retry exception; pending retained: source=" source
            " nonce=" pending.nonce " error=" e.Message, "WARN")
    } finally {
        previousCritical := Critical("On")
        try RC_ACK_RETRY_IN_PROGRESS := false
        finally Critical(previousCritical)
    }

    if retryNewer
        return RC_TryFlushPendingCommandAck(source "-newer")
    return requestOk
}

RC_PatchCommandAck(nonce, stateApplied, resultCode := "APPLIED", resultDetail := "",
    serverIndex := 0, serverName := "") {
    ack := RC_NormalizeCommandAck(nonce, stateApplied, resultCode, resultDetail,
        serverIndex, serverName)
    if (ack.nonce <= 0) {
        RC_Log("Skipped invalid command ACK nonce=" nonce, "WARN")
        return false
    }
    persisted := RC_SavePendingCommandAck(ack)
    RC_TryFlushPendingCommandAck("immediate")
    ; 回傳值代表 ACK 已有 durable journal，可安全清除 command claim；
    ; 是否已送達雲端由 pending retry 個別追蹤，不混成同一個布林值。
    return persisted
}

RC_PatchSettingsAck(revision, resultCode, resultDetail, applied, ackAt := 0) {
    global RC_LAST_SETTINGS_APPLIED_REVISION
    global CURRENT_SERVER_TARGET, SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_INDEX, SERVER_SCHEDULE_LIST
    nowMs := (ackAt > 0 ? ackAt : RC_UnixMs())
    if RCSH_IsPrimary() {
        if !RCSH_SendSettingsAck(revision, resultCode, resultDetail, applied)
            RC_Log("Self-hosted settings ACK failed; local applied revision remains durable", "WARN")
        return
    }
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
    body .= '"effectiveLiveQualityProfile":{"stringValue":"' RC_JsonEsc(effectiveSettings.liveQualityProfile) '"},'
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
    url .= "&updateMask.fieldPaths=effectiveLiveQualityProfile"
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
    url .= "&mask.fieldPaths=lastAckNonce"
    url .= "&mask.fieldPaths=lastAckState"
    url .= "&mask.fieldPaths=lastAckResult"
    url .= "&mask.fieldPaths=lastAckDetail"
    url .= "&mask.fieldPaths=lastAckServerIndex"
    url .= "&mask.fieldPaths=lastAckServerName"
    url .= "&mask.fieldPaths=lastAckAt"
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
    url .= "&mask.fieldPaths=desiredLiveQualityProfile"
    url .= "&mask.fieldPaths=selfHostedServerUrl"
    url .= "&mask.fieldPaths=selfHostedMode"
    url .= "&mask.fieldPaths=selfHostedEpoch"
    url .= "&mask.fieldPaths=selfHostedFirestoreFallbackUntil"
    url .= "&mask.fieldPaths=selfHostedUpdatedAt"
    r := RC_HttpRequest("GET", url, "")
    if !r.ok {
        RC_Log("RemoteControl poll failed: " r.msg, "WARN")
        return ""
    }
    try RCSH_ProcessDiscoveryResponse(r.body)
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
        try FileAppend(ts " [" level "] [RemoteControl] " msg "`r`n", RuntimeFiles_LogFallbackPath("RemoteControl"), "UTF-8")
    }
}
