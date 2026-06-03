; Firestore-based remote control MVP for AHK v2
; This module is intentionally self-contained and optional.

global RC_ENABLED := false
global RC_PROJECT_ID := ""
global RC_API_KEY := ""
global RC_COLLECTION := "ahk_clients"
global RC_CFG_PATH := ""
global RC_UID := ""
global RC_DISPLAY_NAME := ""
global RC_CONTROL_SECRET := ""
global RC_HEARTBEAT_INTERVAL_MS := 90000
global RC_POLL_INTERVAL_MS := 5000
global RC_TIMEOUT_MS := 2500
global RC_LAST_NONCE := 0
global RC_REMOTE_DESIRED_STATE := "RUN"
global RC_REMOTE_PAUSED := false
global RC_LAST_HEARTBEAT_OK := 0
global RC_LAST_ERROR_MSG := ""
global RC_ON_STATE_CHANGED := ""

RC_Init(cfgPath, onStateChangedCallback := "") {
    global RC_ENABLED, RC_PROJECT_ID, RC_API_KEY, RC_COLLECTION, RC_CFG_PATH, RC_UID, RC_DISPLAY_NAME
    global RC_CONTROL_SECRET, RC_HEARTBEAT_INTERVAL_MS, RC_POLL_INTERVAL_MS, RC_TIMEOUT_MS
    global RC_ON_STATE_CHANGED, RC_REMOTE_DESIRED_STATE

    RC_EnsureIniFileUnicode(cfgPath)
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

    RC_CONTROL_SECRET := Trim(RC_IniReadSafe(cfgPath, "remote_control", "control_secret", ""), " `t`r`n")
    RC_HEARTBEAT_INTERVAL_MS := RC_ToIntRange(RC_IniReadSafe(cfgPath, "remote_control", "heartbeat_interval_ms", "90000"), 90000, 3000, 300000)
    RC_POLL_INTERVAL_MS := RC_ToIntRange(RC_IniReadSafe(cfgPath, "remote_control", "poll_interval_ms", "5000"), 5000, 1000, 30000)
    RC_TIMEOUT_MS := RC_ToIntRange(RC_IniReadSafe(cfgPath, "remote_control", "http_timeout_ms", "2500"), 2500, 800, 10000)

    RC_UID := Trim(RC_IniReadSafe(cfgPath, "remote_control", "uid", ""), " `t`r`n")
    if (RC_UID = "") {
        RC_UID := RC_BuildClientUid()
        try IniWrite(RC_UID, cfgPath, "remote_control", "uid")
    }

    RC_DISPLAY_NAME := Trim(RC_IniReadSafe(cfgPath, "remote_control", "display_name", ""), " `t`r`n")
    if (RC_DISPLAY_NAME = "") {
        RC_DISPLAY_NAME := A_ComputerName
        try IniWrite(RC_DISPLAY_NAME, cfgPath, "remote_control", "display_name")
    }

    RC_REMOTE_DESIRED_STATE := "RUN"
    RC_LAST_NONCE := RC_ToIntRange(RC_IniReadSafe(cfgPath, "remote_control", "last_nonce", "0"), 0, 0, 2147483647)

    RC_StartupDefaultRun()

    RC_Log("RemoteControl initialized. uid=" RC_UID " collection=" RC_COLLECTION)
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
    secret := RC_JsonGetString(resp, "controlSecret")

    if (secret != "" && secret != RC_CONTROL_SECRET) {
        RC_LAST_ERROR_MSG := "control secret mismatch"
        return
    }

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

RC_PatchClientState(state, isShutdown) {
    global RC_LAST_HEARTBEAT_OK, RC_LAST_ERROR_MSG
    nowMs := RC_UnixMs()

    body := "{"
    body .= '"fields":{'
    body .= '"uid":{"stringValue":"' RC_JsonEsc(RC_UID) '"},'
    body .= '"displayName":{"stringValue":"' RC_JsonEsc(RC_DISPLAY_NAME) '"},'
    body .= '"computerName":{"stringValue":"' RC_JsonEsc(A_ComputerName) '"},'
    body .= '"status":{"stringValue":"' RC_JsonEsc(state) '"},'
    body .= '"lastHeartbeat":{"integerValue":"' nowMs '"},'
    body .= '"updatedAt":{"integerValue":"' nowMs '"}'
    body .= "}"
    body .= "}"

    url := RC_ClientDocUrl()
    url .= "&updateMask.fieldPaths=uid"
    url .= "&updateMask.fieldPaths=displayName"
    url .= "&updateMask.fieldPaths=computerName"
    url .= "&updateMask.fieldPaths=status"
    url .= "&updateMask.fieldPaths=lastHeartbeat"
    url .= "&updateMask.fieldPaths=updatedAt"

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

    r := RC_HttpRequest("PATCH", url, body)
    if !r.ok
        RC_Log("RemoteControl ack patch failed: " r.msg, "WARN")
}

RC_FirestoreGetClientDoc() {
    r := RC_HttpRequest("GET", RC_ClientDocUrl(), "")
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
        v := StrReplace(v, '\\"', '"')
        v := StrReplace(v, "\\\\", "\\")
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
    s := StrReplace(s, "\\", "\\\\")
    s := StrReplace(s, '"', '\\"')
    s := StrReplace(s, "`r", "\\r")
    s := StrReplace(s, "`n", "\\n")
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

RC_EnsureIniFileUnicode(filePath) {
    if !FileExist(filePath)
        return false
    if RC_IniFileHasUnicodeBom(filePath)
        return false

    text := RC_ReadIniTextBestEffort(filePath)
    if (text = "")
        return false

    tmpPath := filePath ".unicode.tmp"
    try {
        stream := ComObject("ADODB.Stream")
        stream.Type := 2
        stream.Charset := "unicode"
        stream.Open()
        stream.WriteText(text)
        stream.SaveToFile(tmpPath, 2)
        stream.Close()
        FileMove(tmpPath, filePath, 1)
        return true
    } catch {
        try FileDelete(tmpPath)
        return false
    }
}

RC_IniFileHasUnicodeBom(filePath) {
    try {
        f := FileOpen(filePath, "r")
        if !IsObject(f)
            return false
        bom := Buffer(3, 0)
        read := f.RawRead(bom, 3)
        f.Close()
        if (read >= 2) {
            b0 := NumGet(bom, 0, "UChar")
            b1 := NumGet(bom, 1, "UChar")
            if ((b0 = 0xFF && b1 = 0xFE) || (b0 = 0xFE && b1 = 0xFF))
                return true
        }
        if (read >= 3) {
            b0 := NumGet(bom, 0, "UChar")
            b1 := NumGet(bom, 1, "UChar")
            b2 := NumGet(bom, 2, "UChar")
            if (b0 = 0xEF && b1 = 0xBB && b2 = 0xBF)
                return true
        }
    }
    return false
}

RC_ReadIniTextBestEffort(filePath) {
    bestText := ""
    bestScore := -2147483647
    for charset in ["utf-8", "gb2312", "big5"] {
        text := RC_ReadTextFileWithCharset(filePath, charset)
        score := RC_ScoreIniDecodedText(text)
        if (score > bestScore) {
            bestScore := score
            bestText := text
        }
    }
    return bestText
}

RC_ReadTextFileWithCharset(filePath, charset) {
    try {
        stream := ComObject("ADODB.Stream")
        stream.Type := 2
        stream.Charset := charset
        stream.Open()
        stream.LoadFromFile(filePath)
        text := stream.ReadText(-1)
        stream.Close()
        return text
    } catch {
        return ""
    }
}

RC_ScoreIniDecodedText(text) {
    if (text = "")
        return -2147483647

    score := 0
    for token in ["�", "锟", "嚙", "ｽ", "", "�"] {
        count := 0
        StrReplace(text, token, "", , &count)
        score -= count * 25
    }

    Loop Parse, text {
        ch := A_LoopField
        code := Ord(ch)
        if (code = 0) {
            score -= 100
        } else if (code = 9 || code = 10 || code = 13) {
            continue
        } else if (code >= 32 && code <= 126) {
            score += 1
        } else if ((code >= 0x3400 && code <= 0x4DBF) || (code >= 0x4E00 && code <= 0x9FFF)) {
            score += 2
        } else if (code >= 0xE000 && code <= 0xF8FF) {
            score -= 3
        } else {
            score -= 1
        }
    }
    return score
}

RC_EnsureRemoteControlDefaults(cfgPath) {
    defaults := Map(
        "enabled", "1",
        "project_id", "ww-control-a3988",
        "api_key", "AIzaSyDqWHdBixVQPt4OiTi50hseInFxPtk0hf0",
        "collection", "ahk_clients",
        "uid", "",
        "display_name", "",
        "control_secret", "ww-control-a3988-shared-2026",
        "heartbeat_interval_ms", "90000",
        "poll_interval_ms", "5000",
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
