#Requires AutoHotkey v2.0+
#SingleInstance Off
#Include LauncherProcessCleanupPolicy.ahk
SetWorkingDir A_ScriptDir

global RUN_ID := FormatTime(, "yyyyMMdd_HHmmss") "@" A_TickCount
global PACK_LAUNCHER_BUILD_VERSION := "4.97"
global STEP_SEQ := 0
global TOOLTIP_SLOT := 5
global SKIP_PENDING_LAUNCHER_APPLY := false
global PACK_MAIN_MUTEX_HANDLE := 0

LauncherIsDevelopmentCheckout() {
    root := RTrim(StrReplace(A_ScriptDir, "/", "\"), "\")
    return (DirExist(root "\.git") || FileExist(root "\.git"))
        && FileExist(root "\payload\RuntimeFilePaths.ahk")
        && FileExist(root "\打包更新.ps1")
}

LauncherProjectRoot() {
    dir := RTrim(StrReplace(A_ScriptDir, "/", "\"), "\")
    ; 直接執行 repo 內的原始碼時，所有下載、解壓、設定、Log 與
    ; 暫存都隔離到 .dev-runtime，不改寫原始碼樹。
    if LauncherIsDevelopmentCheckout()
        return dir "\.dev-runtime\launcher-app"
    SplitPath(dir, &leaf)
    ; 已安裝資料夾與原始碼工作區都直接視為專案根目錄；只有首次下載、
    ; 同層尚無 payload/config 時才使用「自動鋤地」子資料夾。
    if (DirExist(dir "\payload") || DirExist(dir "\config")
        || InStr(leaf, "自動鋤地"))
        return dir
    return dir "\自動鋤地"
}

LauncherRuntimeDir(category := "") {
    dir := LauncherProjectRoot() "\執行暫存"
    safeCategory := Trim(String(category), " `t`r`n\")
    if (safeCategory != "") {
        safeCategory := RegExReplace(safeCategory, '[<>:"/\\|?*]', "_")
        dir .= "\" safeCategory
    }
    if !DirExist(dir)
        DirCreate(dir)
    return dir
}

LauncherNewTempPath(prefix, extension := ".tmp", category := "更新") {
    safePrefix := RegExReplace(Trim(String(prefix)), "[^0-9A-Za-z_-]", "_")
    if (safePrefix = "")
        safePrefix := "launcher"
    ext := Trim(String(extension))
    if (SubStr(ext, 1, 1) != ".")
        ext := "." ext
    return LauncherRuntimeDir(category) "\" safePrefix "_" DllCall("GetCurrentProcessId") "_" A_TickCount ext
}

LauncherPruneLogs(logDir, keepCount := 15) {
    logs := []
    Loop Files, logDir "\打包啟動器_*.log", "F"
        logs.Push({path: A_LoopFileFullPath, modified: A_LoopFileTimeModified})
    while (logs.Length > Max(1, keepCount)) {
        oldestIndex := 1
        Loop logs.Length {
            if (logs[A_Index].modified < logs[oldestIndex].modified)
                oldestIndex := A_Index
        }
        try FileDelete(logs[oldestIndex].path)
        logs.RemoveAt(oldestIndex)
    }
}

LauncherLogPath() {
    static logPath := ""
    if (logPath != "")
        return logPath
    logDir := LauncherProjectRoot() "\log\打包啟動器"
    if !DirExist(logDir)
        DirCreate(logDir)
    logPath := logDir "\打包啟動器_" FormatTime(, "yyyyMMdd_HHmmss") "_" DllCall("GetCurrentProcessId") ".log"
    LauncherPruneLogs(logDir, 15)

    ; 舊版單一巨大 fallback log 搬入同一資料夾保存，不留在根目錄。
    legacyLog := A_ScriptDir "\打包啟動器_fallback.log"
    if FileExist(legacyLog) && StrLower(legacyLog) != StrLower(logPath) {
        legacyDest := logDir "\打包啟動器_legacy_" FormatTime(FileGetTime(legacyLog, "M"), "yyyyMMdd_HHmmss") ".log"
        if FileExist(legacyDest)
            legacyDest := logDir "\打包啟動器_legacy_" A_TickCount ".log"
        try FileMove(legacyLog, legacyDest, 1)
    }
    return logPath
}

; payload 內的 FolderPickerHelper 是主要資料夾選擇器；此模式只作為舊 payload
; 或 helper 遺失時的相容後備，且必須在提權、自我更新與主 mutex 之前執行。
if LauncherHasArg("--pick-folder") {
    LauncherRunFolderPickerMode()
    ExitApp
}

ShowTip(msg, duration := 5000) {
    global TOOLTIP_SLOT
    if (duration < 5000)
        duration := 5000
    ToolTip "          " msg, , , TOOLTIP_SLOT
    if (duration > 0)
        SetTimer(() => ToolTip(, , , TOOLTIP_SLOT), -duration)
}

WriteStep(stepName, detail := "", level := "INFO") {
    global STEP_SEQ
    STEP_SEQ += 1
    msg := "[STEP " Format("{:03}", STEP_SEQ) "] " stepName
    if (detail != "")
        msg .= " | " detail
    WriteLog(msg, level)
    ShowTip("📌 " stepName)
}

; 初始化備用日誌系統（獨立實現，避免依賴外部檔案）
WriteLog(msg, level := "INFO") {
    global RUN_ID
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    line := ts " [" level "] [" RUN_ID "] " msg "`r`n"
    try FileAppend(line, LauncherLogPath(), "UTF-8")
}

ResolveBundledAhkExeForLauncher() {
    candidates := []
    candidates.Push(A_ScriptDir "\AutoHotkey64.exe")
    candidates.Push(A_ScriptDir "\..\AutoHotkey64.exe")

    for _, candidate in candidates {
        p := Trim(candidate, ' "')
        if (p != "" && FileExist(p))
            return p
    }
    return ""
}

JoinArray(items, sep := ",") {
    out := ""
    for idx, v in items {
        if (idx > 1)
            out .= sep
        out .= v
    }
    return out
}

BuildStartupReason() {
    parts := []
    if (A_Args.Length > 0)
        parts.Push("args=" JoinArray(A_Args, "|"))
    else
        parts.Push("args=<none>")

    parts.Push("source=" (A_Args.Length > 0 ? "arg-trigger" : "external-trigger(manual-or-scheduler)"))
    return JoinArray(parts, " | ")
}

LauncherHasArg(name) {
    for _, arg in A_Args {
        if (StrLower(arg) = StrLower(name))
            return true
    }
    return false
}

LauncherArgValue(name, defaultValue := "") {
    target := StrLower(name)
    for idx, arg in A_Args {
        if (StrLower(arg) = target && idx < A_Args.Length)
            return A_Args[idx + 1]
    }
    return defaultValue
}

LauncherAdminForwardArgs() {
    ; 主啟動器只轉送自己理解、且不含使用者輸入值的旗標。
    ; 資料夾 picker 在提權前已結束，不會進入這裡。
    args := ""
    for _, flag in ["--force-update", "--resume-current-task", "--cleanup-recordings"] {
        if LauncherHasArg(flag)
            args .= " " flag
    }
    return args
}

LauncherNormalizePath(pathValue) {
    p := Trim(pathValue, ' "`t`r`n')
    if (p = "")
        return ""
    p := StrReplace(p, "/", "\")
    if (StrLen(p) > 3)
        p := RTrim(p, "\")
    return p
}

LauncherMappedPathToUnc(pathValue) {
    p := LauncherNormalizePath(pathValue)
    if (p = "" || SubStr(p, 1, 2) = "\\")
        return p
    if !RegExMatch(p, "i)^([a-z]:)(\\.*)?$", &m)
        return p

    ; 在一般權限 helper 中優先讓 Windows 網路提供者直接解析完整路徑。
    required := 0
    rc := DllCall("Mpr\WNetGetUniversalNameW", "str", p, "uint", 1,
        "ptr", 0, "uint*", &required, "uint")
    if (rc = 234 && required > A_PtrSize) { ; ERROR_MORE_DATA
        info := Buffer(required, 0)
        rc := DllCall("Mpr\WNetGetUniversalNameW", "str", p, "uint", 1,
            "ptr", info.Ptr, "uint*", &required, "uint")
        if (rc = 0) {
            uncPtr := NumGet(info, 0, "ptr")
            if (uncPtr)
                return LauncherNormalizePath(StrGet(uncPtr, "UTF-16"))
        }
    }

    ; 某些網路提供者不支援 UniversalName，改查磁碟代號的遠端根路徑。
    remoteBuf := Buffer(65536, 0)
    remoteChars := 32768
    rc := DllCall("Mpr\WNetGetConnectionW", "str", m[1], "ptr", remoteBuf.Ptr,
        "uint*", &remoteChars, "uint")
    if (rc = 0) {
        remoteRoot := RTrim(StrGet(remoteBuf.Ptr, "UTF-16"), "\")
        suffix := m[2]
        return LauncherNormalizePath(remoteRoot suffix)
    }

    ; 持久映射會記錄在目前使用者 HKCU；這也是網路暫斷時的最後後備。
    try {
        driveLetter := SubStr(m[1], 1, 1)
        remoteRoot := Trim(RegRead("HKCU\Network\" driveLetter, "RemotePath"), ' "`t`r`n')
        if (remoteRoot != "") {
            suffix := m[2]
            return LauncherNormalizePath(RTrim(remoteRoot, "\") suffix)
        }
    }
    return p
}

LauncherWriteFolderPickerReply(replyPath, status, selectedPath := "", message := "") {
    if (replyPath = "")
        return false
    try {
        replyDir := ""
        SplitPath(replyPath, , &replyDir)
        if (replyDir != "" && !DirExist(replyDir))
            DirCreate(replyDir)
        try FileDelete(replyPath)
        IniWrite(status, replyPath, "result", "status")
        IniWrite(selectedPath, replyPath, "result", "path")
        IniWrite(message, replyPath, "result", "message")
        IniWrite(A_IsAdmin ? "1" : "0", replyPath, "result", "helper_was_admin")
        return true
    } catch {
        return false
    }
}

LauncherRunFolderPickerMode() {
    replyPath := LauncherNormalizePath(LauncherArgValue("--reply", ""))
    initialPath := LauncherNormalizePath(LauncherArgValue("--initial", ""))
    if (replyPath = "")
        return

    try {
        ; 後備模式至少固定從「這台電腦」開始，避免目前工作目錄讓 Windows
        ; 對話框只顯示本機資料夾；新版 payload 會改用完整的自訂選擇器。
        shell := ComObject("Shell.Application")
        folder := shell.BrowseForFolder(0,
            "選擇錄影輸出資料夾（可選本機、映射磁碟或網路共用）", 0x8051, 17)
        selected := ""
        if IsObject(folder)
            try selected := folder.Self.Path
        if (selected = "") {
            LauncherWriteFolderPickerReply(replyPath, "cancel")
            return
        }
        resolved := LauncherMappedPathToUnc(selected)
        LauncherWriteFolderPickerReply(replyPath, "ok", resolved)
    } catch as e {
        LauncherWriteFolderPickerReply(replyPath, "error", "", e.Message)
    }
}

LauncherHashText(textValue) {
    ; 32-bit FNV-1a，只用來產生合法且依安裝路徑區分的 mutex 名稱。
    hash := 2166136261
    Loop Parse, StrLower(textValue) {
        hash := (hash ^ Ord(A_LoopField)) & 0xFFFFFFFF
        hash := Mod(hash * 16777619, 0x100000000)
    }
    return Format("{:08X}", hash)
}

LauncherAcquireMainMutex() {
    name := "Local\WutheringAutoLauncher_" LauncherHashText(A_ScriptFullPath)
    handle := DllCall("CreateMutexW", "ptr", 0, "int", true, "str", name, "ptr")
    lastErr := A_LastError
    if (!handle)
        return 0
    if (lastErr = 183) { ; ERROR_ALREADY_EXISTS
        DllCall("CloseHandle", "ptr", handle)
        return -1
    }
    return handle
}

LifecycleOnExit(exitReason, exitCode) {
    WriteLog("生命週期停止原因: reason=" exitReason " | exitCode=" exitCode)
}

WriteLog("打包啟動器開始: " A_ScriptFullPath " | build=" PACK_LAUNCHER_BUILD_VERSION)
WriteLog("生命週期啟動原因: " BuildStartupReason())
OnExit(LifecycleOnExit)
WriteStep("啟動", "PID=" DllCall("GetCurrentProcessId") " AHK=" A_AhkVersion)
WriteStep("工作目錄", A_WorkingDir)

CleanupLauncherReplaceBatFiles(baseDir) {
    if (baseDir = "" || !DirExist(baseDir))
        return 0

    deleted := 0
    Loop Files, baseDir "\launcher_replace_*.bat", "F" {
        try {
            try FileSetAttrib("-R", A_LoopFileFullPath)
            FileDelete(A_LoopFileFullPath)
            deleted += 1
        }
    }
    return deleted
}

IniReadSafe(file, section, key, default := "") {
    try {
        return IniRead(file, section, key, default)
    } catch {
        return default
    }
}

JsonGetString(jsonText, key) {
    pattern := '"' key '"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"'
    if RegExMatch(jsonText, pattern, &m) {
        val := m[1]
        val := StrReplace(val, "\\/", "/")
        val := StrReplace(val, '\\"', '"')
        val := StrReplace(val, "\\n", "`n")
        val := StrReplace(val, "\\r", "`r")
        val := StrReplace(val, "\\t", "`t")
        return val
    }
    return ""
}

GetFileSha256(filePath) {
    outFile := LauncherNewTempPath("hash", ".txt", "更新")
    try {
        cmd := 'cmd /c certutil -hashfile "' filePath '" SHA256 > "' outFile '"'
        rc := RunWait(cmd, , "Hide")
        if (rc != 0)
            return ""

        txt := FileRead(outFile, "UTF-8")
        if RegExMatch(txt, "im)^([0-9A-F ]{64,})$", &m) {
            return StrLower(StrReplace(Trim(m[1]), " "))
        }
        return ""
    } catch {
        return ""
    } finally {
        try FileDelete(outFile)
    }
}

; 若 URL 為 raw.githubusercontent.com，自動轉換為 GitHub API 端點（不受 CDN 快取影響）
ConvertToGitHubApiUrl(url) {
    if RegExMatch(url, "^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$", &m)
        return "https://api.github.com/repos/" m[1] "/" m[2] "/contents/" m[4] "?ref=" m[3]
    return url
}

; HTTP GET 並返回文字（使用系統 Proxy，附帶 no-cache 標頭）
HttpGetText(url, extraHeaders := Map()) {
    http := ComObject("Msxml2.XMLHTTP.6.0")
    http.open("GET", url, false)
    http.setRequestHeader("Cache-Control", "no-cache, no-store, must-revalidate")
    http.setRequestHeader("Pragma", "no-cache")
    http.setRequestHeader("User-Agent", "AHK-Launcher/2.0")
    for k, v in extraHeaders
        http.setRequestHeader(k, v)
    http.send()
    if (http.status != 200)
        throw Error("HTTP " http.status " for: " url)
    return http.responseText
}

; HTTP GET 並將二進位結果寫入檔案（使用系統 Proxy，附帶 no-cache 標頭）
HttpDownloadFile(url, destPath, extraHeaders := Map()) {
    http := ComObject("Msxml2.XMLHTTP.6.0")
    http.open("GET", url, false)
    http.setRequestHeader("Cache-Control", "no-cache, no-store, must-revalidate")
    http.setRequestHeader("Pragma", "no-cache")
    http.setRequestHeader("User-Agent", "AHK-Launcher/2.0")
    for k, v in extraHeaders
        http.setRequestHeader(k, v)
    http.send()
    if (http.status != 200)
        throw Error("HTTP " http.status " for: " url)
    stream := ComObject("ADODB.Stream")
    stream.Type := 1  ; adTypeBinary
    stream.Open()
    stream.Write(http.responseBody)
    stream.SaveToFile(destPath, 2)  ; adSaveCreateOverWrite
    stream.Close()
}

WriteTextFileReplace(path, text, encoding := "UTF-8-RAW") {
    tmpPath := path ".write_" A_TickCount "_" DllCall("GetCurrentProcessId")
    try {
        if FileExist(tmpPath)
            FileDelete(tmpPath)
        FileAppend(text, tmpPath, encoding)
        FileMove(tmpPath, path, 1)
        return true
    } catch as e {
        try FileDelete(tmpPath)
        WriteLog("覆寫狀態檔失敗: " path " | " e.Message, "WARN")
        return false
    }
}

ClearPendingLauncherState(dataDir) {
    ; pending_update.tmp 是唯一的提交標記。清除它與配套中繼資料後，
    ; 本輪結束時就不會再排程舊版本；下載檔本身留給後續維護清理，
    ; 避免相信可能被竄改的狀態檔而刪到任意路徑。
    cleared := true
    for stateFile in [
        dataDir "\\launcher_pending_update.tmp",
        dataDir "\\launcher_pending_version.txt",
        dataDir "\\launcher_pending_sha256.txt"
    ] {
        if !FileExist(stateFile)
            continue
        try FileDelete(stateFile)
        catch as e {
            cleared := false
            WriteLog("清除 launcher pending 狀態失敗: " stateFile " | " e.Message, "WARN")
        }
        if FileExist(stateFile)
            cleared := false
    }
    return cleared
}

FetchRemoteUpdateManifest(dataDir) {
    cfgFile := dataDir "\\config.ini"
    defaultManifestUrl := "https://api.github.com/repos/derek3411888/-/contents/update_manifest.example.json?ref=main"
    enabled := IniReadSafe(cfgFile, "updater", "enabled", "1")
    if (enabled != "1") {
        WriteLog("遠端更新未啟用，略過 launcher 獨立檢查")
        return ""
    }

    manifestUrl := Trim(IniReadSafe(cfgFile, "updater", "manifest_url", defaultManifestUrl), ' "')
    if (manifestUrl = "") {
        WriteLog("遠端更新已啟用但未設定 manifest_url", "WARN")
        return ""
    }

    try {
        manifestApiUrl := ConvertToGitHubApiUrl(manifestUrl)
        return HttpGetText(manifestApiUrl, Map("Accept", "application/vnd.github.raw+v3"))
    } catch as e {
        WriteLog("launcher 獨立更新檢查無法下載 manifest: " e.Message, "WARN")
        return ""
    }
}

TryPrepareRemotePayloadUpdate(workDir, dataDir, &forcedVersion := "", forceDownload := false) {
    WriteLog("開始檢查遠端更新設定...")
    cfgFile := dataDir "\\config.ini"
    defaultManifestUrl := "https://api.github.com/repos/derek3411888/-/contents/update_manifest.example.json?ref=main"

    ; 零設定預設啟用；若使用者手動設為 0 才關閉
    enabled := IniReadSafe(cfgFile, "updater", "enabled", "1")
    if (enabled != "1") {
        WriteLog("遠端更新未啟用（[updater] enabled!=1）")
        return false
    }

    ; 若未提供 manifest_url，使用內建預設網址
    manifestUrl := Trim(IniReadSafe(cfgFile, "updater", "manifest_url", defaultManifestUrl), ' "')
    if (manifestUrl = "") {
        WriteLog("遠端更新已啟用但未設定 manifest_url", "WARN")
        return false
    }

    currentVerFile := dataDir "\\payload_remote_version.txt"
    currentVer := ""
    if FileExist(currentVerFile) {
        try currentVer := Trim(FileRead(currentVerFile, "UTF-8"), " `t`r`n")
    }

    ; 自動將 raw.githubusercontent.com 轉為 GitHub API 端點（繞過 CDN 快取）
    manifestApiUrl := ConvertToGitHubApiUrl(manifestUrl)
    manifestText := ""
    try {
        manifestText := HttpGetText(manifestApiUrl, Map("Accept", "application/vnd.github.raw+v3"))
    } catch as e {
        WriteLog("下載 manifest 失敗: " e.Message, "WARN")
        return false
    }

    try {
        remoteVer := Trim(JsonGetString(manifestText, "version"), " `t`r`n")
        payloadUrl := Trim(JsonGetString(manifestText, "payload_url"), " `t`r`n")
        payloadSha := StrLower(Trim(JsonGetString(manifestText, "payload_sha256"), " `t`r`n"))

        if (remoteVer = "" || payloadUrl = "") {
            WriteLog("manifest 缺少 version 或 payload_url", "WARN")
            return false
        }

        if (!forceDownload && remoteVer = currentVer) {
            WriteLog("遠端版本一致，無需更新：" remoteVer)
            return false
        }

        if (forceDownload && remoteVer = currentVer)
            WriteLog("遠端版本相同，但本地 payload 缺失，改為重新下載：" remoteVer)

        WriteLog("檢測到新版本：" currentVer " -> " remoteVer)
        zipTmp := LauncherNewTempPath("payload_update", ".zip", "更新")
        verified := false
        lastSha := ""

        ; 下載重試：避免 CDN 回傳舊快取導致 SHA 驗證失敗。
        Loop 3 {
            attempt := A_Index
            payloadReqUrl := payloadUrl
            payloadReqUrl .= (InStr(payloadReqUrl, "?") ? "&" : "?") "ver=" remoteVer "&retry=" attempt "&ts=" A_NowUTC

            try {
                HttpDownloadFile(payloadReqUrl, zipTmp)
            } catch as e {
                WriteLog("下載 payload 更新包失敗(第 " attempt " 次): " e.Message, "WARN")
                if (attempt >= 3)
                    return false
                Sleep 1200
                continue
            }

            if (payloadSha = "") {
                WriteLog("manifest 未提供 payload_sha256，略過雜湊驗證", "WARN")
                verified := true
                break
            }

            gotSha := GetFileSha256(zipTmp)
            if (gotSha = "") {
                WriteLog("無法計算更新包 SHA256(第 " attempt " 次)", "WARN")
                if (attempt >= 3) {
                    try FileDelete(zipTmp)
                    return false
                }
                Sleep 1200
                continue
            }

            lastSha := gotSha
            if (gotSha = payloadSha) {
                WriteLog("更新包 SHA256 驗證通過")
                verified := true
                break
            }

            WriteLog("更新包 SHA256 不符(第 " attempt " 次)，預期=" payloadSha " 實際=" gotSha, "WARN")
            if (attempt < 3)
                Sleep 1500
        }

        if !verified {
            WriteLog("更新包 SHA256 連續驗證失敗，預期=" payloadSha " 最後實際=" lastSha, "WARN")
            try FileDelete(zipTmp)
            return false
        }

        payloadPath := workDir "\\payload.zip"
        backupPath := workDir "\\payload.zip.bak"
        try {
            if FileExist(backupPath)
                FileDelete(backupPath)
            if FileExist(payloadPath)
                FileCopy(payloadPath, backupPath, 1)
            FileCopy(zipTmp, payloadPath, 1)
            WriteLog("已套用新 payload.zip")
        } catch as e {
            WriteLog("覆蓋 payload.zip 失敗: " e.Message, "WARN")
            try {
                if FileExist(backupPath)
                    FileCopy(backupPath, payloadPath, 1)
            }
            try FileDelete(zipTmp)
            return false
        }

        try FileDelete(zipTmp)
        forcedVersion := remoteVer
        WriteLog("已準備遠端更新，待解壓套用版本：" forcedVersion)
        return true
    }
}

; ===========================
; 檢查並應用 Launcher 遠端更新
; ===========================
; 檢查 launcher exe 是否需要更新，如需要則下載、驗證、替換
; 注意：exe 本身被占用，無法直接覆蓋，需透過外部 helper 等待退出後替換
TryPrepareRemoteLauncherUpdate(workDir, dataDir, manifestText) {
    global SKIP_PENDING_LAUNCHER_APPLY
    WriteLog("開始檢查 launcher 遠端更新...")
    
    try {
        launcherVer := Trim(JsonGetString(manifestText, "launcher_version"), " `t`r`n")
        launcherUrl := Trim(JsonGetString(manifestText, "launcher_url"), " `t`r`n")
        launcherSha := StrLower(Trim(JsonGetString(manifestText, "launcher_sha256"), " `t`r`n"))
        
        if (launcherVer = "" || launcherUrl = "") {
            WriteLog("manifest 未提供 launcher 更新資訊，跳過更新檢查")
            return false
        }

        if !(launcherVer ~= "^[0-9A-Za-z._-]+$") {
            WriteLog("manifest 的 launcher_version 格式無效：" launcherVer, "WARN")
            return false
        }

        ; launcher 是可執行檔，沒有完整 SHA256 就不得進入自動替換流程。
        ; 同時限制字元集，避免遠端文字進入 helper 命令列時成為參數注入面。
        if !(launcherSha ~= "^[0-9a-f]{64}$") {
            WriteLog("manifest 缺少有效的 launcher_sha256，拒絕自動更新 launcher", "WARN")
            return false
        }
        
        currentVerFile := dataDir "\\launcher_current_version.txt"
        currentVer := ""
        if FileExist(currentVerFile) {
            try currentVer := Trim(FileRead(currentVerFile, "UTF-8"), " `t`r`n")
        }

        ; 新安裝可能還沒有版本狀態檔；若目前執行檔的 SHA 已等於 manifest，
        ; 直接補寫版本，避免下載並替換完全相同的 launcher。
        currentLauncherSha := GetFileSha256(A_ScriptFullPath)
        if (currentLauncherSha != "" && currentLauncherSha = launcherSha) {
            ; 可能是手動換新 launcher，但舊版留下 pending。若不先清掉，
            ; 本輪尾端會把舊 pending 套回去而造成降級。
            SKIP_PENDING_LAUNCHER_APPLY := true
            pendingCleared := ClearPendingLauncherState(dataDir)
            if WriteTextFileReplace(currentVerFile, launcherVer)
                WriteLog("目前 launcher SHA256 已是遠端版本，已補寫版本狀態"
                    (pendingCleared ? "並清除舊 pending：" : "；本輪禁止套用未清除的舊 pending：") launcherVer)
            else
                WriteLog("目前 launcher SHA256 已是遠端版本，但版本狀態補寫失敗", "WARN")
            return false
        }
        
        if (launcherVer = currentVer) {
            ; 版本文字相同但檔案雜湊不同，代表狀態檔失真或 EXE 已損壞，
            ; 必須重新下載，不能只信版本文字。
            WriteLog("launcher 版本文字一致但 SHA256 不符，重新下載修復：" launcherVer, "WARN")
        }
        
        WriteLog("檢測到 launcher 新版本：" currentVer " -> " launcherVer)
        
        ; 下載新 launcher exe
        exeTmp := dataDir "\\launcher_update_" launcherVer "_" A_TickCount ".exe"
        try {
            WriteLog("正在下載新 launcher 版本 " launcherVer)
            HttpDownloadFile(launcherUrl, exeTmp)
        } catch as e {
            WriteLog("下載 launcher 更新失敗: " e.Message, "WARN")
            return false
        }
        
        ; 驗證 SHA256（如果提供了的話）
        if (launcherSha != "") {
            gotSha := GetFileSha256(exeTmp)
            if (gotSha = "") {
                WriteLog("無法計算 launcher 更新包 SHA256", "WARN")
                try FileDelete(exeTmp)
                return false
            }
            
            if (gotSha != launcherSha) {
                WriteLog("launcher 更新包 SHA256 不符，預期=" launcherSha " 實際=" gotSha, "WARN")
                try FileDelete(exeTmp)
                return false
            }
            
            WriteLog("launcher 更新包 SHA256 驗證通過")
        }
        
        ; 先寫中繼資料，最後才寫 pending_update.tmp 作為提交標記。
        ; 如此即使中途斷電，也不會讓替換器讀到只有一半的狀態。
        launcherBackupFile := dataDir "\\launcher_pending_update.tmp"
        versionBackupFile := dataDir "\\launcher_pending_version.txt"
        shaBackupFile := dataDir "\\launcher_pending_sha256.txt"
        if !WriteTextFileReplace(versionBackupFile, launcherVer) {
            ClearPendingLauncherState(dataDir)
            try FileDelete(exeTmp)
            return false
        }
        if !WriteTextFileReplace(shaBackupFile, launcherSha) {
            ClearPendingLauncherState(dataDir)
            try FileDelete(exeTmp)
            return false
        }
        if !WriteTextFileReplace(launcherBackupFile, exeTmp) {
            WriteLog("無法儲存待替換檔案路徑", "WARN")
            ClearPendingLauncherState(dataDir)
            try FileDelete(exeTmp)
            return false
        }
        WriteLog("launcher 待替換檔案已暫存：" exeTmp)
        WriteLog("已記錄待更新版本號：" launcherVer)
        
        return true
    } catch as e {
        WriteLog("檢查 launcher 更新時發生異常: " e.Message, "WARN")
        return false
    }
}

; v4.42 舊替換器留作版本差異追查；不可呼叫。
ApplyPendingLauncherUpdateLegacyUnused(workDir, dataDir) {
    WriteLog("檢查是否有待應用的 launcher 更新...")
    
    launcherBackupFile := dataDir "\\launcher_pending_update.tmp"
    versionBackupFile := dataDir "\\launcher_pending_version.txt"
    
    if !FileExist(launcherBackupFile) {
        WriteLog("無待應用的 launcher 更新")
        return false
    }
    
    try {
        newExePath := Trim(FileRead(launcherBackupFile, "UTF-8"), " `t`r`n")
        if !FileExist(newExePath) {
            WriteLog("待替換 exe 檔案不存在，清理狀態檔", "WARN")
            try FileDelete(launcherBackupFile)
            try FileDelete(versionBackupFile)
            return false
        }
        
        currentExePath := A_ScriptFullPath
        if !FileExist(currentExePath) {
            WriteLog("當前 exe 路徑無效", "WARN")
            try FileDelete(launcherBackupFile)
            return false
        }
        
        ; 使用 PowerShell 進行受限的文件替換（需管理員權限）
        if !A_IsAdmin {
            WriteLog("警告：無法應用待更新的 launcher，因無管理員權限", "WARN")
            return false
        }
        
        ; 嘗試直接替換（如果當前 exe 能被關閉）
        WriteLog("準備替換 launcher exe...")
        replaceBat := LauncherNewTempPath("launcher_replace", ".bat", "更新")
        
        ; 使用更清晰的字符串拼接方式，避免複雜的雙引號
        batLines := []
        batLines.Push("@echo off")
        batLines.Push("setlocal enabledelayedexpansion")
        batLines.Push("timeout /t 2 /nobreak")
        batLines.Push("if exist " . QuoteForBat(currentExePath) . " (")
        batLines.Push("  del /f /q " . QuoteForBat(currentExePath) . " 2>nul")
        batLines.Push(")")
        batLines.Push("move /y " . QuoteForBat(newExePath) . " " . QuoteForBat(currentExePath) . " >nul 2>&1")
        batLines.Push("if !errorlevel! equ 0 (")
        batLines.Push("  " . QuoteForBat(versionBackupFile) . " was updated successfully")
        batLines.Push(")")
        batLines.Push("del /f /q " . QuoteForBat(replaceBat) . " 2>nul")
        
        batContent := ""
        for _, line in batLines {
            batContent .= line "`r`n"
        }
        
        try FileAppend(batContent, replaceBat, "UTF-8-RAW")
        
        ; 後台執行替換批處理，不等待完成
        try Run(replaceBat, , "Hide")
        
        WriteLog("launcher 更新批處理已提交後台執行")
        return true
    } catch as e {
        WriteLog("應用待更新 launcher 時發生異常: " e.Message, "WARN")
        return false
    }
}

; 為批處理腳本中的路徑添加引號
QuoteForBat(path) {
    return "`"" path "`""
}

; v4.43 起使用的安全替換器。主流程確認已啟動後才呼叫；helper 會等目前
; launcher PID 真正退出，再做可回復且有雜湊驗證的替換。
ApplyPendingLauncherUpdateV2(workDir, dataDir) {
    WriteLog("檢查是否有待應用的 launcher 更新...")

    launcherBackupFile := dataDir "\\launcher_pending_update.tmp"
    versionBackupFile := dataDir "\\launcher_pending_version.txt"
    shaBackupFile := dataDir "\\launcher_pending_sha256.txt"
    if !FileExist(launcherBackupFile) {
        WriteLog("無待應用的 launcher 更新")
        return false
    }

    try {
        newExePath := Trim(FileRead(launcherBackupFile, "UTF-8"), " `t`r`n")
        if !FileExist(newExePath) {
            WriteLog("待替換 exe 檔案不存在，清理狀態檔", "WARN")
            try FileDelete(launcherBackupFile)
            try FileDelete(versionBackupFile)
            try FileDelete(shaBackupFile)
            return false
        }

        pendingVersion := ""
        pendingSha := ""
        if FileExist(versionBackupFile)
            try pendingVersion := Trim(FileRead(versionBackupFile, "UTF-8"), " `t`r`n")
        if FileExist(shaBackupFile)
            try pendingSha := StrLower(Trim(FileRead(shaBackupFile, "UTF-8"), " `t`r`n"))
        if !(pendingVersion ~= "^[0-9A-Za-z._-]+$") {
            WriteLog("待套用 launcher 版本號無效，保留待處理檔供下次修復", "WARN")
            return false
        }
        if !(pendingSha ~= "^[0-9a-f]{64}$") {
            WriteLog("待套用 launcher SHA256 格式無效，拒絕排程替換", "ERROR")
            return false
        }
        pendingFileSha := GetFileSha256(newExePath)
        if (pendingFileSha = "" || pendingFileSha != pendingSha) {
            WriteLog("待套用 launcher SHA256 驗證失敗，拒絕排程替換", "ERROR")
            return false
        }

        currentExePath := A_ScriptFullPath
        if !FileExist(currentExePath) {
            WriteLog("當前 exe 路徑無效", "WARN")
            return false
        }
        currentExeSha := GetFileSha256(currentExePath)
        if (currentExeSha != "" && currentExeSha = pendingSha) {
            ; 替換其實已完成，只是上次來不及清理狀態。此時不可再次搬動 EXE。
            if WriteTextFileReplace(dataDir "\\launcher_current_version.txt", pendingVersion) {
                ClearPendingLauncherState(dataDir)
                try FileDelete(newExePath)
                WriteLog("目前 launcher 已符合 pending SHA256，已補寫版本並清理殘留 pending：" pendingVersion)
            } else {
                WriteLog("目前 launcher 已符合 pending SHA256，但版本狀態補寫失敗", "WARN")
            }
            return false
        }
        if !A_IsAdmin {
            WriteLog("警告：無法應用待更新的 launcher，因無管理員權限", "WARN")
            return false
        }

        replacePs1 := LauncherNewTempPath("launcher_replace", ".ps1", "更新")
        outcomeFile := dataDir "\\launcher_update_outcome.log"
        currentVerFile := dataDir "\\launcher_current_version.txt"
        helperLines := [
            "param([int]$LauncherPid,[string]$SourcePath,[string]$TargetPath,[string]$PendingPath,[string]$PendingVersionPath,[string]$PendingShaPath,[string]$CurrentVersionPath,[string]$Version,[string]$ExpectedSha,[string]$OutcomePath)",
            "$ErrorActionPreference = 'Stop'",
            "$candidate = $TargetPath + '.update'",
            "$backup = $TargetPath + '.pre_update.bak'",
            "try {",
            "  $deadline = (Get-Date).AddSeconds(60)",
            "  while ((Get-Process -Id $LauncherPid -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }",
            "  if (Get-Process -Id $LauncherPid -ErrorAction SilentlyContinue) { throw 'launcher PID did not exit within 60 seconds' }",
            "  if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { throw 'pending launcher source is missing' }",
            "  $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $SourcePath).Hash.ToLowerInvariant()",
            "  if ($ExpectedSha -and $sourceHash -ne $ExpectedSha.ToLowerInvariant()) { throw 'pending launcher SHA256 mismatch' }",
            "  Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue",
            "  if ((-not (Test-Path -LiteralPath $TargetPath)) -and (Test-Path -LiteralPath $backup -PathType Leaf)) { Move-Item -LiteralPath $backup -Destination $TargetPath -Force }",
            "  if ((Test-Path -LiteralPath $TargetPath -PathType Leaf) -and (Test-Path -LiteralPath $backup -PathType Leaf)) { Remove-Item -LiteralPath $backup -Force }",
            "  Copy-Item -LiteralPath $SourcePath -Destination $candidate -Force",
            "  if ((Get-Item -LiteralPath $candidate).Length -ne (Get-Item -LiteralPath $SourcePath).Length) { throw 'candidate size mismatch' }",
            "  if (Test-Path -LiteralPath $TargetPath) { Move-Item -LiteralPath $TargetPath -Destination $backup -Force }",
            "  Move-Item -LiteralPath $candidate -Destination $TargetPath -Force",
            "  $targetHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $TargetPath).Hash.ToLowerInvariant()",
            "  if ($targetHash -ne $sourceHash) { throw 'installed launcher SHA256 mismatch' }",
            "  Set-Content -LiteralPath $CurrentVersionPath -Value $Version -Encoding Ascii -NoNewline",
            "  Remove-Item -LiteralPath $PendingPath,$PendingVersionPath,$PendingShaPath,$SourcePath,$backup -Force -ErrorAction SilentlyContinue",
            "  Add-Content -LiteralPath $OutcomePath -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' SUCCESS launcher=' + $Version + ' sha256=' + $targetHash)",
            "} catch {",
            "  $failureReason = $_.Exception.Message",
            "  $rollback = 'not-needed'",
            "  if (Test-Path -LiteralPath $backup -PathType Leaf) {",
            "    try {",
            "      if (Test-Path -LiteralPath $TargetPath) { Remove-Item -LiteralPath $TargetPath -Force }",
            "      Move-Item -LiteralPath $backup -Destination $TargetPath -Force",
            "      $rollback = 'restored'",
            "    } catch {",
            "      $rollback = 'FAILED: ' + $_.Exception.Message",
            "    }",
            "  }",
            "  Add-Content -LiteralPath $OutcomePath -Encoding UTF8 -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' FAILED launcher=' + $Version + ' reason=' + $failureReason + ' rollback=' + $rollback)",
            "} finally {",
            "  Remove-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue",
            "  Start-Sleep -Milliseconds 300",
            "  Remove-Item -LiteralPath $PSCommandPath -Force -ErrorAction SilentlyContinue",
            "}"
        ]
        helperContent := ""
        for _, line in helperLines
            helperContent .= line "`r`n"
        FileAppend(helperContent, replacePs1, "UTF-8-RAW")

        launcherPid := DllCall("GetCurrentProcessId")
        cmd := 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' replacePs1 '"'
        cmd .= ' -LauncherPid ' launcherPid
        cmd .= ' -SourcePath "' newExePath '" -TargetPath "' currentExePath '"'
        cmd .= ' -PendingPath "' launcherBackupFile '" -PendingVersionPath "' versionBackupFile '"'
        cmd .= ' -PendingShaPath "' shaBackupFile '" -CurrentVersionPath "' currentVerFile '"'
        cmd .= ' -Version "' pendingVersion '" -ExpectedSha "' pendingSha '" -OutcomePath "' outcomeFile '"'
        Run(cmd, , "Hide")

        WriteLog("launcher 更新替換 helper 已排程；成功與否將寫入 " outcomeFile)
        return true
    } catch as e {
        WriteLog("應用待更新 launcher 時發生異常: " e.Message, "WARN")
        return false
    }
}

ExtractZipByPowerShell(zipPath, destDir) {
    try {
        psZip := StrReplace(zipPath, "'", "''")
        psDest := StrReplace(destDir, "'", "''")
        psCmd := "$ErrorActionPreference='Stop'; $zip='" psZip "'; $dest='" psDest "'; if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }; New-Item -ItemType Directory -Path $dest -Force | Out-Null; Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force"
        cmd := "powershell -NoProfile -ExecutionPolicy Bypass -Command " Chr(34) psCmd Chr(34)
        return (RunWait(cmd, , "Hide") = 0)
    } catch {
        return false
    }
}

; 設置進程優先級為普通，減少系統負擔
try {
    ProcessSetPriority("Normal", DllCall("GetCurrentProcessId"))
    WriteLog("已設置進程優先級為 Normal")
} catch as e {
    WriteLog("設置進程優先級失敗: " e.Message, "WARN")
}

; 需要系統管理員（若無權限，提權後結束當前執行）
if !A_IsAdmin {
    WriteLog("需要管理員權限，嘗試提權...")
    forwardArgs := LauncherAdminForwardArgs()
    if A_IsCompiled {
        ; EXE 直接提權重啟自身，不依賴 .ahk 關聯。
        try Run('*RunAs "' A_ScriptFullPath '"' forwardArgs)
    } else {
        bundledAhk := ResolveBundledAhkExeForLauncher()
        if FileExist(bundledAhk) {
            try Run('*RunAs "' bundledAhk '" "' A_ScriptFullPath '"' forwardArgs)
        } else {
            MsgBox("錯誤：找不到 AutoHotkey64.exe！`n`n請確認程式檔案完整（需包含內附 AutoHotkey64.exe）。", "缺少AutoHotkey", 16)
        }
    }
    ExitApp
}

; #SingleInstance 必須關閉，才能讓同一個 EXE 另開一般權限的資料夾選擇 helper。
; 主啟動流程改用「依完整安裝路徑區分」的 mutex，避免重複啟動，同時不妨礙
; 第一次執行時從原位置搬到 自動鋤地 子資料夾後重新啟動。
PACK_MAIN_MUTEX_HANDLE := LauncherAcquireMainMutex()
if (PACK_MAIN_MUTEX_HANDLE = -1) {
    WriteLog("同一路徑的啟動器已在執行，略過重複啟動", "WARN")
    MsgBox("全自動鋤地啟動器已在執行。", "啟動器", 48)
    ExitApp
}
if (PACK_MAIN_MUTEX_HANDLE = 0)
    WriteLog("建立啟動器 mutex 失敗，仍繼續執行", "WARN")

; =========================
; 自我組織功能：建立專用資料夾並移動exe
; =========================
autoFolderName := "自動鋤地"
currentDir := A_ScriptDir
autoFolderPath := currentDir "\" autoFolderName
currentExePath := A_ScriptFullPath
SplitPath(currentExePath, &exeFileName)

; 檢查是否已經在「自動鋤地」資料夾內
if !LauncherIsDevelopmentCheckout() && !InStr(currentDir, autoFolderName) {
    WriteLog("開始自我組織：建立專用資料夾並複製所有程式檔案...")
    
    ; 建立「自動鋤地」資料夾
    if !DirExist(autoFolderPath) {
        try {
            DirCreate(autoFolderPath)
            WriteLog("建立資料夾：" autoFolderPath)
        } catch as e {
            WriteLog("建立資料夾失敗: " e.Message, "ERROR")
            MsgBox("無法建立資料夾 '" autoFolderName "'：" e.Message, "錯誤", 16)
            ExitApp
        }
    }
    
    ; 複製所有相關檔案到新資料夾
    newExePath := autoFolderPath "\" exeFileName
    try {
        ; 複製主要exe
        if FileExist(newExePath) {
            FileDelete(newExePath)
            Sleep(100)
        }
        FileCopy(currentExePath, newExePath, 1)
        WriteLog("複製主程式到：" newExePath)
        
        ; 只複製必要的相關檔案，不複製所有檔案
        essentialFiles := ["payload.zip", "AutoHotkey64.exe"]
        for fileName in essentialFiles {
            sourceFile := currentDir "\" fileName
            if FileExist(sourceFile) {
                targetPath := autoFolderPath "\" fileName
                try {
                    FileCopy(sourceFile, targetPath, 1)
                    WriteLog("複製必要檔案：" fileName)
                } catch as e {
                    WriteLog("複製必要檔案失敗 " fileName ": " e.Message, "WARN")
                }
            }
        }
        
        ; 不複製其他目錄，避免複製不相關的檔案
        WriteLog("跳過複製其他目錄，避免複製不相關檔案")
        
        ; 啟動新位置的exe
        Run('"' newExePath '"', autoFolderPath)
        WriteLog("啟動新位置的程式，準備清理原檔案")
        
        ; 延遲清理原目錄的檔案（給新程序時間啟動）
        SetTimer(CleanupOriginalFiles, 3000)
        
        ExitApp
        
        CleanupOriginalFiles() {
            try {
                ; 刪除原exe
                FileDelete(currentExePath)
                WriteLog("已刪除原程式：" currentExePath)
                
                ; 只刪除我們複製過的必要檔案，不要刪除其他檔案
                essentialFiles := ["payload.zip", "AutoHotkey64.exe"]
                for fileName in essentialFiles {
                    sourceFile := currentDir "\" fileName
                    if FileExist(sourceFile) {
                        try {
                            FileDelete(sourceFile)
                            WriteLog("已刪除原檔案：" fileName)
                        } catch as e {
                            WriteLog("刪除原檔案失敗 " fileName ": " e.Message, "WARN")
                        }
                    }
                }
                
                ; 不刪除其他目錄和檔案，避免意外刪除用戶資料
                WriteLog("跳過刪除其他目錄，避免意外刪除用戶資料")
                
                ; 刪除可能的備份日誌檔案
                Loop Files, currentDir "\*_fallback.log", "F" {
                    try {
                        FileDelete(A_LoopFileFullPath)
                        WriteLog("已刪除備份日誌：" A_LoopFileName)
                    } catch as e {
                        WriteLog("刪除備份日誌失敗 " A_LoopFileName ": " e.Message, "WARN")
                    }
                }
                
                WriteLog("原檔案清理完成")
            } catch as e {
                WriteLog("清理原檔案時發生錯誤: " e.Message, "ERROR")
            }
        }
        
    } catch as e {
        WriteLog("自我組織失敗: " e.Message, "ERROR")
        MsgBox("無法完成自我組織：" e.Message "`n`n將在當前位置繼續執行。", "警告", 48)
        ; 繼續在當前位置執行
    }
} else {
    WriteLog("已在專用資料夾內，跳過自我組織")
}

; =========================
; 可調整參數（自動調整路徑到專用資料夾）
; =========================
MAIN_FILE := "全自動.ahk"            ; 主程式（全自動負責啟動前檢查並協調所有輔助腳本）

; 確保在「自動鋤地」資料夾內工作
if LauncherIsDevelopmentCheckout() {
    WORK_DIR := LauncherProjectRoot()
} else if InStr(A_ScriptDir, "自動鋤地") {
    ; 已經在專用資料夾內
    WORK_DIR := A_ScriptDir
} else {
    ; 還在原位置（理論上不會執行到這裡，因為前面已經處理了自我組織）
    WORK_DIR := A_ScriptDir "\自動鋤地"
}

APP_DIR   := WORK_DIR "\payload"       ; 解壓到專用資料夾的payload
DATA_DIR  := WORK_DIR "\config"        ; 設定檔放專用資料夾的config
STAMP     := WORK_DIR "\.version"      ; 版本戳
REMOTE_VER_FILE := DATA_DIR "\payload_remote_version.txt"

WriteLog("工作目錄設定為：" WORK_DIR)

oldReplaceBatCount := CleanupLauncherReplaceBatFiles(LauncherRuntimeDir("更新"))

if (oldReplaceBatCount > 0)
    WriteLog("已清理程式所在資料夾殘留的 launcher_replace 批次檔: " oldReplaceBatCount " 個")

; =========================
; Ahk2Exe 打包指令（編譯時加入）
;@Ahk2Exe-Base Unicode 64-bit
;@Ahk2Exe-AddResource payload.zip, payload.zip
;@Ahk2Exe-AddResource AutoHotkey64.exe, AutoHotkey64.exe
; （可選）;@Ahk2Exe-SetMainIcon "your.ico"
; =========================
; 注意：打包前請確保 AutoHotkey64.exe 與本腳本在同一目錄
; 提示：可從 https://www.autohotkey.com 下載 AutoHotkey v2
; =========================



; 建立目錄
DirCreate(DATA_DIR)
if !DirExist(APP_DIR)
    DirCreate(APP_DIR)

; 釋出內嵌檔案到專用資料夾
WriteLog("正在處理內嵌檔案...")

; 確保 payload.zip 存在並解壓
payloadPath := WORK_DIR "\payload.zip"
try {
    FileInstall("payload.zip", payloadPath, 1)
    WriteLog("成功釋出 payload.zip 到 " payloadPath)
} catch as e {
    ; 如果FileInstall失敗，檢查是否已存在
    if FileExist(payloadPath) {
        WriteLog("payload.zip 已存在，繼續使用現有檔案")
    } else {
        WriteLog("無法釋出 payload.zip: " e.Message, "ERROR")
        MsgBox("無法釋出 payload.zip: " e.Message, "錯誤", 16)
        ExitApp
    }
}

; 釋出 AutoHotkey64.exe 到專用資料夾
ahkPath := WORK_DIR "\AutoHotkey64.exe"
try {
    FileInstall("AutoHotkey64.exe", ahkPath, 1)
    WriteLog("成功釋出 AutoHotkey64.exe 到 " ahkPath)
} catch as e {
    WriteLog("無法釋出 AutoHotkey64.exe: " e.Message, "WARN")
    
    ; 首先檢查本地是否已有 AutoHotkey64.exe
    if FileExist(ahkPath) {
        WriteLog("發現現有的 AutoHotkey64.exe: " ahkPath)
        ; 繼續使用現有檔案，不重設 ahkPath
    } else {
        WriteLog("找不到任何可用的 AutoHotkey64.exe", "ERROR")
        MsgBox("錯誤：找不到 AutoHotkey64.exe！`n`n請確認程式檔案完整（需包含內附 AutoHotkey64.exe）。", "缺少AutoHotkey", 16)
        ExitApp
    }
}

; 以本 EXE 的最後修改時間作為版本判斷
exeMTime   := FileGetTime(A_ScriptFullPath, "M")
WriteLog("當前 EXE 時間戳: " exeMTime)

; 檢查版本戳檔案
currentStamp := ""
if FileExist(STAMP) {
    try {
        currentStamp := Trim(FileRead(STAMP, "UTF-8-RAW"))
        WriteLog("現有版本戳: " currentStamp)
    } catch as e {
        WriteLog("讀取版本戳失敗: " e.Message, "WARN")
    }
} else {
    WriteLog("版本戳檔案不存在")
}

needUnpack := !FileExist(STAMP) || (currentStamp != exeMTime)
remotePreparedVersion := ""
payloadMainPath := APP_DIR "\" MAIN_FILE
payloadHealthy := DirExist(APP_DIR) && FileExist(payloadMainPath)

; ========== 獨立檢查 Launcher 更新 ==========
; launcher 與 payload 使用同一份 manifest，但版本判斷彼此獨立；即使 payload
; 已是最新版，launcher 仍必須能下載並於本輪結束時套用。
manifestForLauncher := FetchRemoteUpdateManifest(DATA_DIR)
if (manifestForLauncher != "") {
    if TryPrepareRemoteLauncherUpdate(WORK_DIR, DATA_DIR, manifestForLauncher)
        WriteLog("檢測到 launcher 新版本，已下載並等待本輪 launcher 退出後套用")
}

; 若本地 payload 缺檔，優先嘗試從遠端重抓同版本內容修復
if !payloadHealthy {
    needUnpack := true
    WriteLog("偵測到本地 payload 不完整，缺少主檔：" payloadMainPath, "WARN")
    if TryPrepareRemotePayloadUpdate(WORK_DIR, DATA_DIR, &remotePreparedVersion, true) {
        WriteLog("已從遠端重新取得 payload.zip，將進行修復解壓")
    } else {
        WriteLog("遠端重新取得 payload 失敗，將改用本地 payload.zip 重新解壓", "WARN")
    }
} else if TryPrepareRemotePayloadUpdate(WORK_DIR, DATA_DIR, &remotePreparedVersion) {
    needUnpack := true
    WriteLog("遠端更新已準備完成，強制執行解壓更新")
}

; 如果有命令列參數 --force-update，強制重新解壓
for param in A_Args {
    if (param = "--force-update") {
        needUnpack := true
        WriteLog("偵測到 --force-update 參數，強制重新解壓")
        break
    }
}

WriteLog("是否需要解壓: " (needUnpack ? "是" : "否"))

if needUnpack {
    WriteLog("需要解壓 payload.zip，開始解壓...")
    
    ; --- 強制結束正在運行的相關進程，避免檔案鎖定導致無法刪除/覆蓋 ---
    WriteLog("正在檢查並終止舊的進程以釋放檔案鎖定...")
    try {
        ; 使用 WMI 取得命令列後交給 fail-safe 精確策略。正式錄影的
        ; RecordingFinalizeWorker（sync/finalize）必須跨主程式與 payload 更新
        ; 繼續工作；不可再因路徑含有 `payload` 就連同收尾 worker 一起強殺。
        wmi := ComObjGet("winmgmts:")
        query := "Select * from Win32_Process Where Name LIKE 'AutoHotkey%'"
        
        for process in wmi.ExecQuery(query) {
            try {
                cmdLine := process.CommandLine
                decision := LauncherCleanup_ProcessDecision(process.Name, cmdLine, APP_DIR)
                if decision.stop {
                    pid := process.ProcessId
                    ProcessClose(pid)
                    WriteLog("已終止精確命中的舊進程 PID: " pid " | role=" decision.role)
                } else if InStr(decision.role, "recording-worker-") = 1 {
                    WriteLog("保留正式錄影背景工具 PID=" process.ProcessId
                        " | role=" decision.role "；payload 更新不得中斷收尾／續傳")
                }
            } catch {
                continue
            }
        }
        
        ; 不使用 taskkill /T 或依映像名稱全殺；前者會連正式 worker child
        ; 一起終止，後者可能命中其他位置的同名程式。上方完整路徑白名單
        ; 是唯一允許的清理入口。

        ; 等待進程完全釋放資源
        Sleep(1000)
    } catch as e {
        WriteLog("終止進程時發生錯誤 (非致命): " e.Message, "WARN")
    }

    ; --- 1) 備份現有 config（保留的副檔名可擴充） ---
    cfgTmp := LauncherRuntimeDir("設定備份") "\cfg_backup"
    if DirExist(cfgTmp)
        DirDelete cfgTmp, 1
    DirCreate(cfgTmp)
    for pat in ["*.ini","*.json","*.cfg"] {
        Loop Files, DATA_DIR "\" pat, "F" {
            try FileCopy(A_LoopFileFullPath, cfgTmp "\" A_LoopFileName, 1)
        }
    }

    ; --- 2) 解壓 payload 到 APP_DIR ---
    ; 如果APP_DIR已存在，完全刪除重建（確保覆蓋）
    if DirExist(APP_DIR) {
        WriteLog("完全清理舊的 payload 目錄...")
        try {
            DirDelete(APP_DIR, 1)
            WriteLog("舊 payload 目錄已刪除")
        } catch as e {
            WriteLog("刪除舊 payload 目錄失敗: " e.Message, "WARN")
            ; 如果無法刪除，嘗試覆蓋重要檔案
            Loop Files, APP_DIR "\*.ahk", "R" {
                try {
                    FileDelete(A_LoopFileFullPath)
                    WriteLog("已刪除舊 .ahk 檔案: " A_LoopFileName)
                } catch as e2 {
                    WriteLog("刪除舊 .ahk 檔案失敗 " A_LoopFileName ": " e2.Message, "WARN")
                }
            }
        }
        Sleep(500)  ; 等待檔案系統同步
    }
    
    ; 重新建立目錄
    if !DirExist(APP_DIR) {
        DirCreate(APP_DIR)
        WriteLog("已重建 payload 目錄")
    }
    
    ; 檢查 payload.zip 是否存在且可讀
    if !FileExist(payloadPath) {
        WriteLog("錯誤：找不到 payload.zip 檔案", "ERROR")
        MsgBox("錯誤：找不到 payload.zip 檔案，無法繼續。", "檔案錯誤", 16)
        ExitApp
    }
    
    ; 檢查檔案大小
    try {
        fileSize := FileGetSize(payloadPath)
        if (fileSize < 1000) {  ; 檔案太小，可能損壞
            WriteLog("警告：payload.zip 檔案大小異常: " fileSize " bytes", "WARN")
        } else {
            WriteLog("payload.zip 檔案大小正常: " fileSize " bytes")
        }
    } catch as e {
        WriteLog("無法讀取 payload.zip 檔案大小: " e.Message, "WARN")
    }

    ; 直接解壓到 APP_DIR
    sh  := ComObject("Shell.Application")
    src := sh.NameSpace(payloadPath)
    dst := sh.NameSpace(APP_DIR)
    if !src || !dst {
        WriteLog("解壓初始化失敗：無法建立 Shell 物件", "ERROR")
        MsgBox("解壓初始化失敗。可能是檔案損壞或權限問題。", "解壓錯誤", 16)
        ExitApp
    }
    
    try {
        dst.CopyHere(src.Items, 16)  ; 16=靜默
        
        ; 增加等待循環，確保解壓完成
        Loop 20 {
            if FileExist(APP_DIR "\" MAIN_FILE) || DirExist(APP_DIR "\payload")
                break
            Sleep 200
        }
        Sleep(1000)  ; 額外緩衝
        
        ; Shell 解壓在某些 zip（含中文檔名/路徑）可能靜默失敗，補一層 PowerShell 備援。
        extractedCount := 0
        try {
            Loop Files, APP_DIR "\*", "R" {
                extractedCount += 1
                break
            }
        }

        if (extractedCount = 0) {
            WriteLog("Shell 解壓後 payload 仍為空，改用 PowerShell Expand-Archive 備援", "WARN")
            if !ExtractZipByPowerShell(payloadPath, APP_DIR) {
                WriteLog("PowerShell 備援解壓也失敗", "ERROR")
                MsgBox("解壓失敗：Shell 與 PowerShell 皆無法解壓 payload.zip", "解壓錯誤", 16)
                ExitApp
            }
            Sleep(400)
        }

        WriteLog("payload.zip 解壓完成到 " APP_DIR)
        
        ; --- 智能目錄結構修正 (遞歸搜尋 MAIN_FILE) ---
        ; 解決各種打包層級問題 (例如 payload/payload/..., 全自動/payload/..., 等)
        if !FileExist(APP_DIR "\" MAIN_FILE) {
            WriteLog("根目錄未找到 " MAIN_FILE "，搜尋子目錄...")
            foundPath := ""
            Loop Files, APP_DIR "\" MAIN_FILE, "R" {
                foundPath := A_LoopFileFullPath
                break ; 找到第一個就停止
            }
            
            if (foundPath) {
                WriteLog("在子目錄找到主文件: " foundPath)
                SplitPath(foundPath, , &correctDir)
                
                ; 使用逐檔案複製方式替代 DirMove，更可靠
                try {
                    ; 1. 複製所有檔案到臨時目錄
                    tempFix := LauncherRuntimeDir("更新") "\temp_fix_" A_TickCount
                    DirCreate(tempFix)
                    
                    Loop Files, correctDir "\*.*", "R" {
                        srcFile := A_LoopFileFullPath
                        relPath := SubStr(srcFile, StrLen(correctDir) + 2)
                        destFile := tempFix "\" relPath
                        
                        ; 建立目標檔案的父目錄
                        SplitPath(destFile, , &parentDir)
                        if !DirExist(parentDir) {
                            DirCreate(parentDir)
                        }
                        
                        ; 複製檔案
                        try {
                            FileCopy(srcFile, destFile, 1)  ; 1=覆蓋
                        } catch as copyErr {
                            WriteLog("複製檔案失敗 " A_LoopFileName ": " copyErr.Message, "WARN")
                        }
                    }
                    
                    ; 2. 清空 APP_DIR
                    try {
                        DirDelete(APP_DIR, 1)
                    } catch {
                        ; 如果刪除失敗，嘗試逐檔案刪除
                        Loop Files, APP_DIR "\*.*", "R" {
                            try FileDelete(A_LoopFileFullPath)
                        }
                    }
                    Sleep(300)
                    
                    ; 3. 重新建立 APP_DIR
                    if DirExist(APP_DIR) {
                        try DirDelete(APP_DIR, 1)
                    }
                    DirCreate(APP_DIR)
                    
                    ; 4. 複製臨時目錄回 APP_DIR
                    Loop Files, tempFix "\*.*", "R" {
                        srcFile := A_LoopFileFullPath
                        relPath := SubStr(srcFile, StrLen(tempFix) + 2)
                        destFile := APP_DIR "\" relPath
                        
                        SplitPath(destFile, , &parentDir)
                        if !DirExist(parentDir) {
                            DirCreate(parentDir)
                        }
                        
                        try {
                            FileCopy(srcFile, destFile, 1)
                        } catch as copyErr {
                            WriteLog("最終複製失敗 " A_LoopFileName ": " copyErr.Message, "WARN")
                        }
                    }
                    
                    ; 5. 清理臨時目錄
                    try {
                        DirDelete(tempFix, 1)
                    } catch {
                        WriteLog("無法刪除臨時目錄: " tempFix, "WARN")
                    }
                    
                    WriteLog("已自動修正目錄結構")
                } catch as e {
                    WriteLog("修正目錄結構失敗: " e.Message, "ERROR")
                }
            } else {
                WriteLog("警告: 在 payload 中完全找不到 " MAIN_FILE, "WARN")
            }
        }

        ; 驗證關鍵檔案是否存在
        keyFiles := ["全自動.ahk", "開啟LRMC.ahk", "自動開啟OKWW.ahk", "聲骸合成.ahk", "LogManager.ahk", "RuntimeFilePaths.ahk", "RemoteControlFirestore.ahk"]
        for fileName in keyFiles {
            filePath := APP_DIR "\" fileName
            if FileExist(filePath) {
                fileSize := FileGetSize(filePath)
                WriteLog("驗證檔案: " fileName " (大小: " fileSize " bytes)")
            } else {
                WriteLog("警告: 關鍵檔案不存在: " fileName, "WARN")
            }
        }
        
    } catch as e {
        WriteLog("解壓過程發生錯誤: " e.Message, "ERROR")
        MsgBox("解壓過程發生錯誤: " e.Message, "解壓錯誤", 16)
        ExitApp
    }

    ; --- 3) 還原使用者設定（覆蓋回去） ---
    if DirExist(cfgTmp) {
        Loop Files, cfgTmp "\*.*", "F" {
            try {
                destPath := DATA_DIR "\" A_LoopFileName
                SplitPath(destPath, , &destDir)
                if !DirExist(destDir)
                    DirCreate(destDir)
                FileCopy(A_LoopFileFullPath, destPath, 1)
                WriteLog("還原設定檔: " A_LoopFileName)
            } catch as e {
                WriteLog("警告: 無法還原設定文件 " A_LoopFileName ": " e.Message, "WARN")
            }
        }
        DirDelete(cfgTmp, 1)
    }

    ; --- 4) 寫入版本戳 ---
    try {
        if FileExist(STAMP)
            FileDelete(STAMP)
        FileAppend(exeMTime, STAMP, "UTF-8-RAW")
        WriteLog("寫入版本戳: " exeMTime)
    } catch as e {
        WriteLog("警告: 無法寫入版本戳: " e.Message, "WARN")
    }

    ; --- 5) 若本次套用了遠端更新，記錄遠端 payload 版本 ---
    if (remotePreparedVersion != "") {
        try {
            if FileExist(REMOTE_VER_FILE)
                FileDelete(REMOTE_VER_FILE)
            FileAppend(remotePreparedVersion, REMOTE_VER_FILE, "UTF-8-RAW")
            WriteLog("寫入遠端 payload 版本: " remotePreparedVersion)
        } catch as e {
            WriteLog("警告: 無法寫入遠端 payload 版本: " e.Message, "WARN")
        }
    }
} else {
    WriteLog("payload已是最新版本，跳過解壓")
}

; 確認 AutoHotkey 執行檔可用
if !FileExist(ahkPath) {
    WriteLog("錯誤：AutoHotkey 執行檔不存在: " ahkPath, "ERROR")
    MsgBox("錯誤：找不到 AutoHotkey64.exe！`n`n請確認程式檔案完整（需包含內附 AutoHotkey64.exe）。", "缺少AutoHotkey", 16)
    ExitApp
}

WriteLog("將使用 AutoHotkey: " ahkPath)

; 對子腳本注入環境變數
WriteLog("設置環境變數: APP_DIR=" APP_DIR)
WriteLog("設置環境變數: DATA_DIR=" DATA_DIR)
EnvSet("PACK_APP_DIR",  APP_DIR)
EnvSet("PACK_DATA_DIR", DATA_DIR)
; 新版 launcher 自己負責等待退出後替換；payload 只在舊 launcher 未提供此旗標時
; 執行一次性相容修復，避免兩個替換器同時競爭同一個 EXE。
EnvSet("PACK_LAUNCHER_HANDLES_SELF_UPDATE", "1")

; 解析主腳本路徑
if (MAIN_FILE = "") {
    found := ""
    Loop Files, APP_DIR "\*.ahk", "F" {
        if RegExMatch(A_LoopFileName, "i)(OKWW|LRMC)") {
            found := A_LoopFileFullPath
            break
        }
    }
    if (found = "") {
        Loop Files, APP_DIR "\*.ahk", "F" {
            found := A_LoopFileFullPath
            break
        }
    }
    if (found = "") {
        MsgBox("app 目錄未找到任何 .ahk。請檢查 payload.zip 內容。")
        ExitApp
    }
    MAIN_PATH := found
} else {
    MAIN_PATH := APP_DIR "\" MAIN_FILE
    if !FileExist(MAIN_PATH) {
        MsgBox("指定的 MAIN_FILE 不存在：`n" MAIN_PATH)
        ExitApp
    }
}

; 執行主腳本（工作目錄設為 APP_DIR）
WriteLog("啟動主腳本: " MAIN_PATH)
WriteLog("使用 AutoHotkey: " ahkPath)
WriteLog("工作目錄: " APP_DIR)

; 全自動腳本會自動協調其他腳本，無需在此處強制關閉現有實例

mainLaunchSucceeded := false
try {
    if LauncherHasArg("--cleanup-recordings") {
        payloadArgs := " cleanup-recordings"
        WriteLog("主腳本將以安全錄影清理模式啟動，不會開始遊戲流程")
    } else {
        payloadArgs := LauncherHasArg("--resume-current-task") ? " restart resume" : ""
    }
    if (payloadArgs != "" && payloadArgs != " cleanup-recordings")
        WriteLog("主腳本將以 restart resume 接續中斷任務")
    Run('"' ahkPath '" "' MAIN_PATH '"' payloadArgs, APP_DIR)
    mainLaunchSucceeded := true
    WriteLog("主腳本已成功啟動")
    
    ; 等待一小段時間確認腳本啟動
    Sleep 2000
    
    ; 檢查全自動腳本是否成功啟動
    processStarted := false
    Loop 5 {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%AutoHotkey%'") {
            try {
                cmdLine := proc.CommandLine
                if (InStr(cmdLine, "全自動.ahk")) {
                    WriteLog("確認全自動腳本已啟動: PID=" proc.ProcessId)
                    processStarted := true
                    break
                }
            } catch {
                ; 忽略錯誤
            }
        }
        if (processStarted)
            break
        Sleep 1000
    }
    
    if (!processStarted) {
        WriteLog("警告：無法確認全自動腳本是否成功啟動", "WARN")
    }
    
} catch as e {
    WriteLog("啟動主腳本失敗: " e.Message, "ERROR")
    
    ; 提供更詳細的錯誤信息
    errDetails := "啟動主腳本失敗：" e.Message "`n`n"
    errDetails .= "AutoHotkey 路徑：" ahkPath "`n"
    errDetails .= "主腳本路徑：" MAIN_PATH "`n"
    errDetails .= "工作目錄：" APP_DIR "`n`n"
    
    ; 檢查檔案是否存在
    if !FileExist(ahkPath)
        errDetails .= "❌ AutoHotkey 執行檔不存在`n"
    else
        errDetails .= "✅ AutoHotkey 執行檔存在`n"
        
    if !FileExist(MAIN_PATH)
        errDetails .= "❌ 主腳本檔案不存在`n"
    else
        errDetails .= "✅ 主腳本檔案存在`n"
        
    if !DirExist(APP_DIR)
        errDetails .= "❌ 工作目錄不存在`n"
    else
        errDetails .= "✅ 工作目錄存在`n"
    
    errDetails .= "`n請檢查以上資訊並重試。"
    
    MsgBox(errDetails, "啟動錯誤", 16)
}

if (mainLaunchSucceeded && !SKIP_PENDING_LAUNCHER_APPLY)
    ApplyPendingLauncherUpdateV2(WORK_DIR, DATA_DIR)
else if SKIP_PENDING_LAUNCHER_APPLY
    WriteLog("目前 launcher 已是 manifest 指定版本，本輪略過 pending 替換以避免降級")

WriteLog("打包啟動器任務完成，即將退出")
ExitApp
