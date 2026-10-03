#Requires AutoHotkey v2.0+
#SingleInstance Off
#Include LauncherProcessCleanupPolicy.ahk
#Include LauncherStartupGuard.ahk
#Include payload\InstallStartupLock.ahk
#Include LauncherHttp.ahk
#Include LauncherPayloadUpdatePolicy.ahk
SetWorkingDir A_ScriptDir

global RUN_ID := FormatTime(, "yyyyMMdd_HHmmss") "@" A_TickCount
global PACK_LAUNCHER_BUILD_VERSION := "5.37"
global STEP_SEQ := 0
global TOOLTIP_SLOT := 5
global SKIP_PENDING_LAUNCHER_APPLY := false
global PACK_MAIN_MUTEX_HANDLE := 0
global PACK_RUNTIME_MUTEX_HANDLE := 0

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
    for _, flag in ["--force-update", "--restart-current-task", "--resume-current-task", "--cleanup-recordings"] {
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
    return InstallStartupLock_Acquire(LauncherProjectRoot())
}

LifecycleOnExit(exitReason, exitCode) {
    WriteLog("生命週期停止原因: reason=" exitReason " | exitCode=" exitCode)
}

WriteLog("打包啟動器開始: " A_ScriptFullPath " | build=" PACK_LAUNCHER_BUILD_VERSION)
WriteLog("生命週期啟動原因: " BuildStartupReason())
OnExit(LifecycleOnExit)
WriteStep("啟動", "PID=" DllCall("GetCurrentProcessId") " AHK=" A_AhkVersion)
WriteLog("初始工作目錄: " A_WorkingDir)

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

TryPrepareRemotePayloadUpdate(workDir, dataDir, &forcedVersion := "", forceDownload := false, manifestText := "") {
    global PACK_PAYLOAD_UPDATE_STATUS
    PACK_PAYLOAD_UPDATE_STATUS := "failed"
    WriteLog("開始檢查遠端更新設定...")
    cfgFile := dataDir "\\config.ini"
    defaultManifestUrl := "https://api.github.com/repos/derek3411888/-/contents/update_manifest.example.json?ref=main"

    ; 零設定預設啟用；若使用者手動設為 0 才關閉
    enabled := IniReadSafe(cfgFile, "updater", "enabled", "1")
    if (enabled != "1") {
        PACK_PAYLOAD_UPDATE_STATUS := "disabled"
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
    try {
        if manifestText = ""
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
            PACK_PAYLOAD_UPDATE_STATUS := "current"
            WriteLog("遠端版本一致，無需更新：" remoteVer)
            return false
        }

        if (forceDownload && remoteVer = currentVer)
            WriteLog("遠端版本相同，但本地 payload 缺失，改為重新下載：" remoteVer)

        ; 新 Launcher 每次啟動都先釋出其內嵌 payload.zip。如果該 ZIP 的
        ; SHA 已等於 manifest，就直接解壓並在成功後補寫版本，不能再把同一個
        ; 34MB 檔案從網路下載一次。這也讓手動換入新版 Launcher 可離線修復。
        localPayloadPath := workDir "\payload.zip"
        localPayloadSha := ""
        if FileExist(localPayloadPath) && payloadSha ~= "^[0-9a-f]{64}$"
            localPayloadSha := GetFileSha256(localPayloadPath)
        reuseDecision := LauncherPayloadReuse_Decide(currentVer, remoteVer,
            payloadSha, localPayloadSha, FileExist(localPayloadPath), forceDownload)
        if reuseDecision.reuseLocalZip {
            PACK_PAYLOAD_UPDATE_STATUS := "prepared"
            forcedVersion := remoteVer
            WriteLog("本機內嵌 payload.zip SHA256 已是遠端版本；略過重複下載，直接解壓套用：" remoteVer)
            return true
        }

        WriteLog("檢測到新版本：" currentVer " -> " remoteVer)
        zipTmp := LauncherNewTempPath("payload_update", ".zip", "更新")
        try {
            LauncherDownloadFile(LauncherNativeHelperPath(), workDir, payloadUrl, zipTmp,
                payloadSha, LauncherDownloadProgress.Bind("Payload " remoteVer))
            WriteLog("更新包下載完成，SHA256 驗證通過")
        } catch as e {
            WriteLog("Payload 更新失敗；保留可續傳暫存並沿用本機版本，未更新成功：" e.Message, "WARN")
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
        PACK_PAYLOAD_UPDATE_STATUS := "prepared"
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
            WriteLog("正在下載新 launcher 版本 " launcherVer "（可續傳；無進度 60 秒才中止；單檔總上限 20 分鐘）")
            LauncherDownloadFile(LauncherNativeHelperPath(), workDir, launcherUrl, exeTmp,
                launcherSha, LauncherDownloadProgress.Bind("Launcher " launcherVer))
        } catch as e {
            WriteLog("下載 launcher 更新失敗，已中止更新並沿用本機 launcher 繼續主流程: " e.Message, "WARN")
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
        
        ; 使用原生 helper 進行受限的檔案替換（沿用啟動器的權限）
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
    if !A_IsCompiled
        return false ; source checkout is never an executable replacement target
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

        helper := LauncherNativeHelperPath()
        launcherPid := DllCall("GetCurrentProcessId", "uint")
        created := LauncherNativeParentStamp()
        ready := dataDir "\launcher_replace_" launcherPid "_" created ".ready"
        cmd := '"' helper '" replace "' workDir '" "' currentExePath '" ' launcherPid ' ' created
        Run(cmd, workDir, "Hide", &helperPid)
        deadline := A_TickCount + 8000
        while A_TickCount < deadline {
            if FileExist(ready) {
                if Trim(FileRead(ready, "UTF-8")) = "READY" {
                    WriteLog("原生 launcher 替換工具已綁定目前程序身分；等待本啟動器退出後才替換，結果寫入 config\\launcher_update_outcome.log")
                    return true
                }
            }
            if !ProcessExist(helperPid)
                break
            Sleep 100
        }
        WriteLog("原生 launcher 替換工具未確認接管；保留 pending，下次再試", "WARN")
        return false
    } catch as e {
        WriteLog("應用待更新 launcher 時發生異常: " e.Message, "WARN")
        return false
    }
}

LauncherNativeParentStamp() {
    created := Buffer(8), exited := Buffer(8), kernel := Buffer(8), user := Buffer(8)
    if !DllCall("GetProcessTimes", "ptr", DllCall("GetCurrentProcess", "ptr"),
        "ptr", created, "ptr", exited, "ptr", kernel, "ptr", user)
        throw OSError(A_LastError, "GetProcessTimes(launcher)")
    return NumGet(created, 0, "Int64")
}

LauncherDownloadProgress(label, status) {
    static lastReport := 0, lastLabel := ""
    if InStr(status, "DOWNLOADING") = 1 {
        if label = lastLabel && A_TickCount - lastReport < 5000
            return
        if RegExMatch(status, "bytes=(\d+) total=(-?\d+)", &parts) {
            doneMiB := Round(Integer(parts[1]) / 1048576, 1)
            totalBytes := Integer(parts[2])
            status := "已下載 " doneMiB " MiB"
                . (totalBytes > 0 ? " / " Round(totalBytes / 1048576, 1) " MiB（" Round(Integer(parts[1])*100/totalBytes, 1) "%）" : "")
        }
    }
    lastReport := A_TickCount, lastLabel := label
    WriteLog(label " 更新下載｜" status)
    ToolTip(label " 更新下載`n" status)
}

LauncherNativeHelperPath() {
    global PACK_NATIVE_HELPER_PATH
    if !IsSet(PACK_NATIVE_HELPER_PATH) || !FileExist(PACK_NATIVE_HELPER_PATH)
        throw Error("Native launcher helper is unavailable")
    return PACK_NATIVE_HELPER_PATH
}

LauncherNeedsPayloadRecovery(workDir) {
    updateDir := workDir "\執行暫存\更新"
    return FileExist(updateDir "\payload_transaction.txt")
        || DirExist(updateDir "\payload_previous")
}

ExtractZipNative(workDir) {
    global PACK_RUNTIME_MUTEX_HANDLE
    try {
        helper := LauncherNativeHelperPath()
        ; Startup reservation remains with this launcher; runtime is explicitly
        ; lent to the extractor so parent death cannot leave installation writes
        ; unguarded. Another main cannot enter while native extraction owns it.
        InstallStartupLock_Release(PACK_RUNTIME_MUTEX_HANDLE)
        PACK_RUNTIME_MUTEX_HANDLE := 0
        parentImage := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
        command := '"' helper '" extract "' workDir '" "' parentImage '" '
            . DllCall("GetCurrentProcessId", "uint") ' ' LauncherNativeParentStamp()
        exitCode := RunWait(command, workDir, "Hide")
        return exitCode = 0
    } catch as e {
        WriteLog("原生解壓失敗，保留舊版本: " e.Message, "ERROR")
        return false
    } finally {
        PACK_RUNTIME_MUTEX_HANDLE := InstallStartupLock_AcquireRuntime(workDir)
        if PACK_RUNTIME_MUTEX_HANDLE <= 0 {
            WriteLog("解壓後無法取回安裝 runtime 鎖；停止本啟動器，不啟動主流程", "ERROR")
            ExitApp 1
        }
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
    WriteStep("等待管理員授權", "請在 Windows UAC 視窗按『是』")
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
WriteStep("管理員權限", "已確認，繼續檢查更新")

; #SingleInstance 必須關閉，才能讓同一個 EXE 另開一般權限的資料夾選擇 helper。
; 主啟動流程改用「依完整安裝路徑區分」的 mutex，避免重複啟動，同時不妨礙
; 第一次執行時從原位置搬到 自動鋤地 子資料夾後重新啟動。
PACK_MAIN_MUTEX_HANDLE := LauncherAcquireMainMutex()
if (PACK_MAIN_MUTEX_HANDLE = -1) {
    WriteLog("同一路徑的啟動器已在執行，略過重複啟動", "WARN")
    MsgBox("全自動鋤地啟動器已在執行。", "啟動器", 48)
    ExitApp
}
if (PACK_MAIN_MUTEX_HANDLE = 0) {
    WriteLog("無法取得安裝目錄啟動／更新鎖，保留目前檔案並停止", "ERROR")
    ExitApp 1
}

; BEGIN LAUNCHER RUNTIME RESERVATION
; Close the direct-main race throughout payload/runtime installation writes.
PACK_RUNTIME_MUTEX_HANDLE := InstallStartupLock_AcquireRuntime(LauncherProjectRoot())
if PACK_RUNTIME_MUTEX_HANDLE <= 0 {
    WriteLog("安裝目錄仍有主流程／更新擁有者；保留檔案，不重複啟動", "WARN")
    ExitApp(PACK_RUNTIME_MUTEX_HANDLE = -1 ? 0 : 1)
}
; END LAUNCHER RUNTIME RESERVATION

; Must run before releasing/replacing any embedded file or updating payload.
; Repeated clicks must leave the active task and recorder untouched.
existingMainGate := LauncherStartup_Inspect(LauncherProjectRoot() "\AutoHotkey64.exe",
    LauncherProjectRoot() "\payload\全自動.ahk")
if !existingMainGate.allow {
    WriteLog("既有主流程保護：" existingMainGate.reason " | PID=" existingMainGate.pid
        "；略過更新與重複啟動，不中斷目前任務", "WARN")
    WriteStep("保留既有主流程", existingMainGate.reason " | PID=" existingMainGate.pid)
    ExitApp
}

; =========================
; 自我組織功能：建立專用資料夾並移動exe
; =========================
autoFolderName := "自動鋤地"
currentDir := A_ScriptDir
autoFolderPath := LauncherProjectRoot()
currentExePath := A_ScriptFullPath
SplitPath(currentExePath, &exeFileName)

; 檢查是否已經在「自動鋤地」資料夾內
if !LauncherIsDevelopmentCheckout() && InstallStartupLock_Normalize(LauncherProjectRoot()) != InstallStartupLock_Normalize(currentDir) {
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
        ; 搬移前後共用安裝目錄鎖：先交出保留權，子程序才能接手。
        ; 此界線之後父程序只能退出；Run 失敗也不可繼續解壓／啟動。
        InstallStartupLock_Release(PACK_RUNTIME_MUTEX_HANDLE)
        PACK_RUNTIME_MUTEX_HANDLE := 0
        InstallStartupLock_Release(PACK_MAIN_MUTEX_HANDLE)
        PACK_MAIN_MUTEX_HANDLE := 0
        Run('"' newExePath '"' LauncherAdminForwardArgs(), autoFolderPath)
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
        MsgBox("無法完成自我組織：" e.Message "`n`n已安全停止，原始檔案保留；不在未持有啟動保留權時繼續執行。", "警告", 48)
        ExitApp(1)
    }
} else {
    WriteLog("已在專用資料夾內，跳過自我組織")
}

; =========================
; 可調整參數（自動調整路徑到專用資料夾）
; =========================
MAIN_FILE := "全自動.ahk"            ; 主程式（全自動負責啟動前檢查並協調所有輔助腳本）

; 確保在同一個已保留 ownership 的安裝根目錄工作。
; 既有安裝可改名；不能靠「自動鋤地」子字串再次推導另一個目錄。
WORK_DIR := LauncherProjectRoot()

APP_DIR   := WORK_DIR "\payload"       ; 解壓到專用資料夾的payload
DATA_DIR  := WORK_DIR "\config"        ; 設定檔放專用資料夾的config
STAMP     := WORK_DIR "\.version"      ; 版本戳
REMOTE_VER_FILE := DATA_DIR "\payload_remote_version.txt"

WriteLog("工作目錄設定為：" WORK_DIR)
WriteStep("工作目錄", WORK_DIR)

oldReplaceBatCount := CleanupLauncherReplaceBatFiles(LauncherRuntimeDir("更新"))

if (oldReplaceBatCount > 0)
    WriteLog("已清理程式所在資料夾殘留的 launcher_replace 批次檔: " oldReplaceBatCount " 個")

; =========================
; Ahk2Exe 打包指令（編譯時加入）
;@Ahk2Exe-Base Unicode 64-bit
;@Ahk2Exe-UpdateManifest 1
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
WriteStep("準備更新", "釋出內嵌 Payload 與 AutoHotkey")

; Kept outside payload because extraction replaces that directory. A unique
; copy also avoids overwriting a replacement helper from an earlier launch.
PACK_NATIVE_HELPER_PATH := LauncherNewTempPath("LauncherMaintenance", ".exe")
; Ahk2Exe only collects FileInstall when it starts its own statement line.
; An inline `try FileInstall(...)` compiles without the embedded resource.
try {
    FileInstall("payload\LauncherMaintenance.exe", PACK_NATIVE_HELPER_PATH, 1)
} catch as e {
    WriteLog("無法釋出原生更新工具: " e.Message, "ERROR")
    ExitApp 1
}

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
PACK_PAYLOAD_UPDATE_STATUS := "not_checked"
payloadMainPath := APP_DIR "\" MAIN_FILE
payloadHealthy := DirExist(APP_DIR) && FileExist(payloadMainPath)

; ========== 獨立檢查 Launcher 更新 ==========
; launcher 與 payload 使用同一份 manifest，但版本判斷彼此獨立；即使 payload
; 已是最新版，launcher 仍必須能下載並於本輪結束時套用。
WriteStep("檢查更新", "讀取遠端版本資訊（有明確逾時）")
manifestForLauncher := FetchRemoteUpdateManifest(DATA_DIR)
if (manifestForLauncher != "") {
    if TryPrepareRemoteLauncherUpdate(WORK_DIR, DATA_DIR, manifestForLauncher)
        WriteLog("檢測到 launcher 新版本，已下載並等待本輪 launcher 退出後套用")
}

; 若本地 payload 缺檔，優先嘗試從遠端重抓同版本內容修復
if !payloadHealthy {
    needUnpack := true
    WriteLog("偵測到本地 payload 不完整，缺少主檔：" payloadMainPath, "WARN")
    if TryPrepareRemotePayloadUpdate(WORK_DIR, DATA_DIR, &remotePreparedVersion, true, manifestForLauncher) {
        WriteLog("已從遠端重新取得 payload.zip，將進行修復解壓")
    } else {
        WriteLog("遠端重新取得 payload 失敗，將改用本地 payload.zip 重新解壓", "WARN")
    }
} else if TryPrepareRemotePayloadUpdate(WORK_DIR, DATA_DIR, &remotePreparedVersion, false, manifestForLauncher) {
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

; A matching version stamp cannot authorize an interrupted publication. Native
; recovery runs under runtime ownership before any main dispatch.
if LauncherNeedsPayloadRecovery(WORK_DIR) {
    needUnpack := true
    WriteLog("發現未完成的 payload 更新交易，先恢復／重新驗證，再允許主流程啟動", "WARN")
}
WriteLog("是否需要解壓: " (needUnpack ? "是" : "否"))

if needUnpack {
    WriteLog("需要解壓 payload.zip，開始解壓...")
    WriteStep("解壓 Payload", "停止精確命中的舊流程並安全更新")
    
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
                if (decision.role = "managed-全自動.ahk") {
                    WriteLog("更新前發現主流程，拒絕終止或覆寫；請由既有交接流程更新", "ERROR")
                    ExitApp 1
                }
                if decision.stop {
                    pid := process.ProcessId
                    if !LauncherCleanup_StopVerified(process, APP_DIR) {
                        WriteLog("舊工具身分已變動、無法驗證或未完全退出；保留程序並停止本次更新 | PID=" pid, "ERROR")
                        ExitApp 1
                    }
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

    } catch as e {
        WriteLog("終止進程時發生錯誤 (非致命): " e.Message, "WARN")
    }

    ; Native helpers may still hold mapped payload images after their parent
    ; exits.  Keep both startup/runtime reservations while waiting on exact,
    ; revalidated images from this APP_DIR.  This policy never terminates a
    ; native helper; timeout or unverifiable identity preserves the old payload.
    WriteLog("等待同一安裝的原生背景工具安全退出...")
    nativeDrain := LauncherCleanup_WaitNativeHelpers(APP_DIR, 45000)
    if !nativeDrain.ok {
        WriteLog("原生背景工具無法安全排空；保留舊 payload 並停止本次更新"
            " | reason=" nativeDrain.reason " | PID=" nativeDrain.pid " | image=" nativeDrain.path, "ERROR")
        MsgBox("背景工具仍在使用程式檔，或無法驗證其身分。`n舊版本已保留，請稍後再試並查看啟動器記錄。",
            "更新前置檢查失敗", 16)
        ExitApp 1
    }
    WriteLog("同一安裝的原生背景工具已排空"
        " | waited=" (nativeDrain.waited ? "yes" : "no") " | elapsed_ms=" nativeDrain.elapsed)

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

    ; Native staged extraction validates the entire archive before replacing
    ; payload. No asynchronous Shell.CopyHere or PowerShell fallback.
    try {
        if !ExtractZipNative(WORK_DIR) {
            WriteLog("原生解壓未完成；舊 payload 保留，不繼續啟動", "ERROR")
            MsgBox("更新解壓失敗，原有版本已保留。請查看啟動器記錄。", "解壓錯誤", 16)
            ExitApp 1
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
    if PACK_PAYLOAD_UPDATE_STATUS = "current"
        WriteLog("已向遠端確認 Payload 版本一致，跳過解壓")
    else if PACK_PAYLOAD_UPDATE_STATUS = "disabled"
        WriteLog("遠端更新已停用；沿用本機 Payload，未確認遠端版本")
    else
        WriteLog("Payload 更新未成功或未完成確認；沿用本機版本，不代表已是最新版", "WARN")
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
WriteStep("啟動主流程", MAIN_PATH)
WriteLog("使用 AutoHotkey: " ahkPath)
WriteLog("工作目錄: " APP_DIR)

; 全自動腳本會自動協調其他腳本，無需在此處強制關閉現有實例

; BEGIN MAIN DISPATCH RESERVATION RELEASE
; Payload/runtime writes are finished. Keep startup serialization until launcher
; exit, but hand runtime ownership to the child BEFORE waiting for its startup.
; The separate pending-EXE helper only replaces the launcher after its exit;
; it never updates a running payload or launches another main.
InstallStartupLock_Release(PACK_RUNTIME_MUTEX_HANDLE)
PACK_RUNTIME_MUTEX_HANDLE := 0
; END MAIN DISPATCH RESERVATION RELEASE
mainLaunchSucceeded := false
try {
    cleanupRecordingsOnly := LauncherHasArg("--cleanup-recordings")
    if cleanupRecordingsOnly {
        payloadArgs := " cleanup-recordings"
        WriteLog("主腳本將以安全錄影清理模式啟動，不會開始遊戲流程")
    } else {
        payloadArgs := LauncherHasArg("--resume-current-task")
            ? " restart resume"
            : (LauncherHasArg("--restart-current-task") ? " restart" : "")
    }
    if (payloadArgs = " restart resume")
        WriteLog("主腳本將以 restart resume 接續已開始的 LRMCAI 任務")
    else if (payloadArgs = " restart")
        WriteLog("主腳本將以 restart 模式重跑尚未開始的流程")
    if cleanupRecordingsOnly {
        cleanupGate := LauncherStartup_Inspect(ahkPath, MAIN_PATH)
        if !cleanupGate.allow
            throw Error("主流程仍存在或無法確認，拒絕用清理入口取代它")
        Run('"' ahkPath '" "' MAIN_PATH '"' payloadArgs, APP_DIR, , &cleanupPid)
        WriteLog("安全錄影清理請求已交給 PID=" cleanupPid "；完成結果需另行核對")
    } else {
        mainStartResult := LauncherStartup_Start(ahkPath, MAIN_PATH, payloadArgs, APP_DIR)
        mainLaunchSucceeded := mainStartResult.started
        if !mainLaunchSucceeded
            WriteLog("本次主腳本尚未確認啟動 | reason=" mainStartResult.reason " pid=" mainStartResult.pid, "WARN")
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
