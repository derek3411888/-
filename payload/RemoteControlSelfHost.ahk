; Self-hosted control transport for AHK v2.
; Firestore remains authoritative in shadow mode. In primary mode the same
; durable nonce/claim/ACK state machine in RemoteControlFirestore.ahk consumes
; this transport's Firestore-shaped response.

global RCSH_CFG_PATH := ""
global RCSH_SERVER_URL := ""
global RCSH_MODE := "shadow"
global RCSH_EPOCH := ""
global RCSH_FIRESTORE_FALLBACK_UNTIL := 0
global RCSH_DEVICE_TOKEN := ""
global RCSH_ENROLLED := false
global RCSH_LAST_ERROR := ""
global RCSH_LAST_CONTROL_OK := 0
global RCSH_LAST_HEARTBEAT_OK := 0
global RCSH_LAST_FIRESTORE_READ_AT := 0
global RCSH_LAST_FIRESTORE_WRITE_AT := 0
global RCSH_LIVE_PID := 0
global RCSH_LIVE_URL := ""
global RCSH_LIVE_SOURCE_URL := ""
global RCSH_LIVE_STARTED_AT := 0
global RCSH_LIVE_ROUTE := "public"
global RCSH_LIVE_CANDIDATES := []
global RCSH_LIVE_CANDIDATE_INDEX := 0
global RCSH_LIVE_EXPIRES_AT := 0
global RCSH_PREVIEW_MARKER := "WUTHERING_RUNTIME_PREVIEW_V1"
global RCSH_HTTP_FAILURE_COUNT := 0
global RCSH_HTTP_RETRY_AFTER := 0
global RCSH_LAST_ERROR_LOG_AT := 0

RCSH_Init(cfgPath) {
    global RCSH_CFG_PATH, RCSH_SERVER_URL, RCSH_MODE, RCSH_EPOCH
    global RCSH_FIRESTORE_FALLBACK_UNTIL, RCSH_DEVICE_TOKEN

    RCSH_CFG_PATH := cfgPath
    RCSH_EnsureDefaults(cfgPath)
    RCSH_SERVER_URL := RCSH_NormalizeServerUrl(
        RC_IniReadSafe(cfgPath, "self_hosted", "server_url", ""))
    RCSH_MODE := RCSH_NormalizeMode(
        RC_IniReadSafe(cfgPath, "self_hosted", "mode", "shadow"))
    RCSH_EPOCH := Trim(RC_IniReadSafe(cfgPath, "self_hosted", "epoch", ""), " `t`r`n")
    RCSH_FIRESTORE_FALLBACK_UNTIL := RC_ToIntRange(
        RC_IniReadSafe(cfgPath, "self_hosted", "firestore_fallback_until", "0"),
        0, 0, 9999999999999)

    protectedToken := Trim(RC_IniReadSafe(cfgPath, "self_hosted", "device_token_dpapi", ""), " `t`r`n")
    if (protectedToken != "") {
        try RCSH_DEVICE_TOKEN := RCSH_DpapiUnprotect(protectedToken)
        catch as e {
            RCSH_DEVICE_TOKEN := ""
            RC_Log("Self-hosted DPAPI token could not be opened for this Windows user: " e.Message, "WARN")
        }
    }
    RCSH_CleanupOrphanLivePreviews()
    if (RCSH_SERVER_URL != "" && RCSH_MODE != "disabled")
        RCSH_EnsureEnrolled()
}

RCSH_EnsureDefaults(cfgPath) {
    defaults := Map(
        "server_url", "",
        "mode", "shadow",
        "epoch", "",
        "firestore_fallback_until", "0",
        "device_token_dpapi", "",
        "upload_limit_mbps", "8"
    )
    sentinel := "__RCSH_MISSING__"
    for key, value in defaults {
        if (RC_IniReadSafe(cfgPath, "self_hosted", key, sentinel) = sentinel) {
            try IniWrite(value, cfgPath, "self_hosted", key)
        }
    }
}

RCSH_NormalizeMode(value) {
    mode := StrLower(Trim(value, " `t`r`n"))
    return (mode = "shadow" || mode = "primary" || mode = "fallback" || mode = "disabled")
        ? mode : "shadow"
}

RCSH_NormalizeServerUrl(value) {
    url := RTrim(Trim(value, " `t`r`n"), "/")
    if (url = "")
        return ""
    if RegExMatch(url, "i)^https://[a-z0-9.-]+(?::\d+)?$")
        return url
    if RegExMatch(url, "i)^http://(?:localhost|127\.0\.0\.1)(?::\d+)?$")
        return url
    return ""
}

RCSH_ProcessDiscoveryResponse(resp) {
    global RCSH_CFG_PATH, RCSH_SERVER_URL, RCSH_MODE, RCSH_EPOCH
    global RCSH_FIRESTORE_FALLBACK_UNTIL
    if (resp = "" || RCSH_CFG_PATH = "")
        return false

    discoveredUrl := RCSH_NormalizeServerUrl(RC_JsonGetString(resp, "selfHostedServerUrl"))
    discoveredModeRaw := RC_JsonGetString(resp, "selfHostedMode")
    discoveredEpoch := RC_JsonGetString(resp, "selfHostedEpoch")
    fallbackUntil := RC_JsonGetInteger(resp, "selfHostedFirestoreFallbackUntil", 0)
    if (discoveredUrl = "" || discoveredModeRaw = "")
        return false

    discoveredMode := RCSH_NormalizeMode(discoveredModeRaw)
    changed := discoveredUrl != RCSH_SERVER_URL || discoveredMode != RCSH_MODE
        || discoveredEpoch != RCSH_EPOCH || fallbackUntil != RCSH_FIRESTORE_FALLBACK_UNTIL
    RCSH_SERVER_URL := discoveredUrl
    RCSH_MODE := discoveredMode
    RCSH_EPOCH := discoveredEpoch
    RCSH_FIRESTORE_FALLBACK_UNTIL := fallbackUntil
    try IniWrite(RCSH_SERVER_URL, RCSH_CFG_PATH, "self_hosted", "server_url")
    try IniWrite(RCSH_MODE, RCSH_CFG_PATH, "self_hosted", "mode")
    try IniWrite(RCSH_EPOCH, RCSH_CFG_PATH, "self_hosted", "epoch")
    try IniWrite(RCSH_FIRESTORE_FALLBACK_UNTIL, RCSH_CFG_PATH, "self_hosted", "firestore_fallback_until")
    if (RCSH_MODE = "disabled") {
        RCSH_StopLivePreview("server disabled")
        return changed
    }
    if changed
        RC_Log("Self-hosted discovery updated: mode=" RCSH_MODE " server=" RCSH_SERVER_URL)
    RCSH_EnsureEnrolled()
    return changed
}

RCSH_IsAvailable() {
    global RCSH_SERVER_URL, RCSH_MODE
    return RCSH_SERVER_URL != "" && RCSH_MODE != "disabled"
}

RCSH_IsPrimary() {
    global RCSH_MODE
    return RCSH_IsAvailable() && RCSH_MODE = "primary"
}

RCSH_ShouldReadFirestore(forceStartup := false) {
    global RCSH_LAST_FIRESTORE_READ_AT, RCSH_FIRESTORE_FALLBACK_UNTIL
    if !RCSH_IsPrimary()
        return true
    nowMs := RC_UnixMs()
    if (RCSH_FIRESTORE_FALLBACK_UNTIL <= nowMs)
        return false
    if (forceStartup || nowMs - RCSH_LAST_FIRESTORE_READ_AT >= 900000) {
        RCSH_LAST_FIRESTORE_READ_AT := nowMs
        return true
    }
    return false
}

RCSH_ShouldWriteFirestore() {
    global RCSH_LAST_FIRESTORE_WRITE_AT, RCSH_FIRESTORE_FALLBACK_UNTIL
    if !RCSH_IsPrimary()
        return true
    nowMs := RC_UnixMs()
    if (RCSH_FIRESTORE_FALLBACK_UNTIL <= nowMs)
        return false
    if (nowMs - RCSH_LAST_FIRESTORE_WRITE_AT >= 900000) {
        RCSH_LAST_FIRESTORE_WRITE_AT := nowMs
        return true
    }
    return false
}

RCSH_SelectControlResponse(firestoreResp := "") {
    RCSH_ExpireLivePreviewIfNeeded()
    if !RCSH_IsAvailable()
        return firestoreResp
    selfHostedResp := RCSH_GetControl()
    if RCSH_IsPrimary()
        return selfHostedResp
    ; Shadow/fallback only consume live leases and mirror status. Commands and
    ; settings stay exclusively on Firestore until the atomic cutover.
    return firestoreResp
}

RCSH_EnsureEnrolled() {
    global RCSH_DEVICE_TOKEN, RCSH_ENROLLED, RCSH_CFG_PATH
    global RC_UID, RC_DISPLAY_NAME, RC_DEVICE_ALIAS, RC_LAST_NONCE
    global RC_LAST_SETTINGS_APPLIED_REVISION
    if !RCSH_IsAvailable()
        return false
    if (RCSH_DEVICE_TOKEN = "") {
        RCSH_DEVICE_TOKEN := RCSH_RandomToken(48)
        try IniWrite(RCSH_DpapiProtect(RCSH_DEVICE_TOKEN), RCSH_CFG_PATH,
            "self_hosted", "device_token_dpapi")
        catch as e {
            RCSH_DEVICE_TOKEN := ""
            RC_Log("Self-hosted device credential could not be protected: " e.Message, "ERROR")
            return false
        }
    }
    body := "{"
    body .= '"uid":"' RC_JsonEsc(RC_UID) '",'
    body .= '"displayName":"' RC_JsonEsc(RC_DISPLAY_NAME) '",'
    body .= '"deviceAlias":"' RC_JsonEsc(RC_DEVICE_ALIAS) '",'
    body .= '"lastNonce":' RC_LAST_NONCE ","
    body .= '"settingsRevision":' RC_LAST_SETTINGS_APPLIED_REVISION ","
    body .= '"deviceToken":"' RC_JsonEsc(RCSH_DEVICE_TOKEN) '"'
    body .= "}"
    result := RCSH_HttpRequest("POST", "/api/v1/device/enroll", body, false)
    RCSH_ENROLLED := result.ok
    if !result.ok
        RCSH_SetError("enroll: " result.msg)
    return result.ok
}

RCSH_GetControl() {
    global RCSH_LAST_CONTROL_OK, RCSH_MODE, RCSH_CFG_PATH, RCSH_FIRESTORE_FALLBACK_UNTIL
    if !RCSH_EnsureReady()
        return ""
    result := RCSH_HttpRequest("GET", "/api/v1/device/control?format=firestore")
    if !result.ok {
        RCSH_SetError("control: " result.msg)
        return ""
    }
    RCSH_LAST_CONTROL_OK := RC_UnixMs()
    ; 模式切換也由自架 API 自己回報。如此在 7 天緊急期結束、Firestore
    ; 輪詢完全停止後，主機端仍可把裝置切回 fallback，不會失去救援入口。
    serverModeRaw := RC_JsonGetString(result.body, "selfHostedMode")
    if (serverModeRaw != "") {
        serverMode := RCSH_NormalizeMode(serverModeRaw)
        if (serverMode != RCSH_MODE) {
            RCSH_MODE := serverMode
            try IniWrite(RCSH_MODE, RCSH_CFG_PATH, "self_hosted", "mode")
            RC_Log("Self-hosted API changed migration mode to " RCSH_MODE, "WARN")
        }
    }
    fallbackUntil := RC_JsonGetInteger(result.body, "selfHostedFirestoreFallbackUntil", 0)
    if (fallbackUntil != RCSH_FIRESTORE_FALLBACK_UNTIL) {
        RCSH_FIRESTORE_FALLBACK_UNTIL := fallbackUntil
        try IniWrite(fallbackUntil, RCSH_CFG_PATH, "self_hosted", "firestore_fallback_until")
    }
    RCSH_HandleLiveControl(result.body)
    return result.body
}

RCSH_EnsureReady() {
    global RCSH_ENROLLED
    if !RCSH_IsAvailable()
        return false
    if RCSH_ENROLLED
        return true
    return RCSH_EnsureEnrolled()
}

RCSH_SendCommandAckHttp(ack) {
    if !RCSH_EnsureReady()
        return {ok: false, status: 0, body: "", msg: "self-hosted enrollment unavailable"}
    body := "{"
    body .= '"nonce":' ack.nonce ","
    body .= '"state":"' RC_JsonEsc(ack.state) '",'
    body .= '"result":"' RC_JsonEsc(ack.result) '",'
    body .= '"detail":"' RC_JsonEsc(ack.detail) '",'
    body .= '"serverIndex":' ack.serverIndex ","
    body .= '"serverName":"' RC_JsonEsc(ack.serverName) '"'
    body .= "}"
    return RCSH_HttpRequest("POST", "/api/v1/device/commands/ack", body)
}

RCSH_SendSettingsAck(revision, resultCode, resultDetail, applied) {
    if !RCSH_EnsureReady()
        return false
    body := '{"revision":' revision
        . ',"result":"' RC_JsonEsc(resultCode) '"'
        . ',"detail":"' RC_JsonEsc(SubStr(resultDetail, 1, 1600)) '"'
        . ',"applied":' (applied ? "true" : "false") "}"
    result := RCSH_HttpRequest("POST", "/api/v1/device/settings/ack", body)
    if !result.ok
        RCSH_SetError("settings ACK: " result.msg)
    return result.ok
}

RCSH_SendHeartbeat(state) {
    global RCSH_LAST_HEARTBEAT_OK
    global RC_UID, RC_DISPLAY_NAME, RC_DEVICE_ALIAS, RC_LAST_NONCE
    global RC_LAST_SETTINGS_APPLIED_REVISION, RC_RECENT_EVENTS
    global CURRENT_STEP_NAME, CURRENT_STEP_DETAIL, CURRENT_STEP_LEVEL
    global CURRENT_SERVER_TARGET, SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_INDEX, SERVER_SCHEDULE_LIST
    global SCREEN_RECORDING_ENABLED, __SCREEN_RECORDING_ACTIVE
    RCSH_ExpireLivePreviewIfNeeded()
    if !RCSH_EnsureReady()
        return false

    currentServer := Trim(CURRENT_SERVER_TARGET, " `t`r`n")
    serverIndex := SERVER_SCHEDULE_ENABLED && SERVER_SCHEDULE_INDEX > 0 ? SERVER_SCHEDULE_INDEX : 0
    serverTotal := SERVER_SCHEDULE_ENABLED ? SERVER_SCHEDULE_LIST.Length : 0
    currentServerLabel := currentServer
    if (serverTotal > 1 && serverIndex > 0 && currentServer != "")
        currentServerLabel := serverIndex "/" serverTotal " | " currentServer
    recording := RC_ReadRecordingStatus()
    serverProgress := RC_ReadServerProgress()
    switchNotify := RC_ReadServerSwitchNotifyStatus()
    eventsJson := RC_BuildRecentEventsJson()
    status := "{"
    status .= '"currentStep":"' RC_JsonEsc(Trim(CURRENT_STEP_NAME, " `t`r`n")) '",'
    status .= '"currentStepDetail":"' RC_JsonEsc(Trim(CURRENT_STEP_DETAIL, " `t`r`n")) '",'
    status .= '"currentStepLevel":"' RC_JsonEsc(Trim(CURRENT_STEP_LEVEL, " `t`r`n")) '",'
    status .= '"currentServer":"' RC_JsonEsc(currentServer) '",'
    status .= '"currentServerLabel":"' RC_JsonEsc(currentServerLabel) '",'
    status .= '"currentServerIndex":' serverIndex ","
    status .= '"currentServerTotal":' serverTotal ","
    status .= '"serverScheduleEnabled":' (SERVER_SCHEDULE_ENABLED ? "true" : "false") ","
    status .= '"serverScheduleList":' RC_BuildStringArrayJson(SERVER_SCHEDULE_LIST) ","
    status .= '"serverCycleKey":"' RC_JsonEsc(serverProgress.cycleKey) '",'
    status .= '"serverCompletedList":' RC_BuildStringArrayJson(serverProgress.completed) ","
    status .= '"serverCompletedCount":' serverProgress.completedCount ","
    status .= '"serverAllCompletedToday":' (serverProgress.allCompleted ? "true" : "false") ","
    status .= '"serverSwitchNotifyPending":' (switchNotify.pending ? "true" : "false") ","
    status .= '"pendingServerSwitchName":"' RC_JsonEsc(switchNotify.pendingTarget) '",'
    status .= '"pendingServerSwitchIndex":' switchNotify.pendingIndex ","
    status .= '"pendingServerSwitchSource":"' RC_JsonEsc(switchNotify.pendingSource) '",'
    status .= '"lastServerSwitchCompletedName":"' RC_JsonEsc(switchNotify.lastTarget) '",'
    status .= '"lastServerSwitchCompletedIndex":' switchNotify.lastIndex ","
    status .= '"lastServerSwitchCompletedAt":' switchNotify.lastCompletedAt ","
    status .= '"lastServerSwitchMailResult":"' RC_JsonEsc(switchNotify.lastMailResult) '",'
    status .= '"lastServerSwitchMailDetail":"' RC_JsonEsc(switchNotify.lastMailDetail) '",'
    status .= '"recording":{'
    status .= '"enabled":' (SCREEN_RECORDING_ENABLED ? "true" : "false") ","
    status .= '"active":' (__SCREEN_RECORDING_ACTIVE ? "true" : "false") ","
    status .= '"state":"' RC_JsonEsc(recording.state) '",'
    status .= '"detail":"' RC_JsonEsc(SubStr(recording.detail, 1, 1000)) '",'
    status .= '"baseName":"' RC_JsonEsc(recording.baseName) '",'
    status .= '"resultPath":"' RC_JsonEsc(recording.resultPath) '",'
    status .= '"failureStorage":"' RC_JsonEsc(recording.failureStorage) '"'
    status .= "}}"

    body := "{"
    body .= '"state":"' RC_JsonEsc(state) '",'
    body .= '"displayName":"' RC_JsonEsc(RC_DISPLAY_NAME) '",'
    body .= '"deviceAlias":"' RC_JsonEsc(RC_DEVICE_ALIAS) '",'
    body .= '"lastNonce":' RC_LAST_NONCE ","
    body .= '"settingsRevision":' RC_LAST_SETTINGS_APPLIED_REVISION ","
    body .= '"status":' status ","
    body .= '"events":' eventsJson
    body .= "}"
    result := RCSH_HttpRequest("PUT", "/api/v1/device/heartbeat", body)
    if result.ok {
        RCSH_LAST_HEARTBEAT_OK := RC_UnixMs()
        RCSH_HandleLiveControl(result.body)
        return true
    }
    RCSH_SetError("heartbeat: " result.msg)
    return false
}

RCSH_PublishRuntimeSnapshot(dataUri, capturedAt, reason := "", width := 0, height := 0, level := "INFO") {
    if !RCSH_EnsureReady()
        return false
    if !RegExMatch(dataUri, "i)^data:image/jpeg;base64,(.+)$", &match)
        return false
    try bytes := RCSH_Base64ToVariant(match[1])
    catch as e {
        RCSH_SetError("snapshot decode: " e.Message)
        return false
    }
    path := "/api/v1/device/snapshot?capturedAt=" capturedAt
        . "&width=" width "&height=" height
        . "&level=" RCSH_UrlEncode(StrUpper(level))
        . "&reason=" RCSH_UrlEncode(SubStr(reason, 1, 260))
    result := RCSH_HttpRequest("PUT", path, bytes, true, "image/jpeg")
    if !result.ok
        RCSH_SetError("snapshot: " result.msg)
    return result.ok
}

RCSH_HandleLiveControl(resp) {
    global RCSH_LIVE_EXPIRES_AT
    ; Heartbeat/control responses from older servers did not always contain
    ; the flattened live fields.  Missing fields mean "no live update", not
    ; "lease expired"; otherwise every heartbeat can stop a healthy preview.
    if (resp = "" || !InStr(resp, '"selfHostedLiveEnabled"'))
        return false
    enabled := RC_JsonGetBoolean(resp, "selfHostedLiveEnabled", false)
    publishUrl := RC_JsonGetString(resp, "selfHostedLivePublishUrl")
    publishUrls := RC_JsonGetString(resp, "selfHostedLivePublishUrls")
    RCSH_LIVE_EXPIRES_AT := RC_JsonGetInteger(resp, "selfHostedLiveExpiresAt", 0)
    if (enabled && publishUrl != "")
        RCSH_StartLivePreview(publishUrl, publishUrls)
    else
        RCSH_StopLivePreview("lease expired")
    return true
}

RCSH_ExpireLivePreviewIfNeeded() {
    global RCSH_LIVE_PID, RCSH_LIVE_EXPIRES_AT
    if (RCSH_LIVE_PID > 0 && RCSH_LIVE_EXPIRES_AT > 0
        && RC_UnixMs() >= RCSH_LIVE_EXPIRES_AT) {
        RCSH_LIVE_EXPIRES_AT := 0
        RCSH_StopLivePreview("local lease deadline reached")
        return true
    }
    return false
}

RCSH_StartLivePreview(publishUrl, publishUrls := "") {
    global RCSH_LIVE_PID, RCSH_LIVE_URL, RCSH_LIVE_SOURCE_URL
    global RCSH_LIVE_STARTED_AT, RCSH_LIVE_ROUTE, RCSH_PREVIEW_MARKER
    global RCSH_LIVE_CANDIDATES, RCSH_LIVE_CANDIDATE_INDEX
    publishUrl := Trim(publishUrl, " `t`r`n")
    if (publishUrl = "")
        return false

    nowMs := RC_UnixMs()
    sameLease := RCSH_LIVE_SOURCE_URL = publishUrl
    if (RCSH_LIVE_PID > 0 && ProcessExist(RCSH_LIVE_PID)) {
        if sameLease
            return true
        RCSH_StopLivePreview("lease changed")
        sameLease := false
    } else if (sameLease && RCSH_LIVE_PID > 0) {
        elapsedMs := RCSH_LIVE_STARTED_AT > 0 ? Max(0, nowMs - RCSH_LIVE_STARTED_AT) : 0
        previousRoute := RCSH_LIVE_ROUTE
        ; The preferred LAN route can fail when a device is outside the home
        ; network. Rotate through the server-provided LAN/public candidates;
        ; localhost remains the final same-host compatibility fallback.
        if (elapsedMs <= 30000 && RCSH_LIVE_CANDIDATES.Length > 1)
            RCSH_LIVE_CANDIDATE_INDEX := Mod(RCSH_LIVE_CANDIDATE_INDEX,
                RCSH_LIVE_CANDIDATES.Length) + 1
        else
            RCSH_LIVE_CANDIDATE_INDEX := 1
        RC_Log("Self-hosted live preview exited early. route=" previousRoute
            " elapsedMs=" elapsedMs " retryCandidate=" RCSH_LIVE_CANDIDATE_INDEX
            "/" RCSH_LIVE_CANDIDATES.Length, "WARN")
        RCSH_LIVE_PID := 0
        RCSH_LIVE_URL := ""
        RCSH_LIVE_STARTED_AT := 0
    }

    if !sameLease {
        RCSH_LIVE_SOURCE_URL := publishUrl
        RCSH_LIVE_CANDIDATES := RCSH_BuildLiveCandidates(publishUrl, publishUrls)
        RCSH_LIVE_CANDIDATE_INDEX := 1
    }

    if (RCSH_LIVE_CANDIDATES.Length = 0)
        RCSH_LIVE_CANDIDATES := RCSH_BuildLiveCandidates(publishUrl, publishUrls)
    if (RCSH_LIVE_CANDIDATE_INDEX < 1
        || RCSH_LIVE_CANDIDATE_INDEX > RCSH_LIVE_CANDIDATES.Length)
        RCSH_LIVE_CANDIDATE_INDEX := 1
    effectiveUrl := RCSH_LIVE_CANDIDATES[RCSH_LIVE_CANDIDATE_INDEX]
    RCSH_LIVE_ROUTE := RCSH_DescribeLiveRoute(effectiveUrl,
        RCSH_LIVE_CANDIDATE_INDEX, RCSH_LIVE_CANDIDATES.Length)
    ffmpegExe := ""
    try ffmpegExe := ResolveScreenRecordingFfmpegExePath("")
    if (ffmpegExe = "" || !FileExist(ffmpegExe)) {
        RCSH_SetError("live preview: ffmpeg.exe not found")
        return false
    }
    cmd := '"' ffmpegExe '" -hide_banner -loglevel warning -f gdigrab -framerate 12 -i desktop '
        . '-vf "scale=-2:720" -an -c:v libx264 -preset ultrafast -tune zerolatency '
        . '-pix_fmt yuv420p -b:v 1500k -maxrate 1500k -bufsize 3000k -g 24 '
        . '-metadata comment=' RCSH_PREVIEW_MARKER ' -f mpegts "' effectiveUrl '"'
    try {
        pid := 0
        Run(cmd, , "Hide", &pid)
        if (pid <= 0) {
            RCSH_SetError("live preview: FFmpeg returned no PID")
            return false
        }
        RCSH_LIVE_PID := pid
        RCSH_LIVE_URL := effectiveUrl
        RCSH_LIVE_STARTED_AT := nowMs
        RC_Log("Self-hosted live preview started. pid=" pid " route=" RCSH_LIVE_ROUTE)
        ; Re-check independently from the 10-second control poll so localhost
        ; fallback starts promptly without blocking the farming workflow.
        SetTimer(RCSH_LiveStartupWatchdog.Bind(publishUrl, pid), -12000)
        return true
    } catch as e {
        RCSH_SetError("live preview start: " e.Message)
        return false
    }
}

RCSH_LiveStartupWatchdog(publishUrl, expectedPid) {
    global RCSH_LIVE_PID, RCSH_LIVE_SOURCE_URL, RCSH_LIVE_EXPIRES_AT
    if (RCSH_LIVE_PID != expectedPid || RCSH_LIVE_SOURCE_URL != publishUrl)
        return
    if (RCSH_LIVE_EXPIRES_AT > 0 && RC_UnixMs() >= RCSH_LIVE_EXPIRES_AT) {
        RCSH_StopLivePreview("startup watchdog found expired lease")
        return
    }
    if !ProcessExist(expectedPid)
        RCSH_StartLivePreview(publishUrl)
}

RCSH_LoopbackSrtUrl(publishUrl) {
    loopbackUrl := RegExReplace(publishUrl,
        "i)^srt://(?:\[[^\]]+\]|[^:/?]+):", "srt://127.0.0.1:", &replaceCount, 1)
    return replaceCount = 1 ? loopbackUrl : ""
}

RCSH_BuildLiveCandidates(primaryUrl, publishUrls := "") {
    candidates := []
    seen := Map()
    for rawUrl in StrSplit(publishUrls, "|")
        RCSH_AddLiveCandidate(candidates, seen, rawUrl)
    RCSH_AddLiveCandidate(candidates, seen, primaryUrl)
    RCSH_AddLiveCandidate(candidates, seen, RCSH_LoopbackSrtUrl(primaryUrl))
    return candidates
}

RCSH_AddLiveCandidate(candidates, seen, candidateUrl) {
    candidateUrl := Trim(candidateUrl, " `t`r`n")
    if (candidateUrl = "" || !RegExMatch(candidateUrl, "i)^srt://"))
        return false
    key := StrLower(candidateUrl)
    if seen.Has(key)
        return false
    seen[key] := true
    candidates.Push(candidateUrl)
    return true
}

RCSH_DescribeLiveRoute(candidateUrl, index, total) {
    if RegExMatch(candidateUrl, "i)^srt://(?:127\.0\.0\.1|localhost):")
        return "loopback"
    return index = 1 ? "preferred" : "fallback-" index "/" total
}

RCSH_StopLivePreview(reason := "") {
    global RCSH_LIVE_PID, RCSH_LIVE_URL, RCSH_LIVE_SOURCE_URL
    global RCSH_LIVE_STARTED_AT, RCSH_LIVE_ROUTE
    global RCSH_LIVE_CANDIDATES, RCSH_LIVE_CANDIDATE_INDEX
    pid := RCSH_LIVE_PID
    RCSH_LIVE_PID := 0
    RCSH_LIVE_URL := ""
    RCSH_LIVE_SOURCE_URL := ""
    RCSH_LIVE_STARTED_AT := 0
    RCSH_LIVE_ROUTE := "public"
    RCSH_LIVE_CANDIDATES := []
    RCSH_LIVE_CANDIDATE_INDEX := 0
    if (pid <= 0)
        return true
    try {
        if ProcessExist(pid)
            ProcessClose(pid)
        RC_Log("Self-hosted live preview stopped. pid=" pid " reason=" reason)
        return true
    } catch as e {
        RC_Log("Self-hosted live preview stop failed for pid=" pid ": " e.Message, "WARN")
        return false
    }
}

RCSH_CleanupOrphanLivePreviews() {
    global RCSH_PREVIEW_MARKER
    marker := StrLower(RCSH_PREVIEW_MARKER)
    stopped := 0
    try {
        for process in ComObjGet("winmgmts:").ExecQuery(
            "Select ProcessId,CommandLine from Win32_Process where Name='ffmpeg.exe'") {
            commandLine := ""
            try commandLine := StrLower(process.CommandLine "")
            if (commandLine = "" || !InStr(commandLine, marker))
                continue
            pid := process.ProcessId + 0
            if (pid > 0 && ProcessExist(pid)) {
                ProcessClose(pid)
                stopped += 1
            }
        }
    } catch as e {
        RC_Log("Self-hosted orphan preview scan failed: " e.Message, "WARN")
    }
    if (stopped > 0)
        RC_Log("Self-hosted startup removed orphan preview FFmpeg count=" stopped, "WARN")
    return stopped
}

RCSH_Shutdown() {
    if RCSH_IsAvailable()
        try RCSH_SendHeartbeat("OFFLINE")
    RCSH_StopLivePreview("script shutdown")
}

RCSH_HttpRequest(method, apiPath, body := "", authenticated := true,
    contentType := "application/json; charset=utf-8") {
    global RCSH_SERVER_URL, RCSH_DEVICE_TOKEN, RC_TIMEOUT_MS, RCSH_ENROLLED
    global RCSH_HTTP_FAILURE_COUNT, RCSH_HTTP_RETRY_AFTER
    result := {ok: false, status: 0, body: "", msg: ""}
    if (RCSH_SERVER_URL = "") {
        result.msg := "self-hosted server URL is empty"
        return result
    }
    nowMs := RC_UnixMs()
    if (RCSH_HTTP_RETRY_AFTER > nowMs) {
        result.msg := "self-hosted retry backoff until " RCSH_HTTP_RETRY_AFTER
        return result
    }
    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        ; 控制傳輸不可長時間佔住 AHK 主執行緒；大型影片另由背景 PowerShell 上傳。
        timeout := Max(1500, Min(5000, RC_TIMEOUT_MS))
        http.SetTimeouts(timeout, timeout, timeout, timeout)
        http.Open(method, RCSH_SERVER_URL apiPath, false)
        http.SetRequestHeader("Content-Type", contentType)
        http.SetRequestHeader("Accept", "application/json")
        http.SetRequestHeader("Cache-Control", "no-cache")
        if (authenticated && RCSH_DEVICE_TOKEN != "")
            http.SetRequestHeader("Authorization", "Bearer " RCSH_DEVICE_TOKEN)
        if IsObject(body)
            http.Send(body)
        else if (body != "")
            http.Send(body)
        else
            http.Send()
        result.status := http.Status + 0
        try result.body := http.ResponseText
        result.ok := result.status >= 200 && result.status < 300
        if result.ok {
            RCSH_HTTP_FAILURE_COUNT := 0
            RCSH_HTTP_RETRY_AFTER := 0
        } else {
            result.msg := "HTTP " result.status " " SubStr(result.body, 1, 1200)
            if (result.status = 401 && authenticated)
                RCSH_ENROLLED := false
            RCSH_MarkHttpFailure()
        }
        return result
    } catch as e {
        result.msg := e.Message
        RCSH_MarkHttpFailure()
        return result
    }
}

RCSH_MarkHttpFailure() {
    global RCSH_HTTP_FAILURE_COUNT, RCSH_HTTP_RETRY_AFTER
    RCSH_HTTP_FAILURE_COUNT += 1
    ; 30、60、120、240、300 秒，之後維持最多 5 分鐘；成功一次立即歸零。
    exponent := Min(4, RCSH_HTTP_FAILURE_COUNT - 1)
    delaySec := Min(300, 30 * (2 ** exponent))
    RCSH_HTTP_RETRY_AFTER := RC_UnixMs() + delaySec * 1000
}

RCSH_SetError(message) {
    global RCSH_LAST_ERROR, RCSH_LAST_ERROR_LOG_AT
    normalized := SubStr(message, 1, 1200)
    nowMs := RC_UnixMs()
    shouldLog := normalized != RCSH_LAST_ERROR || nowMs - RCSH_LAST_ERROR_LOG_AT >= 300000
    RCSH_LAST_ERROR := normalized
    if !shouldLog
        return
    RCSH_LAST_ERROR_LOG_AT := nowMs
    RC_Log("Self-hosted " RCSH_LAST_ERROR, "WARN")
}

RCSH_UrlEncode(text) {
    byteCount := StrPut(text, "UTF-8") - 1
    if (byteCount <= 0)
        return ""
    utf8Buffer := Buffer(byteCount + 1, 0)
    StrPut(text, utf8Buffer, "UTF-8")
    out := ""
    Loop byteCount {
        value := NumGet(utf8Buffer, A_Index - 1, "UChar")
        if ((value >= 0x30 && value <= 0x39) || (value >= 0x41 && value <= 0x5A)
            || (value >= 0x61 && value <= 0x7A) || value = 0x2D || value = 0x2E
            || value = 0x5F || value = 0x7E)
            out .= Chr(value)
        else
            out .= "%" Format("{:02X}", value)
    }
    return out
}

RCSH_Base64ToVariant(base64Text) {
    document := ComObject("Msxml2.DOMDocument.6.0")
    node := document.createElement("base64")
    node.dataType := "bin.base64"
    node.text := base64Text
    return node.nodeTypedValue
}

RCSH_RandomToken(byteCount := 48) {
    randomBuffer := Buffer(byteCount, 0)
    status := DllCall("bcrypt\BCryptGenRandom", "ptr", 0, "ptr", randomBuffer.Ptr,
        "uint", byteCount, "uint", 0x00000002, "uint")
    if (status != 0)
        throw Error("BCryptGenRandom failed: " status)
    return StrReplace(StrReplace(RTrim(RCSH_Base64Encode(randomBuffer), "=`r`n"), "+", "-"), "/", "_")
}

RCSH_DpapiProtect(text) {
    byteCount := StrPut(text, "UTF-8") - 1
    input := Buffer(byteCount + 1, 0)
    StrPut(text, input, "UTF-8")
    protected := RCSH_DpapiTransform(input, byteCount, true)
    return RCSH_Base64Encode(protected)
}

RCSH_DpapiUnprotect(base64Text) {
    encrypted := RCSH_Base64Decode(base64Text)
    plain := RCSH_DpapiTransform(encrypted, encrypted.Size, false)
    return StrGet(plain.Ptr, plain.Size, "UTF-8")
}

RCSH_DpapiTransform(input, inputSize, protect) {
    pointerOffset := A_PtrSize = 8 ? 8 : 4
    blobSize := A_PtrSize = 8 ? 16 : 8
    inputBlob := Buffer(blobSize, 0)
    outputBlob := Buffer(blobSize, 0)
    NumPut("UInt", inputSize, inputBlob, 0)
    NumPut("Ptr", input.Ptr, inputBlob, pointerOffset)
    description := 0
    if protect {
        ok := DllCall("crypt32\CryptProtectData", "ptr", inputBlob.Ptr,
            "wstr", "Wuthering self-hosted device", "ptr", 0, "ptr", 0,
            "ptr", 0, "uint", 0x1, "ptr", outputBlob.Ptr, "int")
    } else {
        ok := DllCall("crypt32\CryptUnprotectData", "ptr", inputBlob.Ptr,
            "ptr*", &description, "ptr", 0, "ptr", 0, "ptr", 0,
            "uint", 0x1, "ptr", outputBlob.Ptr, "int")
    }
    if !ok
        throw OSError(A_LastError, protect ? "CryptProtectData" : "CryptUnprotectData")
    outputSize := NumGet(outputBlob, 0, "UInt")
    outputPointer := NumGet(outputBlob, pointerOffset, "Ptr")
    output := Buffer(outputSize, 0)
    if (outputSize > 0)
        DllCall("kernel32\RtlMoveMemory", "ptr", output.Ptr, "ptr", outputPointer, "uptr", outputSize)
    if outputPointer
        DllCall("kernel32\LocalFree", "ptr", outputPointer, "ptr")
    if description
        DllCall("kernel32\LocalFree", "ptr", description, "ptr")
    return output
}

RCSH_Base64Encode(inputBuffer) {
    chars := 0
    flags := 0x40000001 ; CRYPT_STRING_BASE64 | NOCRLF
    if !DllCall("crypt32\CryptBinaryToStringW", "ptr", inputBuffer.Ptr, "uint", inputBuffer.Size,
        "uint", flags, "ptr", 0, "uint*", &chars)
        throw OSError(A_LastError, "CryptBinaryToStringW(size)")
    output := Buffer(chars * 2, 0)
    if !DllCall("crypt32\CryptBinaryToStringW", "ptr", inputBuffer.Ptr, "uint", inputBuffer.Size,
        "uint", flags, "ptr", output.Ptr, "uint*", &chars)
        throw OSError(A_LastError, "CryptBinaryToStringW")
    return StrGet(output, "UTF-16")
}

RCSH_Base64Decode(text) {
    bytes := 0
    if !DllCall("crypt32\CryptStringToBinaryW", "wstr", text, "uint", 0,
        "uint", 0x1, "ptr", 0, "uint*", &bytes, "ptr", 0, "ptr", 0)
        throw OSError(A_LastError, "CryptStringToBinaryW(size)")
    output := Buffer(bytes, 0)
    if !DllCall("crypt32\CryptStringToBinaryW", "wstr", text, "uint", 0,
        "uint", 0x1, "ptr", output.Ptr, "uint*", &bytes, "ptr", 0, "ptr", 0)
        throw OSError(A_LastError, "CryptStringToBinaryW")
    return output
}
