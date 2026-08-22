#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir
global BUNDLED_AHK_EXE := ResolveBundledAhkExe()

; 🛡️ 自動提權
if !A_IsAdmin {
    if FileExist(BUNDLED_AHK_EXE) {
        try {
            Run('*RunAs "' BUNDLED_AHK_EXE '" "' A_ScriptFullPath '"')
        }
    } else {
        MsgBox "找不到 AutoHotkey64.exe，請先執行「打包啟動器」完成解壓。"
    }
    ExitApp
}

; ⚡ 設定普通優先級以減少系統負擔
ProcessSetPriority("Normal")

; DPI 感知（避免縮放改變座標/影像）
try DllCall("SetProcessDpiAwarenessContext", "ptr", -4)  ; PER_MONITOR_AWARE_V2
catch 
    try DllCall("shcore\SetProcessDpiAwareness", "int", 2)

#Include plugin\RapidOcr\RapidOcr.ahk
#Include plugin\ImagePut-1.11\ImagePut.ahk
#Include LogManager.ahk
#Include RemoteControlFirestore.ahk

; 初始化新的日誌系統
global logger := InitLogger("全自動")
RegisterLifecycleLogging("全自動")
global RUN_ID := A_Now "@" A_TickCount
global RUN_START_TS := A_Now
global STEP_SEQ := 0
global TOOLTIP_SLOT := 1
global TOOLTIP_UNTIL_TICK := 0
global TOOLTIP_CONTENT := ""

; 收尾監測設定（命中兩條「電台_一鍵領取」後延遲關閉）
global REWARD_LOG_FILE := "D:\LRMCAI\log\LRMCAI.log"
global REWARD_START_DELAY_MS := 300000
global REWARD_CHECK_INTERVAL_MS := 3000
global REWARD_SHUTDOWN_DELAY_MS := 5000
global REWARD_MATCH_NEED_COUNT := 2
global REWARD_INVALID_HWND_NEED_COUNT := 6
global REWARD_LOG_RECENT_WINDOW_SEC := 3600
global REWARD_LRMCAI_RESTART_COOLDOWN_MS := 15000
global REWARD_MONITOR_STATE_SECTION := "reward_monitor_runtime"
global __REWARD_MONITOR_ACTIVE := false
global __REWARD_MONITOR_COMPLETION_PENDING := false
global MAIL_NOTIFY_ENABLED := 1
global MAIL_SECTION := "mail_notify"
global SCREEN_RECORDING_ENABLED := 0
global SCREEN_RECORDING_SECTION := "screen_recording"
global SCREEN_RECORDING_ENGINE := "ffmpeg"
global SCREEN_RECORDING_FFMPEG_EXE := ""
global SCREEN_RECORDING_FFMPEG_ARGS := "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -f matroska"
global SCREEN_RECORDING_OUTPUT_DIR := "recordings"
global SCREEN_RECORDING_SEGMENT_MINUTES := 5
global SCREEN_RECORDING_AUTO_MERGE := 1
global SCREEN_RECORDING_KEEP_FINAL_COUNT := 5
global SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK := 0
global SCREEN_RECORDING_AUTO_STOP_EXTERNAL_FFMPEG := 1
global SCREEN_RECORDING_OWNER_MARKER := "WUTHERING_AUTO_RECORDER_V1"
global SCREEN_RECORDING_FFMPEG_AUTO_DOWNLOAD := 1
global SCREEN_RECORDING_FFMPEG_DOWNLOAD_URL := "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
global __SCREEN_RECORDING_FFMPEG_BOOTSTRAP_ATTEMPTED := false
global SCREEN_RECORDING_STOP_MODE := "reward_end"
global SCREEN_RECORDING_STOP_TEMPLATE := "login"
global SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM := ""
global SCREEN_RECORDING_STOP_LRMC_TASK := ""
global __SCREEN_RECORDING_ACTIVE := false
global __SCREEN_RECORDING_PID := 0
global __SCREEN_RECORDING_OUTPUT_PATH := ""
global __SCREEN_RECORDING_SESSION_DIR := ""
global __SCREEN_RECORDING_SYNC_WORKER_PID := 0
global __SCREEN_RECORDING_LAST_WORKER_STATE := ""
global SCREEN_RECORDING_MAINTENANCE_INTERVAL_MS := 30000
global __SCREEN_RECORDING_TEMPLATE_WARNED := false
global __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := false
global __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := 0
global __RESTART_IN_PROGRESS := false
global __NEXTSERVER_RESTART := false
global __MAIL_SETUP := ""
global __SERVER_PREVIEW := ""
global __WUTHERING_AUDIO_MUTED := false
global __WUTHERING_MUTE_PENDING := false
global WUTHERING_PROCESS_EXE := "Client-Win64-Shipping.exe"
global LAST_RESTART_REASON := ""
global LAST_RESTART_CODE := ""
global LAST_RESTART_STAGE := ""
global LAST_RESTART_RECOVERY := ""
global LAST_RESTART_PROCESS_SNAPSHOT := ""
global LAST_RESTART_LRMC_STATE := ""
global PROCESS_DETECT_RETRY_COUNT := 6
global PROCESS_DETECT_RETRY_DELAY_MS := 800
global WUTHERING_STARTUP_WAIT_SEC := 45
global WUTHERING_UPDATE_RECOVERY_WAIT_SEC := 300
global WUTHERING_NO_WINDOW_TOLERANCE := 3
global WUTHERING_NO_WINDOW_RESTART_SEC := 180
global PAYLOAD_BOOTSTRAP_LAUNCHER_VERSION := "4.47"
global __OKWW_MINIMIZE_SWEEP_REMAINING := 0
global __OKWW_MINIMIZE_SWEEP_CONTEXT := ""
global SERVER_SCHEDULE_ENABLED := false
global SERVER_SCHEDULE_LIST := []
global SERVER_SCHEDULE_INDEX := 1
global CURRENT_SERVER_TARGET := ""
global SERVER_SWITCH_POINT_X := 640
global SERVER_SWITCH_POINT_Y := 549
global SERVER_COMPLETED_CYCLE_MAP := Map()  ; 記錄各伺服器在當日循環的完成狀態
global REMOTE_CONTROL_ACTIVE := false
global REMOTE_PAUSE_WAITING := false
global EXITING_FROM_TRAY := false
global REMOTE_STOP_IN_PROGRESS := false
global __REMOTE_WAS_PAUSED := false
global __REMOTE_PAUSE_HOTKEY_BUSY := false
global __REMOTE_RESUME_SYNC_BUSY := false
global __REMOTE_PAUSED_AUX_PIDS := []
global CURRENT_STEP_NAME := ""
global CURRENT_STEP_DETAIL := ""
global CURRENT_STEP_LEVEL := "INFO"
global RUNTIME_DIAGNOSTICS_SECTION := "runtime_diagnostics"
global RUNTIME_DIAGNOSTICS_ENABLED := 1
global RUNTIME_DIAGNOSTICS_INTERVAL_SEC := 30
global RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT := 30
global RUNTIME_DIAGNOSTICS_MAX_WIDTH := 640
global RUNTIME_DIAGNOSTICS_JPEG_QUALITY := 45
global RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED := 1
global RUNTIME_DIAGNOSTICS_VIDEO_INTERVAL_SEC := 60
global RUNTIME_DIAGNOSTICS_VIDEO_DURATION_SEC := 6
global RUNTIME_DIAGNOSTICS_VIDEO_MAX_WIDTH := 480
global RUNTIME_DIAGNOSTICS_VIDEO_MAX_DATA_URI_CHARS := 420000
global RUNTIME_DIAGNOSTICS_VIDEO_OWNER_MARKER := "WUTHERING_RUNTIME_PREVIEW_V1"
global __RUNTIME_DIAGNOSTICS_ACTIVE := false
global __RUNTIME_SNAPSHOT_BUSY := false
global __RUNTIME_LAST_ERROR_SNAPSHOT_TICK := 0
global __RUNTIME_ERROR_SNAPSHOT_PENDING := false
global __RUNTIME_PENDING_REASON := ""
global __RUNTIME_VIDEO_PREVIEW_PID := 0
global __RUNTIME_VIDEO_PREVIEW_PATH := ""
global __RUNTIME_VIDEO_PREVIEW_STARTED_TICK := 0
global __RUNTIME_VIDEO_LAST_CAPTURE_TICK := 0
global __RUNTIME_VIDEO_PREVIEW_WIDTH := 0
global __RUNTIME_VIDEO_PREVIEW_HEIGHT := 0
global __RUNTIME_VIDEO_FFMPEG_MISSING_WARNED := false

; 保底：任何方式離開腳本時都嘗試恢復聲音
OnExit(RestoreWutheringAudioOnExit)

; 提示工具（開頭加5個空白避免被滑鼠遮擋）
ShowTip(msg, duration := 5000) {
    global TOOLTIP_SLOT, TOOLTIP_UNTIL_TICK, TOOLTIP_CONTENT
    if (duration < 3000)
        duration := 3000
    else if (duration > 30000)
        duration := 30000
    msg := StrReplace(msg, "`r", "")

    if (A_TickCount < TOOLTIP_UNTIL_TICK && TOOLTIP_CONTENT != "") {
        lineCount := StrSplit(TOOLTIP_CONTENT, "`n").Length
        if (lineCount >= 5)
            TOOLTIP_CONTENT := msg
        else
            TOOLTIP_CONTENT := TOOLTIP_CONTENT "`n" msg
    } else {
        TOOLTIP_CONTENT := msg
    }

    display := "          " StrReplace(TOOLTIP_CONTENT, "`n", "`n          ")
    TOOLTIP_UNTIL_TICK := A_TickCount + duration
    expireTick := TOOLTIP_UNTIL_TICK

    ToolTip display, , , TOOLTIP_SLOT
    if (duration > 0)
        SetTimer(() => ClearTipIfMatched(expireTick), -duration)
}

ClearTipIfMatched(expireTick) {
    global TOOLTIP_SLOT, TOOLTIP_UNTIL_TICK, TOOLTIP_CONTENT
    if (TOOLTIP_UNTIL_TICK = expireTick) {
        ToolTip(, , , TOOLTIP_SLOT)
        TOOLTIP_UNTIL_TICK := 0
        TOOLTIP_CONTENT := ""
    }
}

; 去除路徑前後的引號和空白
NormalizePath(p) {
    return Trim(p, ' "')
}

CanonicalLocalPath(path) {
    path := NormalizePath(path)
    if (path = "")
        return ""

    buf := Buffer(32768 * 2, 0)
    len := DllCall("Kernel32\GetFullPathNameW", "str", path, "uint", 32768,
        "ptr", buf, "ptr", 0, "uint")
    if (len > 0 && len < 32768)
        return StrGet(buf, len, "UTF-16")
    return path
}

WriteBootstrapTextFile(path, text) {
    tmpPath := path ".write_" A_TickCount "_" DllCall("GetCurrentProcessId")
    try {
        if FileExist(tmpPath)
            FileDelete(tmpPath)
        FileAppend(text, tmpPath, "UTF-8-RAW")
        FileMove(tmpPath, path, 1)
        return true
    } catch as e {
        try FileDelete(tmpPath)
        WriteLog("payload 修復 launcher：覆寫狀態檔失敗 | path=" path " | " e.Message, "WARN")
        return false
    }
}

GetBootstrapFileSha256(filePath) {
    if !FileExist(filePath)
        return ""

    token := A_TickCount "_" DllCall("GetCurrentProcessId")
    scriptPath := A_Temp "\launcher_bootstrap_hash_" token ".ps1"
    outputPath := A_Temp "\launcher_bootstrap_hash_" token ".txt"
    try {
        scriptLines := [
            "param([string]$InputPath,[string]$OutputPath)",
            "$ErrorActionPreference = 'Stop'",
            "$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $InputPath).Hash.ToLowerInvariant()",
            "[System.IO.File]::WriteAllText($OutputPath, $hash, [System.Text.Encoding]::ASCII)"
        ]
        scriptText := ""
        for _, line in scriptLines
            scriptText .= line "`r`n"
        FileAppend(scriptText, scriptPath, "UTF-8-RAW")

        cmd := 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' scriptPath '"'
        cmd .= ' -InputPath "' filePath '" -OutputPath "' outputPath '"'
        if (RunWait(cmd, , "Hide") != 0 || !FileExist(outputPath))
            return ""

        hash := StrLower(Trim(FileRead(outputPath, "UTF-8"), " `t`r`n"))
        return (hash ~= "^[0-9a-f]{64}$") ? hash : ""
    } catch as e {
        WriteLog("payload 修復 launcher：計算 SHA256 失敗 | path=" filePath
            " | " e.Message, "WARN")
        return ""
    } finally {
        try FileDelete(scriptPath)
        try FileDelete(outputPath)
    }
}

IsPlausibleLauncherExe(path, &fileSize) {
    fileSize := 0
    signature := 0
    try {
        fileSize := FileGetSize(path)
        file := FileOpen(path, "r")
        signature := file.ReadUShort()
        file.Close()
    } catch {
        return false
    }
    return (fileSize >= 1048576 && signature = 0x5A4D)
}

RestoreLauncherBackupForBootstrap(targetPath, backupPath, expectedHash := "") {
    if !FileExist(backupPath)
        return {ok: false, hash: "", reason: "backup_missing"}

    backupSize := 0
    if !IsPlausibleLauncherExe(backupPath, &backupSize)
        return {ok: false, hash: "", reason: "backup_invalid_pe_or_size"}

    backupHash := GetBootstrapFileSha256(backupPath)
    if (backupHash = "")
        return {ok: false, hash: "", reason: "backup_hash_failed"}
    if (expectedHash != "" && backupHash != expectedHash)
        return {ok: false, hash: backupHash, reason: "backup_hash_not_original_target"}

    try {
        if FileExist(targetPath)
            FileDelete(targetPath)
        FileMove(backupPath, targetPath, 1)
        if !FileExist(targetPath)
            throw Error("restored_target_missing")
        restoredHash := GetBootstrapFileSha256(targetPath)
        if (restoredHash = "" || restoredHash != backupHash)
            throw Error("restored_target_hash_mismatch")
        return {ok: true, hash: restoredHash, reason: "restored"}
    } catch as e {
        return {ok: false, hash: backupHash, reason: e.Message}
    }
}

IsSafePendingLauncherSource(path, dataDir) {
    path := CanonicalLocalPath(path)
    if (path = "" || !FileExist(path))
        return false

    SplitPath(path, &fileName)
    if !(fileName ~= "i)^launcher_update_[0-9A-Za-z._-]+\.exe$")
        return false

    pathLower := StrLower(path)
    dataRoot := StrLower(RTrim(CanonicalLocalPath(dataDir), "\") "\")
    tempRoot := StrLower(RTrim(CanonicalLocalPath(A_Temp), "\") "\")
    return (InStr(pathLower, dataRoot) = 1 || InStr(pathLower, tempRoot) = 1)
}

ResolvePendingLauncherSource(markerPath, dataDir) {
    try markerText := FileRead(markerPath, "UTF-8")
    catch as e {
        WriteLog("payload 修復 launcher：無法讀取 pending marker | " e.Message, "WARN")
        return ""
    }

    directPath := Trim(markerText, " `t`r`n")
    if IsSafePendingLauncherSource(directPath, dataDir)
        return CanonicalLocalPath(directPath)

    ; v4.42 使用 FileAppend，可能把多次下載路徑無分隔地串在一起。
    ; 逐一抽出 launcher_update_*.exe，選擇最後一個仍存在且位於 Temp/config 的候選。
    lastCandidate := ""
    pos := 1
    pattern := "i)([A-Z]:\\(?:(?![A-Z]:\\)[\s\S])*?launcher_update_[0-9A-Za-z._-]+\.exe)"
    while RegExMatch(markerText, pattern, &m, pos) {
        lastCandidate := CanonicalLocalPath(m[1])
        pos := m.Pos(0) + m.Len(0)
    }

    ; 串接 marker 只接受最後一次下載的語法候選。最後候選若遺失或越界，
    ; 必須保留現場並失敗，不能退回仍存在的舊 EXE 後誤標成新版本。
    if (lastCandidate != "" && IsSafePendingLauncherSource(lastCandidate, dataDir))
        return lastCandidate
    return ""
}

GetLauncherProcessAtPath(targetPath) {
    targetLower := StrLower(CanonicalLocalPath(targetPath))
    if (targetLower = "")
        return {running: false, pid: 0}

    try {
        for proc in ComObjGet("winmgmts:").ExecQuery(
            "Select ProcessId, ExecutablePath from Win32_Process where Name='全自動鋤地.exe'") {
            executablePath := ""
            try executablePath := proc.ExecutablePath
            if (executablePath != ""
                && StrLower(CanonicalLocalPath(executablePath)) = targetLower)
                return {running: true, pid: proc.ProcessId + 0}
        }
    } catch as e {
        WriteLog("payload 修復 launcher：掃描舊 launcher 進程失敗 | " e.Message, "WARN")
    }
    return {running: false, pid: 0}
}

RepairPendingLauncherUpdateFromPayload(dataDir) {
    global PAYLOAD_BOOTSTRAP_LAUNCHER_VERSION

    ; v4.43+ 會自行等待退出後替換；只有 v4.42 等舊 launcher 啟動 payload 時才接手。
    if (EnvGet("PACK_LAUNCHER_HANDLES_SELF_UPDATE") = "1") {
        WriteLog("launcher 更新由新版 launcher 自行處理，payload 略過相容修復")
        return false
    }

    markerPath := dataDir "\\launcher_pending_update.tmp"
    versionPath := dataDir "\\launcher_pending_version.txt"
    shaPath := dataDir "\\launcher_pending_sha256.txt"
    if !FileExist(markerPath)
        return false

    sourcePath := ResolvePendingLauncherSource(markerPath, dataDir)
    if (sourcePath = "") {
        WriteLog("payload 修復 launcher：pending marker 內沒有安全且存在的更新 EXE；保留現場供診斷", "ERROR")
        return false
    }

    sourceSize := 0
    if !IsPlausibleLauncherExe(sourcePath, &sourceSize) {
        WriteLog("payload 修復 launcher：更新 EXE 的 MZ／大小驗證失敗 | size=" sourceSize, "ERROR")
        return false
    }

    sourceSha := GetBootstrapFileSha256(sourcePath)
    if (sourceSha = "") {
        WriteLog("payload 修復 launcher：無法取得更新 EXE 的 SHA256", "ERROR")
        return false
    }

    if FileExist(shaPath) {
        pendingSha := ""
        try pendingSha := StrLower(Trim(FileRead(shaPath, "UTF-8"), " `t`r`n"))
        if !(pendingSha ~= "^[0-9a-f]{64}$") {
            WriteLog("payload 修復 launcher：pending SHA256 格式無效，拒絕替換", "ERROR")
            return false
        }
        if (pendingSha != sourceSha) {
            WriteLog("payload 修復 launcher：pending SHA256 與來源檔不符，拒絕替換", "ERROR")
            return false
        }
    }

    pendingVersion := ""
    if FileExist(versionPath)
        try pendingVersion := Trim(FileRead(versionPath, "UTF-8"), " `t`r`n")
    if !(pendingVersion ~= "^\d+\.\d+$")
        pendingVersion := PAYLOAD_BOOTSTRAP_LAUNCHER_VERSION

    installRoot := CanonicalLocalPath(ResolvePersistentToolsRoot())
    targetPath := CanonicalLocalPath(installRoot "\\全自動鋤地.exe")
    if (targetPath = "") {
        WriteLog("payload 修復 launcher：無法解析 launcher 安裝路徑", "WARN")
        return false
    }
    candidatePath := targetPath ".payload_update"
    backupPath := targetPath ".pre_update.bak"

    WriteLog("偵測到舊 launcher 留下的待更新檔，等待舊 launcher 退出後套用 | source="
        sourcePath " | target=" targetPath)
    lastRunning := {running: false, pid: 0}
    Loop 120 {
        lastRunning := GetLauncherProcessAtPath(targetPath)
        if !lastRunning.running
            break
        if (Mod(A_Index, 10) = 0)
            WriteLog("payload 修復 launcher：仍等待舊 launcher PID=" lastRunning.pid
                " 退出 | " Round(A_Index / 2) "/60 秒")
        RawSleep(500)
    }
    lastRunning := GetLauncherProcessAtPath(targetPath)
    if lastRunning.running {
        WriteLog("payload 修復 launcher：等待 60 秒後舊 launcher 仍在執行，保留 pending 下次重試 | pid="
            lastRunning.pid, "ERROR")
        return false
    }

    ; 先收斂上次可能中斷的兩段式替換。若 target 已是來源 SHA，代表其實已完成；
    ; 否則只要 backup 存在，就先驗證並還原，再從乾淨狀態重新嘗試。
    if FileExist(targetPath) {
        currentTargetSha := GetBootstrapFileSha256(targetPath)
        if (currentTargetSha = sourceSha) {
            if !WriteBootstrapTextFile(dataDir "\\launcher_current_version.txt", pendingVersion) {
                WriteLog("payload 修復 launcher：target 已更新但無法補寫版本狀態", "ERROR")
                return false
            }
            try FileDelete(markerPath)
            try FileDelete(versionPath)
            try FileDelete(shaPath)
            try FileDelete(sourcePath)
            try FileDelete(backupPath)
            WriteLog("payload 修復 launcher：target 已符合 pending SHA，已完成狀態收尾 | version=" pendingVersion)
            return true
        }
    }

    if FileExist(backupPath) {
        recovery := RestoreLauncherBackupForBootstrap(targetPath, backupPath)
        if !recovery.ok {
            WriteLog("payload 修復 launcher：偵測到未完成替換，但 backup 還原失敗"
                " | rollback=FAILED | reason=" recovery.reason, "ERROR")
            return false
        }
        WriteLog("payload 修復 launcher：已從上次中斷狀態還原舊 launcher"
            " | rollback=restored | sha256=" recovery.hash, "WARN")
    }

    if !FileExist(targetPath) {
        WriteLog("payload 修復 launcher：找不到安裝中的 launcher，且沒有可還原 backup"
            " | target=" targetPath, "ERROR")
        return false
    }

    originalTargetSize := 0
    if !IsPlausibleLauncherExe(targetPath, &originalTargetSize) {
        WriteLog("payload 修復 launcher：目前 launcher 的 MZ／大小驗證失敗，拒絕替換", "ERROR")
        return false
    }
    originalTargetSha := GetBootstrapFileSha256(targetPath)
    if (originalTargetSha = "") {
        WriteLog("payload 修復 launcher：無法取得目前 launcher SHA256，拒絕替換", "ERROR")
        return false
    }

    targetMoved := false
    try {
        try FileDelete(candidatePath)
        FileCopy(sourcePath, candidatePath, 1)
        if (FileGetSize(candidatePath) != sourceSize)
            throw Error("候選檔大小與來源不一致")
        candidateSha := GetBootstrapFileSha256(candidatePath)
        if (candidateSha = "" || candidateSha != sourceSha)
            throw Error("候選檔 SHA256 與來源不一致")

        FileMove(targetPath, backupPath, 1)
        targetMoved := true
        FileMove(candidatePath, targetPath, 1)
        if (!FileExist(targetPath) || FileGetSize(targetPath) != sourceSize)
            throw Error("替換後檔案大小驗證失敗")
        installedSha := GetBootstrapFileSha256(targetPath)
        if (installedSha = "" || installedSha != sourceSha)
            throw Error("替換後 SHA256 與來源不一致")
        if !WriteBootstrapTextFile(dataDir "\\launcher_current_version.txt", pendingVersion)
            throw Error("無法寫入 launcher_current_version.txt")

        try FileDelete(markerPath)
        try FileDelete(versionPath)
        try FileDelete(shaPath)
        try FileDelete(sourcePath)
        try FileDelete(backupPath)
        WriteLog("payload 已完成舊 launcher 一次性修復 | version=" pendingVersion
            " | size=" sourceSize)
        return true
    } catch as e {
        try FileDelete(candidatePath)
        rollbackStatus := targetMoved ? "FAILED: backup_missing" : "not-needed"
        if (targetMoved && FileExist(backupPath)) {
            rollback := RestoreLauncherBackupForBootstrap(
                targetPath, backupPath, originalTargetSha)
            rollbackStatus := rollback.ok ? "restored" : "FAILED: " rollback.reason
        }
        WriteLog("payload 修復 launcher 失敗，已保留 pending 供下次重試"
            " | reason=" e.Message " | rollback=" rollbackStatus, "ERROR")
        return false
    }
}

ResolveBundledAhkExe() {
    candidates := []
    candidates.Push(A_ScriptDir "\..\AutoHotkey64.exe")
    candidates.Push(A_ScriptDir "\AutoHotkey64.exe")

    packAppDir := EnvGet("PACK_APP_DIR")
    if (packAppDir != "") {
        candidates.Push(StrReplace(packAppDir, "\payload", "") "\AutoHotkey64.exe")
        candidates.Push(packAppDir "\AutoHotkey64.exe")
    }

    for _, candidate in candidates {
        path := Trim(candidate, ' "')
        if (path != "" && FileExist(path))
            return path
    }
    return ""
}

ResolvePersistentToolsRoot() {
    packAppDir := NormalizePath(EnvGet("PACK_APP_DIR"))
    if (packAppDir != "") {
        if RegExMatch(packAppDir, "i)\\payload$")
            return RegExReplace(packAppDir, "i)\\payload$", "")
        return packAppDir
    }

    return NormalizePath(A_ScriptDir "\\..")
}

FindBundledFfmpegExe() {
    candidates := []
    persistentRoot := ResolvePersistentToolsRoot()
    if (persistentRoot != "") {
        candidates.Push(persistentRoot "\\tools\\ffmpeg\\bin\\ffmpeg.exe")
        candidates.Push(persistentRoot "\\ffmpeg\\bin\\ffmpeg.exe")
        candidates.Push(persistentRoot "\\ffmpeg.exe")
    }

    for _, candidate in candidates {
        p := NormalizePath(candidate)
        if (p != "" && FileExist(p))
            return p
    }
    return ""
}

ResolveDefaultScreenRecordingFfmpegExe() {
    bundled := FindBundledFfmpegExe()
    if (bundled != "")
        return bundled
    return ""
}

ExtractZipByShell(zipPath, destDir) {
    try {
        shell := ComObject("Shell.Application")
        src := shell.NameSpace(zipPath)
        if !IsObject(src)
            return false

        try DirCreate(destDir)
        dst := shell.NameSpace(destDir)
        if !IsObject(dst)
            return false

        ; 16 = no UI, 4 = no progress box
        dst.CopyHere(src.Items, 16 + 4)
        return true
    } catch {
        return false
    }
}

ExtractZipByPowerShell(zipPath, destDir) {
    psZip := StrReplace(zipPath, "'", "''")
    psDest := StrReplace(destDir, "'", "''")
    psCmd := "$ErrorActionPreference='Stop'; $zip='" psZip "'; $dest='" psDest "'; if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }; New-Item -ItemType Directory -Path $dest -Force | Out-Null; Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force"
    cmd := "powershell -NoProfile -ExecutionPolicy Bypass -Command " Chr(34) psCmd Chr(34)
    try {
        return (RunWait(cmd, , "Hide") = 0)
    } catch {
        return false
    }
}

CleanupBootstrapTempDir(tmpRoot) {
    if (tmpRoot = "")
        return
    try {
        if DirExist(tmpRoot)
            DirDelete(tmpRoot, true)
    }
}

GetUrlContentLength(url) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.Open("HEAD", url, false)
        req.Send()
        v := req.GetResponseHeader("Content-Length")
        n := Integer(Trim(v, " `t`r`n"))
        return (n > 0) ? n : 0
    } catch {
        return 0
    }
}

FormatBytesMB(bytes) {
    if (bytes <= 0)
        return "0.0 MB"
    return Format("{1:.1f} MB", bytes / 1048576)
}

FormatSpeedMBps(bytesPerSec) {
    if (bytesPerSec <= 0)
        return "0.0 MB/s"
    return Format("{1:.1f} MB/s", bytesPerSec / 1048576)
}

DownloadFileWithProgress(url, outPath, title := "下載中") {
    SplitPath outPath, , &outDir
    if (outDir != "")
        try DirCreate(outDir)

    if FileExist(outPath)
        try FileDelete(outPath)

    total := GetUrlContentLength(url)

    psUrl := StrReplace(url, "'", "''")
    psOut := StrReplace(outPath, "'", "''")
    psIwr := "$ProgressPreference=`"SilentlyContinue`"; $u='" psUrl "'; $o='" psOut "'; Invoke-WebRequest -Uri $u -OutFile $o"
    cmdIwr := "powershell -NoProfile -ExecutionPolicy Bypass -Command " Chr(34) psIwr Chr(34)

    g := Gui("+ToolWindow -MinimizeBox -MaximizeBox", title)
    g.SetFont("s10", "Microsoft JhengHei UI")
    txt := g.AddText("xm w420", "正在下載，請稍候...")
    bar := g.AddProgress("xm y+8 w420 h18", 0)
    hint := g.AddText("xm y+6 w420", "0.0 MB")
    g.Show("AutoSize Center")

    pid := 0
    try Run(cmdIwr, "", "Hide", &pid)
    catch as e {
        g.Destroy()
        WriteLog("啟動下載進程失敗(IWR): " e.Message, "WARN")
        return false
    }

    WriteLog("FFmpeg 下載模式: IWR")
    spin := 0
    startTick := A_TickCount
    lastTick := startTick
    lastSize := 0
    speedBps := 0.0
    while ProcessExist(pid) {
        size := 0
        try size := FileGetSize(outPath)

        nowTick := A_TickCount
        dt := nowTick - lastTick
        if (dt >= 400) {
            ds := size - lastSize
            if (ds < 0)
                ds := 0
            speedBps := (ds * 1000.0) / dt
            lastTick := nowTick
            lastSize := size
        }

        if (total > 0) {
            pct := Floor((size * 100) / total)
            if (pct < 0)
                pct := 0
            if (pct > 99)
                pct := 99
            bar.Value := pct
            txt.Value := "正在下載 FFmpeg... " pct "%"
            hint.Value := FormatBytesMB(size) " / " FormatBytesMB(total) "  (" FormatSpeedMBps(speedBps) ")"
        } else {
            spin += 4
            if (spin > 100)
                spin := 0
            bar.Value := spin
            txt.Value := "正在下載 FFmpeg..."
            hint.Value := FormatBytesMB(size) "  (" FormatSpeedMBps(speedBps) ")"
        }
        Sleep 200
    }

    ok := false
    finalSize := 0
    try {
        finalSize := FileGetSize(outPath)
        ok := (finalSize > 0)
    }

    if ok {
        bar.Value := 100
        txt.Value := "下載完成"
        hint.Value := FormatBytesMB(finalSize)
        Sleep 300
    } else {
        txt.Value := "下載失敗"
        hint.Value := "請稍後重試或手動放置 ffmpeg.exe"
        Sleep 700
    }

    g.Destroy()
    return ok
}

TryBootstrapBundledFfmpeg() {
    global SCREEN_RECORDING_FFMPEG_AUTO_DOWNLOAD, SCREEN_RECORDING_FFMPEG_DOWNLOAD_URL
    global __SCREEN_RECORDING_FFMPEG_BOOTSTRAP_ATTEMPTED

    if !SCREEN_RECORDING_FFMPEG_AUTO_DOWNLOAD
        return ""

    if __SCREEN_RECORDING_FFMPEG_BOOTSTRAP_ATTEMPTED
        return ""
    __SCREEN_RECORDING_FFMPEG_BOOTSTRAP_ATTEMPTED := true

    persistentRoot := ResolvePersistentToolsRoot()
    if (persistentRoot = "")
        persistentRoot := A_ScriptDir

    targetDir := persistentRoot "\\tools\\ffmpeg\\bin"
    targetExe := targetDir "\\ffmpeg.exe"
    if FileExist(targetExe)
        return targetExe

    tmpRoot := A_Temp "\\wuthering_ffmpeg_bootstrap"
    zipPath := tmpRoot "\\ffmpeg-release-essentials.zip"
    extractDir := tmpRoot "\\extract"

    CleanupBootstrapTempDir(tmpRoot)

    try DirCreate(tmpRoot)

    try {
        WriteLog("未找到本地 ffmpeg，開始自動下載: " SCREEN_RECORDING_FFMPEG_DOWNLOAD_URL)
        if !DownloadFileWithProgress(SCREEN_RECORDING_FFMPEG_DOWNLOAD_URL, zipPath, "FFmpeg 自動下載") {
            WriteLog("FFmpeg 自動下載失敗: 檔案未完成", "WARN")
            CleanupBootstrapTempDir(tmpRoot)
            return ""
        }
        WriteLog("FFmpeg 自動下載完成: " zipPath)
    } catch as e {
        WriteLog("FFmpeg 自動下載失敗: " e.Message, "WARN")
        CleanupBootstrapTempDir(tmpRoot)
        return ""
    }

    if !ExtractZipByShell(zipPath, extractDir) {
        WriteLog("FFmpeg 自動解壓失敗（Shell.Application），改用 Expand-Archive", "WARN")
        if !ExtractZipByPowerShell(zipPath, extractDir) {
            WriteLog("FFmpeg 自動解壓失敗（Expand-Archive）", "WARN")
            CleanupBootstrapTempDir(tmpRoot)
            return ""
        }
    }

    found := ""
    deadline := A_TickCount + 120000
    while (A_TickCount < deadline) {
        Loop Files, extractDir "\\ffmpeg.exe", "R" {
            found := A_LoopFileFullPath
            break
        }
        if (found != "")
            break
        Sleep 200
    }

    if (found = "") {
        WriteLog("FFmpeg 自動解壓後未找到 ffmpeg.exe", "WARN")
        CleanupBootstrapTempDir(tmpRoot)
        return ""
    }

    try DirCreate(targetDir)
    try {
        FileCopy(found, targetExe, true)
        if FileExist(targetExe) {
            WriteLog("FFmpeg 已自動安裝到: " targetExe)
            CleanupBootstrapTempDir(tmpRoot)
            return targetExe
        }
    } catch as e {
        WriteLog("FFmpeg 安裝到目標資料夾失敗: " e.Message, "WARN")
    }

    CleanupBootstrapTempDir(tmpRoot)

    return ""
}

ResolveScreenRecordingFfmpegExePath(configuredValue := "") {
    rootDir := ResolvePersistentToolsRoot()
    raw := NormalizePath(configuredValue)
    if (raw = "")
        raw := SCREEN_RECORDING_FFMPEG_EXE
    raw := NormalizePath(raw)

    if (raw = "" || raw = "ffmpeg" || raw = "ffmpeg.exe") {
        bundled := FindBundledFfmpegExe()
        if (bundled != "")
            return bundled

        bootstrapped := TryBootstrapBundledFfmpeg()
        if (bootstrapped != "")
            return bootstrapped
        return ""
    }

    if RegExMatch(raw, "i)^[a-z]:\\")
        return raw
    if (SubStr(raw, 1, 2) = "\\\\")
        return raw

    candidate := (rootDir != "") ? (rootDir "\\" raw) : (A_ScriptDir "\\" raw)
    if FileExist(candidate)
        return candidate
    return ""
}

NormalizeScreenRecordingQualityPreset(val) {
    s := StrLower(Trim(val, " `t`r`n"))
    if (s = "high" || s = "balanced" || s = "low" || s = "custom")
        return s
    return "balanced"
}

ToIntRange(val, defaultVal, minVal, maxVal) {
    n := defaultVal
    try n := Integer(Trim(val, " `t`r`n"))
    if (n < minVal)
        n := minVal
    if (n > maxVal)
        n := maxVal
    return n
}

ParseScreenRecordingSimpleSettingsFromArgs(args) {
    txt := " " Trim(args, " `t`r`n") " "
    fps := 30
    crf := 23

    if RegExMatch(txt, "i)\s-framerate\s+(\d+)", &m1)
        fps := ToIntRange(m1[1], 30, 10, 120)
    if RegExMatch(txt, "i)\s-crf\s+(\d+)", &m2)
        crf := ToIntRange(m2[1], 23, 0, 51)

    quality := "balanced"
    if (crf <= 20)
        quality := "high"
    else if (crf >= 27)
        quality := "low"

    return {
        fps: fps,
        crf: crf,
        quality: quality
    }
}

BuildScreenRecordingFfmpegArgsBySimple(qualityPreset, fpsVal, crfVal) {
    q := NormalizeScreenRecordingQualityPreset(qualityPreset)
    fps := ToIntRange(fpsVal, 30, 10, 120)
    crf := 23

    if (q = "high")
        crf := 18
    else if (q = "low")
        crf := 28
    else if (q = "custom")
        crf := ToIntRange(crfVal, 23, 0, 51)

    return "-y -f gdigrab -framerate " fps " -i desktop -c:v libx264 -preset veryfast -crf " crf " -pix_fmt yuv420p -f matroska"
}

GetScreenRecordingQualityHint(qualityPreset, crfText := "") {
    q := NormalizeScreenRecordingQualityPreset(qualityPreset)
    if (q = "high")
        return "高畫質：固定 CRF 18（畫質高、檔案較大）"
    if (q = "balanced")
        return "平衡：固定 CRF 23（預設建議）"
    if (q = "low")
        return "小檔案：固定 CRF 28（畫質較低、檔案較小）"

    if RegExMatch(Trim(crfText, " `t`r`n"), "^\d+$") {
        c := ToIntRange(crfText, 23, 0, 51)
        return "自訂 CRF：" c "（數字越小畫質越高、檔案越大；建議 18~28）"
    }
    return "自訂 CRF：數字越小畫質越高、檔案越大；建議 18~28"
}

MuteWutheringAudioAtStartup() {
    global __WUTHERING_MUTE_PENDING
    __WUTHERING_MUTE_PENDING := true
    TryMuteWutheringAudio("主流程前置")
    SetTimer(WutheringMuteTick, 3000)
}

WutheringMuteTick() {
    global __WUTHERING_MUTE_PENDING
    if !__WUTHERING_MUTE_PENDING {
        SetTimer(WutheringMuteTick, 0)
        return
    }

    if TrySetWutheringProcessMute(true) {
        __WUTHERING_MUTE_PENDING := false
        SetTimer(WutheringMuteTick, 0)
        WriteLog("已成功套用鳴潮單獨靜音")
    }
}

TryMuteWutheringAudio(reason := "") {
    global __WUTHERING_MUTE_PENDING
    if TrySetWutheringProcessMute(true) {
        __WUTHERING_MUTE_PENDING := false
        SetTimer(WutheringMuteTick, 0)
        msg := "已啟用鳴潮單獨靜音"
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
        return true
    }
    return false
}

UnmuteWutheringAudio(reason := "") {
    global __WUTHERING_AUDIO_MUTED, __WUTHERING_MUTE_PENDING
    __WUTHERING_MUTE_PENDING := false
    SetTimer(WutheringMuteTick, 0)

    if TrySetWutheringProcessMute(false) {
        msg := "已恢復鳴潮聲音"
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
    } else {
        WriteLog("恢復鳴潮聲音失敗或尚未建立音訊 Session", "WARN")
    }
}

RestoreWutheringAudioOnExit(exitReason, exitCode) {
    global __RESTART_IN_PROGRESS, __NEXTSERVER_RESTART, TOOLTIP_SLOT
    try ToolTip(, , , TOOLTIP_SLOT)
    try StopRuntimeDiagnostics()
    try SetTimer(ScreenRecordingMaintenanceTick, 0)
    try RC_Shutdown()
    if (__RESTART_IN_PROGRESS || __NEXTSERVER_RESTART)
        WriteLog("重啟模式：保留錄影不中斷，略過結束保底停止", "WARN")
    else
        ForceStopManagedScreenRecording("腳本結束保底")
    UnmuteWutheringAudio("腳本結束保底")
}

OnRemoteControlStateChanged(state) {
    global REMOTE_STOP_IN_PROGRESS, __REMOTE_WAS_PAUSED
    if (state = "STOP") {
        if REMOTE_STOP_IN_PROGRESS
            return
        REMOTE_STOP_IN_PROGRESS := true
        try RC_SetPausedFlag(false)
        WriteLog("遠端控制：收到 STOP，開始完整關閉流程", "WARN")
        ShowTip("⏹ 遠端關閉中：腳本/遊戲/OKWW/LRMCAI", 1800)
        ; 直接執行關閉流程，避免在收尾等待中先 ExitApp 導致計時器回呼來不及執行。
        ShutdownGameLrmcOkww(false)
        return
    }

    if (state = "PAUSE") {
        __REMOTE_WAS_PAUSED := true
        WriteLog("遠端控制：收到 PAUSE（軟停模式）", "WARN")
        ShowTip("⏸ 已切換為遠端暫停", 1500)
        SetTimer(RemotePauseHookTick, -50)
    } else {
        WriteLog("遠端控制：收到 RUN（恢復執行）")
        ShowTip("▶ 已切換為遠端執行", 1500)
        if (state = "RUN" && __REMOTE_WAS_PAUSED) {
            __REMOTE_WAS_PAUSED := false
            SetTimer(RemoteRunResumeHookTick, -80)
        }
    }
}

RemotePauseHookTick() {
    global __REMOTE_PAUSE_HOTKEY_BUSY, __REWARD_MONITOR_ACTIVE

    if __REMOTE_PAUSE_HOTKEY_BUSY
        return

    __REMOTE_PAUSE_HOTKEY_BUSY := true
    try {
        PauseAuxManagedScriptsOnRemotePause()

        if !ProcessExist("LRMCAI.exe") {
            WriteLog("遠端PAUSE：LRMCAI 未執行，略過 F9", "INFO")
        } else {
            if SendHotkeyToLrmc("{F9}", "遠端PAUSE")
                WriteLog("遠端PAUSE：已送出 F9 到 LRMCAI")
            else
                WriteLog("遠端PAUSE：送出 F9 到 LRMCAI 失敗", "WARN")
        }

        ; 收尾監測必須持續讀取 LRMCAI 新增日誌。這裡若進入最長 60 秒的模板等待，
        ; AHK 的目前執行緒會壓住主監測迴圈，因此收尾階段只送出暫停熱鍵後立即返回。
        if __REWARD_MONITOR_ACTIVE {
            WriteLog("遠端PAUSE：目前位於收尾監測，略過確認.png等待，保持背景日誌監測不中斷", "INFO")
        } else {
            confirmTemplate := A_ScriptDir "\確認.png"
            if FileExist(confirmTemplate) {
                if WaitForTemplateVisible(confirmTemplate, 60) {
                    if ClickTemplateIfFound(confirmTemplate)
                        WriteLog("遠端PAUSE：60 秒內命中確認.png，已先執行點擊")
                    else
                        WriteLog("遠端PAUSE：已偵測到確認.png，但點擊失敗，繼續原暫停流程", "WARN")
                } else {
                    WriteLog("遠端PAUSE：60 秒內未檢測到確認.png，繼續原暫停流程", "INFO")
                }
            } else {
                WriteLog("遠端PAUSE：找不到確認.png，略過模板檢測", "WARN")
            }
        }
    } finally {
        __REMOTE_PAUSE_HOTKEY_BUSY := false
    }
}

RemoteRunResumeHookTick() {
    global __REMOTE_RESUME_SYNC_BUSY, __REWARD_MONITOR_ACTIVE, __REWARD_MONITOR_COMPLETION_PENDING

    if __REMOTE_RESUME_SYNC_BUSY
        return

    __REMOTE_RESUME_SYNC_BUSY := true
    try {
        ResumeAuxManagedScriptsAfterRemoteRun()

        ; 收尾條件已在 PAUSE 期間保存時，RUN 的唯一工作是解除暫停。
        ; 不再進入登入模板/OCR等待或送 Ctrl+F1，以免把安全收尾平白延後一分鐘以上。
        if (__REWARD_MONITOR_ACTIVE && __REWARD_MONITOR_COMPLETION_PENDING) {
            WriteLog("遠端RUN：收尾完成條件已保存，略過登入/OCR/Ctrl+F1同步，直接交由收尾監測關閉", "INFO")
            return
        }

        hwnd := GetWutheringGameHwnd()
        if !hwnd
            hwnd := WaitForWutheringGameWindow(20)

        loginTemplate := A_ScriptDir "\登入.png"
        loginDetected := false
        if FileExist(loginTemplate) {
            loginDetected := WaitForTemplateVisible(loginTemplate, 60)
            if !loginDetected {
                WriteLog("遠端RUN：1 分鐘未判定到登入.png，直接送出 Ctrl+F1 到 LRMCAI", "WARN")
                TrySendRunCtrlF1ToLrmc("遠端RUN（1分鐘未判定登入模板）")
                return
            }

            ClickTemplateIfFound(loginTemplate)
            WaitLoginScreenClearedByOcrAndCenterClick(hwnd, 40)
        } else {
            WriteLog("遠端RUN：找不到登入模板，略過點擊", "WARN")
        }

        if !hwnd {
            WriteLog("遠端RUN：找不到鳴潮視窗，略過主畫面模板檢測與 Ctrl+F1", "WARN")
            return
        }

        if !WaitEscMenuOCR(hwnd, 90) {
            WriteLog("遠端RUN：未檢測到 icon_main.png，略過送出 Ctrl+F1", "WARN")
            return
        }

        if !ProcessExist("LRMCAI.exe") {
            WriteLog("遠端RUN：LRMCAI 未執行，略過送出 Ctrl+F1", "WARN")
            return
        }

        TrySendRunCtrlF1ToLrmc("遠端RUN恢復")
    } finally {
        __REMOTE_RESUME_SYNC_BUSY := false
    }
}

TrySendRunCtrlF1ToLrmc(reason := "") {
    if !ProcessExist("LRMCAI.exe") {
        WriteLog("遠端RUN：LRMCAI 未執行，略過送出 Ctrl+F1", "WARN")
        return false
    }

    if SendHotkeyToLrmc("^{F1}", reason != "" ? reason : "遠端RUN恢復") {
        WriteLog("遠端RUN：已送出 Ctrl+F1 到 LRMCAI")
        return true
    }

    WriteLog("遠端RUN：送出 Ctrl+F1 到 LRMCAI 失敗", "WARN")
    return false
}

WaitForTemplateVisible(templatePath, timeoutSec := 60) {
    deadline := A_TickCount + timeoutSec * 1000
    while (A_TickCount < deadline) {
        if IsTemplateVisible(templatePath)
            return true
        RawSleep(400)
    }
    return false
}

IsTemplateVisible(templatePath) {
    x := 0
    y := 0
    try {
        if FindTemplateInWutheringWindow(templatePath, &x, &y)
            return true
        return FindTemplateOnScreenWithTolerance(templatePath, &x, &y, 0, 0, A_ScreenWidth - 1, A_ScreenHeight - 1)
    } catch {
        return false
    }
}

IsLoginScreenByOcr(hwnd) {
    loginKeywords := ["點擊開始", "点击开始", "點選開始", "点选开始", "開始遊戲", "开始游戏",
                      "點擊連接", "点击连接", "點選連接", "点选连接",
                      "伺服器", "服务器", "賬號", "账号", "帳號", "账户"]
    tempFile := A_Temp "\ahk_login_ocr_" A_TickCount ".png"
    try {
        ImagePutFile("ahk_id " hwnd, tempFile)
        ocr := RapidOcr()
        res := ocr.ocr_from_file(tempFile, , true)
        if FileExist(tempFile)
            FileDelete(tempFile)
        if !IsObject(res)
            return false
        for block in res {
            clean := StrReplace(StrReplace(block.text, "`r", ""), "`n", "")
            clean := StrReplace(clean, " ", "")
            for _, kw in loginKeywords {
                if InStr(clean, kw)
                    return true
            }
        }
    } catch {
        try FileDelete(tempFile)
    }
    return false
}

WaitLoginScreenClearedByOcrAndCenterClick(hwnd, timeoutSec := 40) {
    if !hwnd {
        WriteLog("遠端RUN：無遊戲視窗，略過登入畫面 OCR 檢測", "WARN")
        return false
    }

    ; 先等登入畫面出現（點擊按鈕後畫面需要短暫切換，最多 30 秒）
    deadline30 := A_TickCount + 30000
    loginScreenFound := false
    while (A_TickCount < deadline30) {
        if IsLoginScreenByOcr(hwnd) {
            loginScreenFound := true
            break
        }
        Sleep 400
    }

    if !loginScreenFound {
        WriteLog("遠端RUN：點擊登入按鈕後 30 秒內未偵測到登入畫面（OCR），繼續後續流程", "INFO")
        return true
    }
    WriteLog("遠端RUN：OCR 偵測到登入畫面，開始以中心點擊直到消失")

    deadline := A_TickCount + timeoutSec * 1000
    attempts := 0
    while (A_TickCount < deadline) {
        Sleep 2000
        if !IsLoginScreenByOcr(hwnd) {
            WriteLog("遠端RUN：登入畫面已消失（OCR 確認），共點擊 " attempts " 次")
            return true
        }

        attempts += 1
        if ClickWutheringCenterPoint(hwnd) {
            WriteLog("遠端RUN：登入畫面仍存在（OCR），已執行第 " attempts " 次中心點擊")
        } else {
            WriteLog("遠端RUN：中心點擊失敗，改用遊戲視窗中心 fallback", "WARN")
            ClickWutheringCenterPoint(hwnd)
        }
        Sleep 300
    }

    WriteLog("遠端RUN：登入畫面在 " timeoutSec " 秒內未消失（OCR），後續仍嘗試主畫面檢測", "WARN")
    return false
}

ClickWutheringCenterPoint(hwnd := 0) {
    if !hwnd
        hwnd := GetWutheringGameHwnd()
    if !hwnd
        hwnd := WaitForWutheringGameWindow(8)
    if !hwnd
        return false

    ; 使用遊戲客戶區相對座標點擊，避免點到視窗外。
    try WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " hwnd)
    catch
        return false

    if (cw <= 0 || ch <= 0)
        return false

    centerX := cw // 2
    centerY := ch // 2
    return ServerClickClient(hwnd, centerX, centerY)
}

PauseAuxManagedScriptsOnRemotePause() {
    global __REMOTE_PAUSED_AUX_PIDS

    suspendedCount := 0
    __REMOTE_PAUSED_AUX_PIDS := []
    for item in EnumerateAuxManagedAhkProcesses() {
        if SuspendProcessByPid(item.pid) {
            __REMOTE_PAUSED_AUX_PIDS.Push(item.pid)
            suspendedCount += 1
            WriteLog("遠端PAUSE：已暫停子腳本 PID=" item.pid "（" item.name "）")
        }
    }

    if (suspendedCount <= 0)
        WriteLog("遠端PAUSE：未發現可暫停的子腳本進程", "INFO")
}

ResumeAuxManagedScriptsAfterRemoteRun() {
    global __REMOTE_PAUSED_AUX_PIDS

    candidates := Map()
    for _, pid in __REMOTE_PAUSED_AUX_PIDS
        candidates[String(pid)] := pid
    for item in EnumerateAuxManagedAhkProcesses()
        candidates[String(item.pid)] := item.pid

    resumed := 0
    for _, pid in candidates {
        if ResumeProcessByPid(pid) {
            resumed += 1
            WriteLog("遠端RUN：已恢復子腳本 PID=" pid)
        }
    }
    __REMOTE_PAUSED_AUX_PIDS := []

    if (resumed <= 0)
        WriteLog("遠端RUN：未發現需要恢復的子腳本進程", "INFO")
}

EnumerateAuxManagedAhkProcesses() {
    currentPid := DllCall("GetCurrentProcessId")
    result := []
    wantedNames := ["聲骸合成.ahk", "自動開啟OKWW.ahk", "開啟LRMC.ahk"]

    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%AutoHotkey%'") {
            if (proc.ProcessId = currentPid)
                continue

            cmdLine := ""
            try cmdLine := proc.CommandLine
            if (cmdLine = "")
                continue

            for _, name in wantedNames {
                if InStr(cmdLine, name) {
                    result.Push({ pid: proc.ProcessId, name: name })
                    break
                }
            }
        }
    }
    return result
}

SuspendProcessByPid(pid) {
    if (pid <= 0)
        return false

    PROCESS_SUSPEND_RESUME := 0x0800
    PROCESS_QUERY_LIMITED_INFORMATION := 0x1000
    hProc := DllCall("Kernel32\OpenProcess", "UInt", PROCESS_SUSPEND_RESUME | PROCESS_QUERY_LIMITED_INFORMATION, "Int", 0, "UInt", pid, "Ptr")
    if !hProc
        return false

    ntStatus := DllCall("ntdll\NtSuspendProcess", "Ptr", hProc, "Int")
    DllCall("Kernel32\CloseHandle", "Ptr", hProc)
    return (ntStatus = 0)
}

ResumeProcessByPid(pid) {
    if (pid <= 0)
        return false

    PROCESS_SUSPEND_RESUME := 0x0800
    PROCESS_QUERY_LIMITED_INFORMATION := 0x1000
    hProc := DllCall("Kernel32\OpenProcess", "UInt", PROCESS_SUSPEND_RESUME | PROCESS_QUERY_LIMITED_INFORMATION, "Int", 0, "UInt", pid, "Ptr")
    if !hProc
        return false

    ntStatus := DllCall("ntdll\NtResumeProcess", "Ptr", hProc, "Int")
    DllCall("Kernel32\CloseHandle", "Ptr", hProc)
    return (ntStatus = 0)
}

SendHotkeyToLrmc(hotkey, reason := "") {
    target := ResolveLrmcTargetWindow()
    if !target.hwnd {
        WriteLog("送出快捷鍵到 LRMCAI 失敗：找不到可用視窗，hotkey=" hotkey, "WARN")
        return false
    }

    ; 需求：先置頂並激活 LRMCAI 主視窗，再送出快捷鍵。
    try {
        WinRestore("ahk_id " target.hwnd)
        WinSetAlwaysOnTop(1, "ahk_id " target.hwnd)
        WinActivate("ahk_id " target.hwnd)
        WinWaitActive("ahk_id " target.hwnd, , 1)
        RawSleep(80)
    } catch as e {
        WriteLog("LRMCAI 視窗置頂/激活失敗，仍嘗試送鍵: hwnd=" target.hwnd " pid=" target.pid " title=" target.title " | " e.Message, "WARN")
    }

    try {
        SendEvent hotkey
        if (reason != "")
            WriteLog("已以前景方式送出快捷鍵到 LRMCAI: " hotkey "（" reason "） | hwnd=" target.hwnd " pid=" target.pid " title=" target.title)
        else
            WriteLog("已以前景方式送出快捷鍵到 LRMCAI: " hotkey " | hwnd=" target.hwnd " pid=" target.pid " title=" target.title)
        return true
    } catch as e {
        WriteLog("前景送出快捷鍵到 LRMCAI 失敗，改用 ControlSend: " hotkey " | hwnd=" target.hwnd " pid=" target.pid " title=" target.title " | " e.Message, "WARN")
    }

    try {
        ControlSend(hotkey, , "ahk_id " target.hwnd)
        if (reason != "")
            WriteLog("已透過 ControlSend 送出快捷鍵到 LRMCAI: " hotkey "（" reason "） | hwnd=" target.hwnd " pid=" target.pid " title=" target.title)
        else
            WriteLog("已透過 ControlSend 送出快捷鍵到 LRMCAI: " hotkey " | hwnd=" target.hwnd " pid=" target.pid " title=" target.title)
        return true
    } catch as e {
        WriteLog("送出快捷鍵到 LRMCAI 失敗: " hotkey " | hwnd=" target.hwnd " pid=" target.pid " title=" target.title " | " e.Message, "WARN")
    }

    return false
}

RawSleep(delayMs) {
    ms := 0
    try ms := Integer(delayMs)
    if (ms < 0)
        ms := 0
    DllCall("Sleep", "UInt", ms)
}

ResolveLrmcTargetWindow() {
    best := { hwnd: 0, pid: 0, title: "", class: "", score: -1 }

    if !ProcessExist("LRMCAI.exe")
        return best

    try {
        for hwnd in WinGetList("ahk_exe LRMCAI.exe") {
            title := ""
            class := ""
            visible := false

            try title := WinGetTitle("ahk_id " hwnd)
            try class := WinGetClass("ahk_id " hwnd)
            try visible := DllCall("IsWindowVisible", "ptr", hwnd, "int")

            score := 0
            if (visible)
                score += 40
            if (title != "")
                score += 10
            if InStr(title, "LRMCAI")
                score += 50
            if (title ~= "i)LRMCAI.*\d")
                score += 100
            if (class != "ConsoleWindowClass")
                score += 20

            if (score > best.score) {
                best := { hwnd: hwnd, pid: WinGetPID("ahk_id " hwnd), title: title, class: class, score: score }
            }
        }
    }

    if (!best.hwnd) {
        try {
            hwnd := WinExist("ahk_exe LRMCAI.exe")
            if hwnd {
                best := { hwnd: hwnd, pid: WinGetPID("ahk_id " hwnd), title: WinGetTitle("ahk_id " hwnd), class: "", score: 0 }
            }
        }
    }

    return best
}

; 軟暫停：主流程在 Sleep 檢查點停住，但遠端監控計時器仍可繼續心跳與收命令。
Sleep(delayMs) {
    global REMOTE_CONTROL_ACTIVE, REMOTE_PAUSE_WAITING

    ms := 0
    try ms := Integer(delayMs)
    if (ms < 0)
        ms := 0

    if (REMOTE_CONTROL_ACTIVE) {
        while RC_IsPaused() {
            if !REMOTE_PAUSE_WAITING {
                REMOTE_PAUSE_WAITING := true
                WriteLog("遠端控制：主流程已進入軟暫停，等待 RUN 指令")
            }
            DllCall("Sleep", "UInt", 250)
        }

        if REMOTE_PAUSE_WAITING {
            REMOTE_PAUSE_WAITING := false
            WriteLog("遠端控制：收到 RUN，主流程恢復")
        }
    }

    DllCall("Sleep", "UInt", ms)
}

GetWutheringAudioTargets() {
    global CFG_FILE, WUTHERING_PROCESS_EXE

    pidMap := Map()
    nameMap := Map()

    for title in ["鸣潮", "鳴潮"] {
        hwnd := WinExist(title)
        if !hwnd
            continue

        try {
            pid := WinGetPID("ahk_id " hwnd)
            if (pid > 0)
                pidMap[String(pid)] := 1
        }

        try {
            procName := WinGetProcessName("ahk_id " hwnd)
            procName := RegExReplace(procName, "i)\.exe$")
            if (procName != "")
                nameMap[StrLower(procName)] := 1
        }
    }

    if ProcessExist(WUTHERING_PROCESS_EXE)
        nameMap[StrLower(RegExReplace(WUTHERING_PROCESS_EXE, "i)\.exe$"))] := 1

    if IsSet(CFG_FILE) {
        cfgWuthering := NormalizePath(IniReadSafe(CFG_FILE, "paths", "WUTHERING", ""))
        if (cfgWuthering != "") {
            SplitPath cfgWuthering, &cfgExeName
            cfgExeName := RegExReplace(cfgExeName, "i)\.exe$")
            if (cfgExeName != "")
                nameMap[StrLower(cfgExeName)] := 1
        }
    }

    pidCsv := ""
    for pidText, _ in pidMap {
        if (pidCsv != "")
            pidCsv .= ","
        pidCsv .= pidText
    }

    nameCsv := ""
    for exeName, _ in nameMap {
        if (nameCsv != "")
            nameCsv .= ","
        nameCsv .= exeName
    }

    return { pids: pidCsv, names: nameCsv }
}

TrySetWutheringProcessMute(mute := true) {
    global WUTHERING_PROCESS_EXE, __WUTHERING_AUDIO_MUTED

    psFile := A_Temp "\\mute_wuthering_" A_TickCount ".ps1"
    targets := GetWutheringAudioTargets()
    pidCsv := StrReplace(targets.pids, "'", "''")
    nameCsv := StrReplace(targets.names, "'", "''")

        csharp := "
    (
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace AudioUtil {
    enum EDataFlow { eRender, eCapture, eAll }
    enum ERole { eConsole, eMultimedia, eCommunications }
    [Flags] enum CLSCTX : uint { INPROC_SERVER = 0x1, INPROC_HANDLER = 0x2, LOCAL_SERVER = 0x4, REMOTE_SERVER = 0x10, ALL = INPROC_SERVER | INPROC_HANDLER | LOCAL_SERVER | REMOTE_SERVER }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject {}
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")] interface IMMDeviceEnumerator { int NotImpl1(); int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppDevice); }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")] interface IMMDevice { int Activate(ref Guid iid, CLSCTX dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface); }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F")] interface IAudioSessionManager2 {
        int GetAudioSessionControl(ref Guid AudioSessionGuid, uint StreamFlags, out IAudioSessionControl SessionControl);
        int GetSimpleAudioVolume(ref Guid AudioSessionGuid, uint StreamFlags, out ISimpleAudioVolume AudioVolume);
        int GetSessionEnumerator(out IAudioSessionEnumerator SessionEnum);
        int RegisterSessionNotification(IntPtr SessionNotification);
        int UnregisterSessionNotification(IntPtr SessionNotification);
    }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8")] interface IAudioSessionEnumerator { int GetCount(out int SessionCount); int GetSession(int SessionCount, out IAudioSessionControl Session); }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD")] interface IAudioSessionControl {
        int GetState(out int pRetVal);
        int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetGroupingParam(out Guid pRetVal);
        int SetGroupingParam(ref Guid Override, ref Guid EventContext);
        int RegisterAudioSessionNotification(IntPtr NewNotifications);
        int UnregisterAudioSessionNotification(IntPtr NewNotifications);
    }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d")] interface IAudioSessionControl2 {
        int GetState(out int pRetVal);
        int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetGroupingParam(out Guid pRetVal);
        int SetGroupingParam(ref Guid Override, ref Guid EventContext);
        int RegisterAudioSessionNotification(IntPtr NewNotifications);
        int UnregisterAudioSessionNotification(IntPtr NewNotifications);
        int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int GetProcessId(out uint pRetVal);
        int IsSystemSoundsSession();
        int SetDuckingPreference(bool optOut);
    }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8")] interface ISimpleAudioVolume { int SetMasterVolume(float fLevel, ref Guid EventContext); int GetMasterVolume(out float pfLevel); int SetMute(bool bMute, ref Guid EventContext); int GetMute(out bool pbMute); }
    public static class SessionMute {
        static bool TryGetSessionManager(IMMDeviceEnumerator deviceEnumerator, ERole role, out IAudioSessionManager2 mgr) {
            mgr = null;
            IMMDevice device;
            int hr = deviceEnumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, role, out device);
            if (hr != 0 || device == null) return false;

            Guid iid = typeof(IAudioSessionManager2).GUID;
            object o;
            hr = device.Activate(ref iid, CLSCTX.ALL, IntPtr.Zero, out o);
            if (hr != 0 || o == null) return false;

            mgr = (IAudioSessionManager2)o;
            return mgr != null;
        }

        static bool IsTargetSession(IAudioSessionControl ctrl, System.Collections.Generic.HashSet<int> pidSet, System.Collections.Generic.HashSet<string> nameSet, out uint pidOut) {
            pidOut = 0;
            if (ctrl == null) return false;

            IntPtr unk = IntPtr.Zero;
            try {
                unk = Marshal.GetIUnknownForObject(ctrl);
                var c2 = (IAudioSessionControl2)Marshal.GetTypedObjectForIUnknown(unk, typeof(IAudioSessionControl2));
                if (c2 == null) return false;

                uint pid;
                if (c2.GetProcessId(out pid) != 0 || pid == 0) return false;
                pidOut = pid;

                if (pidSet.Contains((int)pid)) return true;

                try {
                    var p = Process.GetProcessById((int)pid);
                    var procName = p.ProcessName;
                    if (!string.IsNullOrWhiteSpace(procName) && nameSet.Contains(procName))
                        return true;
                } catch { }

                return false;
            } catch {
                return false;
            } finally {
                if (unk != IntPtr.Zero)
                    Marshal.Release(unk);
            }
        }

        static bool TrySetMuteOnControl(IAudioSessionControl ctrl, bool mute) {
            if (ctrl == null) return false;
            IntPtr unk = IntPtr.Zero;
            try {
                unk = Marshal.GetIUnknownForObject(ctrl);
                var vol = (ISimpleAudioVolume)Marshal.GetTypedObjectForIUnknown(unk, typeof(ISimpleAudioVolume));
                if (vol == null) return false;
                Guid g = Guid.Empty;
                vol.SetMute(mute, ref g);
                return true;
            } catch {
                return false;
            } finally {
                if (unk != IntPtr.Zero)
                    Marshal.Release(unk);
            }
        }

        static bool TryMuteOnRole(IMMDeviceEnumerator deviceEnumerator, ERole role, System.Collections.Generic.HashSet<int> pidSet, System.Collections.Generic.HashSet<string> nameSet, bool mute) {
            IAudioSessionManager2 mgr;
            if (!TryGetSessionManager(deviceEnumerator, role, out mgr))
                return false;

            IAudioSessionEnumerator en;
            if (mgr.GetSessionEnumerator(out en) != 0 || en == null)
                return false;

            int count;
            en.GetCount(out count);
            bool mutedAny = false;

            for (int i = 0; i < count; i++) {
                IAudioSessionControl ctrl;
                if (en.GetSession(i, out ctrl) != 0 || ctrl == null)
                    continue;

                uint pid;
                if (!IsTargetSession(ctrl, pidSet, nameSet, out pid))
                    continue;

                if (TrySetMuteOnControl(ctrl, mute))
                    mutedAny = true;
            }

            return mutedAny;
        }

        public static int SetMuteByTargets(string pidCsv, string nameCsv, bool mute) {
            var pidSet = new System.Collections.Generic.HashSet<int>();
            if (!string.IsNullOrWhiteSpace(pidCsv)) {
                foreach (var s in pidCsv.Split(',')) {
                    int p;
                    if (int.TryParse(s.Trim(), out p) && p > 0)
                        pidSet.Add(p);
                }
            }

            var nameSet = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (!string.IsNullOrWhiteSpace(nameCsv)) {
                foreach (var s in nameCsv.Split(',')) {
                    var n = s.Trim();
                    if (!string.IsNullOrWhiteSpace(n))
                        nameSet.Add(n);
                }
            }

            var deviceEnumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            bool ok = false;

            ok = TryMuteOnRole(deviceEnumerator, ERole.eMultimedia, pidSet, nameSet, mute) || ok;
            ok = TryMuteOnRole(deviceEnumerator, ERole.eConsole, pidSet, nameSet, mute) || ok;
            ok = TryMuteOnRole(deviceEnumerator, ERole.eCommunications, pidSet, nameSet, mute) || ok;

            return ok ? 0 : 2;
        }
    }
}
)"

        script := "$ErrorActionPreference='Stop'`n"
        script .= "$pids='" pidCsv "'`n"
        script .= "$names='" nameCsv "'`n"
        script .= "$mute=" (mute ? "$true" : "$false") "`n"
        script .= "$code=@'`n" csharp "`n'@`n"
        script .= "Add-Type -TypeDefinition $code -Language CSharp | Out-Null`n"
        script .= "$ret = [AudioUtil.SessionMute]::SetMuteByTargets($pids, $names, $mute)`n"
        script .= "exit $ret`n"

    try FileDelete psFile
    FileAppend script, psFile, "UTF-8"

    cmd := 'powershell -NoProfile -ExecutionPolicy Bypass -File "' psFile '"'
    try {
        code := RunWait(cmd, , "Hide") + 0
    } catch {
        try FileDelete psFile
        WriteLog("鳴潮音訊控制執行失敗（PowerShell 呼叫錯誤）", "WARN")
        return false
    }

    try FileDelete psFile
    if (code = 0) {
        __WUTHERING_AUDIO_MUTED := mute ? true : false
        return true
    }

    WriteLog("鳴潮音訊控制未命中任何 Session，退出碼=" code " pids=" targets.pids " names=" targets.names, "WARN")
    return false
}

; 日誌函數（使用新的日誌系統）
WriteLog(msg, level := "INFO") {
    global logger, RUN_ID, REMOTE_CONTROL_ACTIVE
    if IsSet(logger) && IsObject(logger) {
        logger.log("[" RUN_ID "] " msg, level)
    } else {
        ; 備用方案
        ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        line := ts " [" level "] [" RUN_ID "] " msg "`r`n"
        try FileAppend(line, A_ScriptDir "\main_fallback.log", "UTF-8")
    }

    normalizedLevel := StrUpper(Trim(level, " `t`r`n"))
    if (normalizedLevel = "WARN" || normalizedLevel = "ERROR") {
        ; RemoteControl 自己的 HTTP 錯誤不可再次觸發遠端事件，避免失敗遞迴。
        isRemoteInternal := InStr(msg, "[RemoteControl]") ? true : false
        if (REMOTE_CONTROL_ACTIVE && !isRemoteInternal)
            try RC_RecordRuntimeEvent(normalizedLevel = "ERROR" ? "錯誤" : "警告", msg, normalizedLevel)
        if !isRemoteInternal
            try ScheduleRuntimeErrorSnapshot(msg, normalizedLevel)
    }
}

WriteStep(stepName, detail := "", level := "INFO") {
    global STEP_SEQ, CURRENT_STEP_NAME, CURRENT_STEP_DETAIL, CURRENT_STEP_LEVEL, REMOTE_CONTROL_ACTIVE
    STEP_SEQ += 1
    stepId := Format("{:03}", STEP_SEQ)
    CURRENT_STEP_NAME := stepName
    CURRENT_STEP_DETAIL := detail
    CURRENT_STEP_LEVEL := level
    if (REMOTE_CONTROL_ACTIVE)
        try RC_RecordRuntimeEvent(stepName, detail, level)
    msg := "[STEP " stepId "] " stepName
    if (detail != "")
        msg .= " | " detail
    WriteLog(msg, level)
    tip := "📌 STEP " stepId "｜" stepName
    if (detail != "")
        tip .= "`nℹ " detail
    ShowTip(tip)
    if (REMOTE_CONTROL_ACTIVE)
        RC_ReportRuntimeState()
}

WriteStepResult(stepName, ok, detail := "") {
    level := ok ? "INFO" : "WARN"
    status := ok ? "成功" : "失敗"
    WriteStep(stepName, status (detail != "" ? " | " detail : ""), level)
}

WriteLog("全自動腳本啟動: " A_ScriptFullPath)
WriteStep("啟動", "PID=" DllCall("GetCurrentProcessId") " AHK=" A_AhkVersion)

; 鍵盤更穩
SendMode "Input"
SetKeyDelay 40, 40



; === 使用啟動器解壓的位置 ===
; 現在 AutoHotkey64.exe 位於工作目錄的上層（自動鋤地資料夾）
AhkExe := BUNDLED_AHK_EXE
WriteLog("嘗試使用 AutoHotkey: " AhkExe)
if !FileExist(AhkExe) {
    WriteLog("找不到任何 AutoHotkey 執行檔: " AhkExe, "ERROR")
    MsgBox "找不到 AutoHotkey64.exe：`n" AhkExe "`n請先執行「打包啟動器」完成解壓。"
    ExitApp
}
WriteLog("成功找到 AutoHotkey: " AhkExe)

okwwExe := "OK-WW.exe"   ; 由工作管理員確認

; ===== 路徑處理（優先使用打包啟動器設定的環境變數）=====
dataDir := EnvGet("PACK_DATA_DIR")
if (dataDir = "") {
    ; 如果沒有環境變數，嘗試使用新的位置
    dataDir := A_ScriptDir "\..\config"
    if !DirExist(dataDir) {
        ; 向後兼容舊位置
        dataDir := A_Temp "\okww_runtime\config"
    }
}
DirCreate dataDir
RepairPendingLauncherUpdateFromPayload(dataDir)
global CFG_FILE := dataDir "\config.ini"
WriteLog("dataDir=" dataDir)
WriteLog("CFG_FILE=" CFG_FILE)
WriteStep("載入設定", "config=" CFG_FILE)
LoadMailNotifyEnabled()
LoadScreenRecordingEnabled()
LoadRuntimeDiagnosticsSettings()
WriteLog("OCR 模型設定=" RapidOcr.DescribeDefaultModels())
REMOTE_CONTROL_ACTIVE := RC_Init(CFG_FILE, "OnRemoteControlStateChanged")
if REMOTE_CONTROL_ACTIVE
    WriteLog("遠端控制：已啟用")
else
    WriteLog("遠端控制：未啟用")
SetupTrayMenu()

; ★ 流程開始前統一檢查：程式路徑 + 郵件通知設定
WriteStep("前置檢查", "程式路徑與通知設定")
EnsureAllConfigAtStartup()
LoadRuntimeDiagnosticsSettings()
StartRuntimeDiagnostics()
RecoverPendingRecordingSessions()

; ★ 啟動前檢測：確保三個程式都沒有在運行
WriteLog("執行啟動前檢測，確保所有目標程式都已關閉...")
WriteStep("清場", "關閉既有目標進程")
CheckAndCloseExistingProcesses()

; 讀取重啟計數器（避免無限循環）
global MAX_RESTART_COUNT := 10
global restartCount := Integer(IniReadSafe(CFG_FILE, "restart_tracking", "auto_restart_count", "0"))
WriteLog("目前重啟次數: " restartCount "/" MAX_RESTART_COUNT)

; 檢查是否為重啟模式（遊戲更新後需要重新啟動OKWW）
isRestart := false
isNextServerCycle := false
global CRASH_RESTART_MODE := false
if A_Args.Length > 0 && A_Args[1] = "restart" {
    isRestart := true
    WriteLog("檢測到重啟模式，遊戲更新後將重新啟動OKWW")
    prevReason := Trim(IniReadSafe(CFG_FILE, "restart_tracking", "last_restart_reason", ""), " `t`r`n")
    prevTime := Trim(IniReadSafe(CFG_FILE, "restart_tracking", "last_restart_time", ""), " `t`r`n")
    prevCode := Trim(IniReadSafe(CFG_FILE, "restart_tracking", "last_restart_code", "UNSPECIFIED"), " `t`r`n")
    prevStage := Trim(IniReadSafe(CFG_FILE, "restart_tracking", "last_restart_stage", "未指定"), " `t`r`n")
    prevRecovery := Trim(IniReadSafe(CFG_FILE, "restart_tracking", "last_restart_recovery", ""), " `t`r`n")
    if (prevReason != "") {
        detail := "code=" prevCode " | stage=" prevStage " | reason=" prevReason
        if (prevRecovery != "")
            detail .= " | recovery=" prevRecovery
        if (prevTime != "")
            detail .= " @ " prevTime
        WriteStep("上次重啟原因", detail, "WARN")
    }
}

if A_Args.Length > 1 && A_Args[1] = "restart" && (A_Args[2] = "resume" || A_Args[2] = "crash") {
    CRASH_RESTART_MODE := true
    WriteLog("檢測到 LRMCAI 接續模式，LRMCAI 將略過 OCR『副本』並使用快捷鍵啟動；參數=" A_Args[2])
}

isNextServerCycle := false
if A_Args.Length > 0 && A_Args[1] = "nextserver" {
    isNextServerCycle := true
    WriteLog("檢測到伺服器排程續跑模式，將沿用下一個伺服器索引")
}

if (!isRestart && !isNextServerCycle)
    ResetRestartTrackingOnFreshStart()

; ★ 設定檔與重啟狀態就緒後才啟動 UE4 崩潰監看。
;    崩潰事件指紋需要寫入 CFG_FILE，避免同一個已消失/幽靈視窗跨腳本重複觸發。
StartCrashWatcher()

LoadServerScheduleContext(isNextServerCycle)

if MAIL_NOTIFY_ENABLED {
    startMailResult := SendStartNotifyMail(isRestart)
    if startMailResult.ok
        WriteLog("開始通知信已寄出")
    else
        WriteLog("開始通知信寄送失敗: " startMailResult.message, "WARN")
}

; 1) 先處理鳴潮更新／登入，OKWW 之後再啟動
maxUpdateLoops := 3
updateLoops := 0
loginDetected := false
okwwStarted := false
updateRecoveryActive := false
updateRecoveryStartTick := 0
noWindowLoopCount := 0
noWindowSinceTick := 0

if !isRestart
    TryStartScreenRecording("主流程開始")
else {
    AttachManagedScreenRecordingOnRestart("重啟模式接管")
    WriteLog("重啟模式：保留既有錄影，不重新觸發錄影啟動")
}
EnsureWutheringRunning()
WriteStep("鳴潮檢查", "更新與登入流程")

loop {
    loginDetected := false
    TryAssistLoginTemplateBeforeOcr()
    detectState := DetectWutheringAndExit(&loginDetected)
    if (detectState = "update") {
        updateLoops++
        WriteLog("偵測到鳴潮更新，等待遊戲自動重啟後再次檢測 (" updateLoops "/" maxUpdateLoops ")")

        ; 啟用更新後恢復追蹤：若後續長時間 no_window，就主動重跑啟動流程。
        updateRecoveryActive := true
        updateRecoveryStartTick := A_TickCount
        Sleep 8000

        if (updateLoops >= maxUpdateLoops) {
            WriteLog("鳴潮更新檢測達上限，停止自動迴圈，繼續後續流程", "WARN")
            break
        }
        continue
    }

    if (detectState = "no_window") {
        noWindowLoopCount += 1
        if (noWindowSinceTick = 0)
            noWindowSinceTick := A_TickCount

        if (updateRecoveryActive) {
            elapsedSec := Floor((A_TickCount - updateRecoveryStartTick) / 1000)
            if (elapsedSec >= WUTHERING_UPDATE_RECOVERY_WAIT_SEC) {
                WriteLog("更新後等待 " WUTHERING_UPDATE_RECOVERY_WAIT_SEC " 秒仍抓不到鳴潮視窗，執行完整重啟流程", "ERROR")
                ShowTip("⚠️ 更新後超時未啟動，完整重啟流程", 2200)
                RequestRestart(
                    "遊戲更新確認完成後等待 " WUTHERING_UPDATE_RECOVERY_WAIT_SEC " 秒，仍找不到鳴潮遊戲視窗",
                    "ERROR", CRASH_RESTART_MODE, "GAME_UPDATE_RECOVERY_TIMEOUT", "遊戲更新後恢復")
                return
            }
            WriteLog("更新後恢復等待中（" elapsedSec "/" WUTHERING_UPDATE_RECOVERY_WAIT_SEC " 秒），暫不重啟", "WARN")
        }

        elapsedNoWindowSec := Floor((A_TickCount - noWindowSinceTick) / 1000)
        ; 更新恢復有獨立的 300 秒門檻；不能再被一般 no_window 的 180 秒門檻提前截斷。
        if (!updateRecoveryActive && elapsedNoWindowSec >= WUTHERING_NO_WINDOW_RESTART_SEC) {
            WriteLog("鳴潮長時間 no_window（" elapsedNoWindowSec " 秒），判定當機/閃退，執行完整重啟", "ERROR")
            ShowTip("❌ 鳴潮長時間無視窗，完整重啟流程", 2200)
            RequestRestart(
                "連續 " elapsedNoWindowSec " 秒找不到鳴潮遊戲視窗；no_window 次數=" noWindowLoopCount,
                "ERROR", CRASH_RESTART_MODE, "GAME_STARTUP_NO_WINDOW_TIMEOUT", "遊戲啟動／登入")
            return
        }

        WriteLog("鳴潮視窗尚未就緒（no_window），等待後重試（連續=" noWindowLoopCount "，累計=" elapsedNoWindowSec " 秒）", "WARN")
        Sleep 3000
        continue
    }

    noWindowLoopCount := 0
    noWindowSinceTick := 0

    if (detectState = "unknown") {
        WriteLog("鳴潮狀態尚未明確（unknown），不提前判定登入", "WARN")
    }

    updateRecoveryActive := false
    break
}

; 登入畫面時：先做伺服器切換（如有設定），再交由 OKWW 接手點擊流程
serverSwitchOk := true
if (loginDetected) {
    hwndLogin := GetWutheringGameHwnd()
    if !hwndLogin {
        hwndLogin := WaitForWutheringGameWindow(20)
    }

    ; 先切換伺服器，再啟動 OKWW。
    if hwndLogin {
        serverSwitchOk := TrySelectScheduledServer(hwndLogin)
        if !serverSwitchOk
            WriteLog("伺服器切換未完成，將停止本輪避免誤進錯服", "WARN")
    } else {
        serverSwitchOk := false
        WriteLog("伺服器切換未完成：找不到鳴潮登入視窗", "WARN")
    }

    if !serverSwitchOk {
        WriteLog("伺服器切換失敗（重試後仍未成功），改由 OKWW 繼續後續流程", "WARN")
        ShowTip("⚠️ 切服失敗，交由 OKWW 繼續", 1200)
    }

    WriteLog("登入畫面階段啟動 OKWW，後續點擊改由 OKWW 接手")
    ClickTemplateIfFound(A_ScriptDir "\0510.png")
    ClickTemplateIfFound(A_ScriptDir "\登入.png")
    okwwResult := StartOKWWFlowWithLocalRecovery(isRestart, "登入畫面階段")
    okwwStarted := okwwResult.ok
    if !okwwStarted {
        WriteLog("登入畫面 OKWW 接管失敗：" okwwResult.reason
            "，停止本輪避免誤報遊戲主畫面超時", "ERROR")
        RequestRestart(
            okwwResult.reason,
            "ERROR", CRASH_RESTART_MODE, okwwResult.code, okwwResult.stage)
        return
    }
    WriteLog("檢測到登入畫面後不再由全自動點擊遊戲視窗，等待 OKWW 執行")
    Sleep 3000
}

; 2) 登入後啟動 OKWW 並確認啟動成功
if !okwwStarted {
    WriteLog("遊戲可操作驗證通過前，不提前宣告登入完成")
}

; 3) 用主畫面模板比對驗證遊戲是否可操作（去抖動）
gameHwnd := GetWutheringGameHwnd()
WriteLog("開始主畫面模板驗證（最多 90 秒）...")
if !WaitEscMenuOCR(gameHwnd, 90) {
    WriteLog("鳴潮無法使用或超時，觸發重啟機制", "ERROR")
    ShowTip("⚠️ 鳴潮無法使用，重新啟動...", 3000)
    Sleep 3000
    RequestRestart(
        "鳴潮視窗存在，但主畫面／可操作模板在 90 秒內未通過驗證",
        "ERROR", CRASH_RESTART_MODE, "GAME_READY_CHECK_TIMEOUT", "遊戲可操作驗證")
    return
}
WriteStep("遊戲可操作驗證", "模板比對通過")

; 4) 只有在可操作驗證通過後，才啟動 OKWW（避免過早啟動）
if !okwwStarted {
    WriteLog("遊戲已可操作，開始啟動 OKWW...")
    WriteStep("啟動OKWW", isRestart ? "重啟模式" : "一般模式")
    ClickTemplateIfFound(A_ScriptDir "\0510.png")
    ClickTemplateIfFound(A_ScriptDir "\登入.png")
    okwwResult := StartOKWWFlowWithLocalRecovery(isRestart, "遊戲可操作後")
    okwwStarted := okwwResult.ok
    if !okwwStarted {
        WriteLog("遊戲可操作後啟動 OKWW 失敗：" okwwResult.reason
            "，停止後續聲骸／LRMCAI 流程", "ERROR")
        RequestRestart(
            okwwResult.reason,
            "ERROR", CRASH_RESTART_MODE, okwwResult.code, okwwResult.stage)
        return
    }
}

; 5) 執行聲骸合成流程
WriteLog("啟動聲骸合成腳本...")
WriteStep("啟動聲骸合成", "等待完成或重啟標記")
ShowTip("🔧 正在執行聲骸合成...", 1500)
; 額外等待確保OKWW啟動後鳴潮完全穩定
WriteLog("等待OKWW初始化完成，確保遊戲穩定...")
Sleep 20000  ; 再等20秒，確保鳴潮完全穩定
try {
    Run('"' AhkExe '" "' A_ScriptDir '\聲骸合成.ahk"')
    WriteLog("聲骸合成腳本已啟動")
    
    ; 等待聲骸合成完成（檢查進程是否還在運行）
    maxWaitTime := 1800000  ; 最多等待30分鐘
    startTime := A_TickCount
    
    Sleep 5000  ; 先等5秒讓腳本啟動
    
    ; 持續檢查聲骸合成進程是否還在運行
    while (A_TickCount - startTime < maxWaitTime) {
        found := false
        try {
            for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process") {
                try {
                    if (InStr(proc.Name, "AutoHotkey")) {
                        cmdLine := proc.CommandLine
                        if (InStr(cmdLine, "聲骸合成.ahk")) {
                            found := true
                            break
                        }
                    }
                } catch {
                    continue
                }
            }
        } catch as e {
            WriteLog("檢查聲骸合成進程時出錯: " e.Message, "WARN")
        }
        
        if (!found) {
            WriteLog("聲骸合成已完成")
            ShowTip("✅ 聲骸合成已完成", 2000)
            
            ; 檢查是否有重啟標記
            flagFile := dataDir "\synthesis_restart.flag"
            if FileExist(flagFile) {
                WriteLog("偵測到聲骸合成要求重啟，刪除標記並觸發重啟機制", "WARN")
                flagReason := ""
                try flagReason := Trim(FileRead(flagFile, "UTF-8"), " `t`r`n")
                try FileDelete(flagFile)
                Sleep 2000
                detail := "聲骸合成回報重啟旗標 synthesis_restart.flag"
                if (flagReason != "")
                    detail .= "；旗標內容=" flagReason
                RequestRestart(detail, "WARN", CRASH_RESTART_MODE, "SYNTHESIS_RESTART_FLAG", "聲骸合成")
                return
            }
            break
        }

        Sleep 2000  ; 每2秒檢查一次
    }
    
    if (A_TickCount - startTime >= maxWaitTime) {
        WriteLog("聲骸合成超時，觸發重啟機制", "ERROR")
        ShowTip("⚠️ 聲骸合成超時，重新啟動...", 3000)
        Sleep 3000
        RequestRestart(
            "聲骸合成子腳本等待超過 " Round(maxWaitTime / 1000) " 秒仍未完成",
            "ERROR", CRASH_RESTART_MODE, "SYNTHESIS_TIMEOUT", "聲骸合成")
        return
    }
    
} catch as e {
    WriteLog("聲骸合成腳本啟動失敗，跳過並繼續後續流程: " e.Message, "ERROR")
    ShowTip("⚠️ 聲骸合成啟動失敗，繼續執行...", 2000)
    Sleep 2000
}

; 4) 啟動 LRMC 管理腳本（由該腳本負責LRMC的啟動與管理）
WriteLog("啟動 LRMC 管理腳本...")
WriteStep("啟動LRMC", "交由開啟LRMC.ahk 控制")
lrmcCmd := '"' AhkExe '" "' A_ScriptDir '\開啟LRMC.ahk"'
if (CRASH_RESTART_MODE)
    lrmcCmd .= ' resume'
Run(lrmcCmd)
ShowTip("🟢 已啟動 LRMC 管理腳本", 3000)


; 成功完成流程，重置重啟計數器
IniWrite "0", CFG_FILE, "restart_tracking", "auto_restart_count"
WriteLog("流程成功完成，已重置重啟計數器")
WriteStep("主流程完成", "重啟計數已歸零")

WriteLog("全自動流程完成，進入收尾監測（等待電台一鍵領取達標）")
WriteStep("收尾監測", "等待電台一鍵領取條件")
MonitorRewardAndShutdown()
ExitApp


; ======================== 函式區 ========================

; OKWW 自動戰鬥 OCR 在同一個最終視窗內檢查兩次。
; 兩次仍無法確認時直接對該視窗送 F11，不再局部重啟 OKWW，避免重複開出多個視窗。
StartOKWWFlowWithLocalRecovery(isRestart, entryStage := "") {
    firstResult := StartOKWWFlow(isRestart)
    if !IsOkwwAutoBattleCheckFailure(firstResult)
        return firstResult

    stageText := entryStage != "" ? entryStage : "未指定入口"
    fallbackHwnd := firstResult.HasOwnProp("okwwHwnd") ? firstResult.okwwHwnd : 0
    WriteLog("OKWW 自動戰鬥同一視窗連續兩次 OCR 未能確認；不重啟 OKWW，直接送 F11"
        " | hwnd=" fallbackHwnd " | entry=" stageText, "WARN")
    WriteStep("OKWW OCR降級", "兩次未確認，沿用同一最終視窗送 F11 | entry=" stageText, "WARN")

    fallbackSent := false
    if fallbackHwnd {
        topmostCtx := PrepareOkwwTopmostOperation(fallbackHwnd)
        try fallbackSent := SendF11ToOkww(fallbackHwnd)
        finally RestoreTopmostAfterOkwwOperation(topmostCtx)
    }

    if fallbackSent {
        WriteLog("OCR 降級 F11 已送出，等待 2 秒後開始 OKWW 最小化掃描", "WARN")
        Sleep 2000
        ScheduleOkwwMinimizeSweeps("OCR降級F11")
        WriteStepResult("OKWW流程", true, "同一視窗兩次 OCR 未確認；已直接送 F11 並排程最小化")
        return {
            ok: true,
            code: "",
            stage: "OKWW完成（OCR降級）",
            reason: ""
        }
    }

    WriteLog("同一 OKWW 視窗兩次 OCR 未確認後，直接 F11 亦發送失敗；交由原 RequestRestart", "ERROR")
    return {
        ok: false,
        code: "OKWW_F11_SEND_FAILED",
        stage: "OKWW快捷鍵發送（OCR降級）",
        reason: Format("OKWW 同一最終視窗連續兩次無法由 OCR 確認自動戰鬥；直接發送 F11 亦失敗；hwnd={1}；entry={2}", fallbackHwnd, stageText)
    }
}

IsOkwwAutoBattleCheckFailure(result) {
    return IsObject(result) && result.HasOwnProp("ok") && !result.ok
        && result.HasOwnProp("code") && result.code = "OKWW_AUTOBATTLE_CHECK_FAILED"
}

; ★ OKWW 啟動＋前置流程（啟動 → 等待最終主視窗 → F11 → 最小化）
StartOKWWFlow(isRestart) {
    WriteStep("OKWW流程", "入口 isRestart=" (isRestart ? "1" : "0"))
    WriteLog("啟動 OKWW 管理腳本...")
    managerLaunchError := ""
    if isRestart {
        ShowTip("🔄 重啟模式：重新啟動 OKWW", 1500)
        Sleep 1500
    }
    ahkCommand := '"' AhkExe '" "' A_ScriptDir '\自動開啟OKWW.ahk"'
    WriteLog("執行命令: " ahkCommand)
    try {
        Run(ahkCommand)
        WriteLog("OKWW 管理腳本啟動成功" . (isRestart ? "（重啟模式）" : ""))
    } catch as e {
        managerLaunchError := e.Message
        WriteLog("OKWW 管理腳本啟動失敗: " e.Message, "ERROR")
    }
    ShowTip("🟢 已啟動 OKWW 管理腳本" . (isRestart ? "（重新啟動）" : ""), 3000)

    ; 等待最終 pythonw 主視窗穩定出現，避免誤把 ok-ww.exe 的啟動／升級視窗當成目標。
    WriteLog("等待 OKWW 最終主視窗開啟，完成後直接發送 F11...")
    okwwHwnd := 0
    stableHwnd := 0
    stableHits := 0
    maxAttempts := 90
    attempt := 0
    currentPID := DllCall("GetCurrentProcessId")
    
    while (attempt < maxAttempts && !okwwHwnd) {
        attempt++
        candidateHwnd := 0
        candidateTitle := ""
        try {
            ; 最終主視窗格式相容：
            ;   OK-WW v版本數字 Global
            ;   OK-WW v版本數字 Global ... - OK-WW
            for hwnd in WinGetList() {
                pid := 0
                procName := ""
                wclass := ""
                title := WinGetTitle(hwnd)
                try pid := WinGetPID(hwnd)
                try procName := StrLower(WinGetProcessName(hwnd))
                try wclass := StrLower(WinGetClass(hwnd))

                ; 排除當前腳本自身視窗與 Tooltip，避免誤判。
                if (pid = currentPID || wclass = "tooltips_class32")
                    continue

                ; v3.x 最終操作視窗由 pythonw.exe 承載；拒絕前置 ok-ww.exe 視窗。
                if (procName != "pythonw.exe")
                    continue

                if RegExMatch(title, "i)^OK-WW\s+v[\d.]+\s+Global(?:\s*-\s*OK-WW)?\s*$") {
                    candidateHwnd := hwnd
                    candidateTitle := title
                    break
                }
            }
        }

        if candidateHwnd {
            if (candidateHwnd = stableHwnd) {
                stableHits += 1
            } else {
                stableHwnd := candidateHwnd
                stableHits := 1
            }

            WriteLog("找到 OKWW 最終主視窗，穩定確認 " stableHits "/2: hwnd="
                candidateHwnd " title=" candidateTitle)
            if (stableHits >= 2) {
                okwwHwnd := candidateHwnd
                break
            }
        } else {
            stableHwnd := 0
            stableHits := 0
        }

        if (!okwwHwnd) {
            if Mod(attempt, 5) = 0
                WriteLog("等待 OKWW 最終主視窗中：attempt=" attempt "/" maxAttempts)
            Sleep 1000
        }
    }
    
    f11Sent := false
    autoBattleConfirmed := false
    if (okwwHwnd) {
        topmostCtx := PrepareOkwwTopmostOperation(okwwHwnd)
        try {
            Loop 2 {
                checkAttempt := A_Index
                WriteLog("OKWW 自動戰鬥前置確認：attempt=" checkAttempt "/2")
                if EnsureOkwwAutoBattleEnabled(okwwHwnd) {
                    autoBattleConfirmed := true
                    f11Sent := SendF11ToOkww(okwwHwnd)
                    break
                }

                if (checkAttempt < 2) {
                    WriteLog("OKWW 自動戰鬥本次未能確認，等待後重試；尚未發送 F11", "WARN")
                    Sleep 1200
                }
            }

            if !f11Sent
                WriteLog("OKWW 自動戰鬥連續 2 次未能確認，或 F11 發送失敗；交由同視窗 F11 降級處理", "WARN")
        } finally {
            RestoreTopmostAfterOkwwOperation(topmostCtx)
        }
    } else {
        WriteLog("等待 " maxAttempts " 秒仍找不到 OKWW 最終主視窗，未發送 F11", "ERROR")
    }
    
    if f11Sent {
        WriteLog("F11 已送出，等待 2 秒後最小化 OKWW")
        Sleep 2000
        ScheduleOkwwMinimizeSweeps("自動戰鬥確認後F11")
    } else {
        WriteLog("F11 未成功送出，保留 OKWW 視窗供診斷，不執行最小化", "WARN")
    }
    WriteStepResult("OKWW流程", f11Sent,
        f11Sent ? "自動戰鬥已啟用、F11 已送出並完成最小化" : "前置確認或 F11 失敗")
    if f11Sent {
        return {
            ok: true,
            code: "",
            stage: "OKWW完成",
            reason: ""
        }
    }

    if !okwwHwnd {
        if (managerLaunchError != "") {
            return {
                ok: false,
                code: "OKWW_MANAGER_LAUNCH_FAILED",
                stage: "OKWW管理腳本啟動",
                reason: "OKWW 管理腳本啟動失敗，且 " maxAttempts " 秒內未找到最終主視窗：" . managerLaunchError
            }
        }
        return {
            ok: false,
            code: "OKWW_FINAL_WINDOW_TIMEOUT",
            stage: "等待OKWW最終主視窗",
            reason: "OKWW 管理腳本已送出，但 " maxAttempts " 秒內未找到穩定的 pythonw 最終主視窗"
        }
    }

    if !autoBattleConfirmed {
        return {
            ok: false,
            code: "OKWW_AUTOBATTLE_CHECK_FAILED",
            stage: "OKWW自動戰鬥確認",
            reason: "已找到 OKWW 最終主視窗，但同一視窗連續 2 次無法確認自動戰鬥為已啟用",
            okwwHwnd: okwwHwnd
        }
    }

    return {
        ok: false,
        code: "OKWW_F11_SEND_FAILED",
        stage: "OKWW快捷鍵發送",
        reason: "OKWW 自動戰鬥已確認啟用，但 F11 未能成功發送到最終主視窗"
    }
}

EnsureOkwwAutoBattleEnabled(okwwHwnd) {
    if !okwwHwnd || !WinExist("ahk_id " okwwHwnd) {
        WriteLog("OKWW 自動戰鬥檢查失敗：目標視窗已失效 | hwnd=" okwwHwnd, "ERROR")
        return false
    }

    try {
        WinRestore("ahk_id " okwwHwnd)
        WinActivate("ahk_id " okwwHwnd)
        if !WinWaitActive("ahk_id " okwwHwnd, , 3) {
            WriteLog("OKWW 自動戰鬥檢查失敗：無法切到前景 | hwnd=" okwwHwnd, "ERROR")
            return false
        }

        clientW := 0
        clientH := 0
        WinGetClientPos(, , &clientW, &clientH, "ahk_id " okwwHwnd)

        dpi := 96
        try dpi := DllCall("user32\GetDpiForWindow", "ptr", okwwHwnd, "uint")
        scale := dpi > 0 ? dpi / 96.0 : 1.0

        minW := Round(700 * scale)
        minH := Round(400 * scale)
        if (clientW < minW || clientH < minH) {
            WriteLog("OKWW 自動戰鬥檢查失敗：視窗尺寸過小 | client="
                clientW "x" clientH " dpi=" dpi, "ERROR")
            return false
        }

        ocr := RapidOcr()
        navResult := CaptureOkwwOcr(okwwHwnd, ocr, "尋找實時／即時觸發")
        navMatch := FindOkwwRealtimeTriggerOcrBlock(navResult, scale)
        if !navMatch {
            navCandidates := SummarizeOkwwOcrBlocks(
                navResult, Round(320 * scale), 30)
            WriteLog("OKWW 自動戰鬥檢查失敗：OCR 找不到左側「實時／即時觸發」"
                "（含受限一字容錯）"
                " | 左側候選=" navCandidates, "ERROR")
            return false
        }

        if (navMatch.matchType = "bounded_fuzzy") {
            WriteLog("OKWW 左側導覽 OCR 受限容錯命中：raw=" navMatch.rawText
                " normalized=" navMatch.text
                " target=" navMatch.targetText
                " distance=" navMatch.distance
                " rectRight=" Round(navMatch.rect.right), "WARN")
        }

        navX := navMatch.rect.centerX
        navY := navMatch.rect.centerY
        toggleX := Round(clientW - 155 * scale)

        WriteLog("OKWW 自動戰鬥檢查：OCR 命中「" navMatch.text
            "」，前往實時觸發 | client="
            clientW "x" clientH " dpi=" dpi " nav=" navX "," navY
            " toggleX=" toggleX)

        if !ClickOkwwClientPoint(okwwHwnd, navX, navY) {
            WriteLog("OKWW 自動戰鬥檢查失敗：無法點擊實時觸發", "ERROR")
            return false
        }
        Sleep 1200

        stateInfo := ReadOkwwAutoBattleOcrState(okwwHwnd, ocr, scale)
        Sleep 300
        confirmInfo := ReadOkwwAutoBattleOcrState(okwwHwnd, ocr, scale)

        WriteLog("OKWW 自動戰鬥 OCR 初始判定：" confirmInfo.state
            " | label=" confirmInfo.labelText " status=" confirmInfo.statusText
            " rowY=" confirmInfo.rowY)

        if (stateInfo.state != confirmInfo.state) {
            WriteLog("OKWW 自動戰鬥 OCR 狀態不穩定，停止操作 | first="
                stateInfo.state " second=" confirmInfo.state, "ERROR")
            return false
        }

        if (confirmInfo.state = "enabled") {
            WriteLog("OKWW 自動戰鬥已啟用，無需切換")
            return true
        }

        if (confirmInfo.state != "disabled") {
            WriteLog("OKWW 自動戰鬥開關無法可靠辨識，未執行切換", "ERROR")
            return false
        }

        toggleY := confirmInfo.rowY
        if (toggleY <= 0 || toggleY >= clientH) {
            WriteLog("OKWW 自動戰鬥列座標異常，未執行切換 | rowY=" toggleY, "ERROR")
            return false
        }

        Loop 2 {
            WriteLog("OKWW 自動戰鬥目前未啟用，執行第 " A_Index " 次開啟操作")
            if !ClickOkwwClientPoint(okwwHwnd, toggleX, toggleY) {
                WriteLog("OKWW 自動戰鬥切換點擊失敗 | attempt=" A_Index, "ERROR")
                return false
            }
            Sleep 1000

            enabledInfo := ReadOkwwAutoBattleOcrState(okwwHwnd, ocr, scale)
            Sleep 300
            enabledConfirm := ReadOkwwAutoBattleOcrState(okwwHwnd, ocr, scale)

            WriteLog("OKWW 自動戰鬥切換後 OCR 判定：" enabledConfirm.state
                " | label=" enabledConfirm.labelText
                " status=" enabledConfirm.statusText
                " rowY=" enabledConfirm.rowY)

            if (enabledInfo.state = "enabled" && enabledConfirm.state = "enabled") {
                WriteLog("OKWW 自動戰鬥已成功開啟")
                return true
            }

            if (enabledInfo.state != "disabled" || enabledConfirm.state != "disabled") {
                WriteLog("OKWW 自動戰鬥切換後狀態不明，為避免重複切換而停止", "ERROR")
                return false
            }
        }

        WriteLog("OKWW 自動戰鬥重試後仍為未啟用", "ERROR")
        return false
    } catch as e {
        WriteLog("OKWW 自動戰鬥檢查失敗：hwnd=" okwwHwnd " | " e.Message, "ERROR")
        return false
    }
}

CaptureOkwwOcr(okwwHwnd, ocr, purpose := "") {
    tempFile := (A_Temp "\okww_state_" DllCall("GetCurrentProcessId")
        "_" A_TickCount ".png")
    try {
        ImagePutFile("ahk_id " okwwHwnd, tempFile)
        result := ocr.ocr_from_file(tempFile, , true)
        WriteLog("OKWW OCR 完成" (purpose != "" ? "（" purpose "）" : "")
            "：blocks=" (IsObject(result) ? result.Length : 0))
        return result
    } catch as e {
        WriteLog("OKWW OCR 失敗" (purpose != "" ? "（" purpose "）" : "")
            "：" e.Message, "ERROR")
        return []
    } finally {
        if FileExist(tempFile)
            try FileDelete(tempFile)
    }
}

NormalizeOkwwOcrText(text) {
    clean := StrReplace(text, "`r", "")
    clean := StrReplace(clean, "`n", "")
    clean := StrReplace(clean, "`t", "")
    clean := StrReplace(clean, " ", "")
    clean := StrReplace(clean, "　", "")
    ; RapidOCR 可能在同一個詞內混用繁簡字形，先統一成繁體再做嚴格比對。
    clean := StrReplace(clean, "实", "實")
    clean := StrReplace(clean, "时", "時")
    clean := StrReplace(clean, "触", "觸")
    clean := StrReplace(clean, "发", "發")
    clean := StrReplace(clean, "动", "動")
    clean := StrReplace(clean, "战", "戰")
    clean := StrReplace(clean, "斗", "鬥")
    clean := StrReplace(clean, "启", "啟")
    return clean
}

GetOkwwOcrBlockRect(block) {
    points := ""
    if block.HasOwnProp("boxPoint") && IsObject(block.boxPoint) {
        points := block.boxPoint
    } else if block.HasOwnProp("box") && IsObject(block.box) {
        points := block.box
    }

    if !IsObject(points) || points.Length < 3
        return 0

    left := 2147483647
    top := 2147483647
    right := -2147483648
    bottom := -2147483648

    for point in points {
        if IsObject(point) && point.HasOwnProp("x") {
            px := point.x
            py := point.y
        } else if IsObject(point) && point.Length >= 2 {
            px := point[1]
            py := point[2]
        } else {
            continue
        }

        left := Min(left, px)
        top := Min(top, py)
        right := Max(right, px)
        bottom := Max(bottom, py)
    }

    if (right < left || bottom < top)
        return 0

    return {
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        centerX: (left + right) / 2,
        centerY: (top + bottom) / 2
    }
}

FindExactOkwwOcrBlock(result, acceptedTexts) {
    if !IsObject(result)
        return 0

    for block in result {
        clean := NormalizeOkwwOcrText(block.text)
        for accepted in acceptedTexts {
            if (clean = accepted) {
                rect := GetOkwwOcrBlockRect(block)
                if rect
                    return {text: clean, rawText: block.text, rect: rect}
            }
        }
    }
    return 0
}

CountOkwwSameLengthDifferences(leftText, rightText, stopAfter := 1) {
    leftLength := StrLen(leftText)
    if (leftLength != StrLen(rightText))
        return -1

    differenceCount := 0
    Loop leftLength {
        if (SubStr(leftText, A_Index, 1) != SubStr(rightText, A_Index, 1)) {
            differenceCount += 1
            if (differenceCount > stopAfter)
                return differenceCount
        }
    }
    return differenceCount
}

FindOkwwRealtimeTriggerOcrBlock(result, scale := 1.0) {
    if !IsObject(result)
        return 0

    ; 只放寬 OKWW 左側導覽項目，避免影響「自動戰鬥／已啟用」等安全確認。
    acceptedTexts := ["實時觸發", "即時觸發"]
    sidebarRight := Round(180 * scale)
    bestFuzzy := 0
    bestFuzzyDistance := 2147483647
    bestFuzzyCenterX := 2147483647

    for block in result {
        if !block.HasOwnProp("text")
            continue

        rect := GetOkwwOcrBlockRect(block)
        if !rect || rect.right > sidebarRight
            continue

        clean := NormalizeOkwwOcrText(block.text)
        if (clean = "")
            continue

        for accepted in acceptedTexts {
            distance := CountOkwwSameLengthDifferences(clean, accepted, 1)
            if (distance = 0) {
                return {
                    text: clean,
                    rawText: block.text,
                    rect: rect,
                    matchType: "exact",
                    targetText: accepted,
                    distance: 0
                }
            }

            ; 僅允許等長文字的一個字辨識錯誤，例如「即時網發」。
            if (distance = 1
                && (distance < bestFuzzyDistance
                    || (distance = bestFuzzyDistance && rect.centerX < bestFuzzyCenterX))) {
                bestFuzzy := {
                    text: clean,
                    rawText: block.text,
                    rect: rect,
                    matchType: "bounded_fuzzy",
                    targetText: accepted,
                    distance: distance
                }
                bestFuzzyDistance := distance
                bestFuzzyCenterX := rect.centerX
            }
        }
    }

    return bestFuzzy
}

FindOkwwAutoBattleLabelBlock(result, scale := 1.0) {
    if !IsObject(result)
        return 0

    ; OKWW v3.5.25 將「自動戰鬥」與說明文字改成同一行，RapidOCR 可能把兩者合成一個 block。
    ; 僅在主內容區第一列接受完整標題，或接受以完整標題開頭的合併 block，避免全頁 contains 誤判。
    contentLeft := Round(180 * scale)
    firstRowTop := Round(40 * scale)
    firstRowBottom := Round(135 * scale)
    expectedLabel := "自動戰鬥"

    for block in result {
        if !block.HasOwnProp("text")
            continue

        rect := GetOkwwOcrBlockRect(block)
        if !rect
            continue
        if (rect.centerX <= contentLeft
            || rect.centerY < firstRowTop
            || rect.centerY > firstRowBottom)
            continue

        clean := NormalizeOkwwOcrText(block.text)
        labelPos := InStr(clean, expectedLabel)
        ; RapidOCR 在 v3.5.28 偶爾會在第一列前面混入極短雜訊（實測為「x,」）。
        ; 只容許標題位於第 1～3 字元，且仍受主內容第一列與同列狀態的雙重限制。
        hasBoundedLeadingNoise := (labelPos > 1 && labelPos <= 3)
        if (clean = expectedLabel
            || SubStr(clean, 1, StrLen(expectedLabel)) = expectedLabel
            || hasBoundedLeadingNoise) {
            matchType := clean = expectedLabel ? "exact"
                : (labelPos = 1 ? "merged_prefix" : "leading_noise")
            return {
                text: expectedLabel,
                rawText: block.text,
                normalizedText: clean,
                rect: rect,
                matchType: matchType
            }
        }
    }

    return 0
}

SummarizeOkwwOcrRegion(result, minCenterX := 0, maxCenterX := 0,
    minCenterY := 0, maxCenterY := 0, maxItems := 30) {
    if !IsObject(result)
        return "(無 OCR 結果)"

    summary := ""
    count := 0
    for block in result {
        if !block.HasOwnProp("text")
            continue

        rect := GetOkwwOcrBlockRect(block)
        if !rect
            continue
        if (minCenterX > 0 && rect.centerX < minCenterX)
            continue
        if (maxCenterX > 0 && rect.centerX > maxCenterX)
            continue
        if (minCenterY > 0 && rect.centerY < minCenterY)
            continue
        if (maxCenterY > 0 && rect.centerY > maxCenterY)
            continue

        clean := NormalizeOkwwOcrText(block.text)
        if (clean = "")
            continue

        count += 1
        summary .= (summary = "" ? "" : " | ") clean "@" Round(rect.centerX) "," Round(rect.centerY)
        if (count >= maxItems)
            break
    }

    return summary != "" ? summary : "(指定區域無文字候選)"
}

SummarizeOkwwOcrBlocks(result, maxCenterX := 0, maxItems := 30) {
    if !IsObject(result)
        return "(無 OCR 結果)"

    summary := ""
    count := 0
    for block in result {
        clean := NormalizeOkwwOcrText(block.text)
        if (clean = "")
            continue

        rect := GetOkwwOcrBlockRect(block)
        if !rect
            continue
        if (maxCenterX > 0 && rect.centerX > maxCenterX)
            continue

        count += 1
        summary .= (summary = "" ? "" : " | ") clean "@" Round(rect.centerX) "," Round(rect.centerY)
        if (count >= maxItems)
            break
    }

    return summary != "" ? summary : "(左側無文字候選)"
}

ReadOkwwAutoBattleOcrState(okwwHwnd, ocr, scale := 1.0) {
    result := CaptureOkwwOcr(okwwHwnd, ocr, "辨識自動戰鬥狀態")
    labelMatch := FindOkwwAutoBattleLabelBlock(result, scale)
    if !labelMatch {
        firstRowCandidates := SummarizeOkwwOcrRegion(
            result, Round(180 * scale), 0, Round(40 * scale), Round(135 * scale), 30)
        WriteLog("OKWW OCR 在主內容第一列找不到「自動戰鬥」標題"
            "（接受 exact、merged-prefix 或最多 2 字元前綴雜訊） | 區域候選=" firstRowCandidates, "WARN")
        return {
            state: "unknown", rowY: 0, labelText: "", statusText: "",
            reason: "missing_auto_battle_label"
        }
    }

    if (labelMatch.matchType = "merged_prefix" || labelMatch.matchType = "leading_noise") {
        WriteLog("OKWW 自動戰鬥標題以 " labelMatch.matchType " 命中：raw=" labelMatch.rawText
            " normalized=" labelMatch.normalizedText, "WARN")
    }

    bestState := "unknown"
    bestStatusText := ""
    bestRowY := labelMatch.rect.centerY
    bestDistance := 2147483647
    ; v3.5.25 的相鄰列距可能只有約 41px；舊的 55px 容忍會把第二列「未啟用」誤當第一列狀態。
    maxRowDistance := Round(24 * scale)
    clientW := 0
    try WinGetClientPos(, , &clientW, , "ahk_id " okwwHwnd)
    statusColumnLeft := clientW > 0 ? Round(clientW * 0.68) : labelMatch.rect.centerX

    for block in result {
        clean := NormalizeOkwwOcrText(block.text)
        state := ""
        if (clean = "已启用" || clean = "已啟用") {
            state := "enabled"
        } else if (clean = "未启用" || clean = "未啟用") {
            state := "disabled"
        } else {
            continue
        }

        rect := GetOkwwOcrBlockRect(block)
        if (!rect
            || rect.centerX <= labelMatch.rect.centerX
            || rect.centerX < statusColumnLeft)
            continue

        distance := Abs(rect.centerY - labelMatch.rect.centerY)
        if (distance <= maxRowDistance && distance < bestDistance) {
            bestDistance := distance
            bestState := state
            bestStatusText := clean
            bestRowY := rect.centerY
        }
    }

    if (bestState = "unknown") {
        sameRowCandidates := SummarizeOkwwOcrRegion(
            result, statusColumnLeft, 0,
            labelMatch.rect.centerY - maxRowDistance,
            labelMatch.rect.centerY + maxRowDistance, 30)
        WriteLog("OKWW OCR 已找到「" labelMatch.text
            "」，但右側同列找不到精確的「已啟用／未啟用」"
            " | 同列候選=" sameRowCandidates, "WARN")
    }

    return {
        state: bestState,
        rowY: bestRowY,
        labelText: labelMatch.text,
        statusText: bestStatusText,
        reason: (bestState = "unknown" ? "missing_same_row_status" : "")
    }
}

ClickOkwwClientPoint(okwwHwnd, clientX, clientY) {
    if !okwwHwnd || !WinExist("ahk_id " okwwHwnd)
        return false

    try {
        winClientX := 0
        winClientY := 0
        WinGetClientPos(&winClientX, &winClientY, , , "ahk_id " okwwHwnd)
        screenX := winClientX + Round(clientX)
        screenY := winClientY + Round(clientY)

        oldMouseMode := A_CoordModeMouse
        CoordMode("Mouse", "Screen")
        try {
            MouseMove(screenX, screenY, 0)
            Sleep 150
            MouseClick("Left")
        } finally {
            CoordMode("Mouse", oldMouseMode)
        }
        return true
    } catch as e {
        WriteLog("OKWW 座標點擊失敗：client=" clientX "," clientY
            " | " e.Message, "WARN")
        return false
    }
}

SendF11ToOkww(okwwHwnd) {
    if !okwwHwnd || !WinExist("ahk_id " okwwHwnd) {
        WriteLog("OKWW F11 發送失敗：目標視窗已失效 | hwnd=" okwwHwnd, "ERROR")
        return false
    }

    try {
        title := WinGetTitle("ahk_id " okwwHwnd)
        pid := WinGetPID("ahk_id " okwwHwnd)
        procName := StrLower(WinGetProcessName("ahk_id " okwwHwnd))
        if (procName != "pythonw.exe"
            || !RegExMatch(title, "i)^OK-WW\s+v[\d.]+\s+Global(?:\s*-\s*OK-WW)?\s*$")) {
            WriteLog("OKWW F11 發送前安全檢查失敗：pid=" pid
                " process=" procName " title=" title, "ERROR")
            return false
        }

        try WinRestore("ahk_id " okwwHwnd)
        WinActivate("ahk_id " okwwHwnd)
        if WinWaitActive("ahk_id " okwwHwnd, , 3) {
            Sleep 500
            SendEvent("{F11}")
            WriteLog("已直接發送 F11 到 OKWW 最終主視窗：hwnd="
                okwwHwnd " pid=" pid " title=" title)
            return true
        }

        WriteLog("OKWW 無法切至前景，改用 ControlSend 定向發送 F11：hwnd="
            okwwHwnd " pid=" pid " title=" title, "WARN")
        ControlSend("{F11}", , "ahk_id " okwwHwnd)
        WriteLog("已透過 ControlSend 發送 F11 到 OKWW 最終主視窗")
        return true
    } catch as e {
        WriteLog("OKWW F11 發送失敗：hwnd=" okwwHwnd " | " e.Message, "ERROR")
        return false
    }
}

PrepareOkwwTopmostOperation(okwwHwnd) {
    ctx := Map()
    ctx["okww"] := okwwHwnd
    ctx["wuthering"] := 0
    ctx["lrmc"] := 0

    try {
        wuthHwnd := GetWutheringGameHwnd()
        if (wuthHwnd) {
            ctx["wuthering"] := wuthHwnd
            try WinSetAlwaysOnTop(0, "ahk_id " wuthHwnd)
        }
    }

    try {
        target := ResolveLrmcTargetWindow()
        if (target.hwnd) {
            ctx["lrmc"] := target.hwnd
            try WinSetAlwaysOnTop(0, "ahk_id " target.hwnd)
        }
    }

    try {
        WinRestore("ahk_id " okwwHwnd)
        WinSetAlwaysOnTop(1, "ahk_id " okwwHwnd)
        WinActivate("ahk_id " okwwHwnd)
        WinWaitActive("ahk_id " okwwHwnd, , 2)
        WriteLog("OKWW F11 前：已設置 OKWW 置頂，並暫時取消鳴潮/LRMCAI 置頂")
    } catch as e {
        WriteLog("OKWW 置頂準備失敗: " e.Message, "WARN")
    }

    return ctx
}

RestoreTopmostAfterOkwwOperation(ctx) {
    try {
        okwwHwnd := ctx.Has("okww") ? ctx["okww"] : 0
        if (okwwHwnd)
            try WinSetAlwaysOnTop(0, "ahk_id " okwwHwnd)
    }

    try {
        wuthHwnd := ctx.Has("wuthering") ? ctx["wuthering"] : 0
        if (wuthHwnd && WinExist("ahk_id " wuthHwnd)) {
            try WinSetAlwaysOnTop(0, "ahk_id " wuthHwnd)
            WriteLog("OKWW 操作完成：不恢復鳴潮持續置頂")
        }
    }
}

; F11 後 OKWW 的 pythonw 視窗可能延遲再次顯示；用非侵入式計時器補做掃描，絕不啟用視窗。
ScheduleOkwwMinimizeSweeps(context := "") {
    global __OKWW_MINIMIZE_SWEEP_REMAINING, __OKWW_MINIMIZE_SWEEP_CONTEXT
    SetTimer(DelayedOkwwMinimizeSweep, 0)
    __OKWW_MINIMIZE_SWEEP_REMAINING := 3
    __OKWW_MINIMIZE_SWEEP_CONTEXT := context
    MinimizeOKWWWindows(context "｜立即")
    SetTimer(DelayedOkwwMinimizeSweep, -3000)
}

DelayedOkwwMinimizeSweep() {
    global __OKWW_MINIMIZE_SWEEP_REMAINING, __OKWW_MINIMIZE_SWEEP_CONTEXT
    if (__OKWW_MINIMIZE_SWEEP_REMAINING <= 0)
        return

    sweepIndex := 4 - __OKWW_MINIMIZE_SWEEP_REMAINING
    MinimizeOKWWWindows(__OKWW_MINIMIZE_SWEEP_CONTEXT "｜延遲掃描" sweepIndex)
    __OKWW_MINIMIZE_SWEEP_REMAINING -= 1
    if (__OKWW_MINIMIZE_SWEEP_REMAINING > 0)
        SetTimer(DelayedOkwwMinimizeSweep, -4000)
}

; ★ 最小化 OKWW 視窗（只按進程＋精確標題鎖定，不會碰其他 Python）
MinimizeOKWWWindows(context := "") {
    WriteLog("開始尋找並最小化 OKWW 視窗 | context=" context)
    foundCount := 0
    currentPID := DllCall("GetCurrentProcessId")
    
    ; 尋找所有可能的 OKWW 視窗
    for hwnd in WinGetList() {
        try {
            title := WinGetTitle(hwnd)
            processName := WinGetProcessName(hwnd)
            pid := WinGetPID(hwnd)
            wclass := ""
            try wclass := StrLower(WinGetClass(hwnd))
            titleLower := StrLower(title)
            processLower := StrLower(processName)

            ; 排除自身腳本與 Tooltip 視窗，避免誤把 step tooltip 當作 OKWW 視窗。
            if (pid = currentPID || wclass = "tooltips_class32")
                continue
            
            ; 必須同時符合 OKWW 宿主進程與標題；不可只因標題含 OKWW 就動到其他程式。
            isOKWWWindow := (processLower = "ok-ww.exe"
                    && (titleLower = "ok-ww" || InStr(titleLower, "ok-ww-siw")))
                || (processLower = "pythonw.exe"
                    && RegExMatch(title, "i)^OK-WW\s+v[\d.]+\s+Global(?:\s*-\s*OK-WW)?\s*$"))
            
            if (isOKWWWindow) {
                try {
                    WinMinimize(hwnd)
                    foundCount++
                    WriteLog("已最小化 OKWW 視窗: " title " (進程: " processName ")")
                } catch as e {
                    WriteLog("最小化視窗失敗: " title " - " e.Message, "WARN")
                }
            }
        } catch as e {
            ; 忽略無法存取的視窗
        }
    }
    
    if (foundCount > 0) {
        WriteLog("成功最小化 " foundCount " 個 OKWW 視窗")
    } else {
        WriteLog("本次未找到可最小化的 OKWW 視窗 | context=" context)
    }
    return foundCount
}

; 僅識別由 OKWW 使用的 Python 進程，避免誤殺其他 python.exe/pythonw.exe。
IsOkwwPythonProcess(pid, commandLine := "") {
    if (pid <= 0)
        return false

    cmdLower := StrLower(commandLine)
    if (InStr(cmdLower, "ok-ww") || InStr(cmdLower, "okww"))
        return true

    try {
        for hwnd in WinGetList("ahk_pid " pid) {
            titleLower := StrLower(WinGetTitle("ahk_id " hwnd))
            if (InStr(titleLower, "ok-ww") || InStr(titleLower, "okww"))
                return true
        }
    } catch {
        ; 無法讀取該 PID 的視窗時視為非 OKWW；不可因此誤殺其他 Python。
    }

    return false
}

; 舊局部重啟輔助函式僅保留供既有診斷相容；目前主流程不再呼叫。
CloseOkwwPythonProcesses() {
    closedCount := 0
    try {
        wmi := ComObjGet("winmgmts:")
        query := "Select ProcessId, Name, CommandLine from Win32_Process where Name='pythonw.exe' or Name='python.exe'"
        for proc in wmi.ExecQuery(query) {
            pid := proc.ProcessId + 0
            cmdLine := ""
            try cmdLine := proc.CommandLine
            if !IsOkwwPythonProcess(pid, cmdLine)
                continue

            WriteLog("關閉 OKWW Python 進程：PID=" pid " Name=" proc.Name)
            try ProcessClose(pid)
            Sleep 250
            if ProcessExist(pid) {
                WriteLog("OKWW Python 進程仍存在，依 PID 強制關閉：" pid, "WARN")
                try RunWait("taskkill /F /PID " pid, , "Hide")
            }
            closedCount += 1
        }
    } catch as e {
        WriteLog("掃描 OKWW Python 進程失敗：" e.Message, "WARN")
    }
    return closedCount
}

CloseOkwwProcessPid(pid, displayName) {
    if (pid <= 0 || !ProcessExist(pid))
        return false

    WriteLog("局部關閉 " displayName "：PID=" pid)
    try ProcessClose(pid)

    waitUntil := A_TickCount + 2000
    while (ProcessExist(pid) && A_TickCount < waitUntil)
        Sleep 100

    if ProcessExist(pid) {
        WriteLog(displayName " 未在 2 秒內退出，僅依已確認 PID 強制關閉：" pid, "WARN")
        try RunWait("taskkill /F /PID " pid, , "Hide")
        Sleep 200
    }

    if ProcessExist(pid) {
        WriteLog("無法關閉 " displayName " PID=" pid, "ERROR")
        return false
    }
    return true
}

CloseOkwwManagerScriptsOnly() {
    closedCount := 0
    for item in EnumerateAuxManagedAhkProcesses() {
        if (item.name != "自動開啟OKWW.ahk")
            continue
        if CloseOkwwProcessPid(item.pid, "自動開啟OKWW.ahk")
            closedCount += 1
    }
    return closedCount
}

CloseOkwwLauncherProcessesOnly() {
    closedCount := 0
    try {
        query := "Select ProcessId, Name from Win32_Process where Name='ok-ww.exe' or Name='OK-WW.exe'"
        for proc in ComObjGet("winmgmts:").ExecQuery(query) {
            pid := proc.ProcessId + 0
            if CloseOkwwProcessPid(pid, proc.Name)
                closedCount += 1
        }
    } catch as e {
        WriteLog("掃描 ok-ww.exe 進程失敗：" e.Message, "WARN")
    }
    return closedCount
}

RestartOnlyOkwwForAutoBattleRetry() {
    managerClosed := CloseOkwwManagerScriptsOnly()
    launcherClosed := CloseOkwwLauncherProcessesOnly()
    pythonClosed := CloseOkwwPythonProcesses()
    Sleep 1200

    remaining := GetOkwwRuntimeSnapshotState()
    summary := "manager_ahk_closed=" managerClosed
        . " launcher_closed=" launcherClosed
        . " okww_python_closed=" pythonClosed
        . " remaining=" remaining
    WriteStepResult("OKWW局部復原", true, summary)
    return summary
}

; ★ 啟動前檢測：關閉所有目標程式
CheckAndCloseExistingProcesses() {
    WriteStep("清場流程", "入口：檢測並關閉既有進程")
    WriteLog("開始檢測現有程式...")
    
    ; 定義要檢測的程式（使用實際檢測到的程式名稱）
    processes := [
        {name: "ok-ww.exe", display: "OKWW主程式"},
        {name: "Client-Win64-Shipping.exe", display: "鳴潮遊戲"},
        {name: "LRMCAI.exe", display: "LRMC自動"}
    ]
    
    ; 檢測並關閉程式
    foundAny := false
    for process in processes {
        ; 檢查進程是否存在
        processExists := false
        targetPID := 0
        
        ; 先用ProcessExist快速檢查
        pid := ProcessExist(process.name)
        if (pid) {
            processExists := true
            targetPID := pid
        }
        
        if (processExists) {
            foundAny := true
            WriteLog("檢測到運行中的 " process.display " (" process.name " PID:" targetPID ")，正在關閉...")
            ShowTip("🔄 關閉現有的 " process.display " 程式...", 1200)
            
            try {
                if (targetPID > 0) {
                    ProcessClose(targetPID)
                } else {
                    ProcessClose(process.name)
                }
                Sleep 1000  ; 等待程式關閉
                
                ; 確認是否已關閉
                if ProcessExist(process.name) {
                    WriteLog("嘗試強制關閉 " process.name, "WARN")
                    Run("taskkill /F /IM " process.name, , "Hide")
                    Sleep 1000
                }
                WriteLog("已成功關閉 " process.display)
            } catch as e {
                WriteLog("關閉 " process.name " 時出錯: " e.Message, "ERROR")
            }
        }
    }

    ; Python 只依命令列或所屬視窗標題辨識 OKWW，再關閉命中的特定 PID。
    if (CloseOkwwPythonProcesses() > 0)
        foundAny := true
    
    ; 額外檢測：關閉所有 AutoHotkey 進程（除了自己）
    currentPID := DllCall("GetCurrentProcessId")
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%AutoHotkey%'") {
            if (proc.ProcessId != currentPID) {
                try {
                    cmdLine := proc.CommandLine
                    if (InStr(cmdLine, "自動開啟OKWW.ahk") || InStr(cmdLine, "開啟LRMC.ahk")) {
                        WriteLog("關閉現有的 AutoHotkey 腳本: PID=" proc.ProcessId " 命令行=" cmdLine)
                        ProcessClose(proc.ProcessId)
                        foundAny := true
                    }
                } catch {
                    ; 忽略訪問被拒絕的錯誤
                }
            }
        }
    } catch as e {
        WriteLog("檢測AutoHotkey進程時出錯: " e.Message, "WARN")
    }
    
    if foundAny {
        WriteLog("等待程式完全關閉...")
        ShowTip("⏳ 等待程式完全關閉...", 3000)
        WriteLog("啟動前清理完成")
        WriteStepResult("清場流程", true, "已有進程已清理")
    } else {
        WriteLog("沒有檢測到運行中的目標程式，可以開始主流程")
        WriteStepResult("清場流程", true, "無需清理")
    }
}

; ★ 全域 UE4 崩潰監看（獨立 UE4-Client 視窗）
StartCrashWatcher() {
    SetTimer CrashWatcherTick, 5000  ; 從2秒進一步降低到5秒，大幅減少系統負擔
}

GetActionableUe4CrashWindow(hwnd) {
    if !hwnd
        return false

    try {
        if !DllCall("IsWindow", "ptr", hwnd, "int")
            return false
        if !DllCall("IsWindowVisible", "ptr", hwnd, "int")
            return false

        title := Trim(WinGetTitle("ahk_id " hwnd), " `t`r`n")
        exactLegacyTitle := (title = "UE4-Client")
        knownCrashTitle := title ~= "i)^UE4-Client Game.*(crash|崩潰|崩溃|fatal|致命)"
        if (!exactLegacyTitle && !knownCrashTitle)
            return false

        ; 已縮到工作列或被 DWM cloak 的視窗，使用者畫面上其實不存在，不能當成新崩潰。
        if (WinGetMinMax("ahk_id " hwnd) = -1)
            return false

        cloakedBuf := Buffer(4, 0)
        try {
            hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "ptr", cloakedBuf, "uint", 4, "int")
            if (hr = 0 && NumGet(cloakedBuf, 0, "uint") != 0)
                return false
        }

        WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
        if (w < 120 || h < 80)
            return false

        virtualX := SysGet(76)
        virtualY := SysGet(77)
        virtualW := SysGet(78)
        virtualH := SysGet(79)
        if (x + w <= virtualX || y + h <= virtualY || x >= virtualX + virtualW || y >= virtualY + virtualH)
            return false

        pid := WinGetPID("ahk_id " hwnd)
        processName := ""
        try processName := WinGetProcessName("ahk_id " hwnd)
        return { hwnd: hwnd, pid: pid, processName: processName, title: title, x: x, y: y, w: w, h: h }
    }

    return false
}

FindActionableUe4CrashWindow() {
    ; 不依賴全域 TitleMatchMode，逐一比對精確標題，避免其他含 UE4-Client 字樣的視窗誤命中。
    for hwnd in WinGetList() {
        info := GetActionableUe4CrashWindow(hwnd)
        if IsObject(info)
            return info
    }
    return false
}

WaitForUe4CrashWindowDismissal(hwnd, timeoutMs := 2500) {
    deadline := A_TickCount + timeoutMs
    while (A_TickCount < deadline) {
        if !IsObject(GetActionableUe4CrashWindow(hwnd))
            return true
        Sleep 100
    }
    return !IsObject(GetActionableUe4CrashWindow(hwnd))
}

CrashWatcherTick() {
    global CFG_FILE
    static busy := false
    static lastSkippedSignature := ""
    if busy
        return

    crashWindow := FindActionableUe4CrashWindow()
    if !IsObject(crashWindow)
        return

    hwndC := crashWindow.hwnd
    incidentSignature := crashWindow.pid "|" hwndC
    previousSignature := Trim(IniReadSafe(CFG_FILE, "restart_tracking", "last_ue4_crash_signature", ""), " `t`r`n")
    if (incidentSignature = previousSignature) {
        if (incidentSignature != lastSkippedSignature) {
            WriteLog("UE4 崩潰監看：略過已處理事件 PID=" crashWindow.pid " HWND=" hwndC " EXE=" crashWindow.processName, "WARN")
            lastSkippedSignature := incidentSignature
        }
        return
    }

    busy := true
    try {
        WriteLog("UE4 崩潰監看：命中可操作視窗 PID=" crashWindow.pid " HWND=" hwndC " EXE=" crashWindow.processName
            " RECT=" crashWindow.x "," crashWindow.y "," crashWindow.w "x" crashWindow.h, "ERROR")
        ocr := RapidOcr()
        ; 使用唯一臨時檔案名，避免衝突
        tempFile := A_ScriptDir "\ue4crash_" A_TickCount ".png"
        try {
            ImagePutFile("ahk_id " hwndC, tempFile)
            res := ocr.ocr_from_file(tempFile, , true)
            
            ; 立即清理臨時檔案
            if FileExist(tempFile)
                FileDelete(tempFile)
        } catch as e {
            WriteLog("崩潰檢測 OCR 失敗: " e.Message, "WARN")
            if FileExist(tempFile)
                FileDelete(tempFile)
            busy := false
            return
        }

        btn := ""
        crashEvidenceFound := false
        crashOcrSummary := ""
        if IsObject(res) {
            for block in res {
                rawText := StrReplace(StrReplace(block.text, "`r", " "), "`n", " ")
                rawText := Trim(RegExReplace(rawText, "\s+", " "), " `t")
                if (rawText != "") {
                    if (crashOcrSummary != "")
                        crashOcrSummary .= " | "
                    crashOcrSummary .= rawText
                    if (StrLen(crashOcrSummary) > 900)
                        crashOcrSummary := SubStr(crashOcrSummary, 1, 900)
                }

                if (rawText ~= "i)(fatal\s*error|DXGI_ERROR_DEVICE|崩潰|崩溃|致命錯誤|致命错误)")
                    crashEvidenceFound := true

                t := StrReplace(rawText, " ", "")
                t := ToSimp(t)
                if (block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3) {
                    if (InStr(t, "确定") || InStr(t, "確定") || InStr(t, "OK") || InStr(t, "确认") || InStr(t, "Confirm")) {
                        cx := (block.boxPoint[1].x + block.boxPoint[3].x) / 2
                        cy := (block.boxPoint[1].y + block.boxPoint[3].y) / 2
                        btn := [Round(cx), Round(cy)]
                    }
                }
            }
        }

        if !crashEvidenceFound {
            skipDetail := "UE4 崩潰監看：標題命中但 OCR 未找到 Fatal/DXGI/崩潰證據，略過以避免誤殺；title="
            skipDetail .= crashWindow.title " pid=" crashWindow.pid " ocr=" crashOcrSummary
            WriteLog(skipDetail, "WARN")
            return
        }

        ; 先落盤事件指紋，再操作視窗。即使腳本隨即重啟，同一個 HWND/PID 也不會再吃重啟額度。
        IniWrite incidentSignature, CFG_FILE, "restart_tracking", "last_ue4_crash_signature"
        IniWrite FormatTime(, "yyyy-MM-dd HH:mm:ss"), CFG_FILE, "restart_tracking", "last_ue4_crash_time"
        IniWrite crashOcrSummary, CFG_FILE, "restart_tracking", "last_ue4_crash_ocr"

        WinActivate "ahk_id " hwndC
        Sleep 120
        if IsObject(btn)
            MouseClick "left", btn[1], btn[2]
        else
            Send "{Enter}"

        dismissed := WaitForUe4CrashWindowDismissal(hwndC, 2500)
        if !dismissed {
            WriteLog("UE4 崩潰視窗按下確認後仍可操作，嘗試 WinClose；PID=" crashWindow.pid " HWND=" hwndC, "WARN")
            try WinClose("ahk_id " hwndC)
            dismissed := WaitForUe4CrashWindowDismissal(hwndC, 1500)
        }
        if dismissed
            WriteLog("UE4 崩潰視窗已從可操作畫面消失；事件指紋=" incidentSignature)
        else
            WriteLog("UE4 崩潰視窗仍存在，但已記錄事件指紋，不會跨重啟重複觸發；事件指紋=" incidentSignature, "WARN")

        ; 關閉 OKWW 程式，因為遊戲崩潰重啟時 OKWW 也需要重新啟動
        try ProcessClose "ok-ww.exe"
        catch
            try ProcessClose "OK-WW.exe"
        Sleep 2000

        ; 統一走 RequestRestart：
        ; 1) 正確設置重啟旗標，避免 OnExit 誤停錄影
        ; 2) 沿用既有重啟計數/通知/crash hotkey 模式判定
        RequestRestart(
            "偵測到可操作的 UE4 致命錯誤視窗；title=" crashWindow.title
                " pid=" crashWindow.pid " hwnd=" hwndC " exe=" crashWindow.processName
                "；OCR=" crashOcrSummary,
            "ERROR", true, "UE4_FATAL_DIALOG", "UE4 全域崩潰監看")
        return
    } finally busy := false
}

; A) 更新彈窗偵測（簡體關鍵詞）＋ OCR 算出【退出】中心點點擊
;    進入前：把鳴潮視窗貼齊右上角
DetectWutheringAndExit(&loginDetected := false) {
    global WUTHERING_NO_WINDOW_TOLERANCE

    WriteStep("鳴潮檢測", "入口：更新/登入畫面辨識")

    loginDetected := false
    SetTitleMatchMode 2
    hwnd := WaitForWutheringGameWindow(120)
    if !hwnd {
        ShowTip("找不到「Client-Win64-Shipping.exe」遊戲視窗（逾時）。", 1200)
        WriteStepResult("鳴潮檢測", false, "no_window")
        return "no_window"
    }

    ; 視窗移動策略：先偵測到穩定目標視窗，再開始持續重試移動。
    movedTopRight := false
    nextMoveRetryTick := A_TickCount
    foundTargetWindow := false
    stableWindowHit := 0

    ; ⏱️ 至少等待 30 秒讓遊戲完全啟動（登入畫面一般需要 25-35 秒）
    earlyExitDeadline := A_TickCount + 30000
    
    deadline := A_TickCount + 1800000   ; 1800 秒（30 分鐘）
    kwUpdate1 := "更新完成"
    kwUpdate2 := "请重新启动游戏"
    kwUpdate3 := "遊戲即將重啟"
    kwUpdate4 := "游戏即将重启"
    kwBtn     := "退出"
    
    ; 優化：登入畫面檢測需要多個指標同時出現（降低誤判）
    ; 登入按鈕相關詞彙（包括「點擊連接」）
    loginBtnKeywords := [ "點擊開始", "点击开始", "點選開始", "点选开始", "開始遊戲", "开始游戏", "點擊連接", "点击连接", "點選連接", "点选连接" ]
    ; 登入UI相關詞彙（如賬號/伺服器選擇）
    loginUIKeywords := [ "伺服器", "服务器", "賬號", "账号", "帳號", "账户" ]
    noWindowStreak := 0

    while (A_TickCount < deadline) {
        hwnd := GetWutheringGameHwnd()
        if !hwnd {
            stableWindowHit := 0

            ; 尚未真正抓到目標視窗前，不做 no_window 累計，避免啟動初期誤判。
            if !foundTargetWindow {
                Sleep 500
                continue
            }

            noWindowStreak += 1
            if (noWindowStreak >= WUTHERING_NO_WINDOW_TOLERANCE) {
                WriteLog("檢測途中連續 " noWindowStreak " 次失去鳴潮視窗，標記為 no_window", "WARN")
                WriteStepResult("鳴潮檢測", false, "no_window_streak=" noWindowStreak)
                return "no_window"
            }
            WriteLog("檢測途中短暫找不到鳴潮視窗（" noWindowStreak "/" WUTHERING_NO_WINDOW_TOLERANCE "），等待後重試", "WARN")
            Sleep 1200
            continue
        }
        noWindowStreak := 0
        stableWindowHit += 1

        ; 在 OCR 主迴圈中持續做非阻塞的登入模板輔助點擊。
        TryAssistLoginTemplateBeforeOcr()

        if !foundTargetWindow {
            foundTargetWindow := true
            WriteLog("已找到目標鳴潮視窗，開始準備移動到右上角")
        }

        ; 需要連續命中至少 2 次同類視窗，才開始移動，降低初始化中假視窗干擾。
        if (!movedTopRight && stableWindowHit >= 2 && A_TickCount >= nextMoveRetryTick) {
            okMove := false
            try okMove := MoveWindowTopRight(hwnd, 0, 0)
            catch as e {
                WriteLog("視窗移動失敗（非致命）: " e.Message, "WARN")
                okMove := false
            }

            if okMove {
                movedTopRight := true
                WriteLog("視窗位置處理完成（保留原尺寸與狀態），後續不再重試移動")
            } else {
                nextMoveRetryTick := A_TickCount + 1500
            }
        }

        ; 首先用模板檢測叉叉按鈕（不涉及 OCR，更快速）
        closeIconPath := A_ScriptDir "\0510.png"
        if FileExist(closeIconPath) {
            try {
                foundX := 0
                foundY := 0
                searchRight := (A_ScreenWidth > 0) ? (A_ScreenWidth - 1) : 1919
                searchBottom := (A_ScreenHeight > 0) ? (A_ScreenHeight - 1) : 1079
                isFound := ImageSearch(&foundX, &foundY, 0, 0, searchRight, searchBottom, closeIconPath)
                if isFound {
                    ShowTip("✅ 檢測到叉叉提示 → 自動點擊", 800)
                    MouseClick "left", foundX, foundY
                    WriteLog("已點擊叉叉按鈕 位置:" foundX "," foundY, "INFO")
                    Sleep 1000
                    continue
                }
            } catch as e {
                WriteLog("模板檢測叉叉失敗: " e.Message, "WARN")
            }
        }

        ; 使用唯一臨時檔案名，執行後清理（減少磁碟 I/O 衝突）
        tempFile := A_ScriptDir "\temp_update_" A_TickCount ".png"
        try {
            ImagePutFile("ahk_id " hwnd, tempFile)
            ocr := RapidOcr()
            res := ocr.ocr_from_file(tempFile, , true)
            
            ; 立即清理臨時檔案，釋放磁碟空間
            if FileExist(tempFile)
                FileDelete(tempFile)
        } catch as e {
            WriteLog("更新檢測 OCR 失敗: " e.Message, "WARN")
            if FileExist(tempFile)
                FileDelete(tempFile)
            Sleep 1000
            continue
        }

        foundUpdate := false
        foundLoginBtn := false
        foundLoginUI := false
        btnCenter := ""

        if IsObject(res) {
            for block in res {
                clean := StrReplace(StrReplace(block.text, "`r", ""), "`n", "")
                clean := StrReplace(clean, " ", "")
                
                
                ; 檢測更新相關文字
                if InStr(clean, kwUpdate1) || InStr(clean, kwUpdate2) || InStr(clean, kwUpdate3) || InStr(clean, kwUpdate4)
                    foundUpdate := true
                
                ; 檢測登入按鈕相關文字
                for _, btnKw in loginBtnKeywords {
                    if InStr(clean, btnKw) {
                        foundLoginBtn := true
                        WriteLog("檢測到登入按鈕關鍵字: " btnKw " 在文字: " clean)
                        break
                    }
                }
                
                ; 檢測登入UI相關文字
                for _, uiKw in loginUIKeywords {
                    if InStr(clean, uiKw) {
                        foundLoginUI := true
                        WriteLog("檢測到登入UI關鍵字: " uiKw " 在文字: " clean)
                        break
                    }
                }

                ; 檢測退出按鈕
                if InStr(clean, kwBtn) && block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3 {
                    x1 := block.boxPoint[1].x, y1 := block.boxPoint[1].y
                    x2 := block.boxPoint[3].x, y2 := block.boxPoint[3].y
                    btnCenter := [ Round((x1 + x2) / 2), Round((y1 + y2) / 2) ]
                }
                
                ; 檢測確認按鈕（確認、确认、確定、确定）
                if (InStr(clean, "確認") || InStr(clean, "确认") || InStr(clean, "確定") || InStr(clean, "确定")) && 
                   block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3 {
                    x1 := block.boxPoint[1].x, y1 := block.boxPoint[1].y
                    x2 := block.boxPoint[3].x, y2 := block.boxPoint[3].y
                    btnCenter := [ Round((x1 + x2) / 2), Round((y1 + y2) / 2) ]
                    WriteLog("找到確認按鈕: " clean " 位置: " btnCenter[1] "," btnCenter[2])
                }
            }
        }

        if (foundUpdate && IsObject(btnCenter)) {
            ShowTip("✅ 偵測到更新完成 → 點擊按鈕", 800)
            MouseClick "left", btnCenter[1], btnCenter[2]
            ShowTip("已點擊按鈕，準備重新執行腳本。", 1200)
            WriteStepResult("鳴潮檢測", true, "update")
            return "update"
        }
        
        
        ; ✅ 優化：檢測到登入按鈕相關文字，且超過最小等待時間（30秒）才判定為登入畫面
        if (foundLoginBtn && A_TickCount >= earlyExitDeadline) {
            loginDetected := true
            WriteLog("✅ 檢測到登入畫面（已超過 30 秒啟動時間，找到登入按鈕關鍵字），無需更新，繼續正常流程")
            MuteWutheringAudioAtStartup()
            TryMuteWutheringAudio("檢測到登入畫面後")
            ShowTip("✅ 檢測到登入畫面，無需更新", 1000)
            WriteStepResult("鳴潮檢測", true, "login(btn)")
            return "login"
        }
        
        ; 如果只find到登入UI但沒找到按鈕，也要等待足夠時間再判定
        if (foundLoginUI && A_TickCount >= earlyExitDeadline + 10000) {
            loginDetected := true
            WriteLog("⚠️ 檢測到登入UI（伺服器/賬號相關），判定為登入畫面，繼續")
            MuteWutheringAudioAtStartup()
            TryMuteWutheringAudio("檢測到登入UI後")
            ShowTip("✅ 檢測到登入畫面UI，無需更新", 1000)
            WriteStepResult("鳴潮檢測", true, "login(ui)")
            return "login"
        }
        
        Sleep 900
    }

    ShowTip("未檢測到更新或登入畫面，回傳 unknown。", 900)
    WriteStepResult("鳴潮檢測", false, "unknown")
    return "unknown"
}

; B) 去抖動主畫面模板比對（背景 client 截圖的右下 ROI）
WaitEscMenuOCR(hwnd, timeoutSec := 120) {
    WriteStep("主畫面模板驗證", "入口 timeout=" timeoutSec "s")

    if !hwnd {
        hwnd := GetWutheringGameHwnd()
        if !hwnd {
            WriteStepResult("主畫面模板驗證", false, "無有效視窗")
            return false
        }
    }

    templateFile := A_ScriptDir "\icon_main.png"

    if !FileExist(templateFile) {
        WriteLog("模板驗證失敗：找不到模板檔 " templateFile, "WARN")
        WriteStepResult("主畫面模板驗證", false, "模板不存在")
        return false
    }

    variations := [30, 40, 50, 60, 80, 100]
    stableNeeded := 2
    stable := 0
    checkIntervalMs := 500

    baselineWidth := 1280
    baselineHeight := 720
    roiWidth := 500
    roiHeight := 140
    roiRightMargin := 0
    roiBottomMargin := 0

    WriteLog("模板驗證參數: mode=background-client template=" templateFile
        " roi=" roiWidth "x" roiHeight " timeout=" timeoutSec "s")

    deadline := A_TickCount + timeoutSec*1000
    lastProgressLog := A_TickCount
    sampleCount := 0
    bestVar := 0
    while (A_TickCount < deadline) {
        sampleCount += 1

        if !WinExist("ahk_id " hwnd) {
            newHwnd := GetWutheringGameHwnd()
            if newHwnd {
                hwnd := newHwnd
                WriteLog("模板驗證期間遊戲視窗句柄已更新: hwnd=" hwnd, "WARN")
            } else {
                Sleep checkIntervalMs
                continue
            }
        }

        try {
            frame := ImagePutBuffer("ahk_id " hwnd)
        } catch as e {
            WriteLog("模板驗證背景截圖失敗: " e.Message, "WARN")
            Sleep checkIntervalMs
            continue
        }

        captureW := frame.width
        captureH := frame.height
        searchFrame := frame
        searchMode := "native"
        ; icon_main.png 是以 1280x720 UI 比例建立。不同電腦可能直接進入 1920/2560 全螢幕，
        ; 先把背景截圖正規化後再比對，避免模板因等比例放大而永遠找不到。
        if (Abs(captureW - baselineWidth) > 8 || Abs(captureH - baselineHeight) > 8) {
            try {
                searchFrame := ImagePutBuffer({Buffer: frame, scale: [baselineWidth, baselineHeight]})
                searchMode := "normalized_1280x720"
            } catch as e {
                WriteLog("模板驗證正規化失敗，退回原尺寸比對: " e.Message, "WARN")
                searchFrame := frame
                searchMode := "native_fallback"
            }
        }

        searchW := searchFrame.width
        searchH := searchFrame.height
        cropW := Min(roiWidth, searchW - roiRightMargin)
        cropH := Min(roiHeight, searchH - roiBottomMargin)
        cropX := searchW - roiRightMargin - cropW
        cropY := searchH - roiBottomMargin - cropH
        if (cropW <= 0 || cropH <= 0 || cropX < 0 || cropY < 0) {
            Sleep checkIntervalMs
            continue
        }

        found := false
        matchedVar := 0
        try {
            roiFrame := searchFrame.Crop(cropX, cropY, cropW, cropH)
            for _, v in variations {
                hit := roiFrame.ImageSearch(templateFile, v)
                if IsValidImagePutSearchHit(hit, roiFrame) {
                    found := true
                    matchedVar := v
                    bestVar := v
                    break
                }
            }
        } catch as e {
            WriteLog("模板驗證背景比對失敗: " e.Message, "WARN")
        }

        if found {
            stable += 1
            ShowTip("✅ 模板偵測 " stable "/" stableNeeded "（Var=" matchedVar "）", 600)
            if (stable >= stableNeeded) {
                WriteStepResult("主畫面模板驗證", true, "樣本=" sampleCount " var=" matchedVar
                    " mode=" searchMode " capture=" captureW "x" captureH)
                return true
            }
        } else {
            stable := 0
        }

        if (A_TickCount - lastProgressLog >= 5000) {
            remainSec := Round((deadline - A_TickCount) / 1000.0, 1)
            WriteLog("模板驗證進行中: 樣本=" sampleCount " 連續命中=" stable "/" stableNeeded
                " 最後Var=" (bestVar ? bestVar : "-") " mode=" searchMode
                " capture=" captureW "x" captureH " 剩餘=" remainSec "s")
            lastProgressLog := A_TickCount
        }

        Sleep checkIntervalMs
    }

    WriteLog("模板驗證超時: 樣本=" sampleCount " 未達連續命中 " stableNeeded, "WARN")
    WriteStepResult("主畫面模板驗證", false, "超時樣本=" sampleCount)
    return false
}

; E) 點擊指定窗口中心
ClickWindowCenter(hwnd) {
    if !hwnd
        return false
    try {
        oldMode := A_CoordModeMouse
        CoordMode "Mouse", "Screen"
        WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
        if (w = "" || h = "" || w <= 0 || h <= 0)
            return false
        cx := x + (w // 2)
        cy := y + (h // 2)
        WriteLog("點擊視窗中心: " cx "," cy)
        MouseClick "left", cx, cy
        return true
    } catch as e {
        WriteLog("點擊視窗中心失敗: " e.Message, "WARN")
        return false
    } finally {
        if IsSet(oldMode)
            CoordMode "Mouse", oldMode
    }
}

; F) 取得並啟動鳴潮路徑（可記憶）
EnsureWutheringRunning() {
    global WUTHERING_STARTUP_WAIT_SEC

    WriteStep("啟動鳴潮", "入口")

    ; ✅ 只檢查遊戲進程是否存在，不檢查視窗尺寸
    ;    這樣防止因視窗最小化而誤判為「遊戲未運行」
    if (IsWutheringProcessRunning()) {
        WriteStepResult("啟動鳴潮", true, "進程已存在")
        return true
    }
    
    path := GetPathWithAsk("WUTHERING", "請選擇鳴潮遊戲主程式或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
    if (!path) {
        WriteLog("未設定鳴潮路徑，無法啟動", "ERROR")
        MsgBox "未設定鳴潮遊戲路徑。請重新執行並選擇。"
        WriteStepResult("啟動鳴潮", false, "未設定路徑")
        ExitApp
    }
    WriteLog("啟動鳴潮: " path)
    ShowTip("🎮 正在啟動鳴潮...", 1500)
    try Run(path)
    catch as e {
        WriteLog("啟動鳴潮失敗: " e.Message, "ERROR")
        ShowTip("❌ 鳴潮啟動失敗", 1500)
        WriteStepResult("啟動鳴潮", false, "Run失敗")
        return false
    }

    ShowTip("⏳ 等待鳴潮進程初始化...", 1500)
    if !WaitForProcessRunning("Client-Win64-Shipping.exe", WUTHERING_STARTUP_WAIT_SEC) {
        WriteLog("鳴潮啟動後逾時，未偵測到進程（" WUTHERING_STARTUP_WAIT_SEC " 秒）", "ERROR")
        ShowTip("❌ 鳴潮啟動逾時", 1800)
        WriteStepResult("啟動鳴潮", false, "進程逾時")
        return false
    }

    ; 給初始化中的視窗一點緩衝，避免剛啟動就誤判 no_window。
    Sleep 2000
    WriteLog("已偵測到鳴潮進程，繼續後續視窗檢測")
    WriteStepResult("啟動鳴潮", true, "進程已就緒")
    return true
}

LaunchWutheringGameFlowAfterUpdate() {
    WriteLog("準備重新執行鳴潮啟動流程（更新後視窗逾時）")
    ShowTip("🎮 重新啟動鳴潮中...", 1500)

    try ProcessClose("Client-Win64-Shipping.exe")
    catch
        try Run("taskkill /F /IM Client-Win64-Shipping.exe", , "Hide")

    Sleep 1500
    return EnsureWutheringRunning()
}

; ✅ 只檢查遊戲進程是否存在
IsWutheringProcessRunning() {
    global PROCESS_DETECT_RETRY_COUNT, PROCESS_DETECT_RETRY_DELAY_MS

    Loop PROCESS_DETECT_RETRY_COUNT {
        hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe ahk_class UnrealWindow")
        if (hwndList.Length > 0)
            return true

        hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe")
        if (hwndList.Length > 0)
            return true

        if (A_Index < PROCESS_DETECT_RETRY_COUNT)
            Sleep PROCESS_DETECT_RETRY_DELAY_MS
    }

    return false
}

WaitForProcessRunning(exeName, timeoutSec := 30) {
    deadline := A_TickCount + timeoutSec * 1000
    while (A_TickCount < deadline) {
        if ProcessExist(exeName)
            return true

        ; 有些遊戲在初始化期間會先有視窗再穩定到指定 exe，這裡一起判斷。
        if (exeName = "Client-Win64-Shipping.exe") {
            hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe")
            if (hwndList.Length > 0)
                return true
        }

        Sleep 500
    }

    return false
}

GetWutheringGameHwnd() {
    ; ✅ 優先條件：執行程序 + UnrealWindow 類別（完全初始化的遊戲視窗）
    hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe ahk_class UnrealWindow")
    if (hwndList.Length > 0) {
        hwnd := hwndList[1]
        if (IsValidGameWindow(hwnd))
            return hwnd
    }

    ; ⚠️ 回退：部分環境 class 可能不同，但需驗證視窗有效性
    ;   這個回退會延遲遊戲啟動的判定，避免找到臨時初始化視窗
    hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe")
    if (hwndList.Length > 0) {
        for hwnd in hwndList {
            if (IsValidGameWindow(hwnd))
                return hwnd
        }
    }

    return 0
}

; ✅ 驗證視窗是否為真正的遊戲視窗（而非臨時初始化視窗）
IsValidGameWindow(hwnd) {
    if !hwnd
        return false
    
    ; 檢查視窗是否存在
    if !WinExist("ahk_id " hwnd)
        return false
    
    ; 取得視窗寬高
    try WinGetPos , , &w, &h, "ahk_id " hwnd
    catch {
        return false
    }
    
    ; 檢查視窗有合理的尺寸（排除 0x0 或異常小的初始化視窗）
    ; 遊戲視窗通常至少 800x600
    if (w < 800 || h < 600) {
        return false
    }
    
    ; ✅ 視窗有效
    return true
}

WaitForWutheringGameWindow(timeoutSec := 120) {
    deadline := A_TickCount + timeoutSec * 1000
    while (A_TickCount < deadline) {
        hwnd := GetWutheringGameHwnd()
        if hwnd
            return hwnd
        Sleep 300
    }
    return 0
}

EnsureCoreProgramPathsAtStartup() {
    return EnsureAllConfigAtStartup(false, "啟動前檢查核心程式路徑")
}

GetPathWithAsk(key, prompt, filter) {
    global CFG_FILE
    path := NormalizePath(IniReadSafe(CFG_FILE, "paths", key, ""))
    if (path != "" && FileExist(path))
        return path

    WriteLog("路徑未設定或檔案不存在，打開整合設定視窗: " key, "WARN")
    ShowTip("📂 路徑缺失，請完成設定", 1200)
    EnsureAllConfigAtStartup(false, "偵測到路徑缺失或失效（" key "）")

    path := NormalizePath(IniReadSafe(CFG_FILE, "paths", key, ""))
    if (path != "" && FileExist(path))
        return path

    WriteLog("整合設定後仍無有效路徑: " key, "ERROR")
    return path
}

AskPathGui(prompt, defaultPath := "", filter := "All Files (*.*)", force := false) {
    sel := { path: "", keep: 0 }
    g := Gui("+AlwaysOnTop -MinimizeBox", prompt)
    g.SetFont("s10")
    g.Add("Text", "xm ym", "執行檔路徑：")
    e := g.AddEdit("xm w520 vPATH", defaultPath)
    b := g.AddButton("x+m w90", "瀏覽...")
    b.OnEvent("Click", (*) => FileBrowse())
    cb := g.AddCheckbox("xm vKEEP", "下次不再詢問")
    ok := g.AddButton("xm w120 Default", "確定")
    cancel := g.AddButton("x+m w90", "取消")
    ok.OnEvent("Click", (*) => Confirm())
    cancel.OnEvent("Click", (*) => CancelSel())
    g.Show("AutoSize Center")
    WinWaitClose g.Hwnd
    return sel

    FileBrowse() {
        ShowTip("📂 選擇檔案中...", 1000)
        p := FileSelect(, "", prompt, filter)
        if (p)
            e.Value := p
    }

    Confirm() {
        sel.path := Trim(e.Value)
        sel.keep := cb.Value ? 1 : 0
        ShowTip("✅ 已選擇路徑", 800)
        g.Hide()
    }

    CancelSel() {
        sel.path := ""
        ShowTip("❌ 已取消選擇", 800)
        g.Hide()
    }
}

IniReadSafe(file, section, key, default) {
    try {
        return IniRead(file, section, key, default)
    } catch {
        return default
    }
}

; 獲取工作區域信息（排除工作列）
GetWorkArea() {
    rect := Buffer(16)
    DllCall("SystemParametersInfo", "UInt", 48, "UInt", 0, "Ptr", rect, "UInt", 0) ; SPI_GETWORKAREA
    return {
        left: NumGet(rect, 0, "Int"),
        top: NumGet(rect, 4, "Int"), 
        right: NumGet(rect, 8, "Int"),
        bottom: NumGet(rect, 12, "Int"),
        width: NumGet(rect, 8, "Int") - NumGet(rect, 0, "Int"),
        height: NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int")
    }
}

; C) 將一般狀態的指定窗口貼齊螢幕右上角，不改變原始尺寸或最大化／最小化狀態
MoveWindowTopRight(hwnd, marginX := 0, marginY := 0) {
    if !hwnd {
        WriteLog("MoveWindowTopRight: 無效的視窗句柄", "ERROR")
        return false
    }
    
    ; 嘗試最多3次
    Loop 3 {
        attempt := A_Index
        WriteLog("嘗試移動視窗到右上角 (第 " attempt " 次)...")

        ; 遊戲初始化期間可能重建視窗，舊 hwnd 會瞬間失效，先重新校驗一次。
        if !WinExist("ahk_id " hwnd) {
            newHwnd := GetWutheringGameHwnd()
            if newHwnd {
                WriteLog("原視窗句柄失效，改用新句柄: " newHwnd, "WARN")
                hwnd := newHwnd
            } else {
                WriteLog("目前找不到可用鳴潮視窗句柄，稍後重試", "WARN")
                if (attempt < 3) {
                    Sleep 500
                    continue
                }
                return false
            }
        }

        try {
            windowState := WinGetMinMax("ahk_id " hwnd)
            if (windowState = 1) {
                WriteLog("鳴潮視窗目前為最大化；保留原狀態與尺寸，略過右上角移動")
                return true
            }
            if (windowState = -1) {
                WriteLog("鳴潮視窗目前為最小化；保留原狀態與尺寸，稍後再嘗試移動", "WARN")
                return false
            }

            WinGetPos &x, &y, &w, &h, "ahk_id " hwnd
            if (w = "" || h = "" || w <= 0 || h <= 0) {
                WriteLog("無法取得視窗尺寸: w=" w ", h=" h, "ERROR")
                if (attempt < 3) {
                    Sleep 500
                    continue
                }
                return false
            }

            wa := GetWorkArea()
            newX := wa.right - w - marginX  ; 貼齊工作區右側但保留原寬度
            newY := wa.top + marginY           ; 貼齊工作區上側
            
            WriteLog("移動視窗（保留尺寸）: 從 (" x "," y "," w "," h
                ") 到 (" newX "," newY "," w "," h ")")
            WinMove(newX, newY, , , "ahk_id " hwnd)
            Sleep 300  ; 等待視窗移動完成
            
            ; 驗證位置、尺寸及視窗狀態均符合預期。
            WinGetPos &actualX, &actualY, &actualW, &actualH, "ahk_id " hwnd
            actualState := WinGetMinMax("ahk_id " hwnd)
            positionOk := (Abs(actualX - newX) <= 10 && Abs(actualY - newY) <= 10)
            sizeOk := (Abs(actualW - w) <= 2 && Abs(actualH - h) <= 2)
            stateOk := (actualState = windowState)
            if (positionOk && sizeOk && stateOk) {
                WriteLog("✓ 視窗成功移動到右上角，尺寸與狀態保持不變 ("
                    actualX "," actualY "," actualW "," actualH ")")
                return true
            } else {
                WriteLog("視窗移動驗證未通過：目標位置=(" newX "," newY
                    ") 實際位置=(" actualX "," actualY
                    ") | 原尺寸=" w "x" h " 實際尺寸=" actualW "x" actualH
                    " | 原狀態=" windowState " 實際狀態=" actualState, "WARN")
                if (attempt < 3) {
                    Sleep 500
                    continue
                }
            }
        } catch as e {
            WriteLog("視窗移動失敗: " e.Message, "ERROR")
            if InStr(e.Message, "Target window not found") {
                newHwnd := GetWutheringGameHwnd()
                if newHwnd {
                    WriteLog("移動時句柄失效，重抓新句柄後重試: " newHwnd, "WARN")
                    hwnd := newHwnd
                }
            }
            if (attempt < 3) {
                Sleep 500
                continue
            }
            return false
        }
    }
    
    WriteLog("視窗移動失敗（已達最大重試次數）", "ERROR")
    return false
}

; D) 繁→簡（常見詞）
ToSimp(s) {
    static phrase := Map(
        "終端","终端","活動","活动","商城","商城","喚取","唤取","共鳴者","共鸣者","編隊","编队",
        "教程百科","教程百科","任務","任务","好友","好友","成就","成就","設置","设置","地圖","地图",
        "相機","相机","郵件","邮件","社交","社交","數據","数据","索拉指南","索拉指南","先約電台","先约电台"
    )
    for k, v in phrase
        s := StrReplace(s, k, v)

    static single := Map("終","终","鳴","鸣","隊","队","動","动","設","设","圖","图","編","编","術","术","學","学","裝","装","體","体","導","导","頁","页","數","数","約","约","電","电")
    for k, v in single
        s := StrReplace(s, k, v)

    return s
}

; ======================== 伺服器完成記錄機制 ========================

; 判斷兩個時間是否在同一日循環（上午4點～隔天上午4點）
IsSameDayCircle(time1Str, time2Str) {
    if (time1Str = "" || time2Str = "")
        return false

    try {
        k1 := GetDayCircleKey(time1Str)
        k2 := GetDayCircleKey(time2Str)
        if (k1 = "" || k2 = "") {
            WriteLog("IsSameDayCircle 無法解析時間，t1='" time1Str "' t2='" time2Str "'", "WARN")
            return false
        }
        return (k1 = k2)
    } catch as e {
        WriteLog("IsSameDayCircle 時間判斷失敗: " e.Message, "WARN")
        return false
    }
}

NormalizeCycleTimeString(timeStr) {
    s := Trim(timeStr, " `t`r`n")
    s := Trim(s, "　")  ; 全形空白
    if (s = "")
        return ""

    ; 支援 2026-06-29 12:38:13 / 2026/06/29 12:38:13 / 2026-06-29 12:38:13,789
    if RegExMatch(s, "(\d{4})[-/\.](\d{2})[-/\.](\d{2})[ T](\d{2}):(\d{2}):(\d{2})", &m)
        return m[1] m[2] m[3] m[4] m[5] m[6]

    ; 支援 A_Now 格式
    if RegExMatch(s, "^(\d{14})$", &m)
        return m[1]

    return ""
}

GetDayCircleKey(timeStr) {
    ts := NormalizeCycleTimeString(timeStr)
    if (ts = "")
        return ""

    HH := SubStr(ts, 9, 2)

    ; 上午 4 點前算前一天循環
    if (Integer(HH) < 4)
        ts := DateAdd(ts, -1, "Days")

    return SubStr(ts, 1, 8)
}

; 檢查伺服器是否在當日循環已完成
IsServerCompletedInCurrentCycle(server, currentTime := "") {
    global SERVER_COMPLETED_CYCLE_MAP, CFG_FILE
    
    if (server = "")
        return false
    
    if (currentTime = "")
        currentTime := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    
    ; 首先檢查內存 Map
    if SERVER_COMPLETED_CYCLE_MAP.Has(server) {
        completedTime := SERVER_COMPLETED_CYCLE_MAP[server]
        if (completedTime != "") {
            if IsSameDayCircle(completedTime, currentTime) {
                WriteLog("伺服器『" server "』已在當日循環完成過（完成於 " completedTime "）", "INFO")
                return true
            } else {
                WriteLog("伺服器『" server "』的完成時間不在當日循環（完成於 " completedTime "）", "INFO")
                return false
            }
        }
    }
    
    ; 檢查設定檔
    savedTime := Trim(IniReadSafe(CFG_FILE, "server_completed", server, ""), " `t`r`n")
    if (savedTime != "") {
        if IsSameDayCircle(savedTime, currentTime) {
            SERVER_COMPLETED_CYCLE_MAP[server] := savedTime
            WriteLog("伺服器『" server "』已在當日循環完成過（從設定檔讀取，完成於 " savedTime "）", "INFO")
            return true
        } else {
            WriteLog("伺服器『" server "』的完成時間不在當日循環（從設定檔讀取，完成於 " savedTime "）", "INFO")
            return false
        }
    }
    
    return false
}

; 標記伺服器為當日循環已完成
MarkServerCompletedInCurrentCycle(server, completedTime := "") {
    global SERVER_COMPLETED_CYCLE_MAP, CFG_FILE
    
    if (server = "")
        return false
    
    if (completedTime = "")
        completedTime := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    
    SERVER_COMPLETED_CYCLE_MAP[server] := completedTime
    try {
        IniWrite completedTime, CFG_FILE, "server_completed", server
        WriteLog("已標記伺服器『" server "』為當日循環完成（時間: " completedTime "）", "INFO")
        return true
    } catch as e {
        WriteLog("標記伺服器『" server "』完成時寫入設定檔失敗: " e.Message, "WARN")
        return false
    }
}

IsLrmcRunResumeReady() {
    global CFG_FILE
    return IniReadSafe(CFG_FILE, "lrmc_runtime", "run_started", "0") = "1"
}

GetLrmcRunStateSummary() {
    global CFG_FILE
    started := IniReadSafe(CFG_FILE, "lrmc_runtime", "run_started", "0")
    startedTime := Trim(IniReadSafe(CFG_FILE, "lrmc_runtime", "run_started_time", ""), " `t`r`n")
    startMode := Trim(IniReadSafe(CFG_FILE, "lrmc_runtime", "start_mode", ""), " `t`r`n")
    detail := "run_started=" started
    if (startedTime != "")
        detail .= " time=" startedTime
    if (startMode != "")
        detail .= " mode=" startMode
    return detail
}

SetLrmcRunResumeReady(ready, detail := "") {
    global CFG_FILE
    readyValue := ready ? "1" : "0"
    IniWrite readyValue, CFG_FILE, "lrmc_runtime", "run_started"
    IniWrite detail, CFG_FILE, "lrmc_runtime", "last_state_detail"
    if !ready {
        IniWrite "", CFG_FILE, "lrmc_runtime", "run_started_time"
        IniWrite "", CFG_FILE, "lrmc_runtime", "start_mode"
    }
    WriteLog("LRMCAI 可接續狀態=" readyValue (detail != "" ? " | " detail : ""))
}

CaptureRestartProcessSnapshot() {
    gameState := ProcessExist("Client-Win64-Shipping.exe") ? "running" : "missing"
    lrmcState := ProcessExist("LRMCAI.exe") ? "running" : "missing"
    okwwState := GetOkwwRuntimeSnapshotState()
    return "game=" gameState ", lrmc=" lrmcState ", okww=" okwwState
}

GetOkwwRuntimeSnapshotState() {
    try {
        wmi := ComObjGet("winmgmts:")
        query := "Select ProcessId, Name, CommandLine from Win32_Process where Name='pythonw.exe'"
        for proc in wmi.ExecQuery(query) {
            pid := proc.ProcessId + 0
            cmdLine := ""
            try cmdLine := proc.CommandLine
            if IsOkwwPythonProcess(pid, cmdLine)
                return "running(host=pythonw.exe,pid=" pid ")"
        }
    } catch as e {
        WriteLog("建立重啟快照時掃描 OKWW pythonw 失敗：" e.Message, "WARN")
    }

    launcherPid := ProcessExist("ok-ww.exe")
    if launcherPid
        return "running(host=ok-ww.exe,pid=" launcherPid ")"

    return "missing"
}

RequestRestart(reason, level := "ERROR", resumeLrmc := false, reasonCode := "UNSPECIFIED", stage := "未指定") {
    global LAST_RESTART_REASON, LAST_RESTART_CODE, LAST_RESTART_STAGE, LAST_RESTART_RECOVERY
    global LAST_RESTART_PROCESS_SNAPSHOT, LAST_RESTART_LRMC_STATE, CRASH_RESTART_MODE

    reason := Trim(reason, " `t`r`n")
    if (reason = "")
        reason := "未提供"
    reasonCode := Trim(reasonCode, " `t`r`n")
    if (reasonCode = "")
        reasonCode := "UNSPECIFIED"
    stage := Trim(stage, " `t`r`n")
    if (stage = "")
        stage := "未指定"

    LAST_RESTART_REASON := reason
    LAST_RESTART_CODE := reasonCode
    LAST_RESTART_STAGE := stage
    LAST_RESTART_PROCESS_SNAPSHOT := CaptureRestartProcessSnapshot()
    LAST_RESTART_LRMC_STATE := GetLrmcRunStateSummary()

    canResume := resumeLrmc && IsLrmcRunResumeReady()
    CRASH_RESTART_MODE := canResume
    if canResume {
        LAST_RESTART_RECOVERY := "LRMCAI快捷鍵接續（resume）"
    } else {
        LAST_RESTART_RECOVERY := (resumeLrmc
            ? "要求接續但無有效已開始標記，降級為一般完整重跑"
            : "一般完整重跑")
        SetLrmcRunResumeReady(false, "重啟不使用接續模式 | code=" reasonCode)
    }

    detail := "code=" reasonCode " | stage=" stage " | recovery=" LAST_RESTART_RECOVERY
    detail .= " | lrmc=" LAST_RESTART_LRMC_STATE " | processes=" LAST_RESTART_PROCESS_SNAPSHOT
    detail .= " | reason=" reason
    WriteLog("觸發重啟請求：" detail, level)
    WriteStep("重啟請求", detail, level)
    RestartAutoScript(reason)
}

; 重啟全自動腳本（帶重啟計數與重啟原因）
RestartAutoScript(reason := "") {
    global CFG_FILE, restartCount, MAX_RESTART_COUNT, LAST_RESTART_REASON, LAST_RESTART_CODE, LAST_RESTART_STAGE
    global LAST_RESTART_RECOVERY, LAST_RESTART_PROCESS_SNAPSHOT, LAST_RESTART_LRMC_STATE
    global CRASH_RESTART_MODE, __RESTART_IN_PROGRESS, __NEXTSERVER_RESTART, MAIL_NOTIFY_ENABLED

    reason := Trim(reason, " `t`r`n")
    if (reason = "")
        reason := Trim(LAST_RESTART_REASON, " `t`r`n")
    if (reason = "")
        reason := "未提供"

    __RESTART_IN_PROGRESS := true
    __NEXTSERVER_RESTART := false
    
    ; 增加重啟計數
    restartCount++
    nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    WriteLog("準備重啟全自動腳本，第 " restartCount " 次重啟，原因: " reason, "WARN")
    WriteStep("重啟流程", "第 " restartCount " 次 | " reason, "WARN")

    ; 記錄最近一次重啟原因，供下一次啟動追蹤
    IniWrite reason, CFG_FILE, "restart_tracking", "last_restart_reason"
    IniWrite nowText, CFG_FILE, "restart_tracking", "last_restart_time"
    IniWrite LAST_RESTART_CODE, CFG_FILE, "restart_tracking", "last_restart_code"
    IniWrite LAST_RESTART_STAGE, CFG_FILE, "restart_tracking", "last_restart_stage"
    IniWrite LAST_RESTART_RECOVERY, CFG_FILE, "restart_tracking", "last_restart_recovery"
    IniWrite LAST_RESTART_PROCESS_SNAPSHOT, CFG_FILE, "restart_tracking", "last_restart_process_snapshot"
    IniWrite LAST_RESTART_LRMC_STATE, CFG_FILE, "restart_tracking", "last_restart_lrmc_state"
    
    ; 檢查是否超過最大重啟次數
    if (restartCount > MAX_RESTART_COUNT) {
        WriteLog("重啟次數已達上限 (" MAX_RESTART_COUNT ")，停止重啟以避免無限循環。最後原因: " reason, "ERROR")
        WriteStep("重啟流程", "超過上限，停止重啟", "ERROR")
        ShowTip("❌ 重啟次數過多，停止執行", 5000)

        ; 這條路徑已不會再啟動下一個腳本，必須切回正常終止模式並完成錄影收尾。
        ; 否則 OnExit 會把它誤認成重啟交接，留下 FFmpeg 持續錄影或遭外力中止後損壞檔案。
        __RESTART_IN_PROGRESS := false
        __NEXTSERVER_RESTART := false
        try SetTimer(CrashWatcherTick, 0)
        SetLrmcRunResumeReady(false, "重啟次數達上限")
        ForceStopManagedScreenRecording("重啟次數達上限")

        Sleep 5000
        ; 重置計數器
        IniWrite "0", CFG_FILE, "restart_tracking", "auto_restart_count"
        ExitApp
    }
    
    ; 儲存重啟計數
    IniWrite restartCount, CFG_FILE, "restart_tracking", "auto_restart_count"

    ; 檢查當前伺服器是否已在當日循環完成過
    global CURRENT_SERVER_TARGET, SERVER_SCHEDULE_ENABLED
    if (SERVER_SCHEDULE_ENABLED && CURRENT_SERVER_TARGET != "") {
        if IsServerCompletedInCurrentCycle(CURRENT_SERVER_TARGET) {
            WriteLog("伺服器『" CURRENT_SERVER_TARGET "』已在當日循環完成過，將跳過重新執行該伺服器，轉到下一個伺服器", "WARN")
            WriteStep("重啟流程", "當前伺服器已完成，嘗試切換下一服", "WARN")
            ShowTip("⏭️ 伺服器已完成，轉向下一個", 2000)
            Sleep 2000
            
            ; 嘗試切換到下一個伺服器
            if AdvanceServerScheduleForNextCycle() {
                WriteLog("已切換到下一個伺服器，使用 nextserver 模式重啟", "WARN")
                WriteStep("重啟流程", "nextserver 模式重啟", "WARN")
                __NEXTSERVER_RESTART := true
                WriteLog("nextserver 重啟：保留錄影不中斷，略過停止錄影", "WARN")
                SetLrmcRunResumeReady(false, "錯誤後改切換下一伺服器")
                CheckAndCloseExistingProcesses()
                Sleep 2000
                
                try {
                    global AhkExe
                    restartCmd := '"' AhkExe '" "' A_ScriptFullPath '" nextserver'
                    Run(restartCmd)
                    WriteLog("nextserver 重啟命令已發送")
                    WriteStep("重啟流程", "nextserver 命令已發送")
                } catch as e {
                    WriteLog("nextserver 重啟失敗: " e.Message, "ERROR")
                    WriteStep("重啟流程", "nextserver 重啟失敗 | " e.Message, "ERROR")
                }
                Sleep 1000
                ExitApp
            } else {
                WriteLog("無更多伺服器可切換，停止執行", "WARN")
                WriteStep("重啟流程", "無更多伺服器可切換，停止", "WARN")
                ShowTip("✅ 所有伺服器今日循環已完成", 3000)
                Sleep 3000
                ExitApp
            }
        }
    }
    
    ; 關閉所有相關進程
    WriteLog("關閉所有相關進程...")
    WriteStep("重啟流程", "關閉相關進程")
    CheckAndCloseExistingProcesses()
    
    Sleep 3000
    
    ; 重新啟動腳本
    WriteLog("重新啟動全自動腳本...")
    WriteStep("重啟流程", "送出 restart 命令")
    try {
        global AhkExe
        restartCmd := '"' AhkExe '" "' A_ScriptFullPath '" restart'
        if (CRASH_RESTART_MODE)
            restartCmd .= ' resume'
        Run(restartCmd)
        WriteLog("重啟命令已發送")
        WriteStep("重啟流程", "restart 命令已發送")
    } catch as e {
        WriteLog("重啟失敗: " e.Message, "ERROR")
        WriteStep("重啟流程", "重啟失敗 | " e.Message, "ERROR")
    }
    
    ; 結束當前進程
    Sleep 1000
    ExitApp
}

MonitorRewardAndShutdown() {
    global REWARD_LOG_FILE, REWARD_START_DELAY_MS, REWARD_CHECK_INTERVAL_MS, REWARD_SHUTDOWN_DELAY_MS
    global REWARD_MATCH_NEED_COUNT, REWARD_INVALID_HWND_NEED_COUNT, REWARD_LOG_RECENT_WINDOW_SEC
    global REMOTE_CONTROL_ACTIVE, __REWARD_MONITOR_ACTIVE, __REWARD_MONITOR_COMPLETION_PENDING
    global SERVER_SCHEDULE_ENABLED, CURRENT_SERVER_TARGET

    logPath := ResolveRewardLogPath()
    if (logPath = "") {
        WriteLog("收尾監測未設定日誌檔，跳過監測", "WARN")
        WriteStep("收尾監測", "未設定日誌檔，略過", "WARN")
        return
    }

    if !FileExist(logPath) {
        WriteLog("收尾監測找不到日誌檔: " logPath, "WARN")
        WriteStep("收尾監測", "找不到日誌檔，略過", "WARN")
        return
    }

    initialPos := GetLogFileLength(logPath)
    state := LoadRewardMonitorRuntimeState(logPath, initialPos)
    startDelaySec := Round(REWARD_START_DELAY_MS / 1000)
    warmupDeadline := state.pendingReason != "" ? A_TickCount : A_TickCount + REWARD_START_DELAY_MS
    warmupFinishedLogged := (warmupDeadline <= A_TickCount)
    pausedLogged := false
    pendingPauseLogged := false
    pendingWarmupLogged := false

    __REWARD_MONITOR_ACTIVE := true
    __REWARD_MONITOR_COMPLETION_PENDING := (state.pendingReason != "")
    try {
        WriteLog("收尾監測已建立日誌游標，起始偏移: " state.lastPos "；暖機 " startDelaySec " 秒期間仍持續讀取並保存新增命中: " logPath)
        WriteStep("收尾監測", "持續讀取新增日誌；暖機 " startDelaySec " 秒")
        ShowTip("🧭 收尾監測已啟動（暖機中）", 1200)

        if state.restored {
            WriteLog("收尾監測已還原持久狀態：hit=" state.hit
                " noReward=" (state.seenNoReward ? "1" : "0")
                " daily=" (state.seenDailyRewardSuccess ? "1" : "0")
                " solaraFail=" (state.seenSolaraRewardFail ? "1" : "0")
                " invalidHwnd=" state.invalidHwndHits
                " pending=" (state.pendingReason != "" ? state.pendingReason : "無"))
        }

        loop {
            paused := REMOTE_CONTROL_ACTIVE && RC_IsPaused()
            warmupFinished := (A_TickCount >= warmupDeadline)

            if paused {
                if !pausedLogged {
                    pausedLogged := true
                    WriteLog("收尾監測：遠端已暫停；僅持續讀取並持久保存 LRMCAI 日誌，不執行點擊、復原、重啟或關閉", "WARN")
                    WriteStep("收尾監測", "PAUSE期間保持被動讀檔", "WARN")
                }
            } else if pausedLogged {
                pausedLogged := false
                pendingPauseLogged := false
                WriteLog("收尾監測：收到 RUN，恢復主動檢查與安全收尾")
            }

            lastPos := state.lastPos
            chunk := ReadLogAppended(logPath, &lastPos)
            state.lastPos := lastPos
            if (chunk != "") {
                stateChanged := false
                for line in StrSplit(chunk, "`n") {
                    line := Trim(line, "`r`t ")
                    if (line = "")
                        continue

                    if !IsRecentRewardMonitorLogLine(line, REWARD_LOG_RECENT_WINDOW_SEC)
                        continue

                    ; 暫停時只解析並保存命中，不做錄影、視窗、程序等外部動作。
                    if (!paused && warmupFinished && !(REMOTE_CONTROL_ACTIVE && RC_IsPaused()))
                        TryStopScreenRecordingByLrmcTaskLine(line)

                    if IsInvalidWindowHandleLogLine(line) {
                        state.invalidHwndHits += 1
                        state.lastInvalidHwndLine := line
                        stateChanged := true
                        WriteLog("監測命中『無效視窗控制代碼』累計次數: " state.invalidHwndHits "/" REWARD_INVALID_HWND_NEED_COUNT " | " line, "WARN")
                        if (state.invalidHwndHits = 1 || Mod(state.invalidHwndHits, 3) = 0)
                            WriteStep("收尾監測", "無效視窗控制代碼累計 " state.invalidHwndHits "/" REWARD_INVALID_HWND_NEED_COUNT, "WARN")
                    }

                    if (line ~= "i)(电台.*一键领取|電台.*一鍵領取)") {
                        state.seenClickReward := true
                        state.hit += 1
                        stateChanged := true
                        WriteLog("監測命中『電台_一鍵領取』(" state.hit "/" REWARD_MATCH_NEED_COUNT "): " line
                            (paused ? "【PAUSE期間已保存】" : ""))
                        WriteStep("收尾監測", "命中電台一鍵領取 " state.hit "/" REWARD_MATCH_NEED_COUNT)
                    }

                    if (line ~= "i)(没有奖励能领取|沒有獎勵能領取)") {
                        state.seenNoReward := true
                        stateChanged := true
                        WriteLog("監測命中『沒有獎勵能領取』: " line (paused ? "【PAUSE期間已保存】" : ""))
                    }

                    if (line ~= "i)(领取每日奖励成功|領取每日獎勵成功)") {
                        state.seenDailyRewardSuccess := true
                        stateChanged := true
                        WriteLog("監測命中『領取每日獎勵成功』: " line (paused ? "【PAUSE期間已保存】" : ""))
                    }

                    if (line ~= "i)(索拉奖励领取失败|索拉獎勵領取失敗|索拉獎勵錄取失敗)") {
                        state.seenSolaraRewardFail := true
                        stateChanged := true
                        WriteLog("監測命中『索拉獎勵領取失敗』: " line (paused ? "【PAUSE期間已保存】" : ""))
                    }
                }

                completionReason := GetRewardMonitorCompletionReason(state)
                if (state.pendingReason = "" && completionReason != "") {
                    state.pendingReason := completionReason
                    state.pendingAt := FormatTime(, "yyyy-MM-dd HH:mm:ss")
                    __REWARD_MONITOR_COMPLETION_PENDING := true
                    stateChanged := true
                    WriteLog("收尾監測條件已達成並持久保存：" completionReason
                        (paused ? "；目前為 PAUSE，等待 RUN 後才執行關閉" : ""))
                    WriteStep("收尾監測", "條件已保存：" completionReason)
                    if !paused
                        ShowTip("✅ 收尾條件已達成", 2000)
                }

                ; 命中時連同當下游標立即保存；一般高頻日誌不反覆重寫設定檔。
                if stateChanged
                    SaveRewardMonitorRuntimeState(state)
            }

            ; 解析期間可能收到新的遠端命令，主動操作前重新取得即時狀態。
            paused := REMOTE_CONTROL_ACTIVE && RC_IsPaused()
            if (state.pendingReason != "" && !state.completionRecorded
                && SERVER_SCHEDULE_ENABLED && CURRENT_SERVER_TARGET != "") {
                if MarkServerCompletedInCurrentCycle(CURRENT_SERVER_TARGET, state.pendingAt) {
                    state.completionRecorded := true
                    SaveRewardMonitorRuntimeState(state)
                    WriteLog("收尾條件已達成：已先持久標記伺服器『" CURRENT_SERVER_TARGET "』完成；實際關閉仍遵守 PAUSE", "INFO")
                }
            }

            if (state.pendingReason != "") {
                if paused {
                    if !pendingPauseLogged {
                        pendingPauseLogged := true
                        WriteLog("收尾監測：完成條件已保存，PAUSE期間不關閉程式；將持續讀檔並等待 RUN", "WARN")
                    }
                } else if !warmupFinished {
                    if !pendingWarmupLogged {
                        pendingWarmupLogged := true
                        WriteLog("收尾監測：暖機期間已命中完成條件，狀態已保存；暖機結束後安全收尾")
                    }
                } else {
                    delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                    WriteLog("收尾監測：準備依已保存條件『" state.pendingReason "』於 " delaySec " 秒後關閉")
                    ShowTip("✅ 收尾條件成立，" delaySec "秒後關閉", 2000)
                    if !WaitRewardMonitorForShutdown(REWARD_SHUTDOWN_DELAY_MS, "收尾監測命中後關閉延遲") {
                        WriteLog("收尾關閉延遲期間收到停止指令，已提前結束監測", "WARN")
                        return
                    }

                    ; 從最後一次 PAUSE 判斷到正式進入收尾必須是不可被計時器插入的單一提交點。
                    ; 若 PAUSE 已先被遠端輪詢處理，這裡會延後；若命令在提交後才抵達，
                    ; 主程序會直接完成既有收尾並退出，因此該筆命令不會被錯誤 ACK 成已套用。
                    Critical "On"
                    if (REMOTE_CONTROL_ACTIVE && RC_IsPaused()) {
                        Critical "Off"
                        pendingPauseLogged := false
                        WriteLog("收尾監測：關閉前再次收到 PAUSE，保留完成狀態並延後關閉", "WARN")
                    } else {
                        ClearRewardMonitorRuntimeState(state.key)
                        __REWARD_MONITOR_COMPLETION_PENDING := false
                        try HandleCycleFinishAndShutdown(state.pendingAt)
                        finally Critical "Off"
                        return
                    }
                }
            } else if (!paused && warmupFinished) {
                ; 計時器可能在本輪任何兩行之間套用新的 PAUSE。
                ; 每個外部動作前都重新讀取即時狀態，避免沿用本輪開頭的舊 paused=false。
                activeAllowed := !(REMOTE_CONTROL_ACTIVE && RC_IsPaused())
                if (activeAllowed && state.invalidHwndHits >= REWARD_INVALID_HWND_NEED_COUNT) {
                    WriteLog("偵測到大量無效視窗控制代碼，判定為遊戲閃退，觸發重啟", "ERROR")
                    WriteStep("收尾監測", "無效視窗命中達閾值，觸發重啟", "ERROR")
                    if !(REMOTE_CONTROL_ACTIVE && RC_IsPaused()) {
                        ShowTip("❌ 偵測遊戲閃退，準備重啟流程", 2500)
                        RequestRestart(
                            "LRMCAI 日誌在收尾監測期間累計 " state.invalidHwndHits
                                " 次無效視窗控制代碼；門檻=" REWARD_INVALID_HWND_NEED_COUNT
                                "；最後一行=" state.lastInvalidHwndLine,
                            "ERROR", true, "LRMCAI_INVALID_HWND_BURST", "收尾監測／LRMCAI 日誌")
                        return
                    }
                }

                if !(REMOTE_CONTROL_ACTIVE && RC_IsPaused())
                    TryRecoverLrmcDuringRewardMonitor()

                ; PAUSE 時不執行此檢查；RUN 後才根據當下狀態決定是否復原。
                if (!(REMOTE_CONTROL_ACTIVE && RC_IsPaused())
                    && !WinExist("ahk_exe Client-Win64-Shipping.exe")) {
                    WriteLog("收尾監測期間偵測鳴潮遊戲窗口已消失，判定為遊戲閃退", "ERROR")
                    WriteStep("收尾監測", "鳴潮視窗消失，觸發重啟", "ERROR")
                    if !(REMOTE_CONTROL_ACTIVE && RC_IsPaused()) {
                        ShowTip("❌ 收尾期間鳴潮閃退，準備重啟", 2500)
                        RequestRestart(
                            "收尾監測期間 Client-Win64-Shipping.exe 進程與遊戲視窗消失",
                            "ERROR", true, "GAME_PROCESS_EXITED_DURING_REWARD_MONITOR", "收尾監測")
                        return
                    }
                }

                ; 收尾監測只做背景模板搜尋；不可因每輪輪詢而置頂或切換到鳴潮。
                ; 若實際找到登入按鈕，才會在點擊時啟用鳴潮。
                if !(REMOTE_CONTROL_ACTIVE && RC_IsPaused())
                    ClickTemplateIfFound(A_ScriptDir "\登入.png", true, false)
            }

            if (!warmupFinishedLogged && warmupFinished) {
                warmupFinishedLogged := true
                WriteLog("收尾監測暖機完成；新增日誌在暖機期間已持續讀取並保存")
                WriteStep("收尾監測", "暖機完成，開始主動檢查")
            }

            if !WaitRewardMonitorForShutdown(REWARD_CHECK_INTERVAL_MS, "收尾監測輪詢間隔") {
                WriteLog("收尾監測輪詢間隔期間收到停止指令，已提前結束監測", "WARN")
                return
            }
        }
    } finally {
        __REWARD_MONITOR_ACTIVE := false
    }
}

WaitRewardMonitorForShutdown(totalMs, phase := "") {
    global REMOTE_STOP_IN_PROGRESS, EXITING_FROM_TRAY

    if (totalMs <= 0)
        return true

    deadline := A_TickCount + totalMs
    while (A_TickCount < deadline) {
        if (REMOTE_STOP_IN_PROGRESS || EXITING_FROM_TRAY) {
            if (phase != "")
                WriteLog("等待中止（" phase "）：收到停止/離開請求", "WARN")
            return false
        }

        remain := deadline - A_TickCount
        chunk := (remain > 300) ? 300 : remain
        if (chunk < 1)
            break
        ; 不走全域 Sleep() 的遠端暫停閘門。這個等待只供收尾監測使用，
        ; 讓 PAUSE 期間主流程仍能回到讀檔迴圈；其他流程仍照常被 Sleep() 暫停。
        RawSleep(chunk)
    }

    return !(REMOTE_STOP_IN_PROGRESS || EXITING_FROM_TRAY)
}

GetRewardMonitorStateKey(logPath) {
    global CURRENT_SERVER_TARGET

    cycleKey := GetDayCircleKey(A_Now)
    if (cycleKey = "")
        cycleKey := SubStr(A_Now, 1, 8)
    serverKey := CURRENT_SERVER_TARGET != "" ? CURRENT_SERVER_TARGET : "(single)"
    normalizedLogPath := StrLower(NormalizePath(logPath))
    return cycleKey "|" serverKey "|" normalizedLogPath
}

LoadRewardMonitorRuntimeState(logPath, defaultPos) {
    global CFG_FILE, REWARD_MONITOR_STATE_SECTION

    stateKey := GetRewardMonitorStateKey(logPath)
    state := {
        key: stateKey,
        lastPos: defaultPos,
        hit: 0,
        seenClickReward: false,
        seenNoReward: false,
        seenDailyRewardSuccess: false,
        seenSolaraRewardFail: false,
        invalidHwndHits: 0,
        lastInvalidHwndLine: "",
        pendingReason: "",
        pendingAt: "",
        completionRecorded: false,
        restored: false
    }

    savedKey := Trim(IniReadSafe(CFG_FILE, REWARD_MONITOR_STATE_SECTION, "state_key", ""), " `t`r`n")
    if (savedKey != stateKey) {
        SaveRewardMonitorRuntimeState(state)
        return state
    }

    state.lastPos := ReadRewardMonitorStateInteger("last_pos", defaultPos)
    state.hit := ReadRewardMonitorStateInteger("click_reward_hits", 0)
    state.seenClickReward := ReadRewardMonitorStateBool("seen_click_reward")
    state.seenNoReward := ReadRewardMonitorStateBool("seen_no_reward")
    state.seenDailyRewardSuccess := ReadRewardMonitorStateBool("seen_daily_reward_success")
    state.seenSolaraRewardFail := ReadRewardMonitorStateBool("seen_solara_reward_fail")
    state.invalidHwndHits := ReadRewardMonitorStateInteger("invalid_hwnd_hits", 0)
    state.lastInvalidHwndLine := IniReadSafe(CFG_FILE, REWARD_MONITOR_STATE_SECTION, "last_invalid_hwnd_line", "")
    state.pendingReason := Trim(IniReadSafe(CFG_FILE, REWARD_MONITOR_STATE_SECTION, "pending_reason", ""), " `t`r`n")
    state.pendingAt := Trim(IniReadSafe(CFG_FILE, REWARD_MONITOR_STATE_SECTION, "pending_at", ""), " `t`r`n")
    if (state.pendingReason != "" && state.pendingAt = "")
        state.pendingAt := Trim(IniReadSafe(CFG_FILE, REWARD_MONITOR_STATE_SECTION, "updated_at", ""), " `t`r`n")
    state.completionRecorded := ReadRewardMonitorStateBool("completion_recorded")
    state.restored := true
    return state
}

SaveRewardMonitorRuntimeState(state) {
    global CFG_FILE, REWARD_MONITOR_STATE_SECTION

    try {
        IniWrite state.key, CFG_FILE, REWARD_MONITOR_STATE_SECTION, "state_key"
        IniWrite state.hit, CFG_FILE, REWARD_MONITOR_STATE_SECTION, "click_reward_hits"
        IniWrite state.seenClickReward ? "1" : "0", CFG_FILE, REWARD_MONITOR_STATE_SECTION, "seen_click_reward"
        IniWrite state.seenNoReward ? "1" : "0", CFG_FILE, REWARD_MONITOR_STATE_SECTION, "seen_no_reward"
        IniWrite state.seenDailyRewardSuccess ? "1" : "0", CFG_FILE, REWARD_MONITOR_STATE_SECTION, "seen_daily_reward_success"
        IniWrite state.seenSolaraRewardFail ? "1" : "0", CFG_FILE, REWARD_MONITOR_STATE_SECTION, "seen_solara_reward_fail"
        IniWrite state.invalidHwndHits, CFG_FILE, REWARD_MONITOR_STATE_SECTION, "invalid_hwnd_hits"
        IniWrite state.lastInvalidHwndLine, CFG_FILE, REWARD_MONITOR_STATE_SECTION, "last_invalid_hwnd_line"
        IniWrite state.pendingReason, CFG_FILE, REWARD_MONITOR_STATE_SECTION, "pending_reason"
        IniWrite state.pendingAt, CFG_FILE, REWARD_MONITOR_STATE_SECTION, "pending_at"
        IniWrite state.completionRecorded ? "1" : "0", CFG_FILE, REWARD_MONITOR_STATE_SECTION, "completion_recorded"
        IniWrite FormatTime(, "yyyy-MM-dd HH:mm:ss"), CFG_FILE, REWARD_MONITOR_STATE_SECTION, "updated_at"
        ; 游標最後寫入：若前面的狀態落盤中途失敗，重啟後最多重讀，不會先推進游標而漏掉命中。
        IniWrite state.lastPos, CFG_FILE, REWARD_MONITOR_STATE_SECTION, "last_pos"
        return true
    } catch as e {
        WriteLog("收尾監測持久狀態寫入失敗：" e.Message, "ERROR")
        return false
    }
}

ClearRewardMonitorRuntimeState(expectedKey := "") {
    global CFG_FILE, REWARD_MONITOR_STATE_SECTION

    try {
        savedKey := Trim(IniReadSafe(CFG_FILE, REWARD_MONITOR_STATE_SECTION, "state_key", ""), " `t`r`n")
        if (expectedKey != "" && savedKey != "" && savedKey != expectedKey) {
            WriteLog("收尾監測狀態鍵已變更，略過清除：expected=" expectedKey " actual=" savedKey, "WARN")
            return false
        }

        for key in [
            "state_key", "last_pos", "click_reward_hits", "seen_click_reward", "seen_no_reward",
            "seen_daily_reward_success", "seen_solara_reward_fail", "invalid_hwnd_hits",
            "last_invalid_hwnd_line", "pending_reason", "pending_at", "completion_recorded", "updated_at"
        ]
            IniWrite "", CFG_FILE, REWARD_MONITOR_STATE_SECTION, key
        WriteLog("收尾監測持久狀態已在正式收尾前清除")
        return true
    } catch as e {
        WriteLog("清除收尾監測持久狀態失敗：" e.Message, "WARN")
        return false
    }
}

ReadRewardMonitorStateInteger(key, defaultValue := 0) {
    global CFG_FILE, REWARD_MONITOR_STATE_SECTION

    raw := Trim(IniReadSafe(CFG_FILE, REWARD_MONITOR_STATE_SECTION, key, ""), " `t`r`n")
    if (raw ~= "^\d+$")
        return Integer(raw)
    return defaultValue
}

ReadRewardMonitorStateBool(key) {
    return ReadRewardMonitorStateInteger(key, 0) = 1
}

GetRewardMonitorCompletionReason(state) {
    global REWARD_MATCH_NEED_COUNT

    if (state.hit >= REWARD_MATCH_NEED_COUNT)
        return "電台一鍵領取命中 " state.hit "/" REWARD_MATCH_NEED_COUNT
    if (state.seenClickReward && state.seenNoReward)
        return "一鍵領取＋沒有獎勵能領取"
    if (state.seenDailyRewardSuccess && state.seenNoReward)
        return "每日獎勵成功＋沒有獎勵能領取"
    if (state.seenSolaraRewardFail && state.seenNoReward)
        return "索拉獎勵失敗＋沒有獎勵能領取"
    return ""
}

ResolveRewardLogPath() {
    global CFG_FILE, REWARD_LOG_FILE

    lrmcExe := NormalizePath(IniReadSafe(CFG_FILE, "paths", "LRMC", ""))
    if (lrmcExe != "") {
        lrmcResolved := ResolveLrmcPathForLog(lrmcExe)
        SplitPath lrmcResolved, , &lrmcDir
        if (lrmcDir != "") {
            candidate := lrmcDir "\log\LRMCAI.log"
            if FileExist(candidate) {
                WriteLog("收尾監測日誌路徑（由 LRMC 路徑推導）: " candidate "，來源=" lrmcResolved)
                return candidate
            }

            WriteLog("由 LRMC 路徑推導的日誌不存在，改用後備路徑: " candidate "，來源=" lrmcResolved, "WARN")
        }
    }

    cfgFallback := NormalizePath(IniReadSafe(CFG_FILE, "reward_monitor", "fallback_log_file", ""))
    if (cfgFallback = "") {
        cfgFallback := Trim(REWARD_LOG_FILE, ' "')
        if (cfgFallback != "") {
            try IniWrite cfgFallback, CFG_FILE, "reward_monitor", "fallback_log_file"
            WriteLog("已初始化後備日誌路徑到設定檔: " cfgFallback)
        }
    }

    if (cfgFallback != "") {
        WriteLog("收尾監測使用後備日誌路徑: " cfgFallback, "WARN")
        return cfgFallback
    }

    return ""
}

TryRecoverLrmcDuringRewardMonitor() {
    global REWARD_LRMCAI_RESTART_COOLDOWN_MS, __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK, AhkExe

    if ProcessExist("LRMCAI.exe") {
        __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := 0
        return false
    }

    if (__REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK > 0 && (A_TickCount - __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK) < REWARD_LRMCAI_RESTART_COOLDOWN_MS)
        return false

    if (!IsSet(AhkExe) || AhkExe = "" || !FileExist(AhkExe)) {
        WriteLog("收尾監測：LRMCAI 已退出，但找不到可用 AutoHotkey 執行檔，無法重啟", "ERROR")
        __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := A_TickCount
        return false
    }

    cmd := '"' AhkExe '" "' A_ScriptDir '\開啟LRMC.ahk" resume'
    try {
        Run(cmd)
        __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := A_TickCount
        WriteLog("收尾監測：偵測 LRMCAI 已退出，已用 resume 快捷鍵模式重啟（不走 OCR）", "WARN")
        ShowTip("⚠️ LRMCAI 退出，已自動熱鍵重啟", 1200)
        return true
    } catch as e {
        __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := A_TickCount
        WriteLog("收尾監測：LRMCAI 收尾監測熱鍵重啟失敗: " e.Message, "ERROR")
        return false
    }
}

ResolveLrmcPathForLog(pathVal) {
    p := NormalizePath(pathVal)
    if (p = "")
        return ""

    ; 若設定的是捷徑，先解析到實際目標程式，避免用到開始功能表目錄。
    if (p ~= "i)\.lnk$") {
        try {
            target := "", outDir := "", outArgs := "", outDesc := "", outIcon := "", outIconNum := 0, outRunState := 0
            FileGetShortcut p, &target, &outDir, &outArgs, &outDesc, &outIcon, &outIconNum, &outRunState
            target := NormalizePath(target)
            if (target != "") {
                WriteLog("LRMC 捷徑已解析：" p " -> " target)
                return target
            }

            if (outDir != "") {
                candidateExe := NormalizePath(outDir "\\LRMCAI.exe")
                if FileExist(candidateExe) {
                    WriteLog("LRMC 捷徑目標為空，改用捷徑工作目錄推導：" candidateExe, "WARN")
                    return candidateExe
                }
            }

            WriteLog("LRMC 捷徑解析失敗，沿用原路徑：" p, "WARN")
            return p
        } catch as e {
            WriteLog("LRMC 捷徑解析例外，沿用原路徑：" p "，" e.Message, "WARN")
            return p
        }
    }

    return p
}

GetLogFileLength(filePath) {
    try {
        f := FileOpen(filePath, "r")
        if !IsObject(f)
            return 0

        size := f.Length
        f.Close()
        return size
    } catch {
        return 0
    }
}

ReadLogAppended(filePath, &lastPos) {
    try {
        f := FileOpen(filePath, "r")
        if !IsObject(f)
            return ""

        size := f.Length

        ; 日誌輪替或被截斷時，從頭重新讀
        if (size < lastPos)
            lastPos := 0

        if (size = lastPos) {
            f.Close()
            return ""
        }

        f.Pos := lastPos
        txt := f.Read()
        lastPos := size
        f.Close()

        return txt
    } catch {
        return ""
    }
}

ExtractLogTimestampToA_NowFormat(line) {
    ; 支援格式：
    ; 1) YYYY-MM-DD HH:MM:SS [LEVEL] ...
    ; 2) YYYY-MM-DD HH:MM:SS,mmm - LRMCAI - INFO - ...
    if RegExMatch(line, "^\s*(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})(?:[\.,]\d{1,6})?", &m)
        return m[1] m[2] m[3] m[4] m[5] m[6]
    return ""
}

IsRecentRewardMonitorLogLine(line, maxAgeSec := 3600) {
    ts := ExtractLogTimestampToA_NowFormat(line)
    if (ts = "")
        return false

    try {
        ; 正值表示該行時間早於現在；僅接受近期日誌，並容忍最多10秒時鐘漂移
        deltaSec := DateDiff(A_Now, ts, "Seconds")
        return (deltaSec >= -10 && deltaSec <= maxAgeSec)
    } catch {
        return false
    }
}

IsInvalidWindowHandleLogLine(line) {
    return (line ~= "i)(無效(的)?視窗控制代碼|无效(的)?窗口控制代码|无效(的)?视窗控制代码|無效(的)?視窗句柄|无效(的)?窗口句柄|无效(的)?窗口控件句柄|invalid\s+(window\s+)?(handle|hwnd))")
}

ResetRestartTrackingOnFreshStart() {
    global CFG_FILE, restartCount, LAST_RESTART_REASON, LAST_RESTART_CODE, LAST_RESTART_STAGE
    global LAST_RESTART_RECOVERY, LAST_RESTART_PROCESS_SNAPSHOT, LAST_RESTART_LRMC_STATE, CRASH_RESTART_MODE

    restartCount := 0
    LAST_RESTART_REASON := ""
    LAST_RESTART_CODE := ""
    LAST_RESTART_STAGE := ""
    LAST_RESTART_RECOVERY := ""
    LAST_RESTART_PROCESS_SNAPSHOT := ""
    LAST_RESTART_LRMC_STATE := ""
    CRASH_RESTART_MODE := false

    IniWrite "0", CFG_FILE, "restart_tracking", "auto_restart_count"
    IniWrite "", CFG_FILE, "restart_tracking", "last_restart_reason"
    IniWrite "", CFG_FILE, "restart_tracking", "last_restart_time"
    IniWrite "", CFG_FILE, "restart_tracking", "last_restart_code"
    IniWrite "", CFG_FILE, "restart_tracking", "last_restart_stage"
    IniWrite "", CFG_FILE, "restart_tracking", "last_restart_recovery"
    IniWrite "", CFG_FILE, "restart_tracking", "last_restart_process_snapshot"
    IniWrite "", CFG_FILE, "restart_tracking", "last_restart_lrmc_state"
    SetLrmcRunResumeReady(false, "正常首次啟動")
    WriteLog("正常首次啟動：已重置重啟計數器、重啟原因與 LRMCAI 接續狀態")
}

HandleCycleFinishAndShutdown(completedTime := "") {
    ; 標記當前伺服器為已完成（收尾監測完成時才記錄）
    global CURRENT_SERVER_TARGET, SERVER_SCHEDULE_ENABLED
    if (SERVER_SCHEDULE_ENABLED && CURRENT_SERVER_TARGET != "") {
        ; 使用實際命中時間，不用恢復 RUN 後的當下時間覆寫。
        ; 如 PAUSE 跨過凌晨 4 點，仍會歸到命中當時的正確日循環。
        MarkServerCompletedInCurrentCycle(CURRENT_SERVER_TARGET, completedTime)
    }

    if AdvanceServerScheduleForNextCycle() {
        global __NEXTSERVER_RESTART, __RESTART_IN_PROGRESS
        __RESTART_IN_PROGRESS := true
        __NEXTSERVER_RESTART := true
        WriteLog("伺服器排程：重啟模式保留錄影，不停止目前錄影", "WARN")
        WriteLog("伺服器排程：本輪完成，關閉程式後自動啟動下一個伺服器流程", "WARN")
        ShutdownGameLrmcOkww(true)
        return
    }

    TryStopScreenRecording("收尾監測達標（保底停止）")
    ShutdownGameLrmcOkww(false)
}

ShutdownGameLrmcOkww(relaunchForNextServer := false) {
    global __RESTART_IN_PROGRESS
    SetLrmcRunResumeReady(false, relaunchForNextServer ? "切換下一伺服器" : "正常／手動收尾")
    if (__RESTART_IN_PROGRESS || relaunchForNextServer)
        WriteLog("重啟模式：保留錄影不中斷，略過收尾保底停止", "WARN")
    else
        ForceStopManagedScreenRecording("手動/收尾關閉流程保底")
    UnmuteWutheringAudio("監測到結束，開始收尾")
    WriteLog("開始關閉收尾目標程式：鳴潮、LRMCAI、OKWW")
    ShowTip("🛑 正在關閉鳴潮/LRMCAI/OKWW...", 1500)

    ; 1) 鳴潮
    try ProcessClose("Client-Win64-Shipping.exe")
    catch
        try Run("taskkill /F /IM Client-Win64-Shipping.exe", , "Hide")
    Sleep 600

    ; 2) LRMCAI
    try ProcessClose("LRMCAI.exe")
    catch
        try Run("taskkill /F /IM LRMCAI.exe", , "Hide")
    Sleep 600

    ; 3) OKWW（主程式 + 更新檢測）
    try ProcessClose("ok-ww.exe")
    catch
        try ProcessClose("OK-WW.exe")
    try Run("taskkill /F /IM ok-ww.exe", , "Hide")
    try Run("taskkill /F /IM OK-WW.exe", , "Hide")
    CloseOkwwPythonProcesses()

    ; 停止監看計時器，避免後續流程再觸發
    try SetTimer(CrashWatcherTick, 0)

    ; 關閉相關 AutoHotkey 管理腳本（保留自己，最後再 ExitApp）
    currentPID := DllCall("GetCurrentProcessId")
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%AutoHotkey%'") {
            if (proc.ProcessId = currentPID)
                continue
            try {
                cmdLine := proc.CommandLine
                if (InStr(cmdLine, "開啟LRMC.ahk") || InStr(cmdLine, "自動開啟OKWW.ahk") || InStr(cmdLine, "聲骸合成.ahk") || InStr(cmdLine, "全自動.ahk"))
                    ProcessClose(proc.ProcessId)
            }
        }
    }

    if MAIL_NOTIFY_ENABLED {
        mailResult := SendShutdownNotifyMail()
        if mailResult.ok
            WriteLog("收尾通知信已寄出")
        else
            WriteLog("收尾通知信寄送失敗: " mailResult.message, "WARN")
    }

    if relaunchForNextServer {
        WriteLog("伺服器排程：準備啟動下一輪流程", "WARN")
        ShowTip("🔁 切換下一個伺服器，準備重啟流程", 2000)
        Sleep 1200
        try Run('"' AhkExe '" "' A_ScriptFullPath '" nextserver')
        catch as e
            WriteLog("啟動下一輪伺服器流程失敗: " e.Message, "ERROR")
    }

    WriteLog("收尾關閉流程已完成，所有流程已停止")
    ShowTip("✅ 已關閉並停止所有流程", 2000)
    Sleep 800
    ExitApp
}

SendShutdownNotifyMail() {
    global CFG_FILE, MAIL_SECTION

    state := ReadCombinedConfigState()
    if state.needSetup {
        WriteLog("收尾寄信前偵測到設定缺漏，重新打開整合設定視窗", "WARN")
        ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, "收尾寄信前偵測到設定有空白或錯誤")
        if !ok
            return { ok: false, message: "使用者取消整合設定" }

        state := ReadCombinedConfigState()
        if state.needSetup
            return { ok: false, message: "設定仍不完整: " state.errorText }
    }

    cfgPath := Trim(CFG_FILE, " `t`r`n")
    section := Trim(MAIL_SECTION, " `t`r`n")
    if (cfgPath = "")
        return { ok: false, message: "CFG_FILE 未設定" }
    if !FileExist(cfgPath)
        return { ok: false, message: "找不到設定檔: " cfgPath }

    smtpHost := Trim(IniRead(cfgPath, section, "smtp_host", ""), " `t`r`n")
    smtpPort := Trim(IniRead(cfgPath, section, "smtp_port", "587"), " `t`r`n")
    smtpUser := Trim(IniRead(cfgPath, section, "smtp_user", ""), " `t`r`n")
    smtpPass := Trim(IniRead(cfgPath, section, "smtp_pass", ""), " `t`r`n")
    if (smtpPass = "")
        smtpPass := Trim(IniRead(cfgPath, section, "smtp_password", ""), " `t`r`n")
    mailFrom := Trim(IniRead(cfgPath, section, "from", ""), " `t`r`n")
    mailTo := Trim(IniRead(cfgPath, section, "to", ""), " `t`r`n")
    subjectPrefix := Trim(IniRead(cfgPath, section, "subject_prefix", "LRMCAI"), " `t`r`n")
    useSsl := Trim(IniRead(cfgPath, section, "use_ssl", "1"), " `t`r`n")

    if (smtpHost = "" || smtpUser = "" || smtpPass = "" || mailFrom = "" || mailTo = "")
        return { ok: false, message: "mail_config.ini 欄位不完整" }
    if !(smtpPort ~= "^\d+$")
        return { ok: false, message: "smtp_port 不是數字: " smtpPort }

    nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    subject := subjectPrefix " 關閉完成通知 " nowText
    body := BuildNotifyMailBody("全自動收尾已完成。", nowText)

    return SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl)
}

SendStartNotifyMail(isRestart := false) {
    global CFG_FILE, MAIL_SECTION

    state := ReadCombinedConfigState()
    if state.needSetup {
        WriteLog("開始寄信前偵測到設定缺漏，重新打開整合設定視窗", "WARN")
        ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, "開始寄信前偵測到設定有空白或錯誤")
        if !ok
            return { ok: false, message: "使用者取消整合設定" }

        state := ReadCombinedConfigState()
        if state.needSetup
            return { ok: false, message: "設定仍不完整: " state.errorText }
    }

    cfgPath := Trim(CFG_FILE, " `t`r`n")
    section := Trim(MAIL_SECTION, " `t`r`n")
    if (cfgPath = "")
        return { ok: false, message: "CFG_FILE 未設定" }
    if !FileExist(cfgPath)
        return { ok: false, message: "找不到設定檔: " cfgPath }

    smtpHost := Trim(IniRead(cfgPath, section, "smtp_host", ""), " `t`r`n")
    smtpPort := Trim(IniRead(cfgPath, section, "smtp_port", "587"), " `t`r`n")
    smtpUser := Trim(IniRead(cfgPath, section, "smtp_user", ""), " `t`r`n")
    smtpPass := Trim(IniRead(cfgPath, section, "smtp_pass", ""), " `t`r`n")
    if (smtpPass = "")
        smtpPass := Trim(IniRead(cfgPath, section, "smtp_password", ""), " `t`r`n")
    mailFrom := Trim(IniRead(cfgPath, section, "from", ""), " `t`r`n")
    mailTo := Trim(IniRead(cfgPath, section, "to", ""), " `t`r`n")
    subjectPrefix := Trim(IniRead(cfgPath, section, "subject_prefix", "LRMCAI"), " `t`r`n")
    useSsl := Trim(IniRead(cfgPath, section, "use_ssl", "1"), " `t`r`n")

    if (smtpHost = "" || smtpUser = "" || smtpPass = "" || mailFrom = "" || mailTo = "")
        return { ok: false, message: "mail_config.ini 欄位不完整" }
    if !(smtpPort ~= "^\d+$")
        return { ok: false, message: "smtp_port 不是數字: " smtpPort }

    nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    subject := subjectPrefix " 開始鋤地通知 " nowText
    body := BuildNotifyMailBody("全自動鋤地流程已開始，請勿登入。", nowText)
    body .= "`r`n提醒：若需要登入，請先執行停止鋤地流程。"

    if (isRestart) {
        restartReason := Trim(IniReadSafe(cfgPath, "restart_tracking", "last_restart_reason", ""), " `t`r`n")
        restartTime := Trim(IniReadSafe(cfgPath, "restart_tracking", "last_restart_time", ""), " `t`r`n")
        restartCount := Trim(IniReadSafe(cfgPath, "restart_tracking", "auto_restart_count", "0"), " `t`r`n")
        restartCode := Trim(IniReadSafe(cfgPath, "restart_tracking", "last_restart_code", "UNSPECIFIED"), " `t`r`n")
        restartStage := Trim(IniReadSafe(cfgPath, "restart_tracking", "last_restart_stage", "未指定"), " `t`r`n")
        restartRecovery := Trim(IniReadSafe(cfgPath, "restart_tracking", "last_restart_recovery", "一般完整重跑"), " `t`r`n")
        restartProcesses := Trim(IniReadSafe(cfgPath, "restart_tracking", "last_restart_process_snapshot", ""), " `t`r`n")
        restartLrmcState := Trim(IniReadSafe(cfgPath, "restart_tracking", "last_restart_lrmc_state", ""), " `t`r`n")
        if (restartReason = "")
            restartReason := "未提供"
        if (restartCode = "")
            restartCode := "UNSPECIFIED"
        if (restartStage = "")
            restartStage := "未指定"
        if (restartRecovery = "")
            restartRecovery := "一般完整重跑"

        body .= "`r`n`r`n【重啟資訊】"
        body .= "`r`n重啟模式：是"
        body .= "`r`n重啟次數：" restartCount
        body .= "`r`n原因代碼：" restartCode
        body .= "`r`n發生階段：" restartStage
        body .= "`r`n詳細原因：" restartReason
        body .= "`r`n恢復策略：" restartRecovery
        if (restartLrmcState != "")
            body .= "`r`nLRMCAI 當時狀態：" restartLrmcState
        if (restartProcesses != "")
            body .= "`r`n當時進程快照：" restartProcesses
        if (restartTime != "")
            body .= "`r`n異常偵測時間：" restartTime
        subject := subjectPrefix " 重啟#" restartCount " [" restartCode "] " nowText
    }

    return SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl)
}

BuildNotifyMailBody(prefixLine, nowText := "") {
    if (nowText = "")
        nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")

    serverInfo := (CURRENT_SERVER_TARGET != "" ? "伺服器：" CURRENT_SERVER_TARGET "`r`n" : "")
    modeInfo := "模式：" (A_Args.Length > 0 ? A_Args[1] : "normal") "`r`n"
    return prefixLine "`r`n時間：" nowText "`r`n主機：" A_ComputerName "`r`n" modeInfo serverInfo "腳本：" A_ScriptFullPath
}

EnsureMailConfigAtStartup() {
    return EnsureAllConfigAtStartup(false, "郵件設定檢查")
}

EnsureAllConfigAtStartup(force := false, reason := "") {
    global CFG_FILE, MAIL_SECTION

    state := ReadCombinedConfigState()
    if (!force && !state.needSetup)
        return true

    if (reason = "")
        reason := "偵測到設定缺漏或錯誤"

    WriteLog("打開整合設定視窗：" reason, "WARN")
    ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, reason)
    if !ok {
        MsgBox "你已取消設定。為了確保流程一致，本次不啟動主流程。", "整合設定", "Iconx"
        ExitApp
    }

    verify := ReadCombinedConfigState()
    if verify.needSetup {
        msg := "儲存後仍有未完成項目：`n" verify.errorText
        MsgBox msg, "整合設定", "Iconx"
        ExitApp
    }

    WriteLog("整合設定檢查完成，繼續主流程")
    return true
}

ReadCombinedConfigState() {
    global CFG_FILE, MAIL_NOTIFY_ENABLED, MAIL_SECTION, REWARD_LOG_FILE, SCREEN_RECORDING_ENABLED, SCREEN_RECORDING_SECTION
    global SCREEN_RECORDING_ENGINE, SCREEN_RECORDING_FFMPEG_EXE, SCREEN_RECORDING_FFMPEG_ARGS, SCREEN_RECORDING_OUTPUT_DIR, SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK, SCREEN_RECORDING_AUTO_STOP_EXTERNAL_FFMPEG
    global SCREEN_RECORDING_SEGMENT_MINUTES, SCREEN_RECORDING_AUTO_MERGE, SCREEN_RECORDING_KEEP_FINAL_COUNT
    global SCREEN_RECORDING_STOP_MODE, SCREEN_RECORDING_STOP_TEMPLATE, SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM, SCREEN_RECORDING_STOP_LRMC_TASK
    global RUNTIME_DIAGNOSTICS_SECTION, RUNTIME_DIAGNOSTICS_ENABLED, RUNTIME_DIAGNOSTICS_INTERVAL_SEC
    global RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT, RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED

    state := {}
    state.okwwPath := NormalizePath(IniReadSafe(CFG_FILE, "paths", "OKWW", ""))
    state.lrmcPath := NormalizePath(IniReadSafe(CFG_FILE, "paths", "LRMC", ""))
    state.wuPath := NormalizePath(IniReadSafe(CFG_FILE, "paths", "WUTHERING", ""))

    state.smtpHost := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "smtp_host", ""), " `t`r`n")
    state.smtpPort := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "smtp_port", "587"), " `t`r`n")
    state.smtpUser := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "smtp_user", ""), " `t`r`n")
    state.smtpPass := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "smtp_pass", ""), " `t`r`n")
    if (state.smtpPass = "")
        state.smtpPass := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "smtp_password", ""), " `t`r`n")
    state.mailFrom := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "from", ""), " `t`r`n")
    state.mailTo := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "to", ""), " `t`r`n")
    state.subjectPrefix := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "subject_prefix", "LRMCAI"), " `t`r`n")
    state.useSsl := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "use_ssl", "1"), " `t`r`n")
    state.sendEnabled := ParseBool01(IniReadSafe(CFG_FILE, MAIL_SECTION, "send_enabled", "1"), 1)
    state.screenRecordingEnabled := ParseBool01(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "enabled", "0"), 0)
    state.screenRecordingEngine := NormalizeScreenRecordingEngine(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "engine", "ffmpeg"))
    state.screenRecordingAllowHotkeyFallback := 0
    state.screenRecordingFfmpegExe := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "ffmpeg_exe", ResolveDefaultScreenRecordingFfmpegExe()))
    if (state.screenRecordingFfmpegExe = "")
        state.screenRecordingFfmpegExe := ResolveDefaultScreenRecordingFfmpegExe()
    state.screenRecordingFfmpegArgs := Trim(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "ffmpeg_args", "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -f matroska"), " `t`r`n")
    if (state.screenRecordingFfmpegArgs = "")
        state.screenRecordingFfmpegArgs := "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -f matroska"
    state.screenRecordingAutoStopExternalFfmpeg := ParseBool01(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "auto_stop_external_ffmpeg", "1"), 1)
    parsedSimple := ParseScreenRecordingSimpleSettingsFromArgs(state.screenRecordingFfmpegArgs)
    state.screenRecordingUseSimpleParams := ParseBool01(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "use_simple_params", "1"), 1)
    state.screenRecordingQualityPreset := NormalizeScreenRecordingQualityPreset(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "quality_preset", parsedSimple.quality))
    state.screenRecordingFps := ToIntRange(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "fps", parsedSimple.fps), parsedSimple.fps, 10, 120)
    state.screenRecordingCrf := ToIntRange(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "crf", parsedSimple.crf), parsedSimple.crf, 0, 51)
    state.screenRecordingOutputDir := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "output_dir", "recordings"))
    if (state.screenRecordingOutputDir = "")
        state.screenRecordingOutputDir := "recordings"
    state.screenRecordingSegmentMinutes := ToIntRange(
        IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "segment_minutes", "5"), 5, 1, 60)
    state.screenRecordingAutoMerge := ParseBool01(
        IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "auto_merge", "1"), 1)
    state.screenRecordingKeepFinalCount := ToIntRange(
        IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "keep_final_count", "5"), 5, 1, 50)
    state.screenRecordingStopMode := NormalizeScreenRecordingStopMode(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_mode", "reward_end"))
    state.screenRecordingStopTemplate := NormalizeScreenRecordingStopTemplate(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_template", "login"))
    state.screenRecordingStopTemplateCustom := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_template_custom", ""))
    state.screenRecordingStopLrmcTask := Trim(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_lrmc_task", ""), " `t`r`n")
    state.serverScheduleEnabled := ParseBool01(IniReadSafe(CFG_FILE, "server_schedule", "enabled", "0"), 0)
    state.serverScheduleList := Trim(IniReadSafe(CFG_FILE, "server_schedule", "list", ""), " `t`r`n")
    state.serverSwitchX := Trim(IniReadSafe(CFG_FILE, "server_schedule", "switch_x", "640"), " `t`r`n")
    state.serverSwitchY := Trim(IniReadSafe(CFG_FILE, "server_schedule", "switch_y", "549"), " `t`r`n")
    state.remoteUid := Trim(IniReadSafe(CFG_FILE, "remote_control", "uid", ""), " `t`r`n")
    state.remoteDeviceAlias := Trim(IniReadSafe(CFG_FILE, "remote_control", "device_alias", ""), " `t`r`n")
    state.remoteDisplayName := Trim(IniReadSafe(CFG_FILE, "remote_control", "display_name", ""), " `t`r`n")
    state.runtimeDiagnosticsEnabled := ParseBool01(
        IniReadSafe(CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION, "enabled", "1"), 1)
    state.runtimeDiagnosticsIntervalSec := ToIntRange(
        IniReadSafe(CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION, "snapshot_interval_sec", "30"), 30, 15, 600)
    state.runtimeDiagnosticsErrorKeepCount := ToIntRange(
        IniReadSafe(CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION, "error_keep_count", "30"), 30, 5, 200)
    state.runtimeDiagnosticsVideoPreviewEnabled := ParseBool01(
        IniReadSafe(CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION, "video_preview_enabled", "1"), 1)
    MAIL_NOTIFY_ENABLED := state.sendEnabled
    SCREEN_RECORDING_ENABLED := state.screenRecordingEnabled
    SCREEN_RECORDING_ENGINE := state.screenRecordingEngine
    SCREEN_RECORDING_FFMPEG_EXE := state.screenRecordingFfmpegExe
    SCREEN_RECORDING_FFMPEG_ARGS := state.screenRecordingFfmpegArgs
    SCREEN_RECORDING_OUTPUT_DIR := state.screenRecordingOutputDir
    SCREEN_RECORDING_SEGMENT_MINUTES := state.screenRecordingSegmentMinutes
    SCREEN_RECORDING_AUTO_MERGE := state.screenRecordingAutoMerge
    SCREEN_RECORDING_KEEP_FINAL_COUNT := state.screenRecordingKeepFinalCount
    SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK := 0
    SCREEN_RECORDING_AUTO_STOP_EXTERNAL_FFMPEG := state.screenRecordingAutoStopExternalFfmpeg
    RUNTIME_DIAGNOSTICS_ENABLED := state.runtimeDiagnosticsEnabled
    RUNTIME_DIAGNOSTICS_INTERVAL_SEC := state.runtimeDiagnosticsIntervalSec
    RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT := state.runtimeDiagnosticsErrorKeepCount
    RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED := state.runtimeDiagnosticsVideoPreviewEnabled
    SCREEN_RECORDING_STOP_MODE := state.screenRecordingStopMode
    SCREEN_RECORDING_STOP_TEMPLATE := state.screenRecordingStopTemplate
    SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM := state.screenRecordingStopTemplateCustom
    SCREEN_RECORDING_STOP_LRMC_TASK := state.screenRecordingStopLrmcTask
    state.fallbackLogFile := NormalizePath(IniReadSafe(CFG_FILE, "reward_monitor", "fallback_log_file", ""))
    if (state.fallbackLogFile = "")
        state.fallbackLogFile := Trim(REWARD_LOG_FILE, ' "')

    err := []
    if (state.okwwPath = "")
        err.Push("OKWW 路徑為空")
    else if !FileExist(state.okwwPath)
        err.Push("OKWW 路徑不存在")

    if (state.lrmcPath = "")
        err.Push("LRMCAI 路徑為空")
    else if !FileExist(state.lrmcPath)
        err.Push("LRMCAI 路徑不存在")

    if (state.wuPath = "")
        err.Push("鳴潮路徑為空")
    else if !FileExist(state.wuPath)
        err.Push("鳴潮路徑不存在")

    if MAIL_NOTIFY_ENABLED {
        if (state.smtpHost = "")
            err.Push("smtp_host 為空")
        if (state.smtpPort = "")
            err.Push("smtp_port 為空")
        else if !(state.smtpPort ~= "^\d+$")
            err.Push("smtp_port 不是數字")
        if (state.smtpUser = "")
            err.Push("smtp_user 為空")
        if (state.smtpPass = "")
            err.Push("smtp_pass 為空")
        if (state.mailFrom = "")
            err.Push("from 為空")
        if (state.mailTo = "")
            err.Push("to 為空")
    }

    if (state.serverScheduleEnabled) {
        listParsed := ParseServerScheduleList(state.serverScheduleList)
        if (listParsed.Length = 0)
            err.Push("server_schedule.list 為空（啟用排程時必填）")
        if !(state.serverSwitchX ~= "^\d+$")
            err.Push("server_schedule.switch_x 不是數字")
        if !(state.serverSwitchY ~= "^\d+$")
            err.Push("server_schedule.switch_y 不是數字")
    }

    state.errors := err
    state.needSetup := (err.Length > 0)
    state.errorText := ""
    for item in err
        state.errorText .= "- " item "`n"

    return state
}

ShowCombinedConfigSetupGui(cfgPath, section, state, reason := "") {
    ; 加寬最小視窗尺寸以容納雙欄
    g := Gui("+Resize +MinSize1550x760", "整合設定（程式路徑 + 郵件通知）")
    g.SetFont("s10", "Microsoft JhengHei UI")

    ; === 頂部共用區域 (全寬) ===
    g.AddText("w1510", "【觸發原因】" reason)
    g.AddText("w1510", "【設定檔位置】" cfgPath)
    g.AddText("w1510", "【說明】以下欄位會載入目前設定，你可以一次全部修改後儲存。")
    g.AddText("w1510", "【路徑要求】三個程式路徑都必須存在；若之後檢測到空白或錯誤，會再次跳出此視窗。")

    summary := "目前偵測值：`r`n"
    summary .= "OKWW: " state.okwwPath "`r`n"
    summary .= "LRMCAI: " state.lrmcPath "`r`n"
    summary .= "鳴潮: " state.wuPath "`r`n"
    summary .= "smtp_host: " state.smtpHost "`r`n"
    summary .= "smtp_port: " state.smtpPort "`r`n"
    summary .= "smtp_user: " state.smtpUser "`r`n"
    summary .= "from: " state.mailFrom "`r`n"
    summary .= "to: " state.mailTo "`r`n"
    summary .= "send_enabled: " (state.sendEnabled ? "1(啟用)" : "0(停用)") "`r`n"
    summary .= "screen_recording.enabled: " (state.screenRecordingEnabled ? "1(啟用)" : "0(停用)") "`r`n"
    summary .= "screen_recording.engine: " state.screenRecordingEngine "`r`n"
    summary .= "screen_recording.allow_hotkey_fallback: " state.screenRecordingAllowHotkeyFallback "`r`n"
    summary .= "screen_recording.use_simple_params: " state.screenRecordingUseSimpleParams "`r`n"
    summary .= "screen_recording.quality_preset: " state.screenRecordingQualityPreset "`r`n"
    summary .= "screen_recording.fps: " state.screenRecordingFps "`r`n"
    summary .= "screen_recording.crf: " state.screenRecordingCrf "`r`n"
    summary .= "screen_recording.ffmpeg_exe: " state.screenRecordingFfmpegExe "`r`n"
    summary .= "screen_recording.ffmpeg_args: " state.screenRecordingFfmpegArgs "`r`n"
    summary .= "screen_recording.auto_stop_external_ffmpeg: " state.screenRecordingAutoStopExternalFfmpeg "`r`n"
    summary .= "screen_recording.output_dir: " state.screenRecordingOutputDir "`r`n"
    summary .= "screen_recording.segment_minutes: " state.screenRecordingSegmentMinutes "`r`n"
    summary .= "screen_recording.auto_merge: " state.screenRecordingAutoMerge "`r`n"
    summary .= "screen_recording.keep_final_count: " state.screenRecordingKeepFinalCount "`r`n"
    summary .= "screen_recording.stop_mode: " state.screenRecordingStopMode "`r`n"
    summary .= "screen_recording.stop_template: " state.screenRecordingStopTemplate "`r`n"
    summary .= "screen_recording.stop_template_custom: " state.screenRecordingStopTemplateCustom "`r`n"
    summary .= "screen_recording.stop_lrmc_task: " state.screenRecordingStopLrmcTask "`r`n"
    summary .= "server_schedule.enabled: " (state.serverScheduleEnabled ? "1(啟用)" : "0(停用)") "`r`n"
    summary .= "server_schedule.list: " state.serverScheduleList "`r`n"
    summary .= "server_schedule.switch: (" state.serverSwitchX "," state.serverSwitchY ")`r`n"
    summary .= "remote_control.device_alias: " state.remoteDeviceAlias "`r`n"
    summary .= "remote_control.display_name: " state.remoteDisplayName "`r`n"
    summary .= "remote_control.uid: " state.remoteUid "`r`n"
    summary .= "runtime_diagnostics.enabled: " state.runtimeDiagnosticsEnabled "`r`n"
    summary .= "runtime_diagnostics.snapshot_interval_sec: " state.runtimeDiagnosticsIntervalSec "`r`n"
    summary .= "runtime_diagnostics.error_keep_count: " state.runtimeDiagnosticsErrorKeepCount "`r`n"
    summary .= "runtime_diagnostics.video_preview_enabled: " state.runtimeDiagnosticsVideoPreviewEnabled "`r`n"
    summary .= "fallback_log_file: " state.fallbackLogFile
    g.AddEdit("xm w1510 r8 ReadOnly", summary)

    if (state.needSetup)
        g.AddEdit("xm y+8 w1510 r4 ReadOnly", "目前需修正：`r`n" state.errorText)

    ; ==========================================
    ; === 左欄開始 (使用 Section 建立錨點) ===
    ; ==========================================
    g.AddText("xm y+15 Section w500", "【基本路徑設定】")

    g.AddText("xs y+12 w95", "OKWW")
    edOkww := g.AddEdit("x+8 w345", state.okwwPath)
    btnOkww := g.AddButton("x+8 w80", "瀏覽...")

    g.AddText("xs y+12 w95", "LRMCAI")
    edLrmc := g.AddEdit("x+8 w345", state.lrmcPath)
    btnLrmc := g.AddButton("x+8 w80", "瀏覽...")

    g.AddText("xs y+12 w95", "鳴潮")
    edWu := g.AddEdit("x+8 w345", state.wuPath)
    btnWu := g.AddButton("x+8 w80", "瀏覽...")

    g.AddText("xs y+12 w95", "後備 log")
    edFallbackLog := g.AddEdit("x+8 w345", state.fallbackLogFile)
    btnFallbackLog := g.AddButton("x+8 w80", "瀏覽...")
    txtFallbackHint := g.AddText("xs y+4 w490 cE6A700", "")

    g.AddText("xs y+28 w450", "【伺服器排程】")
    cbServerScheduleEnabled := g.AddCheckbox("xs y+8 w440", "啟用伺服器排程")
    cbServerScheduleEnabled.Value := state.serverScheduleEnabled ? 1 : 0
    txtServerHint := g.AddText("xs y+4 w440 c666666", state.serverScheduleEnabled ? "目前啟用：會依清單逐一切服並續跑" : "目前停用：維持單伺服器流程")

    g.AddText("xs y+8 w80", "伺服器清單")
    edServerList := g.AddEdit("x+5 w280", state.serverScheduleList)
    btnServerPreview := g.AddButton("x+5 w70", "預覽")

    g.AddText("xs y+8 w80", "切服座標")
    edServerSwitchX := g.AddEdit("x+5 w50", state.serverSwitchX)
    g.AddText("x+5 w15", ",")
    edServerSwitchY := g.AddEdit("x+5 w50", state.serverSwitchY)
    g.AddText("x+10 w115 c666666", "預設(640,549)")

    g.AddText("xs y+22 w450", "【郵件設定】")
    cbSendEnabled := g.AddCheckbox("xs y+8 w440", "啟用收尾通知寄信")
    cbSendEnabled.Value := state.sendEnabled ? 1 : 0
    txtMailHint := g.AddText("xs y+4 w440 c666666", state.sendEnabled ? "目前啟用寄信：需填寫 SMTP 欄位" : "目前停用寄信：可略過 SMTP 欄位")

    g.AddText("xs y+8 w80", "smtp_host")
    edHost := g.AddEdit("x+5 w355", state.smtpHost)

    g.AddText("xs y+8 w80", "smtp_port")
    edPort := g.AddEdit("x+5 w80", state.smtpPort)
    g.AddText("x+15 w50", "SSL")
    ddSsl := g.AddDropDownList("x+5 w100", ["1", "0"])
    ddSsl.Value := (state.useSsl = "0") ? 2 : 1

    g.AddText("xs y+8 w80", "smtp_user")
    edUser := g.AddEdit("x+5 w355", state.smtpUser)

    g.AddText("xs y+8 w80", "smtp_pass")
    edPass := g.AddEdit("x+5 w355 Password", state.smtpPass)

    g.AddText("xs y+8 w80", "from")
    edFrom := g.AddEdit("x+5 w355", state.mailFrom)

    g.AddText("xs y+8 w80", "to")
    edTo := g.AddEdit("x+5 w355", state.mailTo)

    g.AddText("xs y+8 w80", "prefix")
    edPrefix := g.AddEdit("x+5 w355", state.subjectPrefix)

    ; ==========================================
    ; === 右欄開始 (ys 對齊左欄頂部，新 Section) ===
    ; ==========================================
    g.AddText("x600 ys Section w440", "【螢幕錄影設定】")
    cbScreenRecordingEnabled := g.AddCheckbox("xs y+10 w440", "啟用螢幕錄影")
    cbScreenRecordingEnabled.Value := state.screenRecordingEnabled ? 1 : 0

    g.AddText("xs y+10 w80", "錄影引擎")
    ddScreenRecordingEngine := g.AddDropDownList("x+5 w355", ["ffmpeg:跨電腦建議"])
    ddScreenRecordingEngine.Choose(1)

    cbScreenRecordingAllowFallback := g.AddCheckbox("xs y+8 w440", "已移除 Alt+F9 錄影回退（僅使用 FFmpeg）")
    cbScreenRecordingAllowFallback.Value := 0

    g.AddText("xs y+10 w80", "ffmpeg.exe")
    edScreenRecordingFfmpegExe := g.AddEdit("x+5 w280", state.screenRecordingFfmpegExe)
    btnScreenRecordingFfmpegExe := g.AddButton("x+5 w70", "瀏覽...")

    cbScreenRecordingUseSimpleParams := g.AddCheckbox("xs y+8 w440", "使用簡易錄影參數（建議）")
    cbScreenRecordingUseSimpleParams.Value := state.screenRecordingUseSimpleParams ? 1 : 0

    cbScreenRecordingAutoStopExternalFfmpeg := g.AddCheckbox("xs y+8 w440", "自動停止外部 FFmpeg 錄影並改由本程式接管")
    cbScreenRecordingAutoStopExternalFfmpeg.Value := state.screenRecordingAutoStopExternalFfmpeg ? 1 : 0

    g.AddText("xs y+8 w80", "畫質等級")
    ddScreenRecordingQualityPreset := g.AddDropDownList("x+5 w355", ["balanced:平衡(建議)", "high:高畫質", "low:小檔案", "custom:自訂CRF"])
    ddScreenRecordingQualityPreset.Choose((state.screenRecordingQualityPreset = "high") ? 2 : (state.screenRecordingQualityPreset = "low") ? 3 : (state.screenRecordingQualityPreset = "custom") ? 4 : 1)

    g.AddText("xs y+8 w40", "FPS")
    edScreenRecordingFps := g.AddEdit("x+5 w60", state.screenRecordingFps)
    g.AddText("x+10 w40", "CRF")
    edScreenRecordingCrf := g.AddEdit("x+5 w60", state.screenRecordingCrf)

    txtScreenRecordingQualityHint := g.AddText("xs y+4 w440 c666666", GetScreenRecordingQualityHint(state.screenRecordingQualityPreset, state.screenRecordingCrf))

    g.AddText("xs y+8 w80", "ffmpeg參數")
    edScreenRecordingFfmpegArgs := g.AddEdit("x+5 w355", state.screenRecordingFfmpegArgs)

    txtScreenRecordingArgsHint := g.AddText("xs y+4 w440 c666666", "簡易模式會自動生成，進階可手動修改")

    g.AddText("xs y+8 w80", "輸出資料夾")
    edScreenRecordingOutputDir := g.AddEdit("x+5 w205", state.screenRecordingOutputDir)
    btnScreenRecordingOutputDir := g.AddButton("x+5 w70", "瀏覽...")
    btnScreenRecordingTestOutput := g.AddButton("x+5 w70", "測試寫入")
    txtScreenRecordingOutputHint := g.AddText("xs y+4 w440 c666666", "可選本機、映射磁碟或 \\電腦\共用；選取後會保存為 UNC。")

    g.AddText("xs y+8 w80", "分段分鐘")
    edScreenRecordingSegmentMinutes := g.AddEdit("x+5 w60", state.screenRecordingSegmentMinutes)
    g.AddText("x+12 w80", "保留成品")
    edScreenRecordingKeepFinalCount := g.AddEdit("x+5 w60", state.screenRecordingKeepFinalCount)
    g.AddText("x+5 w30", "份")

    cbScreenRecordingAutoMerge := g.AddCheckbox("xs y+7 w440", "正常結束後無損合併，驗證成功才刪除分段")
    cbScreenRecordingAutoMerge.Value := state.screenRecordingAutoMerge ? 1 : 0

    g.AddText("xs y+8 w80", "停止時機")
    ddScreenRecordingStopMode := g.AddDropDownList("x+5 w355", ["reward_end:收尾監測達標時", "lrmc_task_end:LRMCAI任務完成時"])
    ddScreenRecordingStopMode.Choose((state.screenRecordingStopMode = "lrmc_task_end") ? 2 : 1)

    g.AddText("xs y+8 w80", "任務名稱")
    edScreenRecordingStopLrmcTask := g.AddEdit("x+5 w355", state.screenRecordingStopLrmcTask)

    txtScreenRecordingHint := g.AddText("xs y+8 w440 c666666 h30", "") ; 多行提示區

    ; ==========================================
    ; === 第三欄：遠端控制識別設定 ===
    ; ==========================================
    g.AddText("x1060 ys Section w440", "【遠端控制識別】")
    g.AddText("xs y+10 w440 c666666", "建議兩台機器填不同裝置別名，網頁上會更好辨認。")

    g.AddText("xs y+10 w80", "裝置別名")
    edRemoteDeviceAlias := g.AddEdit("x+5 w355", state.remoteDeviceAlias)

    g.AddText("xs y+10 w80", "顯示名稱")
    edRemoteDisplayName := g.AddEdit("x+5 w355", state.remoteDisplayName)

    g.AddText("xs y+10 w80", "UID")
    edRemoteUid := g.AddEdit("x+5 w355 ReadOnly", state.remoteUid)

    g.AddText("xs y+6 w440 c666666", "提示：若顯示名稱留空，會自動使用 別名@電腦名-短碼。")

    g.AddText("xs y+24 w440", "【即時診斷】")
    cbRuntimeDiagnosticsEnabled := g.AddCheckbox("xs y+8 w440", "啟用定時畫面與警告／錯誤快照")
    cbRuntimeDiagnosticsEnabled.Value := state.runtimeDiagnosticsEnabled ? 1 : 0

    g.AddText("xs y+8 w80", "快照間隔")
    edRuntimeDiagnosticsInterval := g.AddEdit("x+5 w60", state.runtimeDiagnosticsIntervalSec)
    g.AddText("x+5 w30", "秒")
    g.AddText("x+15 w95", "錯誤圖保留")
    edRuntimeDiagnosticsKeepCount := g.AddEdit("x+5 w60", state.runtimeDiagnosticsErrorKeepCount)
    g.AddText("x+5 w30", "張")
    cbRuntimeVideoPreviewEnabled := g.AddCheckbox("xs y+8 w440", "網站顯示最近 6 秒短影片（每 60 秒更新）")
    cbRuntimeVideoPreviewEnabled.Value := state.runtimeDiagnosticsVideoPreviewEnabled ? 1 : 0
    txtRuntimeDiagnosticsHint := g.AddText("xs y+5 w440 c666666 h48", "網頁顯示最新畫面、短影片、錄影結果路徑與最近 50 筆事件；完整長影片仍存到錄影輸出資料夾。")

    ; === 底部按鈕區 ===
    btnSave := g.AddButton("xm y+25 w170 h34 Default", "儲存全部並繼續")
    btnCancel := g.AddButton("x+12 w110 h34", "取消")

    global __MAIL_SETUP
    __MAIL_SETUP := {
        done: false,
        saved: false,
        gui: g,
        btnSave: btnSave,
        btnCancel: btnCancel,
        cfgPath: cfgPath,
        section: section,
        edOkww: edOkww,
        edLrmc: edLrmc,
        edWu: edWu,
        edFallbackLog: edFallbackLog,
        txtFallbackHint: txtFallbackHint,
        cbServerScheduleEnabled: cbServerScheduleEnabled,
        txtServerHint: txtServerHint,
        edServerList: edServerList,
        btnServerPreview: btnServerPreview,
        edServerSwitchX: edServerSwitchX,
        edServerSwitchY: edServerSwitchY,
        edHost: edHost,
        edPort: edPort,
        edUser: edUser,
        edPass: edPass,
        edFrom: edFrom,
        edTo: edTo,
        edPrefix: edPrefix,
        ddSsl: ddSsl,
        cbSendEnabled: cbSendEnabled,
        cbScreenRecordingEnabled: cbScreenRecordingEnabled,
        ddScreenRecordingEngine: ddScreenRecordingEngine,
        cbScreenRecordingAllowFallback: cbScreenRecordingAllowFallback,
        edScreenRecordingFfmpegExe: edScreenRecordingFfmpegExe,
        btnScreenRecordingFfmpegExe: btnScreenRecordingFfmpegExe,
        cbScreenRecordingUseSimpleParams: cbScreenRecordingUseSimpleParams,
        cbScreenRecordingAutoStopExternalFfmpeg: cbScreenRecordingAutoStopExternalFfmpeg,
        ddScreenRecordingQualityPreset: ddScreenRecordingQualityPreset,
        edScreenRecordingFps: edScreenRecordingFps,
        edScreenRecordingCrf: edScreenRecordingCrf,
        txtScreenRecordingQualityHint: txtScreenRecordingQualityHint,
        edScreenRecordingFfmpegArgs: edScreenRecordingFfmpegArgs,
        txtScreenRecordingArgsHint: txtScreenRecordingArgsHint,
        edScreenRecordingOutputDir: edScreenRecordingOutputDir,
        btnScreenRecordingOutputDir: btnScreenRecordingOutputDir,
        btnScreenRecordingTestOutput: btnScreenRecordingTestOutput,
        txtScreenRecordingOutputHint: txtScreenRecordingOutputHint,
        edScreenRecordingSegmentMinutes: edScreenRecordingSegmentMinutes,
        edScreenRecordingKeepFinalCount: edScreenRecordingKeepFinalCount,
        cbScreenRecordingAutoMerge: cbScreenRecordingAutoMerge,
        ddScreenRecordingStopMode: ddScreenRecordingStopMode,
        edScreenRecordingStopLrmcTask: edScreenRecordingStopLrmcTask,
        txtScreenRecordingHint: txtScreenRecordingHint,
        txtMailHint: txtMailHint,
        edRemoteDeviceAlias: edRemoteDeviceAlias,
        edRemoteDisplayName: edRemoteDisplayName,
        edRemoteUid: edRemoteUid,
        cbRuntimeDiagnosticsEnabled: cbRuntimeDiagnosticsEnabled,
        edRuntimeDiagnosticsInterval: edRuntimeDiagnosticsInterval,
        edRuntimeDiagnosticsKeepCount: edRuntimeDiagnosticsKeepCount,
        cbRuntimeVideoPreviewEnabled: cbRuntimeVideoPreviewEnabled,
        txtRuntimeDiagnosticsHint: txtRuntimeDiagnosticsHint
    }

    btnOkww.OnEvent("Click", OnCombinedBrowseOkww)
    btnLrmc.OnEvent("Click", OnCombinedBrowseLrmc)
    btnWu.OnEvent("Click", OnCombinedBrowseWu)
    btnFallbackLog.OnEvent("Click", OnCombinedBrowseFallbackLog)
    btnServerPreview.OnEvent("Click", OnServerSchedulePreview)
    edFallbackLog.OnEvent("Change", OnFallbackLogChanged)
    cbServerScheduleEnabled.OnEvent("Click", OnServerScheduleEnabledChanged)
    cbSendEnabled.OnEvent("Click", OnSendEnabledChanged)
    cbScreenRecordingEnabled.OnEvent("Click", OnScreenRecordingSettingChanged)
    ddScreenRecordingEngine.OnEvent("Change", OnScreenRecordingSettingChanged)
    cbScreenRecordingAllowFallback.OnEvent("Click", OnScreenRecordingSettingChanged)
    cbScreenRecordingUseSimpleParams.OnEvent("Click", OnScreenRecordingSettingChanged)
    cbScreenRecordingAutoStopExternalFfmpeg.OnEvent("Click", OnScreenRecordingSettingChanged)
    ddScreenRecordingQualityPreset.OnEvent("Change", OnScreenRecordingSettingChanged)
    edScreenRecordingFps.OnEvent("Change", OnScreenRecordingSettingChanged)
    edScreenRecordingCrf.OnEvent("Change", OnScreenRecordingSettingChanged)
    ddScreenRecordingStopMode.OnEvent("Change", OnScreenRecordingSettingChanged)
    btnScreenRecordingFfmpegExe.OnEvent("Click", OnBrowseScreenRecordingFfmpegExe)
    btnScreenRecordingOutputDir.OnEvent("Click", OnBrowseScreenRecordingOutputDir)
    btnScreenRecordingTestOutput.OnEvent("Click", OnTestScreenRecordingOutputDir)
    cbRuntimeDiagnosticsEnabled.OnEvent("Click", OnRuntimeDiagnosticsSettingChanged)
    cbRuntimeVideoPreviewEnabled.OnEvent("Click", OnRuntimeDiagnosticsSettingChanged)
    btnSave.OnEvent("Click", OnCombinedSetupSave)
    btnCancel.OnEvent("Click", OnCombinedSetupCancel)
    g.OnEvent("Size", OnCombinedSetupGuiSize)
    g.OnEvent("Close", OnCombinedSetupClose)

    RefreshFallbackLogHint()
    RefreshMailInputsEnabled()
    RefreshServerScheduleInputsEnabled()
    RefreshScreenRecordingInputsEnabled()
    RefreshRuntimeDiagnosticsInputsEnabled()

    ShowGuiFitToScreen(g)
    ReflowCombinedSetupFooterButtons()
    while !__MAIL_SETUP.done
        Sleep 50

    saved := __MAIL_SETUP.saved
    __MAIL_SETUP := ""
    return saved
}

ShowGuiFitToScreen(g, margin := 24) {
    g.Show("AutoSize Center")

    try {
        WinGetPos(&x, &y, &w, &h, "ahk_id " g.Hwnd)
        maxW := A_ScreenWidth - (margin * 2)
        maxH := A_ScreenHeight - (margin * 2)

        if (maxW < 640)
            maxW := 640
        if (maxH < 520)
            maxH := 520

        newW := (w > maxW) ? maxW : w
        newH := (h > maxH) ? maxH : h

        if (newW != w || newH != h) {
            newX := Floor((A_ScreenWidth - newW) / 2)
            newY := Floor((A_ScreenHeight - newH) / 2)
            if (newX < margin)
                newX := margin
            if (newY < margin)
                newY := margin
            WinMove(newX, newY, newW, newH, "ahk_id " g.Hwnd)
        }
    } catch {
    }
}

OnCombinedSetupGuiSize(thisGui, minMax, width, height) {
    ReflowCombinedSetupFooterButtons(width, height)
}

ReflowCombinedSetupFooterButtons(width := 0, height := 0) {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    if !IsSet(width) || (width <= 0) || !IsSet(height) || (height <= 0) {
        try WinGetClientPos(, , &width, &height, "ahk_id " __MAIL_SETUP.gui.Hwnd)
    }
    if (width <= 0 || height <= 0)
        return

    margin := 16
    gap := 12
    minSaveW := 130
    minCancelW := 90
    saveW := 170
    cancelW := 110
    btnH := 34

    avail := width - (margin * 2) - gap
    if (avail < (saveW + cancelW)) {
        if (avail < (minSaveW + minCancelW))
            avail := minSaveW + minCancelW
        saveW := Max(minSaveW, Floor(avail * 0.62))
        cancelW := Max(minCancelW, avail - saveW)
    }

    x1 := margin
    y := height - margin - btnH
    if (y < 8)
        y := 8

    x2 := x1 + saveW + gap
    __MAIL_SETUP.btnSave.Move(x1, y, saveW, btnH)
    __MAIL_SETUP.btnCancel.Move(x2, y, cancelW, btnH)
}

OnCombinedBrowseOkww(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "選擇 OKWW 可執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
    if (p)
        __MAIL_SETUP.edOkww.Value := p
}

OnCombinedBrowseLrmc(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "選擇 LRMCAI 可執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
    if (p)
        __MAIL_SETUP.edLrmc.Value := p
}

OnCombinedBrowseWu(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "選擇鳴潮可執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
    if (p)
        __MAIL_SETUP.edWu.Value := p
}

OnCombinedBrowseFallbackLog(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "選擇後備 LRMCAI.log", "Log 檔 (*.log)")
    if (p) {
        __MAIL_SETUP.edFallbackLog.Value := p
        RefreshFallbackLogHint()
    }
}

OnFallbackLogChanged(*) {
    RefreshFallbackLogHint()
}

RefreshFallbackLogHint() {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    p := NormalizePath(__MAIL_SETUP.edFallbackLog.Value)
    if (p = "") {
        __MAIL_SETUP.txtFallbackHint.Value := "提示：後備 log 路徑為空，會改用預設或由 LRMC 路徑推導。"
        return
    }

    if FileExist(p)
        __MAIL_SETUP.txtFallbackHint.Value := "提示：後備 log 路徑存在，可作為監測後備來源。"
    else
        __MAIL_SETUP.txtFallbackHint.Value := "⚠ 警告：後備 log 檔不存在，儲存仍可繼續，但監測時可能找不到後備日誌。"
}

OnCombinedSetupSave(*) {
    global __MAIL_SETUP, MAIL_NOTIFY_ENABLED, SCREEN_RECORDING_ENABLED
    global SCREEN_RECORDING_ENGINE, SCREEN_RECORDING_FFMPEG_EXE, SCREEN_RECORDING_FFMPEG_ARGS, SCREEN_RECORDING_OUTPUT_DIR, SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK, SCREEN_RECORDING_AUTO_STOP_EXTERNAL_FFMPEG
    global SCREEN_RECORDING_SEGMENT_MINUTES, SCREEN_RECORDING_AUTO_MERGE, SCREEN_RECORDING_KEEP_FINAL_COUNT
    global SCREEN_RECORDING_STOP_MODE, SCREEN_RECORDING_STOP_TEMPLATE, SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM, SCREEN_RECORDING_STOP_LRMC_TASK
    global RUNTIME_DIAGNOSTICS_ENABLED, RUNTIME_DIAGNOSTICS_INTERVAL_SEC, RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT
    global RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED
    st := __MAIL_SETUP

    okwwPath := NormalizePath(st.edOkww.Value)
    lrmcPath := NormalizePath(st.edLrmc.Value)
    wuPath := NormalizePath(st.edWu.Value)
    fallbackLogVal := NormalizePath(st.edFallbackLog.Value)

    hostVal := Trim(st.edHost.Value, " `t`r`n")
    portVal := Trim(st.edPort.Value, " `t`r`n")
    userVal := Trim(st.edUser.Value, " `t`r`n")
    passVal := Trim(st.edPass.Value, " `t`r`n")
    fromVal := Trim(st.edFrom.Value, " `t`r`n")
    toVal := Trim(st.edTo.Value, " `t`r`n")
    prefixVal := Trim(st.edPrefix.Value, " `t`r`n")
    serverScheduleEnabledVal := st.cbServerScheduleEnabled.Value ? 1 : 0
    serverListVal := Trim(st.edServerList.Value, " `t`r`n")
    serverSwitchXVal := Trim(st.edServerSwitchX.Value, " `t`r`n")
    serverSwitchYVal := Trim(st.edServerSwitchY.Value, " `t`r`n")
    sslVal := st.ddSsl.Text
    sendEnabledVal := st.cbSendEnabled.Value ? 1 : 0
    screenRecordingEnabledVal := st.cbScreenRecordingEnabled.Value ? 1 : 0
    recordingEngineVal := "ffmpeg"
    allowFallbackVal := 0
    useSimpleParamsVal := st.cbScreenRecordingUseSimpleParams.Value ? 1 : 0
    autoStopExternalFfmpegVal := st.cbScreenRecordingAutoStopExternalFfmpeg.Value ? 1 : 0
    qualityPresetVal := NormalizeScreenRecordingQualityPreset(StrSplit(st.ddScreenRecordingQualityPreset.Text, ":")[1])
    fpsText := Trim(st.edScreenRecordingFps.Value, " `t`r`n")
    crfText := Trim(st.edScreenRecordingCrf.Value, " `t`r`n")
    fpsVal := ToIntRange(fpsText, 30, 10, 120)
    crfVal := ToIntRange(crfText, 23, 0, 51)
    ffmpegExeVal := NormalizePath(st.edScreenRecordingFfmpegExe.Value)
    ffmpegArgsVal := Trim(st.edScreenRecordingFfmpegArgs.Value, " `t`r`n")
    outputDirVal := ConvertMappedPathToUnc(NormalizePath(st.edScreenRecordingOutputDir.Value))
    segmentMinutesText := Trim(st.edScreenRecordingSegmentMinutes.Value, " `t`r`n")
    keepFinalCountText := Trim(st.edScreenRecordingKeepFinalCount.Value, " `t`r`n")
    segmentMinutesVal := ToIntRange(segmentMinutesText, 5, 1, 60)
    keepFinalCountVal := ToIntRange(keepFinalCountText, 5, 1, 50)
    autoMergeVal := st.cbScreenRecordingAutoMerge.Value ? 1 : 0
    stopModeVal := NormalizeScreenRecordingStopMode(StrSplit(st.ddScreenRecordingStopMode.Text, ":")[1])
    stopTemplateVal := "login"
    stopTemplateCustomVal := ""
    stopLrmcTaskVal := Trim(st.edScreenRecordingStopLrmcTask.Value, " `t`r`n")
    remoteDeviceAliasVal := Trim(st.edRemoteDeviceAlias.Value, " `t`r`n")
    remoteDisplayNameVal := Trim(st.edRemoteDisplayName.Value, " `t`r`n")
    runtimeDiagnosticsEnabledVal := st.cbRuntimeDiagnosticsEnabled.Value ? 1 : 0
    runtimeDiagnosticsVideoPreviewEnabledVal := st.cbRuntimeVideoPreviewEnabled.Value ? 1 : 0
    runtimeDiagnosticsIntervalText := Trim(st.edRuntimeDiagnosticsInterval.Value, " `t`r`n")
    runtimeDiagnosticsKeepText := Trim(st.edRuntimeDiagnosticsKeepCount.Value, " `t`r`n")
    runtimeDiagnosticsIntervalVal := ToIntRange(runtimeDiagnosticsIntervalText, 30, 15, 600)
    runtimeDiagnosticsKeepVal := ToIntRange(runtimeDiagnosticsKeepText, 30, 5, 200)

    if (okwwPath = "" || !FileExist(okwwPath)) {
        MsgBox "OKWW 路徑空白或不存在", "整合設定", "Iconx"
        return
    }
    if (lrmcPath = "" || !FileExist(lrmcPath)) {
        MsgBox "LRMCAI 路徑空白或不存在", "整合設定", "Iconx"
        return
    }
    if (wuPath = "" || !FileExist(wuPath)) {
        MsgBox "鳴潮路徑空白或不存在", "整合設定", "Iconx"
        return
    }

    if serverScheduleEnabledVal {
        parsed := ParseServerScheduleList(serverListVal)
        if (parsed.Length = 0) {
            MsgBox "啟用伺服器排程時，伺服器清單不可空白", "整合設定", "Iconx"
            return
        }
        if !(serverSwitchXVal ~= "^\d+$") || !(serverSwitchYVal ~= "^\d+$") {
            MsgBox "切服座標 X/Y 必須是數字", "整合設定", "Iconx"
            return
        }
    }

    if sendEnabledVal {
        if (hostVal = "" || portVal = "" || userVal = "" || passVal = "" || fromVal = "" || toVal = "") {
            MsgBox "郵件欄位不可空白：smtp_host/smtp_port/smtp_user/smtp_pass/from/to", "整合設定", "Iconx"
            return
        }
        if !(portVal ~= "^\d+$") {
            MsgBox "smtp_port 必須是數字", "整合設定", "Iconx"
            return
        }
    }

    if (screenRecordingEnabledVal && stopModeVal = "lrmc_task_end") {
        if (stopLrmcTaskVal = "") {
            MsgBox "錄影停止條件為 LRMCAI 任務完成時，任務名稱不可空白", "整合設定", "Iconx"
            return
        }
    }

    if (screenRecordingEnabledVal && recordingEngineVal = "ffmpeg") {
        if useSimpleParamsVal {
            if !RegExMatch(fpsText, "^\d+$") {
                MsgBox "FPS 必須是數字（建議 30 或 60）", "整合設定", "Iconx"
                return
            }
            if (qualityPresetVal = "custom") && !RegExMatch(crfText, "^\d+$") {
                MsgBox "自訂 CRF 必須是數字（0~51，建議 18~28）", "整合設定", "Iconx"
                return
            }
        }

        if useSimpleParamsVal
            ffmpegArgsVal := BuildScreenRecordingFfmpegArgsBySimple(qualityPresetVal, fpsVal, crfVal)

        if (ffmpegArgsVal = "") {
            MsgBox "使用 FFmpeg 錄影時，ffmpeg 參數不可空白", "整合設定", "Iconx"
            return
        }
        if (outputDirVal = "") {
            MsgBox "使用 FFmpeg 錄影時，輸出資料夾不可空白", "整合設定", "Iconx"
            return
        }
        if !RegExMatch(segmentMinutesText, "^\d+$") {
            MsgBox "分段分鐘必須是 1～60 的數字", "整合設定", "Iconx"
            return
        }
        if (Integer(segmentMinutesText) < 1 || Integer(segmentMinutesText) > 60) {
            MsgBox "分段分鐘必須介於 1～60", "整合設定", "Iconx"
            return
        }
        if !RegExMatch(keepFinalCountText, "^\d+$") {
            MsgBox "成品保留份數必須是 1～50 的數字", "整合設定", "Iconx"
            return
        }
        if (Integer(keepFinalCountText) < 1 || Integer(keepFinalCountText) > 50) {
            MsgBox "成品保留份數必須介於 1～50", "整合設定", "Iconx"
            return
        }

        writeTest := TestWritableDirectory(outputDirVal)
        if !writeTest.ok {
            st.txtScreenRecordingOutputHint.Value := "❌ " writeTest.message
            MsgBox "錄影輸出資料夾無法寫入：`n" writeTest.path "`n`n" writeTest.message,
                "整合設定", "Iconx"
            return
        }
        outputDirVal := writeTest.path
    }

    if runtimeDiagnosticsEnabledVal {
        if !RegExMatch(runtimeDiagnosticsIntervalText, "^\d+$") {
            MsgBox "快照間隔必須是 15～600 秒的數字", "整合設定", "Iconx"
            return
        }
        if (Integer(runtimeDiagnosticsIntervalText) < 15 || Integer(runtimeDiagnosticsIntervalText) > 600) {
            MsgBox "快照間隔必須介於 15～600 秒", "整合設定", "Iconx"
            return
        }
        if !RegExMatch(runtimeDiagnosticsKeepText, "^\d+$") {
            MsgBox "錯誤圖保留數量必須是 5～200 的數字", "整合設定", "Iconx"
            return
        }
        if (Integer(runtimeDiagnosticsKeepText) < 5 || Integer(runtimeDiagnosticsKeepText) > 200) {
            MsgBox "錯誤圖保留數量必須介於 5～200", "整合設定", "Iconx"
            return
        }
    }

    IniWrite okwwPath, st.cfgPath, "paths", "OKWW"
    IniWrite "1", st.cfgPath, "flags", "OKWW_remember"
    IniWrite lrmcPath, st.cfgPath, "paths", "LRMC"
    IniWrite "1", st.cfgPath, "flags", "LRMC_remember"
    IniWrite wuPath, st.cfgPath, "paths", "WUTHERING"
    IniWrite "1", st.cfgPath, "flags", "WUTHERING_remember"

    IniWrite fallbackLogVal, st.cfgPath, "reward_monitor", "fallback_log_file"

    IniWrite serverScheduleEnabledVal, st.cfgPath, "server_schedule", "enabled"
    IniWrite serverListVal, st.cfgPath, "server_schedule", "list"
    IniWrite (serverSwitchXVal = "" ? "640" : serverSwitchXVal), st.cfgPath, "server_schedule", "switch_x"
    IniWrite (serverSwitchYVal = "" ? "549" : serverSwitchYVal), st.cfgPath, "server_schedule", "switch_y"
    IniWrite "1", st.cfgPath, "server_schedule", "current_index"

    IniWrite hostVal, st.cfgPath, st.section, "smtp_host"
    IniWrite portVal, st.cfgPath, st.section, "smtp_port"
    IniWrite userVal, st.cfgPath, st.section, "smtp_user"
    IniWrite passVal, st.cfgPath, st.section, "smtp_pass"
    IniWrite fromVal, st.cfgPath, st.section, "from"
    IniWrite toVal, st.cfgPath, st.section, "to"
    IniWrite (prefixVal = "" ? "LRMCAI" : prefixVal), st.cfgPath, st.section, "subject_prefix"
    IniWrite sslVal, st.cfgPath, st.section, "use_ssl"
    IniWrite sendEnabledVal, st.cfgPath, st.section, "send_enabled"
    IniWrite screenRecordingEnabledVal, st.cfgPath, "screen_recording", "enabled"
    IniWrite recordingEngineVal, st.cfgPath, "screen_recording", "engine"
    IniWrite allowFallbackVal, st.cfgPath, "screen_recording", "allow_hotkey_fallback"
    IniWrite useSimpleParamsVal, st.cfgPath, "screen_recording", "use_simple_params"
    IniWrite autoStopExternalFfmpegVal, st.cfgPath, "screen_recording", "auto_stop_external_ffmpeg"
    IniWrite qualityPresetVal, st.cfgPath, "screen_recording", "quality_preset"
    IniWrite fpsVal, st.cfgPath, "screen_recording", "fps"
    IniWrite crfVal, st.cfgPath, "screen_recording", "crf"
    IniWrite (ffmpegExeVal = "" ? ResolveDefaultScreenRecordingFfmpegExe() : ffmpegExeVal), st.cfgPath, "screen_recording", "ffmpeg_exe"
    IniWrite (ffmpegArgsVal = "" ? "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -f matroska" : ffmpegArgsVal), st.cfgPath, "screen_recording", "ffmpeg_args"
    IniWrite (outputDirVal = "" ? "recordings" : outputDirVal), st.cfgPath, "screen_recording", "output_dir"
    IniWrite segmentMinutesVal, st.cfgPath, "screen_recording", "segment_minutes"
    IniWrite autoMergeVal, st.cfgPath, "screen_recording", "auto_merge"
    IniWrite keepFinalCountVal, st.cfgPath, "screen_recording", "keep_final_count"
    IniWrite stopModeVal, st.cfgPath, "screen_recording", "stop_mode"
    IniWrite stopTemplateVal, st.cfgPath, "screen_recording", "stop_template"
    IniWrite stopTemplateCustomVal, st.cfgPath, "screen_recording", "stop_template_custom"
    IniWrite stopLrmcTaskVal, st.cfgPath, "screen_recording", "stop_lrmc_task"
    IniWrite remoteDeviceAliasVal, st.cfgPath, "remote_control", "device_alias"
    IniWrite remoteDisplayNameVal, st.cfgPath, "remote_control", "display_name"
    IniWrite runtimeDiagnosticsEnabledVal, st.cfgPath, "runtime_diagnostics", "enabled"
    IniWrite runtimeDiagnosticsIntervalVal, st.cfgPath, "runtime_diagnostics", "snapshot_interval_sec"
    IniWrite runtimeDiagnosticsKeepVal, st.cfgPath, "runtime_diagnostics", "error_keep_count"
    IniWrite runtimeDiagnosticsVideoPreviewEnabledVal, st.cfgPath, "runtime_diagnostics", "video_preview_enabled"

    MAIL_NOTIFY_ENABLED := sendEnabledVal
    SCREEN_RECORDING_ENABLED := screenRecordingEnabledVal
    SCREEN_RECORDING_ENGINE := recordingEngineVal
    SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK := 0
    SCREEN_RECORDING_FFMPEG_EXE := (ffmpegExeVal = "" ? ResolveDefaultScreenRecordingFfmpegExe() : ffmpegExeVal)
    SCREEN_RECORDING_FFMPEG_ARGS := (ffmpegArgsVal = "" ? "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -f matroska" : ffmpegArgsVal)
    SCREEN_RECORDING_OUTPUT_DIR := (outputDirVal = "" ? "recordings" : outputDirVal)
    SCREEN_RECORDING_SEGMENT_MINUTES := segmentMinutesVal
    SCREEN_RECORDING_AUTO_MERGE := autoMergeVal
    SCREEN_RECORDING_KEEP_FINAL_COUNT := keepFinalCountVal
    SCREEN_RECORDING_AUTO_STOP_EXTERNAL_FFMPEG := autoStopExternalFfmpegVal
    SCREEN_RECORDING_STOP_MODE := stopModeVal
    SCREEN_RECORDING_STOP_TEMPLATE := stopTemplateVal
    SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM := stopTemplateCustomVal
    SCREEN_RECORDING_STOP_LRMC_TASK := stopLrmcTaskVal
    RUNTIME_DIAGNOSTICS_ENABLED := runtimeDiagnosticsEnabledVal
    RUNTIME_DIAGNOSTICS_INTERVAL_SEC := runtimeDiagnosticsIntervalVal
    RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT := runtimeDiagnosticsKeepVal
    RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED := runtimeDiagnosticsVideoPreviewEnabledVal
    StartRuntimeDiagnostics()

    __MAIL_SETUP.saved := true
    __MAIL_SETUP.done := true
    st.gui.Destroy()
}

OnSendEnabledChanged(*) {
    RefreshMailInputsEnabled()
}

OnScreenRecordingSettingChanged(*) {
    RefreshScreenRecordingInputsEnabled()
}

OnBrowseScreenRecordingFfmpegExe(*) {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    p := FileSelect(, "", "選擇 ffmpeg.exe", "可執行檔 (*.exe)")
    if (p)
        __MAIL_SETUP.edScreenRecordingFfmpegExe.Value := p
}

ConvertMappedPathToUnc(pathValue) {
    p := NormalizePath(pathValue)
    p := StrReplace(p, "/", "\")
    if (p = "" || SubStr(p, 1, 2) = "\\")
        return p
    if !RegExMatch(p, "i)^([a-z]:)(\\.*)?$", &m)
        return p

    required := 0
    rc := DllCall("Mpr\WNetGetUniversalNameW", "str", p, "uint", 1,
        "ptr", 0, "uint*", &required, "uint")
    if (rc = 234 && required > A_PtrSize) {
        info := Buffer(required, 0)
        rc := DllCall("Mpr\WNetGetUniversalNameW", "str", p, "uint", 1,
            "ptr", info.Ptr, "uint*", &required, "uint")
        if (rc = 0) {
            uncPtr := NumGet(info, 0, "ptr")
            if (uncPtr)
                return RTrim(StrGet(uncPtr, "UTF-16"), "\")
        }
    }

    ; 管理員工作階段可能看不到映射連線，但同一使用者的持久映射仍在 HKCU。
    try {
        driveLetter := SubStr(m[1], 1, 1)
        remoteRoot := Trim(RegRead("HKCU\Network\" driveLetter, "RemotePath"), ' "`t`r`n')
        if (remoteRoot != "") {
            suffix := m[2]
            return RTrim(remoteRoot, "\") suffix
        }
    }
    return p
}

ResolveConfiguredDirectoryPath(pathValue) {
    p := ConvertMappedPathToUnc(NormalizePath(pathValue))
    if (p = "")
        return ""
    if RegExMatch(p, "i)^[a-z]:\\") || SubStr(p, 1, 2) = "\\"
        return p
    return A_ScriptDir "\" p
}

TestWritableDirectory(pathValue) {
    resolved := ResolveConfiguredDirectoryPath(pathValue)
    result := {ok: false, path: resolved, message: ""}
    if (resolved = "") {
        result.message := "路徑不可空白"
        return result
    }
    if RegExMatch(resolved, "i)^(?:shell:|::\{)") {
        result.message := "這是檔案總管捷徑位置，不是真實檔案路徑；請選擇 SMB 共用資料夾"
        return result
    }

    testPath := resolved "\.wuthering_write_test_" DllCall("GetCurrentProcessId") "_" A_TickCount ".tmp"
    token := "write-test-" A_TickCount
    try {
        if !DirExist(resolved)
            DirCreate(resolved)
        FileAppend(token, testPath, "UTF-8")
        readBack := FileRead(testPath, "UTF-8")
        if (readBack != token)
            throw Error("測試檔寫入後讀回內容不一致")
        FileDelete(testPath)
        result.ok := true
        result.message := "寫入、讀取與刪除測試成功"
        return result
    } catch as e {
        try FileDelete(testPath)
        result.message := e.Message
        if (SubStr(resolved, 1, 2) = "\\")
            result.message .= "；請確認共用權限、資料夾安全性權限及 Windows 認證"
        return result
    }
}

QuoteFolderPickerArg(value) {
    return '"' StrReplace(value, '"', '') '"'
}

SelectRecordingOutputFolderWithUserToken(initialPath := "") {
    global BUNDLED_AHK_EXE
    launcherPath := ResolvePersistentToolsRoot() "\全自動鋤地.exe"
    helperScript := A_ScriptDir "\FolderPickerHelper.ahk"
    if ((!FileExist(helperScript) || !FileExist(BUNDLED_AHK_EXE)) && !FileExist(launcherPath))
        return {ok: false, cancelled: false, path: "", message: "找不到資料夾選擇 helper／啟動器"}

    replyPath := A_Temp "\wuthering_folder_picker_" DllCall("GetCurrentProcessId") "_" A_TickCount ".ini"
    try FileDelete(replyPath)
    initialResolved := ResolveConfiguredDirectoryPath(initialPath)
    if (FileExist(helperScript) && FileExist(BUNDLED_AHK_EXE)) {
        pickerExe := BUNDLED_AHK_EXE
        args := QuoteFolderPickerArg(helperScript) " --reply " QuoteFolderPickerArg(replyPath)
        args .= " --initial " QuoteFolderPickerArg(initialResolved)
        pickerWorkDir := A_ScriptDir
        pickerKind := "payload_helper"
    } else {
        pickerExe := launcherPath
        args := "--pick-folder --reply " QuoteFolderPickerArg(replyPath)
        args .= " --initial " QuoteFolderPickerArg(initialResolved)
        pickerWorkDir := ResolvePersistentToolsRoot()
        pickerKind := "launcher_fallback"
    }

    try {
        ; Shell.Application 由桌面 Explorer 代理啟動，子程序使用一般使用者權杖，
        ; 新 helper 還會自行列出映射磁碟／網路位置，並提供 UNC 直接輸入。
        shell := ComObject("Shell.Application")
        shell.ShellExecute(pickerExe, args, pickerWorkDir, "open", 1)
    } catch as e {
        return {ok: false, cancelled: false, path: "", message: "啟動資料夾選擇器失敗: " e.Message}
    }

    deadline := A_TickCount + 600000
    while (A_TickCount < deadline) {
        if FileExist(replyPath)
            break
        Sleep 100
    }
    if !FileExist(replyPath)
        return {ok: false, cancelled: false, path: "", message: "資料夾選擇器 10 分鐘內沒有回覆"}

    try {
        status := IniRead(replyPath, "result", "status", "error")
        selected := IniRead(replyPath, "result", "path", "")
        message := IniRead(replyPath, "result", "message", "")
        helperWasAdmin := IniRead(replyPath, "result", "helper_was_admin", "0")
        networkCount := IniRead(replyPath, "result", "network_count", "0")
        pickerSource := IniRead(replyPath, "result", "source", "")
        try FileDelete(replyPath)
        if (status = "cancel")
            return {ok: false, cancelled: true, path: "", message: ""}
        if (status != "ok" || selected = "")
            return {ok: false, cancelled: false, path: "", message: message != "" ? message : "選擇器未回傳路徑"}
        selected := ConvertMappedPathToUnc(selected)
        note := helperWasAdmin = "1" ? "（helper 為管理員權限；已提供持久映射與 UNC 輸入保底）" : ""
        return {ok: true, cancelled: false, path: selected, message: note,
            helperWasAdmin: helperWasAdmin, networkCount: networkCount,
            pickerSource: pickerSource, pickerKind: pickerKind}
    } catch as e {
        try FileDelete(replyPath)
        return {ok: false, cancelled: false, path: "", message: "讀取選擇結果失敗: " e.Message}
    }
}

OnBrowseScreenRecordingOutputDir(*) {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    picked := SelectRecordingOutputFolderWithUserToken(__MAIL_SETUP.edScreenRecordingOutputDir.Value)
    if picked.cancelled
        return
    if !picked.ok {
        __MAIL_SETUP.txtScreenRecordingOutputHint.Value := "❌ " picked.message
        MsgBox picked.message, "錄影輸出資料夾", "Iconx"
        return
    }

    __MAIL_SETUP.edScreenRecordingOutputDir.Value := picked.path
    WriteLog("錄影輸出選擇完成 | path=" picked.path
        " | helper_admin=" picked.helperWasAdmin " | network_count=" picked.networkCount
        " | source=" picked.pickerSource " | picker=" picked.pickerKind)
    testResult := TestWritableDirectory(picked.path)
    if testResult.ok {
        __MAIL_SETUP.edScreenRecordingOutputDir.Value := testResult.path
        __MAIL_SETUP.txtScreenRecordingOutputHint.Value := "✅ " testResult.message " | " testResult.path
            (picked.message != "" ? " " picked.message : "")
    } else
        __MAIL_SETUP.txtScreenRecordingOutputHint.Value := "⚠ 已選取，但目前無法寫入：" testResult.message
}

OnTestScreenRecordingOutputDir(*) {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return
    result := TestWritableDirectory(__MAIL_SETUP.edScreenRecordingOutputDir.Value)
    if result.ok {
        __MAIL_SETUP.edScreenRecordingOutputDir.Value := result.path
        __MAIL_SETUP.txtScreenRecordingOutputHint.Value := "✅ " result.message " | " result.path
        MsgBox "資料夾可正常寫入：`n" result.path, "錄影輸出測試", "Iconi"
    } else {
        __MAIL_SETUP.txtScreenRecordingOutputHint.Value := "❌ " result.message
        MsgBox "資料夾無法寫入：`n" result.path "`n`n" result.message, "錄影輸出測試", "Iconx"
    }
}

OnRuntimeDiagnosticsSettingChanged(*) {
    RefreshRuntimeDiagnosticsInputsEnabled()
}

RefreshRuntimeDiagnosticsInputsEnabled() {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return
    enabled := __MAIL_SETUP.cbRuntimeDiagnosticsEnabled.Value ? true : false
    __MAIL_SETUP.edRuntimeDiagnosticsInterval.Enabled := enabled
    __MAIL_SETUP.edRuntimeDiagnosticsKeepCount.Enabled := enabled
    __MAIL_SETUP.cbRuntimeVideoPreviewEnabled.Enabled := enabled
    __MAIL_SETUP.txtRuntimeDiagnosticsHint.Value := enabled
        ? (__MAIL_SETUP.cbRuntimeVideoPreviewEnabled.Value
            ? "網頁顯示最新畫面、最近 6 秒短影片與錄影結果路徑；完整長影片不會上傳。"
            : "網頁顯示最新畫面與錄影結果路徑；短影片預覽目前停用。")
        : "即時診斷已停用；遠端頁面仍保留基本步驟與心跳。"
}

OnServerScheduleEnabledChanged(*) {
    RefreshServerScheduleInputsEnabled()
}

RefreshScreenRecordingInputsEnabled() {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    enabled := __MAIL_SETUP.cbScreenRecordingEnabled.Value ? true : false
    engineKey := NormalizeScreenRecordingEngine(StrSplit(__MAIL_SETUP.ddScreenRecordingEngine.Text, ":")[1])
    useFfmpeg := enabled && (engineKey = "ffmpeg")
    useSimple := useFfmpeg && (__MAIL_SETUP.cbScreenRecordingUseSimpleParams.Value ? true : false)
    __MAIL_SETUP.ddScreenRecordingEngine.Enabled := enabled
    __MAIL_SETUP.cbScreenRecordingAllowFallback.Enabled := false
    __MAIL_SETUP.edScreenRecordingFfmpegExe.Enabled := useFfmpeg
    __MAIL_SETUP.btnScreenRecordingFfmpegExe.Enabled := useFfmpeg
    __MAIL_SETUP.cbScreenRecordingUseSimpleParams.Enabled := useFfmpeg
    __MAIL_SETUP.cbScreenRecordingAutoStopExternalFfmpeg.Enabled := useFfmpeg
    __MAIL_SETUP.ddScreenRecordingQualityPreset.Enabled := useSimple
    __MAIL_SETUP.edScreenRecordingFps.Enabled := useSimple
    qualityKey := NormalizeScreenRecordingQualityPreset(StrSplit(__MAIL_SETUP.ddScreenRecordingQualityPreset.Text, ":")[1])
    __MAIL_SETUP.edScreenRecordingCrf.Enabled := useSimple && (qualityKey = "custom")
    __MAIL_SETUP.txtScreenRecordingQualityHint.Value := GetScreenRecordingQualityHint(qualityKey, __MAIL_SETUP.edScreenRecordingCrf.Value)
    __MAIL_SETUP.edScreenRecordingFfmpegArgs.Enabled := useFfmpeg && !useSimple
    __MAIL_SETUP.edScreenRecordingOutputDir.Enabled := useFfmpeg
    __MAIL_SETUP.btnScreenRecordingOutputDir.Enabled := useFfmpeg
    __MAIL_SETUP.btnScreenRecordingTestOutput.Enabled := useFfmpeg
    __MAIL_SETUP.edScreenRecordingSegmentMinutes.Enabled := useFfmpeg
    __MAIL_SETUP.edScreenRecordingKeepFinalCount.Enabled := useFfmpeg
    __MAIL_SETUP.cbScreenRecordingAutoMerge.Enabled := useFfmpeg
    __MAIL_SETUP.ddScreenRecordingStopMode.Enabled := enabled

    if useSimple {
        fpsVal := ToIntRange(__MAIL_SETUP.edScreenRecordingFps.Value, 30, 10, 120)
        crfVal := ToIntRange(__MAIL_SETUP.edScreenRecordingCrf.Value, 23, 0, 51)
        __MAIL_SETUP.edScreenRecordingFfmpegArgs.Value := BuildScreenRecordingFfmpegArgsBySimple(qualityKey, fpsVal, crfVal)
        __MAIL_SETUP.txtScreenRecordingArgsHint.Value := "簡易模式已啟用：會自動用畫質/FPS/CRF 組合 ffmpeg 參數。"
    } else
        __MAIL_SETUP.txtScreenRecordingArgsHint.Value := "進階模式：你可直接手動編輯完整 ffmpeg 參數。"

    modeKey := NormalizeScreenRecordingStopMode(StrSplit(__MAIL_SETUP.ddScreenRecordingStopMode.Text, ":")[1])
    useTaskMode := enabled && (modeKey = "lrmc_task_end")
    __MAIL_SETUP.edScreenRecordingStopLrmcTask.Enabled := useTaskMode

    if !enabled
        __MAIL_SETUP.txtScreenRecordingHint.Value := "提示：螢幕錄影目前停用。"
    else if (engineKey = "ffmpeg")
        __MAIL_SETUP.txtScreenRecordingHint.Value := "提示：目前僅使用 FFmpeg；找不到 ffmpeg 會嘗試自動下載。"
    else if (modeKey = "lrmc_task_end")
        __MAIL_SETUP.txtScreenRecordingHint.Value := "提示：任務包命中任務名稱且同段含『用時:..秒』可直接停錄；或偵測到『到達終點』後下一條任務包命中也會停錄（繁簡互通）。"
    else if (modeKey = "reward_end")
        __MAIL_SETUP.txtScreenRecordingHint.Value := "提示：會在收尾監測達標時停止錄影。"
    else
        __MAIL_SETUP.txtScreenRecordingHint.Value := "提示：會在收尾監測達標時停止錄影。"
}

OnServerSchedulePreview(*) {
    global __MAIL_SETUP, __SERVER_PREVIEW
    if !IsObject(__MAIL_SETUP)
        return

    src := Trim(__MAIL_SETUP.edServerList.Value, " `t`r`n")
    arr := ParseServerScheduleList(src)
    if (arr.Length = 0) {
        MsgBox "伺服器清單是空的，請先輸入至少一個伺服器。", "伺服器清單預覽", "Iconx"
        return
    }

    g := Gui("+Owner" __MAIL_SETUP.gui.Hwnd " +MinSize540x360", "伺服器清單預覽排序")
    g.SetFont("s10", "Microsoft JhengHei UI")
    g.AddText("xm w500", "可用【上移/下移】調整順序，或按【字母排序】後套用回主設定。")

    lb := g.AddListBox("xm y+8 w500 r10", arr)
    lb.Choose(1)

    btnUp := g.AddButton("xm y+10 w90", "上移")
    btnDown := g.AddButton("x+8 w90", "下移")
    btnSort := g.AddButton("x+8 w110", "字母排序")
    btnRefresh := g.AddButton("x+8 w110", "重讀清單")
    btnApply := g.AddButton("xm y+14 w150 h32 Default", "套用回主清單")
    btnClose := g.AddButton("x+10 w90 h32", "關閉")

    __SERVER_PREVIEW := {
        gui: g,
        lb: lb,
        sourceEdit: __MAIL_SETUP.edServerList,
        sourceText: src
    }

    btnUp.OnEvent("Click", OnServerPreviewMoveUp)
    btnDown.OnEvent("Click", OnServerPreviewMoveDown)
    btnSort.OnEvent("Click", OnServerPreviewSort)
    btnRefresh.OnEvent("Click", OnServerPreviewReload)
    btnApply.OnEvent("Click", OnServerPreviewApply)
    btnClose.OnEvent("Click", OnServerPreviewClose)
    g.OnEvent("Close", OnServerPreviewClose)
    g.Show("AutoSize")
}

GetServerPreviewItems() {
    global __SERVER_PREVIEW
    items := []
    if !IsObject(__SERVER_PREVIEW)
        return items

    txt := __SERVER_PREVIEW.lb.Text
    ; ListBox Text 會回傳選中項目，改用主欄位重建更穩定
    src := Trim(__SERVER_PREVIEW.sourceEdit.Value, " `t`r`n")
    items := ParseServerScheduleList(src)
    if (items.Length = 0) {
        ; 從預覽建立時的來源回退
        items := ParseServerScheduleList(__SERVER_PREVIEW.sourceText)
    }
    return items
}

SetServerPreviewItems(items, selectedIndex := 1) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return
    __SERVER_PREVIEW.lb.Delete()
    for item in items
        __SERVER_PREVIEW.lb.Add([item])

    if (items.Length = 0)
        return

    if (selectedIndex < 1)
        selectedIndex := 1
    if (selectedIndex > items.Length)
        selectedIndex := items.Length
    __SERVER_PREVIEW.lb.Choose(selectedIndex)
}

OnServerPreviewMoveUp(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return

    items := GetServerPreviewItems()
    if (items.Length <= 1)
        return
    idx := __SERVER_PREVIEW.lb.Value
    if (idx <= 1)
        return

    tmp := items[idx - 1]
    items[idx - 1] := items[idx]
    items[idx] := tmp
    __SERVER_PREVIEW.sourceEdit.Value := JoinServerList(items)
    SetServerPreviewItems(items, idx - 1)
}

OnServerPreviewMoveDown(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return

    items := GetServerPreviewItems()
    if (items.Length <= 1)
        return
    idx := __SERVER_PREVIEW.lb.Value
    if (idx >= items.Length)
        return

    tmp := items[idx + 1]
    items[idx + 1] := items[idx]
    items[idx] := tmp
    __SERVER_PREVIEW.sourceEdit.Value := JoinServerList(items)
    SetServerPreviewItems(items, idx + 1)
}

OnServerPreviewSort(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return

    items := GetServerPreviewItems()
    if (items.Length <= 1)
        return
    items := SortServerList(items)
    __SERVER_PREVIEW.sourceEdit.Value := JoinServerList(items)
    SetServerPreviewItems(items, 1)
}

OnServerPreviewReload(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return

    items := ParseServerScheduleList(__SERVER_PREVIEW.sourceEdit.Value)
    if (items.Length = 0)
        items := ParseServerScheduleList(__SERVER_PREVIEW.sourceText)
    SetServerPreviewItems(items, 1)
}

OnServerPreviewApply(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return

    items := GetServerPreviewItems()
    if (items.Length = 0) {
        MsgBox "目前沒有可套用的伺服器項目。", "伺服器清單預覽", "Iconx"
        return
    }

    __SERVER_PREVIEW.sourceEdit.Value := JoinServerList(items)
    ShowTip("✅ 已套用伺服器排序", 1000)
}

OnServerPreviewClose(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return
    try __SERVER_PREVIEW.gui.Destroy()
    __SERVER_PREVIEW := ""
}

JoinServerList(items) {
    out := ""
    for item in items {
        if (out != "")
            out .= ", "
        out .= item
    }
    return out
}

SortServerList(items) {
    buf := ""
    for item in items
        buf .= item "`n"
    sorted := Sort(RTrim(buf, "`n"), "CL")
    out := []
    for line in StrSplit(sorted, "`n") {
        line := Trim(line, " `t`r`n")
        if (line != "")
            out.Push(line)
    }
    return out
}

RefreshMailInputsEnabled() {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    enabled := __MAIL_SETUP.cbSendEnabled.Value ? true : false
    __MAIL_SETUP.edHost.Enabled := enabled
    __MAIL_SETUP.edPort.Enabled := enabled
    __MAIL_SETUP.edUser.Enabled := enabled
    __MAIL_SETUP.edPass.Enabled := enabled
    __MAIL_SETUP.edFrom.Enabled := enabled
    __MAIL_SETUP.edTo.Enabled := enabled
    __MAIL_SETUP.edPrefix.Enabled := enabled
    __MAIL_SETUP.ddSsl.Enabled := enabled
    __MAIL_SETUP.txtMailHint.Value := enabled ? "目前啟用寄信：需填寫 SMTP 欄位" : "目前停用寄信：可略過 SMTP 欄位"
}

RefreshServerScheduleInputsEnabled() {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    enabled := __MAIL_SETUP.cbServerScheduleEnabled.Value ? true : false
    __MAIL_SETUP.edServerList.Enabled := enabled
    __MAIL_SETUP.btnServerPreview.Enabled := enabled
    __MAIL_SETUP.edServerSwitchX.Enabled := enabled
    __MAIL_SETUP.edServerSwitchY.Enabled := enabled
    __MAIL_SETUP.txtServerHint.Value := enabled ? "目前啟用：會依清單逐一切服並續跑" : "目前停用：維持單伺服器流程"
}

LoadMailNotifyEnabled() {
    global CFG_FILE, MAIL_SECTION, MAIL_NOTIFY_ENABLED
    MAIL_NOTIFY_ENABLED := ParseBool01(IniReadSafe(CFG_FILE, MAIL_SECTION, "send_enabled", "1"), 1)
    WriteLog("郵件通知開關(send_enabled)=" MAIL_NOTIFY_ENABLED)
}

LoadRuntimeDiagnosticsSettings() {
    global CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION
    global RUNTIME_DIAGNOSTICS_ENABLED, RUNTIME_DIAGNOSTICS_INTERVAL_SEC
    global RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT, RUNTIME_DIAGNOSTICS_MAX_WIDTH
    global RUNTIME_DIAGNOSTICS_JPEG_QUALITY, RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED

    RUNTIME_DIAGNOSTICS_ENABLED := ParseBool01(
        IniReadSafe(CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION, "enabled", "1"), 1)
    RUNTIME_DIAGNOSTICS_INTERVAL_SEC := ToIntRange(
        IniReadSafe(CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION, "snapshot_interval_sec", "30"),
        30, 15, 600)
    RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT := ToIntRange(
        IniReadSafe(CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION, "error_keep_count", "30"),
        30, 5, 200)
    RUNTIME_DIAGNOSTICS_MAX_WIDTH := ToIntRange(
        IniReadSafe(CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION, "snapshot_max_width", "640"),
        640, 320, 1280)
    RUNTIME_DIAGNOSTICS_JPEG_QUALITY := ToIntRange(
        IniReadSafe(CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION, "jpeg_quality", "45"),
        45, 20, 80)
    RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED := ParseBool01(
        IniReadSafe(CFG_FILE, RUNTIME_DIAGNOSTICS_SECTION, "video_preview_enabled", "1"), 1)
    WriteLog("即時診斷 enabled=" RUNTIME_DIAGNOSTICS_ENABLED
        " interval=" RUNTIME_DIAGNOSTICS_INTERVAL_SEC "s error_keep=" RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT
        " video_preview=" RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED)
}

ResolveRuntimeDiagnosticsDir() {
    localBase := NormalizePath(EnvGet("LOCALAPPDATA"))
    if (localBase = "")
        localBase := A_Temp
    return localBase "\WutheringAuto\diagnostics"
}

StartRuntimeDiagnostics() {
    global RUNTIME_DIAGNOSTICS_ENABLED, RUNTIME_DIAGNOSTICS_INTERVAL_SEC
    global RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED, REMOTE_CONTROL_ACTIVE
    global __RUNTIME_DIAGNOSTICS_ACTIVE, __RUNTIME_VIDEO_LAST_CAPTURE_TICK
    global __RUNTIME_VIDEO_FFMPEG_MISSING_WARNED

    StopRuntimeDiagnostics()
    if !RUNTIME_DIAGNOSTICS_ENABLED {
        WriteLog("即時診斷已停用")
        return false
    }

    diagDir := ResolveRuntimeDiagnosticsDir()
    try DirCreate(diagDir)
    catch as e {
        WriteLog("建立即時診斷資料夾失敗: " e.Message, "WARN")
        return false
    }

    __RUNTIME_DIAGNOSTICS_ACTIVE := true
    intervalMs := Max(15000, RUNTIME_DIAGNOSTICS_INTERVAL_SEC * 1000)
    SetTimer(RuntimeSnapshotTick, intervalMs)
    SetTimer(() => CaptureRuntimeSnapshot("啟動／設定完成", false), -800)
    __RUNTIME_VIDEO_LAST_CAPTURE_TICK := 0
    __RUNTIME_VIDEO_FFMPEG_MISSING_WARNED := false
    if (RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED && REMOTE_CONTROL_ACTIVE)
        SetTimer(RuntimeVideoPreviewTick, 1000)
    WriteLog("即時診斷已啟動，每 " RUNTIME_DIAGNOSTICS_INTERVAL_SEC " 秒更新畫面"
        " | 6秒短影片=" (RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED && REMOTE_CONTROL_ACTIVE ? "啟用" : "停用"))
    return true
}

StopRuntimeDiagnostics() {
    global __RUNTIME_DIAGNOSTICS_ACTIVE, __RUNTIME_VIDEO_PREVIEW_PID
    global __RUNTIME_VIDEO_PREVIEW_PATH, __RUNTIME_VIDEO_PREVIEW_STARTED_TICK
    __RUNTIME_DIAGNOSTICS_ACTIVE := false
    try SetTimer(RuntimeSnapshotTick, 0)
    try SetTimer(RuntimeErrorSnapshotTick, 0)
    try SetTimer(RuntimeVideoPreviewTick, 0)
    if (__RUNTIME_VIDEO_PREVIEW_PID > 0 && ProcessExist(__RUNTIME_VIDEO_PREVIEW_PID)
        && IsOwnedRuntimeVideoPreviewPid(__RUNTIME_VIDEO_PREVIEW_PID)) {
        ; 只關閉本次由即時診斷啟動並持有 PID 的短影片 ffmpeg，不掃描或誤殺其他程序。
        try ProcessClose(__RUNTIME_VIDEO_PREVIEW_PID)
    }
    __RUNTIME_VIDEO_PREVIEW_PID := 0
    __RUNTIME_VIDEO_PREVIEW_STARTED_TICK := 0
    if (__RUNTIME_VIDEO_PREVIEW_PATH != "")
        try FileDelete(__RUNTIME_VIDEO_PREVIEW_PATH)
    __RUNTIME_VIDEO_PREVIEW_PATH := ""
}

RuntimeSnapshotTick() {
    CaptureRuntimeSnapshot("定時快照", false)
}

IsOwnedRuntimeVideoPreviewPid(pid) {
    if (pid <= 0)
        return false
    try {
        query := "Select Name, CommandLine from Win32_Process where ProcessId=" Integer(pid)
        for proc in ComObjGet("winmgmts:").ExecQuery(query) {
            name := ""
            cmdLine := ""
            try name := proc.Name
            try cmdLine := proc.CommandLine
            return StrLower(name) = "ffmpeg.exe" && IsRuntimeVideoPreviewFfmpegCommand(cmdLine)
        }
    }
    return false
}

ResolveRuntimeVideoPreviewFfmpegExe() {
    global SCREEN_RECORDING_FFMPEG_EXE
    configured := NormalizePath(SCREEN_RECORDING_FFMPEG_EXE)
    if (configured != "") {
        if RegExMatch(configured, "i)^[a-z]:\\") || SubStr(configured, 1, 2) = "\\" {
            if FileExist(configured)
                return configured
        } else if (configured != "ffmpeg" && configured != "ffmpeg.exe") {
            rootDir := ResolvePersistentToolsRoot()
            candidate := rootDir != "" ? rootDir "\" configured : A_ScriptDir "\" configured
            if FileExist(candidate)
                return candidate
        }
    }
    return FindBundledFfmpegExe()
}

ReadBinaryFileBase64(filePath) {
    data := FileRead(filePath, "RAW")
    if !(data is Buffer) || data.Size <= 0
        return ""

    chars := 0
    flags := 0x40000001 ; CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
    if !DllCall("Crypt32\CryptBinaryToStringW", "ptr", data.Ptr, "uint", data.Size,
        "uint", flags, "ptr", 0, "uint*", &chars)
        return ""
    encoded := Buffer(chars * 2, 0)
    if !DllCall("Crypt32\CryptBinaryToStringW", "ptr", data.Ptr, "uint", data.Size,
        "uint", flags, "ptr", encoded.Ptr, "uint*", &chars)
        return ""
    return StrGet(encoded, "UTF-16")
}

PublishCompletedRuntimeVideoPreview(tempPath, width, height) {
    global RUNTIME_DIAGNOSTICS_VIDEO_DURATION_SEC, RUNTIME_DIAGNOSTICS_VIDEO_MAX_DATA_URI_CHARS
    global REMOTE_CONTROL_ACTIVE

    if (tempPath = "" || !FileExist(tempPath))
        return false
    sizeBytes := 0
    try sizeBytes := FileGetSize(tempPath)
    if (sizeBytes <= 1024) {
        WriteLog("即時診斷短影片未建立有效檔案，略過上傳", "INFO")
        return false
    }

    diagDir := ResolveRuntimeDiagnosticsDir()
    latestPath := diagDir "\latest_preview.mp4"
    try FileMove(tempPath, latestPath, 1)
    catch as e {
        WriteLog("即時診斷短影片整理失敗: " e.Message, "INFO")
        return false
    }

    try {
        base64 := ReadBinaryFileBase64(latestPath)
        dataUri := "data:video/mp4;base64," base64
        if (base64 = "" || StrLen(dataUri) > RUNTIME_DIAGNOSTICS_VIDEO_MAX_DATA_URI_CHARS) {
            WriteLog("即時診斷短影片過大，略過上傳 | bytes=" sizeBytes
                " chars=" StrLen(dataUri), "INFO")
            return false
        }
        if REMOTE_CONTROL_ACTIVE
            return RC_PublishRuntimeVideoPreview(dataUri, RC_UnixMs(),
                RUNTIME_DIAGNOSTICS_VIDEO_DURATION_SEC, width, height, sizeBytes)
    } catch as e {
        WriteLog("即時診斷短影片上傳準備失敗: " e.Message, "INFO")
    }
    return false
}

RuntimeVideoPreviewTick() {
    global __RUNTIME_DIAGNOSTICS_ACTIVE, RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED
    global RUNTIME_DIAGNOSTICS_VIDEO_INTERVAL_SEC, RUNTIME_DIAGNOSTICS_VIDEO_DURATION_SEC
    global RUNTIME_DIAGNOSTICS_VIDEO_MAX_WIDTH, RUNTIME_DIAGNOSTICS_VIDEO_OWNER_MARKER
    global __RUNTIME_VIDEO_PREVIEW_PID, __RUNTIME_VIDEO_PREVIEW_PATH
    global __RUNTIME_VIDEO_PREVIEW_STARTED_TICK, __RUNTIME_VIDEO_LAST_CAPTURE_TICK
    global __RUNTIME_VIDEO_PREVIEW_WIDTH, __RUNTIME_VIDEO_PREVIEW_HEIGHT
    global __RUNTIME_VIDEO_FFMPEG_MISSING_WARNED, REMOTE_CONTROL_ACTIVE

    if !__RUNTIME_DIAGNOSTICS_ACTIVE || !RUNTIME_DIAGNOSTICS_VIDEO_PREVIEW_ENABLED || !REMOTE_CONTROL_ACTIVE
        return

    if (__RUNTIME_VIDEO_PREVIEW_PID > 0) {
        if (ProcessExist(__RUNTIME_VIDEO_PREVIEW_PID)
            && IsOwnedRuntimeVideoPreviewPid(__RUNTIME_VIDEO_PREVIEW_PID)) {
            timeoutMs := (RUNTIME_DIAGNOSTICS_VIDEO_DURATION_SEC + 30) * 1000
            if (__RUNTIME_VIDEO_PREVIEW_STARTED_TICK > 0
                && A_TickCount - __RUNTIME_VIDEO_PREVIEW_STARTED_TICK > timeoutMs) {
                timedOutPid := __RUNTIME_VIDEO_PREVIEW_PID
                if IsOwnedRuntimeVideoPreviewPid(timedOutPid) {
                    try ProcessClose(timedOutPid)
                    WriteLog("即時診斷短影片逾時，已只停止自有 PID=" timedOutPid, "INFO")
                } else {
                    WriteLog("即時診斷短影片逾時，但 PID 身分已改變；不執行停止以避免誤殺 PID=" timedOutPid, "INFO")
                }
                __RUNTIME_VIDEO_PREVIEW_PID := 0
                __RUNTIME_VIDEO_PREVIEW_STARTED_TICK := 0
                if (__RUNTIME_VIDEO_PREVIEW_PATH != "")
                    try FileDelete(__RUNTIME_VIDEO_PREVIEW_PATH)
                __RUNTIME_VIDEO_PREVIEW_PATH := ""
                __RUNTIME_VIDEO_LAST_CAPTURE_TICK := A_TickCount
            }
            return
        }

        finishedPath := __RUNTIME_VIDEO_PREVIEW_PATH
        finishedWidth := __RUNTIME_VIDEO_PREVIEW_WIDTH
        finishedHeight := __RUNTIME_VIDEO_PREVIEW_HEIGHT
        __RUNTIME_VIDEO_PREVIEW_PID := 0
        __RUNTIME_VIDEO_PREVIEW_PATH := ""
        __RUNTIME_VIDEO_PREVIEW_STARTED_TICK := 0
        __RUNTIME_VIDEO_LAST_CAPTURE_TICK := A_TickCount
        PublishCompletedRuntimeVideoPreview(finishedPath, finishedWidth, finishedHeight)
        try FileDelete(finishedPath)
        return
    }

    if (__RUNTIME_VIDEO_LAST_CAPTURE_TICK > 0
        && A_TickCount - __RUNTIME_VIDEO_LAST_CAPTURE_TICK < RUNTIME_DIAGNOSTICS_VIDEO_INTERVAL_SEC * 1000)
        return

    ffmpegExe := ResolveRuntimeVideoPreviewFfmpegExe()
    if (ffmpegExe = "" || !FileExist(ffmpegExe)) {
        if !__RUNTIME_VIDEO_FFMPEG_MISSING_WARNED {
            __RUNTIME_VIDEO_FFMPEG_MISSING_WARNED := true
            WriteLog("即時診斷短影片略過：找不到 ffmpeg.exe；截圖與錄影狀態仍會正常顯示", "INFO")
        }
        __RUNTIME_VIDEO_LAST_CAPTURE_TICK := A_TickCount
        return
    }
    __RUNTIME_VIDEO_FFMPEG_MISSING_WARNED := false

    diagDir := ResolveRuntimeDiagnosticsDir()
    try DirCreate(diagDir)
    catch {
        __RUNTIME_VIDEO_LAST_CAPTURE_TICK := A_TickCount
        return
    }

    width := Min(A_ScreenWidth, RUNTIME_DIAGNOSTICS_VIDEO_MAX_WIDTH)
    if Mod(width, 2)
        width -= 1
    width := Max(2, width)
    height := Max(2, Round(A_ScreenHeight * width / Max(1, A_ScreenWidth)))
    if Mod(height, 2)
        height -= 1
    tempPath := diagDir "\preview_" DllCall("GetCurrentProcessId") "_" A_TickCount ".tmp.mp4"
    try FileDelete(tempPath)

    cmd := '"' ffmpegExe '" -hide_banner -loglevel error -nostdin -y'
    cmd .= ' -f gdigrab -framerate 2 -i desktop -t ' RUNTIME_DIAGNOSTICS_VIDEO_DURATION_SEC
    cmd .= ' -vf "scale=' width ':-2" -an -c:v libx264 -preset ultrafast -tune zerolatency'
    cmd .= ' -b:v 160k -maxrate 180k -bufsize 360k -pix_fmt yuv420p -movflags +faststart'
    cmd .= ' -metadata comment="' RUNTIME_DIAGNOSTICS_VIDEO_OWNER_MARKER '" -f mp4 "' tempPath '"'
    try {
        Run(cmd, "", "Hide", &previewPid)
        if (previewPid <= 0)
            throw Error("沒有取得 PID")
        __RUNTIME_VIDEO_PREVIEW_PID := previewPid
        __RUNTIME_VIDEO_PREVIEW_PATH := tempPath
        __RUNTIME_VIDEO_PREVIEW_STARTED_TICK := A_TickCount
        __RUNTIME_VIDEO_PREVIEW_WIDTH := width
        __RUNTIME_VIDEO_PREVIEW_HEIGHT := height
    } catch as e {
        __RUNTIME_VIDEO_LAST_CAPTURE_TICK := A_TickCount
        try FileDelete(tempPath)
        WriteLog("啟動即時診斷短影片失敗: " e.Message, "INFO")
    }
}

ScheduleRuntimeErrorSnapshot(message, level := "WARN") {
    global __RUNTIME_DIAGNOSTICS_ACTIVE, __RUNTIME_SNAPSHOT_BUSY
    global __RUNTIME_LAST_ERROR_SNAPSHOT_TICK, __RUNTIME_ERROR_SNAPSHOT_PENDING
    global __RUNTIME_PENDING_REASON

    if !__RUNTIME_DIAGNOSTICS_ACTIVE || __RUNTIME_SNAPSHOT_BUSY || __RUNTIME_ERROR_SNAPSHOT_PENDING
        return false
    if (__RUNTIME_LAST_ERROR_SNAPSHOT_TICK > 0
        && A_TickCount - __RUNTIME_LAST_ERROR_SNAPSHOT_TICK < 10000)
        return false

    __RUNTIME_ERROR_SNAPSHOT_PENDING := true
    __RUNTIME_PENDING_REASON := SubStr(level ": " message, 1, 180)
    SetTimer(RuntimeErrorSnapshotTick, -200)
    return true
}

RuntimeErrorSnapshotTick() {
    global __RUNTIME_ERROR_SNAPSHOT_PENDING, __RUNTIME_PENDING_REASON
    __RUNTIME_ERROR_SNAPSHOT_PENDING := false
    reason := IsSet(__RUNTIME_PENDING_REASON) ? __RUNTIME_PENDING_REASON : "警告／錯誤"
    CaptureRuntimeSnapshot(reason, true)
}

PruneRuntimeDiagnosticScreenshots(keepCount) {
    diagDir := ResolveRuntimeDiagnosticsDir()
    files := []
    Loop Files, diagDir "\error_*.jpg", "F" {
        files.Push({path: A_LoopFileFullPath, modified: A_LoopFileTimeModified})
    }
    if (files.Length <= keepCount)
        return 0

    i := 1
    while (i <= files.Length - 1) {
        j := i + 1
        while (j <= files.Length) {
            if (files[i].modified < files[j].modified) {
                tmp := files[i]
                files[i] := files[j]
                files[j] := tmp
            }
            j += 1
        }
        i += 1
    }
    deleted := 0
    Loop files.Length - keepCount {
        try {
            FileDelete(files[keepCount + A_Index].path)
            deleted += 1
        }
    }
    return deleted
}

CaptureRuntimeSnapshot(reason := "定時快照", preserveErrorCopy := false) {
    global __RUNTIME_DIAGNOSTICS_ACTIVE, __RUNTIME_SNAPSHOT_BUSY
    global __RUNTIME_LAST_ERROR_SNAPSHOT_TICK, RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT
    global RUNTIME_DIAGNOSTICS_MAX_WIDTH, RUNTIME_DIAGNOSTICS_JPEG_QUALITY
    global REMOTE_CONTROL_ACTIVE

    if !__RUNTIME_DIAGNOSTICS_ACTIVE || __RUNTIME_SNAPSHOT_BUSY
        return false
    __RUNTIME_SNAPSHOT_BUSY := true

    try {
        diagDir := ResolveRuntimeDiagnosticsDir()
        DirCreate(diagDir)
        latestPath := diagDir "\latest.jpg"
        tempPath := diagDir "\latest_" DllCall("GetCurrentProcessId") "_" A_TickCount ".tmp.jpg"
        targetWidth := Min(A_ScreenWidth, RUNTIME_DIAGNOSTICS_MAX_WIDTH)
        targetHeight := Max(1, Round(A_ScreenHeight * targetWidth / Max(1, A_ScreenWidth)))
        captureSpec := {Screenshot: [0, 0, A_ScreenWidth, A_ScreenHeight], scale: [targetWidth, ""]}

        ImagePutFile(captureSpec, tempPath, RUNTIME_DIAGNOSTICS_JPEG_QUALITY)
        if !FileExist(tempPath)
            throw Error("截圖檔未建立")
        FileMove(tempPath, latestPath, 1)

        if preserveErrorCopy {
            errorPath := diagDir "\error_" FormatTime(, "yyyyMMdd_HHmmss") "_" A_TickCount ".jpg"
            FileCopy(latestPath, errorPath, 1)
            __RUNTIME_LAST_ERROR_SNAPSHOT_TICK := A_TickCount
            PruneRuntimeDiagnosticScreenshots(RUNTIME_DIAGNOSTICS_ERROR_KEEP_COUNT)
        }

        if REMOTE_CONTROL_ACTIVE {
            base64 := ImagePutBase64(latestPath)
            dataUri := "data:image/jpeg;base64," base64
            ; 同一 Firestore 文件也會保存短影片與事件；截圖固定壓在約 28 萬字元內。
            if (StrLen(dataUri) > 280000) {
                retryPath := diagDir "\latest_retry_" A_TickCount ".tmp.jpg"
                retryWidth := Min(A_ScreenWidth, 400)
                retryHeight := Max(1, Round(A_ScreenHeight * retryWidth / Max(1, A_ScreenWidth)))
                ImagePutFile({Screenshot: [0, 0, A_ScreenWidth, A_ScreenHeight], scale: [retryWidth, ""]},
                    retryPath, 30)
                FileMove(retryPath, latestPath, 1)
                targetWidth := retryWidth
                targetHeight := retryHeight
                dataUri := "data:image/jpeg;base64," ImagePutBase64(latestPath)
            }
            RC_PublishRuntimeSnapshot(dataUri, RC_UnixMs(), SubStr(reason, 1, 180),
                targetWidth, targetHeight)
        }
        return true
    } catch as e {
        ; 這裡不能使用 WARN，否則截圖失敗會再次排程錯誤截圖。
        WriteLog("即時診斷截圖失敗: " e.Message, "INFO")
        return false
    } finally {
        __RUNTIME_SNAPSHOT_BUSY := false
        try FileDelete(tempPath)
        try FileDelete(retryPath)
    }
}

LoadScreenRecordingEnabled() {
    global CFG_FILE, SCREEN_RECORDING_SECTION, SCREEN_RECORDING_ENABLED
    global SCREEN_RECORDING_ENGINE, SCREEN_RECORDING_FFMPEG_EXE, SCREEN_RECORDING_FFMPEG_ARGS, SCREEN_RECORDING_OUTPUT_DIR, SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK, SCREEN_RECORDING_AUTO_STOP_EXTERNAL_FFMPEG
    global SCREEN_RECORDING_SEGMENT_MINUTES, SCREEN_RECORDING_AUTO_MERGE, SCREEN_RECORDING_KEEP_FINAL_COUNT
    global SCREEN_RECORDING_STOP_MODE, SCREEN_RECORDING_STOP_TEMPLATE, SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM, SCREEN_RECORDING_STOP_LRMC_TASK
    global __SCREEN_RECORDING_ACTIVE, __SCREEN_RECORDING_TEMPLATE_WARNED, __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING, __SCREEN_RECORDING_PID, __SCREEN_RECORDING_OUTPUT_PATH, __SCREEN_RECORDING_SESSION_DIR
    SCREEN_RECORDING_ENABLED := ParseBool01(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "enabled", "0"), 0)
    SCREEN_RECORDING_ENGINE := NormalizeScreenRecordingEngine(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "engine", "ffmpeg"))
    SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK := 0
    SCREEN_RECORDING_FFMPEG_EXE := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "ffmpeg_exe", ResolveDefaultScreenRecordingFfmpegExe()))
    if (SCREEN_RECORDING_FFMPEG_EXE = "")
        SCREEN_RECORDING_FFMPEG_EXE := ResolveDefaultScreenRecordingFfmpegExe()
    SCREEN_RECORDING_FFMPEG_ARGS := Trim(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "ffmpeg_args", "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -f matroska"), " `t`r`n")
    if (SCREEN_RECORDING_FFMPEG_ARGS = "")
        SCREEN_RECORDING_FFMPEG_ARGS := "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -f matroska"
    SCREEN_RECORDING_AUTO_STOP_EXTERNAL_FFMPEG := ParseBool01(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "auto_stop_external_ffmpeg", "1"), 1)
    SCREEN_RECORDING_OUTPUT_DIR := ConvertMappedPathToUnc(NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "output_dir", "recordings")))
    if (SCREEN_RECORDING_OUTPUT_DIR = "")
        SCREEN_RECORDING_OUTPUT_DIR := "recordings"
    SCREEN_RECORDING_SEGMENT_MINUTES := ToIntRange(
        IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "segment_minutes", "5"), 5, 1, 60)
    SCREEN_RECORDING_AUTO_MERGE := ParseBool01(
        IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "auto_merge", "1"), 1)
    SCREEN_RECORDING_KEEP_FINAL_COUNT := ToIntRange(
        IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "keep_final_count", "5"), 5, 1, 50)
    SCREEN_RECORDING_STOP_MODE := NormalizeScreenRecordingStopMode(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_mode", "reward_end"))
    SCREEN_RECORDING_STOP_TEMPLATE := NormalizeScreenRecordingStopTemplate(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_template", "login"))
    SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_template_custom", ""))
    SCREEN_RECORDING_STOP_LRMC_TASK := Trim(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_lrmc_task", ""), " `t`r`n")
    __SCREEN_RECORDING_TEMPLATE_WARNED := false
    __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := false
    ; 避免在錄影進行中（例如系統匣儲存設定）把 PID 清掉，導致後續無法正常停止。
    if !__SCREEN_RECORDING_ACTIVE {
        __SCREEN_RECORDING_PID := 0
        __SCREEN_RECORDING_OUTPUT_PATH := ""
        __SCREEN_RECORDING_SESSION_DIR := ""
    }
    WriteLog("螢幕錄影開關(enabled)=" SCREEN_RECORDING_ENABLED)
    WriteLog("螢幕錄影引擎(engine)=" SCREEN_RECORDING_ENGINE " ffmpeg_exe=" SCREEN_RECORDING_FFMPEG_EXE " allow_hotkey_fallback=" SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK " auto_stop_external_ffmpeg=" SCREEN_RECORDING_AUTO_STOP_EXTERNAL_FFMPEG)
    WriteLog("螢幕錄影分段=" SCREEN_RECORDING_SEGMENT_MINUTES " 分鐘 auto_merge=" SCREEN_RECORDING_AUTO_MERGE " destination=" ResolveScreenRecordingOutputDir())
    WriteLog("螢幕錄影停止條件 stop_mode=" SCREEN_RECORDING_STOP_MODE " stop_template=" SCREEN_RECORDING_STOP_TEMPLATE)
}

TryStartScreenRecording(reason := "") {
    global SCREEN_RECORDING_ENABLED, SCREEN_RECORDING_ENGINE, __SCREEN_RECORDING_ACTIVE
    global __SCREEN_RECORDING_PID, __SCREEN_RECORDING_OUTPUT_PATH, __SCREEN_RECORDING_SESSION_DIR, __SCREEN_RECORDING_LAST_WORKER_STATE

    if !SCREEN_RECORDING_ENABLED {
        WriteLog("螢幕錄影未啟用，略過開始", "INFO")
        return false
    }
    if __SCREEN_RECORDING_ACTIVE
        return true

    if (SCREEN_RECORDING_ENGINE != "ffmpeg") {
        WriteLog("錄影引擎設定無效（僅支援 ffmpeg）", "WARN")
        return false
    }

    existingPid := 0
    existingPath := ""
    precheck := EnsureScreenRecordingSessionBeforeStart(&existingPid, &existingPath)
    if (precheck = "adopted") {
        __SCREEN_RECORDING_ACTIVE := true
        __SCREEN_RECORDING_PID := existingPid
        __SCREEN_RECORDING_OUTPUT_PATH := existingPath
        __SCREEN_RECORDING_SESSION_DIR := GetRecordingSessionDirFromOutputPattern(existingPath)
        __SCREEN_RECORDING_LAST_WORKER_STATE := ""
        if (__SCREEN_RECORDING_SESSION_DIR != "")
            WriteRecordingRuntimeState(__SCREEN_RECORDING_SESSION_DIR, "recording", "已接管既有 FFmpeg 分段錄影", 1, true)
        StartScreenRecordingMaintenance()
        msg := "沿用既有 FFmpeg 螢幕錄影 PID=" existingPid
        if (existingPath != "")
            msg .= " 檔案=" existingPath
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
        return true
    }
    if (precheck = "blocked")
        return false
    if (precheck = "none")
        WriteLog("錄影接管掃描結果：未接管既有進程，將啟動新錄影", "INFO")

    if StartFfmpegScreenRecording(&outPath, &pid) {
        __SCREEN_RECORDING_ACTIVE := true
        __SCREEN_RECORDING_PID := pid
        __SCREEN_RECORDING_OUTPUT_PATH := outPath
        __SCREEN_RECORDING_SESSION_DIR := GetRecordingSessionDirFromOutputPattern(outPath)
        __SCREEN_RECORDING_LAST_WORKER_STATE := ""
        if (__SCREEN_RECORDING_SESSION_DIR != "")
            WriteRecordingRuntimeState(__SCREEN_RECORDING_SESSION_DIR, "recording", "FFmpeg 分段錄影進行中；分段同步由背景工具處理", 1, true)
        StartScreenRecordingMaintenance()
        msg := "已啟動 FFmpeg 螢幕錄影 PID=" pid " 檔案=" outPath
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
        return true
    }

    WriteLog("FFmpeg 錄影啟動失敗（已移除 Alt+F9 錄影功能）", "WARN")
    return false
}

AttachManagedScreenRecordingOnRestart(reason := "") {
    global __SCREEN_RECORDING_ACTIVE, __SCREEN_RECORDING_PID, __SCREEN_RECORDING_OUTPUT_PATH, __SCREEN_RECORDING_SESSION_DIR, __SCREEN_RECORDING_LAST_WORKER_STATE

    existingPid := 0
    existingPath := ""
    for item in EnumerateRunningFfmpegProcesses() {
        if !IsLikelyFfmpegScreenRecordingCommand(item.cmdLine)
            continue
        if !IsManagedByCurrentScriptFfmpegCommand(item.cmdLine)
            continue

        existingPid := item.pid
        existingPath := ParseFfmpegOutputPathFromCommandLine(item.cmdLine)
        break
    }

    if (existingPid > 0) {
        __SCREEN_RECORDING_ACTIVE := true
        __SCREEN_RECORDING_PID := existingPid
        __SCREEN_RECORDING_OUTPUT_PATH := existingPath
        __SCREEN_RECORDING_SESSION_DIR := GetRecordingSessionDirFromOutputPattern(existingPath)
        __SCREEN_RECORDING_LAST_WORKER_STATE := ""
        if (__SCREEN_RECORDING_SESSION_DIR != "")
            WriteRecordingRuntimeState(__SCREEN_RECORDING_SESSION_DIR, "recording", "重啟後已接管既有 FFmpeg 分段錄影", 1, true)
        StartScreenRecordingMaintenance()
        msg := "重啟接管成功：PID=" existingPid
        if (existingPath != "")
            msg .= " 檔案=" existingPath
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
        return true
    }

    __SCREEN_RECORDING_ACTIVE := false
    __SCREEN_RECORDING_PID := 0
    __SCREEN_RECORDING_OUTPUT_PATH := ""
    __SCREEN_RECORDING_SESSION_DIR := ""
    msg := "重啟接管未命中：未找到受管 FFmpeg 錄影"
    if (reason != "")
        msg .= "（" reason "）"
    WriteLog(msg, "WARN")
    return false
}

TryStopScreenRecording(reason := "") {
    global __SCREEN_RECORDING_ACTIVE, __SCREEN_RECORDING_PID, __SCREEN_RECORDING_OUTPUT_PATH, __SCREEN_RECORDING_SESSION_DIR

    if !__SCREEN_RECORDING_ACTIVE
        return false

    if (__SCREEN_RECORDING_PID <= 0) {
        WriteLog("停止錄影失敗：未持有有效 FFmpeg PID", "WARN")
        return false
    }

    pid := __SCREEN_RECORDING_PID
    sessionDir := __SCREEN_RECORDING_SESSION_DIR
    if (sessionDir = "")
        sessionDir := GetRecordingSessionDirFromOutputPattern(__SCREEN_RECORDING_OUTPUT_PATH)
    if (sessionDir != "")
        WriteRecordingRuntimeState(sessionDir, "stopping", "正在要求 FFmpeg 正常封口目前分段", 1, true)
    if StopFfmpegScreenRecording(pid) {
        SetTimer(ScreenRecordingMaintenanceTick, 0)
        __SCREEN_RECORDING_ACTIVE := false
        __SCREEN_RECORDING_PID := 0
        msg := "已停止 FFmpeg 螢幕錄影 PID=" pid
        if (__SCREEN_RECORDING_OUTPUT_PATH != "")
            msg .= " 檔案=" __SCREEN_RECORDING_OUTPUT_PATH
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
        if (sessionDir != "")
            LaunchRecordingWorker("finalize", sessionDir)
        __SCREEN_RECORDING_OUTPUT_PATH := ""
        __SCREEN_RECORDING_SESSION_DIR := ""
        return true
    }

    if (sessionDir != "")
        WriteRecordingRuntimeState(sessionDir, "stop_failed", "FFmpeg 無法正常停止；既有分段與本機工作階段已保留", ProcessExist(pid) ? 1 : 0, true)
    WriteLog("停止 FFmpeg 錄影失敗（已移除 Alt+F9 錄影功能）", "WARN")
    return false
}

ForceStopManagedScreenRecording(reason := "") {
    global __SCREEN_RECORDING_ACTIVE, __SCREEN_RECORDING_PID, __SCREEN_RECORDING_OUTPUT_PATH, __SCREEN_RECORDING_SESSION_DIR

    attempted := 0
    stopped := 0
    seen := Map()
    finalizeSessions := Map()

    if (__SCREEN_RECORDING_PID > 0) {
        pidKey := String(__SCREEN_RECORDING_PID)
        seen[pidKey] := 1
        rememberedSession := __SCREEN_RECORDING_SESSION_DIR
        if (rememberedSession = "")
            rememberedSession := GetRecordingSessionDirFromOutputPattern(__SCREEN_RECORDING_OUTPUT_PATH)
        if (rememberedSession != "")
            finalizeSessions[StrLower(rememberedSession)] := rememberedSession
        attempted += 1
        if StopFfmpegScreenRecording(__SCREEN_RECORDING_PID) {
            stopped += 1
            WriteLog("保底停錄：已停止記憶中的 FFmpeg PID=" __SCREEN_RECORDING_PID)
        } else {
            WriteLog("保底停錄：停止記憶中的 FFmpeg 失敗 PID=" __SCREEN_RECORDING_PID, "WARN")
        }
    }

    for item in EnumerateRunningFfmpegProcesses() {
        if !IsLikelyFfmpegScreenRecordingCommand(item.cmdLine)
            continue
        if !IsManagedByCurrentScriptFfmpegCommand(item.cmdLine)
            continue

        pidKey := String(item.pid)
        if seen.Has(pidKey)
            continue
        seen[pidKey] := 1
        itemSession := GetRecordingSessionDirFromOutputPattern(ParseFfmpegOutputPathFromCommandLine(item.cmdLine))
        if (itemSession != "")
            finalizeSessions[StrLower(itemSession)] := itemSession

        attempted += 1
        if StopFfmpegScreenRecording(item.pid) {
            stopped += 1
            WriteLog("保底停錄：已停止受管 FFmpeg PID=" item.pid)
        } else {
            WriteLog("保底停錄：停止受管 FFmpeg 失敗 PID=" item.pid, "WARN")
        }
    }

    if (stopped > 0) {
        SetTimer(ScreenRecordingMaintenanceTick, 0)
        __SCREEN_RECORDING_ACTIVE := false
        __SCREEN_RECORDING_PID := 0
        __SCREEN_RECORDING_OUTPUT_PATH := ""
        __SCREEN_RECORDING_SESSION_DIR := ""
        msg := "保底停錄完成：共停止 " stopped " 個受管 FFmpeg"
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
        for _, sessionDir in finalizeSessions
            LaunchRecordingWorker("finalize", sessionDir)
        return true
    }

    if (attempted > 0) {
        msg := "保底停錄：有受管 FFmpeg 但未能停止"
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg, "WARN")
        return false
    }

    WriteLog("保底停錄：未發現受管 FFmpeg 進程", "INFO")
    return false
}

NormalizeScreenRecordingEngine(val) {
    return "ffmpeg"
}

ResolveScreenRecordingOutputDir() {
    global SCREEN_RECORDING_OUTPUT_DIR

    p := ConvertMappedPathToUnc(NormalizePath(SCREEN_RECORDING_OUTPUT_DIR))
    if (p = "")
        p := "recordings"

    if RegExMatch(p, "i)^[a-z]:\\")
        return p
    if (SubStr(p, 1, 2) = "\\")
        return p
    return A_ScriptDir "\" p
}

ResolveRecordingStagingRoot() {
    localBase := NormalizePath(EnvGet("LOCALAPPDATA"))
    if (localBase = "")
        localBase := A_Temp
    return localBase "\WutheringAuto\recording_staging"
}

RecordingUnixMs() {
    ft := Buffer(8, 0)
    DllCall("GetSystemTimeAsFileTime", "ptr", ft.Ptr)
    t := NumGet(ft, 0, "Int64")
    return (t // 10000) - 11644473600000
}

WriteRecordingRuntimeState(sessionDir, state, detail := "", captureActive := -1, publishNow := false) {
    global REMOTE_CONTROL_ACTIVE
    ini := sessionDir "\session.ini"
    if (sessionDir = "" || !FileExist(ini))
        return false

    try {
        updatedAt := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        updatedMs := RecordingUnixMs()
        if (captureActive >= 0)
            IniWrite(captureActive ? "1" : "0", ini, "recording", "capture_active")
        IniWrite(state, ini, "recording", "state")
        IniWrite(detail, ini, "recording", "state_detail")
        IniWrite(updatedAt, ini, "recording", "state_updated_at")
        IniWrite(updatedMs, ini, "recording", "state_updated_unix_ms")

        destinationDir := NormalizePath(IniRead(ini, "recording", "destination_dir", ""))
        baseName := Trim(IniRead(ini, "recording", "base_name", ""), ' "`t`r`n')
        autoMerge := IniRead(ini, "recording", "auto_merge", "1") = "1"
        isCaptureActive := IniRead(ini, "recording", "capture_active", "0") = "1"
        destinationSegments := (destinationDir != "" && baseName != "")
            ? destinationDir "\" baseName "_segments" : ""
        finalPath := (autoMerge && destinationDir != "" && baseName != "")
            ? destinationDir "\" baseName ".mkv" : ""
        resultPath := autoMerge ? finalPath : destinationSegments
        stagingRoot := ResolveRecordingStagingRoot()
        statusPath := stagingRoot "\recording_status.ini"
        DirCreate(stagingRoot)
        IniWrite(state, statusPath, "recording", "state")
        IniWrite(detail, statusPath, "recording", "state_detail")
        IniWrite(updatedAt, statusPath, "recording", "state_updated_at")
        IniWrite(updatedMs, statusPath, "recording", "state_updated_unix_ms")
        IniWrite(sessionDir, statusPath, "recording", "local_session_dir")
        IniWrite(destinationDir, statusPath, "recording", "destination_dir")
        IniWrite(destinationSegments, statusPath, "recording", "destination_segments_dir")
        IniWrite(finalPath, statusPath, "recording", "final_path")
        IniWrite(resultPath, statusPath, "recording", "result_path")
        IniWrite(sessionDir, statusPath, "recording", "failure_storage")
        IniWrite(stagingRoot "\recording_worker.log", statusPath, "recording", "worker_log_path")
        IniWrite(baseName, statusPath, "recording", "base_name")
        IniWrite(autoMerge ? "1" : "0", statusPath, "recording", "auto_merge")
        IniWrite(isCaptureActive ? "1" : "0", statusPath, "recording", "capture_active")
        if (publishNow && REMOTE_CONTROL_ACTIVE)
            try RC_ReportRuntimeState()
        return true
    } catch as e {
        WriteLog("寫入錄影狀態失敗: " e.Message, "INFO")
        return false
    }
}

GetRecordingSessionDirFromOutputPattern(outputPath) {
    p := NormalizePath(outputPath)
    if (p = "")
        return ""
    dir := ""
    SplitPath(p, , &dir)
    if (dir = "" || !FileExist(dir "\.wuthering_recording_session"))
        return ""
    return dir
}

WriteRecordingSessionMetadata(sessionDir, destinationDir, baseName, ffmpegExe) {
    global SCREEN_RECORDING_SEGMENT_MINUTES, SCREEN_RECORDING_AUTO_MERGE, SCREEN_RECORDING_KEEP_FINAL_COUNT
    global CFG_FILE
    try {
        DirCreate(sessionDir)
        marker := sessionDir "\.wuthering_recording_session"
        if !FileExist(marker)
            FileAppend("WUTHERING_RECORDING_SESSION_V2", marker, "UTF-8")
        ini := sessionDir "\session.ini"
        IniWrite(destinationDir, ini, "recording", "destination_dir")
        IniWrite(baseName, ini, "recording", "base_name")
        IniWrite(ffmpegExe, ini, "recording", "ffmpeg_exe")
        IniWrite(CFG_FILE, ini, "recording", "config_path")
        IniWrite(SCREEN_RECORDING_SEGMENT_MINUTES, ini, "recording", "segment_minutes")
        IniWrite(SCREEN_RECORDING_AUTO_MERGE ? "1" : "0", ini, "recording", "auto_merge")
        IniWrite(SCREEN_RECORDING_KEEP_FINAL_COUNT, ini, "recording", "keep_final_count")
        IniWrite(FormatTime(, "yyyy-MM-dd HH:mm:ss"), ini, "recording", "started_at")
        IniWrite("0", ini, "recording", "capture_active")
        if !WriteRecordingRuntimeState(sessionDir, "starting", "已建立本機錄影工作階段，準備啟動 FFmpeg", 0)
            throw Error("無法初始化持久錄影狀態")
        return true
    } catch as e {
        WriteLog("建立錄影工作階段失敗: " e.Message, "ERROR")
        return false
    }
}

StartScreenRecordingMaintenance() {
    global SCREEN_RECORDING_MAINTENANCE_INTERVAL_MS
    SetTimer(ScreenRecordingMaintenanceTick, 0)
    SetTimer(ScreenRecordingMaintenanceTick, SCREEN_RECORDING_MAINTENANCE_INTERVAL_MS)
    SetTimer(() => ScreenRecordingMaintenanceTick(), -3000)
}

ScreenRecordingMaintenanceTick() {
    global __SCREEN_RECORDING_ACTIVE, __SCREEN_RECORDING_SESSION_DIR
    global __SCREEN_RECORDING_SYNC_WORKER_PID, __SCREEN_RECORDING_LAST_WORKER_STATE
    if !__SCREEN_RECORDING_ACTIVE || __SCREEN_RECORDING_SESSION_DIR = ""
        return
    if (__SCREEN_RECORDING_SYNC_WORKER_PID > 0 && ProcessExist(__SCREEN_RECORDING_SYNC_WORKER_PID))
        return
    __SCREEN_RECORDING_SYNC_WORKER_PID := 0

    state := ""
    detail := ""
    try state := IniRead(__SCREEN_RECORDING_SESSION_DIR "\session.ini", "recording", "state", "")
    try detail := IniRead(__SCREEN_RECORDING_SESSION_DIR "\session.ini", "recording", "state_detail", "")
    stateSignature := state "|" detail
    if (stateSignature != "|" && stateSignature != __SCREEN_RECORDING_LAST_WORKER_STATE) {
        __SCREEN_RECORDING_LAST_WORKER_STATE := stateSignature
        if InStr(state, "waiting")
            WriteLog("錄影補傳狀態=" state " | " detail, "WARN")
        else
            WriteLog("錄影補傳狀態=" state " | " detail)
    }
    LaunchRecordingWorker("sync", __SCREEN_RECORDING_SESSION_DIR)
}

LaunchRecordingWorker(mode, sessionDir) {
    global BUNDLED_AHK_EXE, __SCREEN_RECORDING_SYNC_WORKER_PID
    workerPath := A_ScriptDir "\RecordingFinalizeWorker.ahk"
    if (!FileExist(workerPath) || !FileExist(BUNDLED_AHK_EXE)) {
        if (StrLower(mode) = "finalize")
            WriteRecordingRuntimeState(sessionDir, "worker_missing", "錄影背景收尾工具或 AutoHotkey 執行檔缺失", 0, true)
        WriteLog("錄影背景工具缺失，無法執行 " mode " | worker=" workerPath, "ERROR")
        return false
    }
    if (sessionDir = "" || !FileExist(sessionDir "\.wuthering_recording_session"))
        return false

    normalizedMode := StrLower(mode)
    if (normalizedMode = "sync") {
        if (__SCREEN_RECORDING_SYNC_WORKER_PID > 0 && ProcessExist(__SCREEN_RECORDING_SYNC_WORKER_PID))
            return true
    } else if (normalizedMode = "finalize") {
        ; 若剛好仍在補傳上一段，先給它完成；逾時就停止我們自己的 helper，
        ; 殘留 .partial 會由收尾 worker 覆寫，不會當成完成檔。
        if (__SCREEN_RECORDING_SYNC_WORKER_PID > 0 && ProcessExist(__SCREEN_RECORDING_SYNC_WORKER_PID)) {
            deadline := A_TickCount + 30000
            while (A_TickCount < deadline && ProcessExist(__SCREEN_RECORDING_SYNC_WORKER_PID))
                Sleep 200
            if ProcessExist(__SCREEN_RECORDING_SYNC_WORKER_PID) {
                try ProcessClose(__SCREEN_RECORDING_SYNC_WORKER_PID)
                Sleep 300
            }
        }
        __SCREEN_RECORDING_SYNC_WORKER_PID := 0
        WriteRecordingRuntimeState(sessionDir, "finalize_pending", "錄影已停止，等待補傳、合併與驗證", 0, true)
    } else
        return false

    cmd := '"' BUNDLED_AHK_EXE '" "' workerPath '" --mode ' normalizedMode
    cmd .= ' --session "' sessionDir '"'
    try {
        Run(cmd, A_ScriptDir, "Hide", &workerPid)
        if (workerPid <= 0)
            throw Error("背景工具未回傳有效 PID")
        if (normalizedMode = "sync")
            __SCREEN_RECORDING_SYNC_WORKER_PID := workerPid
        WriteLog("已啟動錄影背景工具 mode=" normalizedMode " PID=" workerPid " session=" sessionDir)
        return workerPid > 0
    } catch as e {
        if (normalizedMode = "finalize")
            WriteRecordingRuntimeState(sessionDir, "worker_start_failed", "啟動錄影背景收尾工具失敗: " e.Message, 0, true)
        WriteLog("啟動錄影背景工具失敗 mode=" normalizedMode " | " e.Message, "ERROR")
        return false
    }
}

RecoverPendingRecordingSessions() {
    stagingRoot := ResolveRecordingStagingRoot()
    if !DirExist(stagingRoot)
        return 0

    activeDirs := Map()
    for item in EnumerateRunningFfmpegProcesses() {
        if !IsManagedByCurrentScriptFfmpegCommand(item.cmdLine)
            continue
        activeDir := GetRecordingSessionDirFromOutputPattern(ParseFfmpegOutputPathFromCommandLine(item.cmdLine))
        if (activeDir != "")
            activeDirs[StrLower(activeDir)] := 1
    }

    launched := 0
    Loop Files, stagingRoot "\wuthering_auto_recording_*", "D" {
        sessionDir := A_LoopFileFullPath
        if !FileExist(sessionDir "\.wuthering_recording_session")
            continue
        if activeDirs.Has(StrLower(sessionDir))
            continue
        state := ""
        try state := IniRead(sessionDir "\session.ini", "recording", "state", "")
        if (state = "complete")
            continue
        if LaunchRecordingWorker("finalize", sessionDir)
            launched += 1
    }
    if (launched > 0)
        WriteLog("已恢復待收尾錄影工作階段 " launched " 個", "WARN")
    return launched
}

PruneScreenRecordingFiles(keepCount := 5) {
    outDir := ResolveScreenRecordingOutputDir()
    if !DirExist(outDir)
        return 0

    files := []
    Loop Files, outDir "\\*.mkv", "F" {
        files.Push({ path: A_LoopFileFullPath, modified: A_LoopFileTimeModified })
    }

    if (files.Length <= keepCount)
        return 0

    ; AHK v2.0.19 的 Array 沒有 Sort 方法，這裡用簡單交換排序（新->舊）。
    i := 1
    while (i <= files.Length - 1) {
        j := i + 1
        while (j <= files.Length) {
            if (files[i].modified < files[j].modified) {
                tmp := files[i]
                files[i] := files[j]
                files[j] := tmp
            }
            j += 1
        }
        i += 1
    }

    deleted := 0
    Loop (files.Length - keepCount) {
        target := files[keepCount + A_Index]
        try {
            FileDelete(target.path)
            deleted += 1
        }
    }

    if (deleted > 0)
        WriteLog("錄影檔清理完成，僅保留最新 " keepCount " 個，已刪除 " deleted " 個舊檔")
    return deleted
}

StartFfmpegScreenRecording(&outPath, &pid) {
    global SCREEN_RECORDING_FFMPEG_EXE, SCREEN_RECORDING_FFMPEG_ARGS, SCREEN_RECORDING_OWNER_MARKER
    global SCREEN_RECORDING_SEGMENT_MINUTES

    outPath := ""
    pid := 0

    ffmpegExe := ResolveScreenRecordingFfmpegExePath(SCREEN_RECORDING_FFMPEG_EXE)
    if (ffmpegExe = "") {
        WriteLog("主程式資料夾內找不到 ffmpeg.exe", "WARN")
        return false
    }

    ts := FormatTime(A_Now, "yyyyMMdd_HHmmss")
    baseName := "wuthering_auto_recording_" ts
    destinationDir := ResolveScreenRecordingOutputDir()
    ; 執行期不在主執行緒碰網路分享，避免離線 SMB 的系統 timeout 卡住自動流程。
    ; 真正的建立／複製／重試全部交給獨立 worker；錄影永遠先在本機開始。
    WriteLog("錄影採本機優先；目的端將由背景工具檢查與補傳 | destination=" destinationDir)

    stagingRoot := ResolveRecordingStagingRoot()
    try DirCreate(stagingRoot)
    catch as e {
        WriteLog("建立本機錄影暫存資料夾失敗: " e.Message, "ERROR")
        return false
    }
    sessionDir := stagingRoot "\" baseName "_" A_TickCount
    try DirCreate(sessionDir)
    catch as e {
        WriteLog("建立錄影工作階段資料夾失敗: " e.Message, "ERROR")
        return false
    }
    if !WriteRecordingSessionMetadata(sessionDir, destinationDir, baseName, ffmpegExe) {
        try DirDelete(sessionDir, true)
        return false
    }

    outPath := sessionDir "\segment_%05d.mkv"
    segmentListPath := sessionDir "\segments.ffconcat"
    args := Trim(SCREEN_RECORDING_FFMPEG_ARGS, " `t`r`n")
    if (args = "")
        args := "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -f matroska"
    ; 舊設定把單一輸出的 matroska muxer 放在參數尾端；分段模式改由 segment muxer
    ; 管理每個 MKV，因此只移除尾端的輸出格式宣告，保留所有擷取與編碼參數。
    args := RegExReplace(args, "i)\s+-f\s+matroska\s*$", "")
    segmentSeconds := Max(60, SCREEN_RECORDING_SEGMENT_MINUTES * 60)
    keyframeArgs := ""
    if RegExMatch(args, "i)(libx264|libx265|h264_nvenc|hevc_nvenc)")
        keyframeArgs := ' -force_key_frames "expr:gte(t,n_forced*' segmentSeconds ')"'

    cmd := '"' ffmpegExe '" ' args keyframeArgs
    cmd .= ' -metadata comment="' SCREEN_RECORDING_OWNER_MARKER '"'
    cmd .= ' -f segment -segment_time ' segmentSeconds
    cmd .= ' -reset_timestamps 1 -segment_format matroska'
    cmd .= ' -segment_list_type ffconcat -segment_list "' segmentListPath '"'
    cmd .= ' "' outPath '"'
    try {
        Run(cmd, "", "Hide", &pid)
        if (pid <= 0) {
            WriteRecordingRuntimeState(sessionDir, "start_failed", "FFmpeg 未回傳有效 PID，未產生可用影片", 0, true)
            try DirDelete(sessionDir, true)
            return false
        }

        Sleep 800
        if !ProcessExist(pid) {
            WriteRecordingRuntimeState(sessionDir, "start_failed", "FFmpeg 啟動後立即退出；請查看主程式 log", 0, true)
            return false
        }
        WriteRecordingRuntimeState(sessionDir, "recording", "FFmpeg 分段錄影進行中；分段同步由背景工具處理", 1)
        WriteLog("FFmpeg 分段錄影已啟動 | segment=" SCREEN_RECORDING_SEGMENT_MINUTES
            "min | staging=" sessionDir " | destination=" destinationDir)
        return true
    } catch as e {
        WriteRecordingRuntimeState(sessionDir, "start_failed", "啟動 FFmpeg 失敗: " e.Message, 0, true)
        WriteLog("啟動 FFmpeg 失敗: " e.Message, "WARN")
        return false
    }
}

EnsureScreenRecordingSessionBeforeStart(&existingPid, &existingOutPath) {
    global SCREEN_RECORDING_AUTO_STOP_EXTERNAL_FFMPEG

    existingPid := 0
    existingOutPath := ""

    recordingFound := false
    externalCount := 0
    externalPids := []
    scannedRecordingCount := 0

    for item in EnumerateRunningFfmpegProcesses() {
        cmdLine := item.cmdLine
        if !IsLikelyFfmpegScreenRecordingCommand(cmdLine)
            continue

        scannedRecordingCount += 1
        recordingFound := true
        if IsManagedByCurrentScriptFfmpegCommand(cmdLine) {
            existingPid := item.pid
            existingOutPath := ParseFfmpegOutputPathFromCommandLine(cmdLine)
            WriteLog("錄影接管命中：PID=" existingPid (existingOutPath != "" ? " 檔案=" existingOutPath : ""))
            return "adopted"
        }

        externalCount += 1
        externalPids.Push(item.pid)
    }

    if !recordingFound {
        WriteLog("錄影接管掃描：未發現任何 ffmpeg 錄影進程", "INFO")
        return "none"
    }
    if (externalCount <= 0)
        return "none"

    WriteLog("錄影接管掃描：共找到 " scannedRecordingCount " 個錄影進程，其中外部進程 " externalCount " 個", "INFO")

    if !SCREEN_RECORDING_AUTO_STOP_EXTERNAL_FFMPEG {
        WriteLog("偵測到外部 FFmpeg 錄影（" externalCount " 個），已停用自動停止外部錄影，略過本次啟動", "WARN")
        return "blocked"
    }

    stopped := 0
    for _, pid in externalPids {
        if StopFfmpegScreenRecording(pid)
            stopped += 1
        else
            WriteLog("停止外部 FFmpeg 錄影失敗，PID=" pid, "WARN")
    }

    remaining := 0
    for item in EnumerateRunningFfmpegProcesses() {
        if !IsLikelyFfmpegScreenRecordingCommand(item.cmdLine)
            continue
        if IsManagedByCurrentScriptFfmpegCommand(item.cmdLine)
            continue
        remaining += 1
    }

    if (remaining > 0) {
        WriteLog("仍有 " remaining " 個外部 FFmpeg 錄影未能停止，為避免衝突，略過本次啟動", "WARN")
        return "blocked"
    }

    if (stopped > 0)
        WriteLog("已停止外部 FFmpeg 錄影 " stopped " 個，改由本程式重新啟動錄影", "WARN")
    return "none"
}

EnumerateRunningFfmpegProcesses() {
    out := []
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name='ffmpeg.exe'") {
            pid := 0
            cmdLine := ""
            try pid := proc.ProcessId + 0
            try cmdLine := proc.CommandLine
            if (pid > 0)
                out.Push({ pid: pid, cmdLine: cmdLine })
        }
    } catch as e {
        WriteLog("掃描 ffmpeg 進程失敗: " e.Message, "WARN")
    }
    return out
}

IsLikelyFfmpegScreenRecordingCommand(cmdLine) {
    s := StrLower(Trim(cmdLine, " `t`r`n"))
    if (s = "")
        return false
    if !InStr(s, "ffmpeg")
        return false
    if IsRuntimeVideoPreviewFfmpegCommand(s)
        return false
    if (InStr(s, "-f gdigrab") && InStr(s, "-i desktop"))
        return true
    if (InStr(s, "-f dshow") && InStr(s, "-i") && InStr(s, "video="))
        return true
    return false
}

IsRuntimeVideoPreviewFfmpegCommand(cmdLine) {
    global RUNTIME_DIAGNOSTICS_VIDEO_OWNER_MARKER
    marker := StrLower(Trim(RUNTIME_DIAGNOSTICS_VIDEO_OWNER_MARKER, " `t`r`n"))
    return marker != "" && InStr(StrLower(cmdLine), marker) ? true : false
}

IsManagedByCurrentScriptFfmpegCommand(cmdLine) {
    global SCREEN_RECORDING_OWNER_MARKER

    candidate := StrLower(StrReplace(Trim(cmdLine, " `t`r`n"), "/", "\\"))
    if (candidate = "")
        return false

    marker := StrLower(Trim(SCREEN_RECORDING_OWNER_MARKER, " `t`r`n"))
    if (marker != "" && InStr(candidate, marker))
        return true

    outDir := StrLower(StrReplace(ResolveScreenRecordingOutputDir(), "/", "\\"))
    if (SubStr(outDir, -1) = "\\")
        outDir := SubStr(outDir, 1, -1)

    hasManagedPrefix := InStr(candidate, "wuthering_auto_recording_") || InStr(candidate, "\\recording_")
    isInManagedDir := (outDir != "") && InStr(candidate, outDir "\\")
    return hasManagedPrefix && isInManagedDir
}

ParseFfmpegOutputPathFromCommandLine(cmdLine) {
    if RegExMatch(cmdLine, 'i)"([^"]+\.mkv)"\s*$', &m)
        return m[1]
    if RegExMatch(cmdLine, 'i)([^\s]+\.mkv)\s*$', &m)
        return m[1]
    return ""
}

StopFfmpegScreenRecording(pid) {
    if (pid <= 0)
        return false

    if !ProcessExist(pid)
        return true

    ; 先把目前程序附加到 FFmpeg 的 console，送出 Ctrl+C，讓 FFmpeg 寫完
    ; 當前 MKV 的 cues/index 後自行結束。舊版在等待前就 taskkill，正是最後影片
    ; 可能損壞的主因。SetConsoleCtrlHandler 讓本腳本忽略同一個 Ctrl+C。
    signaled := false
    attached := false
    try {
        attached := DllCall("Kernel32\AttachConsole", "uint", pid, "int") ? true : false
        if attached {
            DllCall("Kernel32\SetConsoleCtrlHandler", "ptr", 0, "int", true)
            signaled := DllCall("Kernel32\GenerateConsoleCtrlEvent", "uint", 0, "uint", 0, "int") ? true : false
            Sleep 120
            DllCall("Kernel32\FreeConsole")
            DllCall("Kernel32\SetConsoleCtrlHandler", "ptr", 0, "int", false)
        }
    } catch {
        if attached
            try DllCall("Kernel32\FreeConsole")
        try DllCall("Kernel32\SetConsoleCtrlHandler", "ptr", 0, "int", false)
    }

    if signaled
        WriteLog("已向 FFmpeg PID=" pid " 送出 Ctrl+C，等待分段正常封口")
    else {
        WriteLog("無法向 FFmpeg PID=" pid " 送出 Ctrl+C，改嘗試關閉視窗", "WARN")
        try {
            hwnd := WinExist("ahk_pid " pid)
            if hwnd
                WinClose("ahk_id " hwnd)
        }
    }

    deadlineSoft := A_TickCount + 15000
    while (A_TickCount < deadlineSoft) {
        if !ProcessExist(pid)
            return true
        Sleep 100
    }

    ; 超過 15 秒仍未結束才強制停止；之前已完成的五分鐘分段不受影響。
    WriteLog("FFmpeg PID=" pid " 在 15 秒內未正常結束，執行強制停止；最後未封口分段可能需捨棄", "WARN")
    try ProcessClose(pid)

    deadlineHard := A_TickCount + 2000
    while (A_TickCount < deadlineHard) {
        if !ProcessExist(pid)
            return true
        Sleep 100
    }

    try RunWait('taskkill /F /PID ' pid, , "Hide")
    Sleep 150
    return !ProcessExist(pid)
}

NormalizeScreenRecordingStopMode(val) {
    s := StrLower(Trim(val, " `t`r`n"))
    if (s = "reward_end" || s = "lrmc_task_end")
        return s
    return "reward_end"
}

NormalizeScreenRecordingStopTemplate(val) {
    s := StrLower(Trim(val, " `t`r`n"))
    if (s = "login" || s = "close" || s = "custom")
        return s
    return "login"
}

ResolveScreenRecordingStopTemplatePath() {
    global SCREEN_RECORDING_STOP_TEMPLATE, SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM

    if (SCREEN_RECORDING_STOP_TEMPLATE = "login")
        return A_ScriptDir "\登入.png"
    if (SCREEN_RECORDING_STOP_TEMPLATE = "close")
        return A_ScriptDir "\0510.png"

    p := NormalizePath(SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM)
    if (p = "")
        return ""

    if RegExMatch(p, "i)^[a-z]:\\")
        return p
    if (SubStr(p, 1, 2) = "\\\\")
        return p
    return A_ScriptDir "\" p
}

TryStopScreenRecordingByMode(stage) {
    global SCREEN_RECORDING_ENABLED, SCREEN_RECORDING_STOP_MODE

    if !SCREEN_RECORDING_ENABLED
        return false
    if (SCREEN_RECORDING_STOP_MODE = "reward_end" && stage = "reward_end")
        return TryStopScreenRecording("收尾監測達標")
    return false
}

NormalizeZhTaskText(s) {
    t := StrLower(Trim(s, " `t`r`n"))
    if (t = "")
        return ""

    ; 常見繁簡轉換，覆蓋任務名常見字
    t := StrReplace(t, "嶼", "屿")
    t := StrReplace(t, "區", "区")
    t := StrReplace(t, "務", "务")
    t := StrReplace(t, "達", "达")
    t := StrReplace(t, "終", "终")
    t := StrReplace(t, "點", "点")
    t := StrReplace(t, "時", "时")
    t := StrReplace(t, "領", "领")
    t := StrReplace(t, "獎", "奖")
    t := StrReplace(t, "體", "体")
    t := StrReplace(t, "經", "经")

    t := RegExReplace(t, "[\s\-_:：，,。.!！？()（）\[\]{}]+", "")
    return t
}

IsLrmcArrivalLine(line) {
    t := NormalizeZhTaskText(line)
    if (t = "")
        return false
    return (InStr(t, "到达终点") || InStr(t, "判定为到达终点"))
}

IsLrmcRewardOrStaminaLine(line) {
    t := NormalizeZhTaskText(line)
    if (t = "")
        return false
    return InStr(t, "已经领取奖励或体力不足了") ? true : false
}

ParseLrmcTaskPackageName(line) {
    t := Trim(line, " `t`r`n")
    if (t = "")
        return ""
    if !(InStr(t, "任务包:") || InStr(t, "任務包:"))
        return ""

    p := RegExReplace(t, "^.*?(任务包:|任務包:)", "")
    p := RegExReplace(p, "(用时|用時)[:：].*$", "")
    p := Trim(p, " `t`r`n")
    if (p = "")
        return ""

    last := p
    if InStr(p, "\\") {
        arr := StrSplit(p, "\\")
        if (arr.Length > 0)
            last := arr[arr.Length]
    } else if InStr(p, "/") {
        arr := StrSplit(p, "/")
        if (arr.Length > 0)
            last := arr[arr.Length]
    }

    return Trim(last, " `t`r`n")
}

IsLrmcTaskPackageDurationLine(line) {
    t := Trim(line, " `t`r`n")
    if (t = "")
        return false
    if !(InStr(t, "任务包:") || InStr(t, "任務包:"))
        return false

    ; 例：用时:12秒 / 用時：12.5秒
    return RegExMatch(t, "(用时|用時)\s*[:：]\s*\d+(\.\d+)?\s*秒") ? true : false
}

TryStopScreenRecordingByLrmcTaskLine(line) {
    global SCREEN_RECORDING_ENABLED, SCREEN_RECORDING_STOP_MODE, SCREEN_RECORDING_STOP_LRMC_TASK, __SCREEN_RECORDING_ACTIVE, __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING

    if !SCREEN_RECORDING_ENABLED
        return false
    if !__SCREEN_RECORDING_ACTIVE
        return false
    if (SCREEN_RECORDING_STOP_MODE != "lrmc_task_end")
        return false

    if IsLrmcArrivalLine(line) {
        __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := true
        WriteLog("錄影任務停止：已偵測到到達終點，等待任務包行", "INFO")
        return false
    }

    if IsLrmcRewardOrStaminaLine(line) {
        __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := true
        WriteLog("錄影任務停止：已偵測到領獎/體力不足，等待任務包行", "INFO")
        return false
    }

    target := NormalizeZhTaskText(SCREEN_RECORDING_STOP_LRMC_TASK)
    if (target = "")
        return false

    lineNorm := NormalizeZhTaskText(line)
    taskName := ParseLrmcTaskPackageName(line)
    if (taskName = "") {
        ; 後備判定：任務包行同段帶有用時，且整行包含目標任務名。
        if (IsLrmcTaskPackageDurationLine(line) && InStr(lineNorm, target)) {
            __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := false
            WriteLog("錄影任務停止命中（任務包整行比對）: " SCREEN_RECORDING_STOP_LRMC_TASK)
            return TryStopScreenRecording("LRMCAI任務包完成")
        }
        return false
    }

    current := NormalizeZhTaskText(taskName)

    isMatched := (InStr(current, target) || InStr(target, current) || InStr(lineNorm, target) || InStr(target, lineNorm))
    if !isMatched {
        if __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING {
            __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := false
            WriteLog("錄影任務停止未命中：" taskName "（設定=" SCREEN_RECORDING_STOP_LRMC_TASK "）", "INFO")
        }
        return false
    }

    ; 新增條件：任務包行同段帶有「用時：..秒」可直接視為任務包完成。
    if IsLrmcTaskPackageDurationLine(line) {
        __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := false
        WriteLog("錄影任務停止命中（任務包用時）：" taskName "（設定=" SCREEN_RECORDING_STOP_LRMC_TASK "）")
        return TryStopScreenRecording("LRMCAI任務包完成")
    }

    if !__SCREEN_RECORDING_LRMC_ARRIVAL_PENDING
        return false

    __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := false
    WriteLog("錄影任務停止命中：" taskName "（設定=" SCREEN_RECORDING_STOP_LRMC_TASK "）")
    return TryStopScreenRecording("LRMCAI任務完成")
}

TryStopScreenRecordingByTemplate() {
    global SCREEN_RECORDING_ENABLED, SCREEN_RECORDING_STOP_MODE, __SCREEN_RECORDING_ACTIVE, __SCREEN_RECORDING_TEMPLATE_WARNED

    if !SCREEN_RECORDING_ENABLED
        return false
    if !__SCREEN_RECORDING_ACTIVE
        return false
    if (SCREEN_RECORDING_STOP_MODE != "template")
        return false

    templatePath := ResolveScreenRecordingStopTemplatePath()
    if (templatePath = "") {
        if !__SCREEN_RECORDING_TEMPLATE_WARNED {
            WriteLog("螢幕錄影模板停止條件未設定有效模板路徑", "WARN")
            __SCREEN_RECORDING_TEMPLATE_WARNED := true
        }
        return false
    }
    if !FileExist(templatePath) {
        if !__SCREEN_RECORDING_TEMPLATE_WARNED {
            WriteLog("螢幕錄影模板檔不存在: " templatePath, "WARN")
            __SCREEN_RECORDING_TEMPLATE_WARNED := true
        }
        return false
    }

    x := 0
    y := 0
    try {
        if ImageSearch(&x, &y, 0, 0, A_ScreenWidth, A_ScreenHeight, templatePath) {
            WriteLog("螢幕錄影停止模板命中: " templatePath " @" x "," y)
            return TryStopScreenRecording("模板命中")
        }
    } catch as e {
        if !__SCREEN_RECORDING_TEMPLATE_WARNED {
            WriteLog("螢幕錄影模板檢測失敗: " e.Message, "WARN")
            __SCREEN_RECORDING_TEMPLATE_WARNED := true
        }
    }
    return false
}

ParseBool01(val, defaultVal := 1) {
    s := StrLower(Trim(val, " `t`r`n"))
    if (s = "")
        return defaultVal
    if (s = "1" || s = "true" || s = "yes" || s = "on")
        return 1
    if (s = "0" || s = "false" || s = "no" || s = "off")
        return 0
    return defaultVal
}

ParseServerScheduleList(raw) {
    out := []
    seen := Map()
    if !IsSet(raw)
        return out

    txt := StrReplace(raw, "`r", "`n")
    token := ""
    depth := 0

    Loop Parse, txt {
        ch := A_LoopField

        if (ch = "(" || ch = "（") {
            depth += 1
            token .= ch
            continue
        }

        if (ch = ")" || ch = "）") {
            if (depth > 0)
                depth -= 1
            token .= ch
            continue
        }

        isSeparator := (ch = "," || ch = ";" || ch = "|" || ch = "`n")
        if (isSeparator && depth = 0) {
            name := Trim(token, " `t`r`n")
            if (name != "") {
                key := StrLower(name)
                if !seen.Has(key) {
                    seen[key] := 1
                    out.Push(name)
                }
            }
            token := ""
            continue
        }

        token .= ch
    }

    name := Trim(token, " `t`r`n")
    if (name != "") {
        key := StrLower(name)
        if !seen.Has(key) {
            seen[key] := 1
            out.Push(name)
        }
    }
    return out
}

NormalizeServerMatchText(s) {
    t := StrLower(Trim(s, " `t`r`n"))
    if (t = "")
        return ""

    ; 常見伺服器名稱別名正規化（中英互通）
    t := StrReplace(t, "亞洲", "asia")
    t := StrReplace(t, "亚服", "asia")
    t := StrReplace(t, "亞服", "asia")
    t := StrReplace(t, "東南亞", "sea")
    t := StrReplace(t, "东南亚", "sea")
    t := StrReplace(t, "美洲", "america")
    t := StrReplace(t, "美服", "america")
    t := StrReplace(t, "歐洲", "europe")
    t := StrReplace(t, "欧洲", "europe")
    t := StrReplace(t, "歐服", "europe")
    t := StrReplace(t, "欧服", "europe")
    t := StrReplace(t, "港澳台", "hmt")

    ; 去除括號內容，讓「HMT(HK, MO, TW)」與「HMT」可以互相命中
    t := RegExReplace(t, "\([^)]*\)", "")
    t := RegExReplace(t, "（[^）]*）", "")

    ; 去除常見空白與分隔符，降低 OCR 標點差異影響
    t := RegExReplace(t, "[\s,，;；|]", "")
    return t
}

IsServerTargetMatch(ocrText, targetText) {
    a := NormalizeServerMatchText(ocrText)
    b := NormalizeServerMatchText(targetText)
    if (a = "" || b = "")
        return false

    ; 先做雙向包含，再回退到原字串包含
    if (InStr(a, b) || InStr(b, a))
        return true
    return InStr(StrLower(ocrText), StrLower(targetText)) ? true : false
}

IsLikelyServerNameText(ocrText) {
    t := NormalizeServerMatchText(ocrText)
    if (t = "")
        return false

    ; 常見伺服器名稱或縮寫（含 OCR 常見變形）
    if (InStr(t, "hmt") || InStr(t, "asia") || InStr(t, "sea") || InStr(t, "america") || InStr(t, "europe"))
        return true

    ; 例如 HMT(HK, MO, TW) 去括號後可能殘留 hk/mo/tw
    if (InStr(t, "hk") || InStr(t, "mo") || InStr(t, "tw"))
        return true

    return false
}

IsServerConfirmText(ocrText) {
    t := Trim(StrReplace(StrReplace(ocrText, "`r", ""), "`n", ""), " `t")
    if (t = "")
        return false

    return (InStr(t, "確認") || InStr(t, "确认") || InStr(t, "確定") || InStr(t, "确定"))
}

LoadServerScheduleContext(isContinueCycle := false) {
    global CFG_FILE, SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_LIST, SERVER_SCHEDULE_INDEX, CURRENT_SERVER_TARGET, SERVER_SWITCH_POINT_X, SERVER_SWITCH_POINT_Y

    SERVER_SCHEDULE_ENABLED := ParseBool01(IniReadSafe(CFG_FILE, "server_schedule", "enabled", "0"), 0) ? true : false
    rawList := Trim(IniReadSafe(CFG_FILE, "server_schedule", "list", ""), " `t`r`n")
    SERVER_SCHEDULE_LIST := ParseServerScheduleList(rawList)

    WriteLog("伺服器排程狀態載入：enabled=" (SERVER_SCHEDULE_ENABLED ? "1" : "0") ", 清單=" rawList " (" SERVER_SCHEDULE_LIST.Length " 項)")

    sx := Trim(IniReadSafe(CFG_FILE, "server_schedule", "switch_x", "640"), " `t`r`n")
    sy := Trim(IniReadSafe(CFG_FILE, "server_schedule", "switch_y", "549"), " `t`r`n")
    SERVER_SWITCH_POINT_X := (sx ~= "^\d+$") ? Integer(sx) : 640
    SERVER_SWITCH_POINT_Y := (sy ~= "^\d+$") ? Integer(sy) : 549

    if (!SERVER_SCHEDULE_ENABLED || SERVER_SCHEDULE_LIST.Length = 0) {
        CURRENT_SERVER_TARGET := ""
        SERVER_SCHEDULE_INDEX := 1
        WriteLog("伺服器排程未啟用或清單為空，不執行切服")
        return
    }

    idxRaw := Trim(IniReadSafe(CFG_FILE, "server_schedule", "current_index", "1"), " `t`r`n")
    idx := (idxRaw ~= "^\d+$") ? Integer(idxRaw) : 1
    if !isContinueCycle
        idx := 1

    if (idx < 1)
        idx := 1
    if (idx > SERVER_SCHEDULE_LIST.Length)
        idx := 1

    resolvedIdx := ResolveNextPendingServerIndexInCurrentCycle(idx)
    if (resolvedIdx = 0) {
        SERVER_SCHEDULE_INDEX := 1
        CURRENT_SERVER_TARGET := ""
        IniWrite "1", CFG_FILE, "server_schedule", "current_index"
        WriteLog("伺服器排程：今日循環所有伺服器都已完成，啟動時不指定切服目標", "WARN")
        return
    }

    if (resolvedIdx != idx)
        WriteLog("伺服器排程：已自動略過今日已完成伺服器，改用第 " resolvedIdx " 個目標")
    idx := resolvedIdx

    SERVER_SCHEDULE_INDEX := idx
    CURRENT_SERVER_TARGET := SERVER_SCHEDULE_LIST[idx]
    IniWrite idx, CFG_FILE, "server_schedule", "current_index"
    WriteLog("伺服器排程已載入：第 " idx "/" SERVER_SCHEDULE_LIST.Length " 個，目標=" CURRENT_SERVER_TARGET)
    SyncRemoteControlRuntimeState()
}

ResolveNextPendingServerIndexInCurrentCycle(startIdx := 1) {
    global SERVER_SCHEDULE_LIST

    total := SERVER_SCHEDULE_LIST.Length
    if (total <= 0)
        return 0

    idx := startIdx
    if (idx < 1 || idx > total)
        idx := 1

    Loop total {
        current := idx + (A_Index - 1)
        if (current > total)
            current -= total

        server := SERVER_SCHEDULE_LIST[current]
        if !IsServerCompletedInCurrentCycle(server)
            return current
    }

    return 0
}

AdvanceServerScheduleForNextCycle() {
    global CFG_FILE, SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_LIST, SERVER_SCHEDULE_INDEX

    if (!SERVER_SCHEDULE_ENABLED || SERVER_SCHEDULE_LIST.Length <= 1)
        return false

    nextIndex := SERVER_SCHEDULE_INDEX + 1
    if (nextIndex > SERVER_SCHEDULE_LIST.Length) {
        IniWrite "1", CFG_FILE, "server_schedule", "current_index"
        WriteLog("伺服器排程已完成全部清單，本輪後不再續跑")
        return false
    }

    IniWrite nextIndex, CFG_FILE, "server_schedule", "current_index"
    WriteLog("伺服器排程切換到下一個：第 " nextIndex "/" SERVER_SCHEDULE_LIST.Length " 個")
    SyncRemoteControlRuntimeState()
    return true
}

SyncRemoteControlRuntimeState() {
    global REMOTE_CONTROL_ACTIVE

    if (REMOTE_CONTROL_ACTIVE)
        RC_ReportRuntimeState()
}

GetOcrBlockCenter(block) {
    if (block.HasOwnProp("boxPoint") && IsObject(block.boxPoint)) {
        minX := 2147483647, minY := 2147483647
        maxX := -2147483648, maxY := -2147483648
        found := false
        for _, pt in block.boxPoint {
            if (!IsObject(pt) || !pt.HasOwnProp("x") || !pt.HasOwnProp("y"))
                continue
            x := pt.x, y := pt.y
            if (x < minX)
                minX := x
            if (y < minY)
                minY := y
            if (x > maxX)
                maxX := x
            if (y > maxY)
                maxY := y
            found := true
        }
        if found
            return [Round((minX + maxX) / 2), Round((minY + maxY) / 2)]
    }
    if (block.HasOwnProp("box") && IsObject(block.box)) {
        minX := 2147483647, minY := 2147483647
        maxX := -2147483648, maxY := -2147483648
        found := false
        for _, pt in block.box {
            if (!IsObject(pt) || pt.Length < 2)
                continue
            x := pt[1], y := pt[2]
            if (x < minX)
                minX := x
            if (y < minY)
                minY := y
            if (x > maxX)
                maxX := x
            if (y > maxY)
                maxY := y
            found := true
        }
        if found
            return [Round((minX + maxX) / 2), Round((minY + maxY) / 2)]
    }
    return ""
}

ServerClickClient(hwnd, x, y, logText := "") {
    if !hwnd
        return false

    oldMouseMode := A_CoordModeMouse
    try WinActivate "ahk_id " hwnd
    Sleep 100
    CoordMode "Mouse", "Client"

    MouseMove Round(x), Round(y)
    Sleep 50
    Click
    Sleep 100

    CoordMode "Mouse", oldMouseMode
    if (logText != "")
        WriteLog(logText "，點擊客戶區座標=" Round(x) "," Round(y))
    return true
}

MapReferencePointToClient(hwnd, refX, refY, refW := 1280, refH := 720) {
    if !hwnd
        return ""

    try WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " hwnd)
    catch
        return ""

    if (cw <= 0 || ch <= 0 || refW <= 0 || refH <= 0)
        return ""

    px := cx + Round((refX * cw) / refW)
    py := cy + Round((refY * ch) / refH)
    return [px, py, cw, ch]
}

TrySelectScheduledServer(hwnd, attempt := 1) {
    global CURRENT_SERVER_TARGET, SERVER_SWITCH_POINT_X, SERVER_SWITCH_POINT_Y

    WriteStep("伺服器切換", "入口 target=" CURRENT_SERVER_TARGET " attempt=" attempt)

    if (CURRENT_SERVER_TARGET = "") {
        WriteStepResult("伺服器切換", true, "目標為空，略過")
        return true
    }
    if !hwnd
        return false

    maxAttempts := 3
    if (attempt > maxAttempts) {
        WriteStepResult("伺服器切換", false, "超過最大重試")
        return false
    }

    WriteLog("伺服器排程：準備選擇伺服器 -> " CURRENT_SERVER_TARGET "（嘗試 " attempt "/" maxAttempts "）")
    try WinActivate "ahk_id " hwnd
    try WinRestore "ahk_id " hwnd
    WinWaitActive "ahk_id " hwnd, , 3
    Sleep 400

    ; 先在登入畫面做一次 OCR：若已是目標伺服器，直接略過切換，不做任何點擊
    preMatched := false
    preTempFile := A_Temp "\\server_precheck_" A_TickCount ".png"
    WriteLog("伺服器排程：開始預檢登入畫面是否已是目標伺服器 (" CURRENT_SERVER_TARGET ")")
    try {
        ImagePutFile(hwnd, preTempFile)
        preOcr := RapidOcr()
        preRes := preOcr.ocr_from_file(preTempFile, , true)
        ocrRecognized := ""
        if IsObject(preRes) {
            for block in preRes {
                txt := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
                if (txt = "")
                    continue
                ocrRecognized .= (ocrRecognized = "" ? "" : " | ") txt
                if IsServerTargetMatch(txt, CURRENT_SERVER_TARGET) {
                    preMatched := true
                    break
                }
            }
            WriteLog("伺服器排程：預檢 OCR 辨識結果：" ocrRecognized)
        } else {
            WriteLog("伺服器排程：預檢 OCR 無結果（res 不是物件）", "WARN")
        }
    } catch as e {
        WriteLog("伺服器排程：預檢 OCR 失敗，改走切服流程: " e.Message, "WARN")
    }
    try FileDelete(preTempFile)

    if preMatched {
        WriteLog("伺服器排程：登入畫面已是目標伺服器 " CURRENT_SERVER_TARGET "，略過切換動作")
        WriteStepResult("伺服器切換", true, "已是目標伺服器")
        return true
    }

    if (CURRENT_SERVER_TARGET = "") {
        WriteLog("伺服器排程：目標伺服器為空，略過切換")
        WriteStepResult("伺服器切換", true, "目標為空")
        return true
    }

    WriteLog("伺服器排程：登入畫面不是目標伺服器，需要執行切換 -> " CURRENT_SERVER_TARGET)

    WriteLog("伺服器排程：準備用 OCR 找伺服器名稱區塊並點擊開選單")

    tempFile := A_Temp "\\server_menu_" A_TickCount ".png"
    serverMenuOpened := false
    menuOpenBy := ""
    try {
        ImagePutFile(hwnd, tempFile)
        ocr := RapidOcr()
        res := ocr.ocr_from_file(tempFile, , true)
        if IsObject(res) {
            for block in res {
                txt := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
                if (txt = "")
                    continue

                c := GetOcrBlockCenter(block)
                if (IsObject(c) && IsLikelyServerNameText(txt)) {
                    ServerClickClient(hwnd, c[1], c[2], "伺服器排程：找到伺服器名稱區塊（" txt "）")
                    serverMenuOpened := true
                    menuOpenBy := "server-name"
                    Sleep 1600
                    break
                }
            }
        }
    } catch as e {
        WriteLog("伺服器排程：OCR 掃伺服器名稱區塊失敗: " e.Message, "WARN")
    }
    try FileDelete(tempFile)

    ; 若 OCR 沒找到伺服器名稱區塊，直接用客戶區內固定座標（例如 640,549）
    if !serverMenuOpened {
        ServerClickClient(hwnd, SERVER_SWITCH_POINT_X, SERVER_SWITCH_POINT_Y, "伺服器排程：OCR 未找到伺服器名稱區塊，改用客戶區固定座標=" SERVER_SWITCH_POINT_X "," SERVER_SWITCH_POINT_Y)
        Sleep 1600
    } else {
        WriteLog("伺服器排程：已開啟伺服器選單，方式=" menuOpenBy)
    }

    tempFile := A_Temp "\\server_pick_" A_TickCount ".png"
    try {
        ImagePutFile(hwnd, tempFile)
        ocr := RapidOcr()
        res := ocr.ocr_from_file(tempFile, , true)
    } catch as e {
        WriteLog("伺服器排程：OCR 失敗: " e.Message, "WARN")
        try FileDelete(tempFile)
        Sleep 800
        return TrySelectScheduledServer(hwnd, attempt + 1)
    }
    try FileDelete(tempFile)

    targetClicked := false

    if IsObject(res) {
        for block in res {
            txt := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
            if (txt = "")
                continue

            if (!targetClicked && IsServerTargetMatch(txt, CURRENT_SERVER_TARGET)) {
                c := GetOcrBlockCenter(block)
                if IsObject(c) {
                    ServerClickClient(hwnd, c[1], c[2], "伺服器排程：已點選伺服器 " CURRENT_SERVER_TARGET "（OCR: " txt "）")
                    targetClicked := true
                    Sleep 500
                    break
                }
            }
        }
    }

    if !targetClicked {
        WriteLog("伺服器排程：未在列表中找到目標伺服器文字 -> " CURRENT_SERVER_TARGET, "WARN")
        WriteStepResult("伺服器切換", false, "找不到目標伺服器文字")
        Sleep 800
        return TrySelectScheduledServer(hwnd, attempt + 1)
    }

    ; 點選伺服器後需再點擊「確認」
    confirmClicked := false
    tempFile := A_Temp "\\server_confirm_" A_TickCount ".png"
    try {
        ImagePutFile(hwnd, tempFile)
        ocr := RapidOcr()
        resConfirm := ocr.ocr_from_file(tempFile, , true)
        if IsObject(resConfirm) {
            for block in resConfirm {
                txt := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
                if (txt = "")
                    continue

                if IsServerConfirmText(txt) {
                    c := GetOcrBlockCenter(block)
                    if IsObject(c) {
                        ServerClickClient(hwnd, c[1], c[2], "伺服器排程：已點擊確認按鈕（OCR: " txt "）")
                        confirmClicked := true
                        Sleep 600
                        break
                    }
                }
            }
        }
    } catch as e {
        WriteLog("伺服器排程：OCR 掃確認按鈕失敗: " e.Message, "WARN")
    }
    try FileDelete(tempFile)

    if !confirmClicked {
        confirmX := 890
        confirmY := 543
        ServerClickClient(hwnd, confirmX, confirmY, "伺服器排程：未找到確認文字，改用固定確認座標")
        Sleep 600
        confirmClicked := true
    }

    if confirmClicked {
        WriteLog("伺服器排程：伺服器切換完成 -> " CURRENT_SERVER_TARGET)
        WriteStepResult("伺服器切換", true, "target=" CURRENT_SERVER_TARGET)
        return true
    }

    WriteLog("伺服器排程：確認按鈕點擊失敗，準備重試", "WARN")
    WriteStepResult("伺服器切換", false, "確認按鈕點擊失敗")
    Sleep 800
    return TrySelectScheduledServer(hwnd, attempt + 1)
}

SetupTrayMenu() {
    try {
        A_TrayMenu.Delete("開啟設定 UI")
    }
    try {
        A_TrayMenu.Delete("離開腳本（立即）")
    }

    A_TrayMenu.Add("開啟設定 UI", OpenSettingsFromTray)
    A_TrayMenu.Add("離開腳本（立即）", ExitFromTrayNow)
    A_TrayMenu.Add()
}

ExitFromTrayNow(*) {
    global EXITING_FROM_TRAY, REMOTE_PAUSE_WAITING, __RESTART_IN_PROGRESS, REMOTE_STOP_IN_PROGRESS
    if EXITING_FROM_TRAY
        return

    EXITING_FROM_TRAY := true
    REMOTE_PAUSE_WAITING := false
    REMOTE_STOP_IN_PROGRESS := true
    ; 使用者手動退出應視為完整關閉，不沿用重啟流程的「保留錄影」判定。
    __RESTART_IN_PROGRESS := false
    try RC_SetPausedFlag(false)
    try WriteLog("系統匣：使用者請求立即離開，改走完整關閉流程")
    ShutdownGameLrmcOkww(false)
}

OpenSettingsFromTray(*) {
    global CFG_FILE, MAIL_SECTION

    WriteLog("使用者由系統匣開啟設定 UI")
    state := ReadCombinedConfigState()
    ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, "由系統匣手動開啟設定")
    if ok {
        LoadMailNotifyEnabled()
        LoadScreenRecordingEnabled()
        WriteLog("系統匣設定已儲存")
        ShowTip("✅ 設定已儲存", 1200)
    } else {
        WriteLog("系統匣設定已取消", "WARN")
        ShowTip("⚠️ 已取消設定", 1200)
    }
}

OnCombinedSetupCancel(*) {
    global __MAIL_SETUP
    __MAIL_SETUP.saved := false
    __MAIL_SETUP.done := true
    try __MAIL_SETUP.gui.Destroy()
}

OnCombinedSetupClose(*) {
    global __MAIL_SETUP
    __MAIL_SETUP.saved := false
    __MAIL_SETUP.done := true
}

SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl := "1") {
    psFile := A_Temp "\send_mail_main_" A_TickCount ".ps1"
    errFile := A_Temp "\send_mail_main_err_" A_TickCount ".txt"
    recipients := ParseMailRecipients(mailTo)
    if (recipients.Length = 0)
        return { ok: false, message: "收件者為空，請在 to 填入至少一位收件者" }

    mailToCsv := ""
    for idx, addr in recipients {
        if (idx > 1)
            mailToCsv .= ","
        mailToCsv .= addr
    }

    escHost := PsEsc(smtpHost)
    escUser := PsEsc(smtpUser)
    escPass := PsEsc(smtpPass)
    escFrom := PsEsc(mailFrom)
    escToCsv := PsEsc(mailToCsv)
    escSubject := PsEsc(subject)
    escBody := PsEsc(body)

    script := "$ErrorActionPreference = 'Stop'`n"
    script .= "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12`n"
    script .= "$smtpHost = '" escHost "'`n"
    script .= "$smtpPort = " smtpPort "`n"
    script .= "$smtpUser = '" escUser "'`n"
    script .= "$smtpPass = '" escPass "'`n"
    script .= "$mailFrom = '" escFrom "'`n"
    script .= "$mailToCsv = '" escToCsv "'`n"
    script .= "$subject = '" escSubject "'`n"
    script .= "$body = '" escBody "'`n"
    script .= "$useSsl = " ((useSsl = "1" || StrLower(useSsl) = "true") ? "$true" : "$false") "`n"
    script .= "try {`n"
    script .= "  $msg = New-Object System.Net.Mail.MailMessage`n"
    script .= "  $msg.From = $mailFrom`n"
    script .= "  $mailToList = $mailToCsv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }`n"
    script .= "  foreach ($to in $mailToList) { $msg.To.Add($to) }`n"
    script .= "  $msg.Subject = $subject`n"
    script .= "  $msg.Body = $body`n"
    script .= "  $msg.BodyEncoding = [System.Text.Encoding]::UTF8`n"
    script .= "  $msg.SubjectEncoding = [System.Text.Encoding]::UTF8`n"
    script .= "  $smtp = New-Object System.Net.Mail.SmtpClient($smtpHost, $smtpPort)`n"
    script .= "  $smtp.UseDefaultCredentials = $false`n"
    script .= "  $smtp.EnableSsl = $useSsl`n"
    script .= "  $smtp.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $smtpPass)`n"
    script .= "  $smtp.Send($msg)`n"
    script .= "  exit 0`n"
    script .= "} catch {`n"
    script .= "  $m = $_.Exception.Message`n"
    script .= "  if ($_.Exception.InnerException) { $m += ' | Inner: ' + $_.Exception.InnerException.Message }`n"
    script .= "  Write-Output $m`n"
    script .= "  exit 1`n"
    script .= "}`n"

    try FileDelete(psFile)
    try FileDelete(errFile)
    FileAppend(script, psFile, "UTF-8")

    cmd := A_ComSpec ' /D /C ""powershell" -NoProfile -ExecutionPolicy Bypass -File "' psFile '" > "' errFile '" 2>&1"'
    exitCode := RunWait(cmd, , "Hide")

    errMsg := ""
    try errMsg := Trim(FileRead(errFile, "UTF-8"), "`r`n`t ")
    if (errMsg = "")
        try errMsg := Trim(FileRead(errFile), "`r`n`t ")

    try FileDelete(psFile)
    try FileDelete(errFile)

    if (exitCode = 0)
        return { ok: true, message: "" }

    if (errMsg = "")
        errMsg := "PowerShell SMTP 呼叫失敗，ExitCode=" exitCode
    return { ok: false, message: errMsg }
}

ParseMailRecipients(mailToText) {
    text := StrReplace(mailToText, "`r`n", ",")
    text := StrReplace(text, "`n", ",")
    text := StrReplace(text, ";", ",")

    recipients := []
    for _, part in StrSplit(text, ",") {
        addr := Trim(part, " `t`r`n")
        if (addr != "")
            recipients.Push(addr)
    }
    return recipients
}

PsEsc(text) {
    return StrReplace(text, "'", "''")
}


; =========================================================
; 額外模板檢測與點擊邏輯
; =========================================================
FindTemplateOnScreenWithTolerance(templatePath, &outX, &outY, x1, y1, x2, y2) {
    outX := 0
    outY := 0
    oldPixelMode := A_CoordModePixel
    CoordMode "Pixel", "Screen"
    variations := [0, 20, 30, 40, 60]
    try {
        for _, v in variations {
            spec := (v > 0) ? ("*" v " " templatePath) : templatePath
            try {
                if ImageSearch(&outX, &outY, x1, y1, x2, y2, spec)
                    return true
            } catch {
                continue
            }
        }
    } finally {
        CoordMode "Pixel", oldPixelMode
    }
    return false
}

IsValidImagePutSearchHit(hit, haystack) {
    return IsObject(hit)
        && hit.Length >= 2
        && hit[1] >= 0
        && hit[2] >= 0
        && hit[1] < haystack.width
        && hit[2] < haystack.height
}

FindTemplateInWutheringWindow(templatePath, &outX, &outY, activateWindow := false) {
    outX := 0
    outY := 0
    hwnd := GetWutheringGameHwnd()
    if !hwnd
        return false

    splitPath templatePath, &tplName

    ; 預設採 PrintWindow client-only 背景截圖，不還原、不啟用、不置頂鳴潮。
    ; 回傳值仍轉成螢幕座標，讓既有點擊流程可以直接使用。
    if !activateWindow {
        try {
            ; ImagePut 遇最小化視窗可能先以 SW_SHOWNOACTIVATE 還原；
            ; client 座標必須在截圖後取得，避免沿用最小化位置。
            frame := ImagePutBuffer("ahk_id " hwnd)
            WinGetClientPos(&clientX, &clientY, &clientW, &clientH, "ahk_id " hwnd)
            if (clientW <= 0 || clientH <= 0)
                return false

            searchFrame := frame
            templateFrame := ImagePutBuffer(templatePath)
            ; ImagePut 預設以模板中心為錨點；點擊流程需要左上座標。
            templateFrame.x := 0
            templateFrame.y := 0
            offsetX := 0
            offsetY := 0

            ; 叉叉模板只搜尋背景 client 的右上區塊。
            if (tplName = "0510.png") {
                offsetX := Floor(frame.width * 0.50)
                roiW := frame.width - offsetX
                roiH := Max(1, Floor(frame.height * 0.25))
                if (roiW <= 0 || roiH <= 0)
                    return false
                searchFrame := frame.Crop(offsetX, 0, roiW, roiH)
            }

            for _, v in [0, 20, 30, 40, 60] {
                hit := searchFrame.ImageSearch(templateFrame, v)
                if IsValidImagePutSearchHit(hit, searchFrame) {
                    outX := clientX + offsetX + hit[1]
                    outY := clientY + offsetY + hit[2]
                    return true
                }
            }
        } catch as e {
            WriteLog("鳴潮背景模板搜尋失敗: " templatePath " | " e.Message, "WARN")
        }
        return false
    }

    if (activateWindow) {
        topmostPulse := false
        try {
            WinRestore("ahk_id " hwnd)
            WinSetAlwaysOnTop(1, "ahk_id " hwnd)
            topmostPulse := true
            WinActivate("ahk_id " hwnd)
            Sleep 80
        } finally {
            if (topmostPulse && WinExist("ahk_id " hwnd))
                try WinSetAlwaysOnTop(0, "ahk_id " hwnd)
        }
    }

    try {
        WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
        if (ww <= 0 || wh <= 0)
            return false

        x1 := Max(0, wx)
        y1 := Max(0, wy)
        x2 := Min(A_ScreenWidth - 1, wx + ww - 1)
        y2 := Min(A_ScreenHeight - 1, wy + wh - 1)

        ; 叉叉模板只在遊戲視窗右上區塊搜尋，避免誤命中左上或中間的相似圖示。
        if (tplName = "0510.png") {
            roiLeft := wx + Floor(ww * 0.50)
            roiTop := wy
            roiRight := wx + ww - 1
            roiBottom := wy + Floor(wh * 0.25)
            x1 := Max(0, roiLeft)
            y1 := Max(0, roiTop)
            x2 := Min(A_ScreenWidth - 1, roiRight)
            y2 := Min(A_ScreenHeight - 1, roiBottom)
            WriteLog("叉叉模板使用右上四分之一ROI搜尋: " x1 "," y1 " -> " x2 "," y2)
        }

        if (x2 <= x1 || y2 <= y1)
            return false

        return FindTemplateOnScreenWithTolerance(templatePath, &outX, &outY, x1, y1, x2, y2)
    }

    return false
}

ClickTemplateIfFound(templatePath, logIfMissing := true, activateWindowForSearch := false) {
    x := 0
    y := 0
    oldMode := A_CoordModeMouse
    topmostForClickHwnd := 0
    try {
        found := FindTemplateInWutheringWindow(templatePath, &x, &y, activateWindowForSearch)
        if !found
            found := FindTemplateOnScreenWithTolerance(templatePath, &x, &y, 0, 0, A_ScreenWidth - 1, A_ScreenHeight - 1)

        if found {
            splitPath templatePath, &tplName
            clickX := x
            clickY := y
            if GetImageFileSize(templatePath, &imgW, &imgH) {
                clickX := x + Floor(imgW / 2)
                clickY := y + Floor(imgH / 2)
            } else {
                ; 取不到尺寸時回退，至少不要點在左上角。
                clickX := x + 8
                clickY := y + 8
            }

            clickX := Min(A_ScreenWidth - 1, Max(0, clickX))
            clickY := Min(A_ScreenHeight - 1, Max(0, clickY))

            CoordMode "Mouse", "Screen"
            hwnd := GetWutheringGameHwnd()
            if (hwnd) {
                try {
                    WinRestore("ahk_id " hwnd)
                    ; 收尾監測採背景搜尋；只有真的找到模板、準備點擊時才短暫置頂。
                    if !activateWindowForSearch {
                        WinSetAlwaysOnTop(1, "ahk_id " hwnd)
                        topmostForClickHwnd := hwnd
                        Sleep 80
                    }
                    WinActivate("ahk_id " hwnd)
                    WinWaitActive("ahk_id " hwnd, , 0.8)
                }
            }

            ; 主通道：實體滑鼠點擊
            MouseMove clickX, clickY
            Sleep 40
            MouseClick "left", clickX, clickY
            WriteLog("模板檢測到並點擊(滑鼠): " . templatePath . " @" . clickX . "," . clickY)

            ; 備援通道：對遊戲視窗發送客戶區點擊訊息，避免滑鼠被鎖視角時失效
            if (hwnd && WinExist("ahk_id " hwnd)) {
                try {
                    pt := Buffer(8, 0)
                    NumPut("int", clickX, pt, 0)
                    NumPut("int", clickY, pt, 4)
                    DllCall("ScreenToClient", "ptr", hwnd, "ptr", pt)
                    cx := NumGet(pt, 0, "int")
                    cy := NumGet(pt, 4, "int")
                    if (cx >= 0 && cy >= 0) {
                        lParam := (cy << 16) | (cx & 0xFFFF)
                        PostMessage 0x201, 1, lParam, , "ahk_id " hwnd
                        Sleep 20
                        PostMessage 0x202, 0, lParam, , "ahk_id " hwnd
                        WriteLog("模板點擊備援(PostMessage)已送出: client=" cx "," cy)
                    }
                } catch as e {
                    WriteLog("模板點擊備援(PostMessage)失敗: " e.Message, "WARN")
                }
            }

            ; 叉叉按鈕額外補一個「右下偏移」點，兼容部分場景把滑鼠中心對到目標中心而非尖端。
            if (tplName = "0510.png") {
                tipOffsetX := 12
                tipOffsetY := 12
                clickX2 := Min(A_ScreenWidth - 1, Max(0, clickX + tipOffsetX))
                clickY2 := Min(A_ScreenHeight - 1, Max(0, clickY + tipOffsetY))
                MouseMove clickX2, clickY2
                Sleep 30
                MouseClick "left", clickX2, clickY2
                WriteLog("叉叉模板補點擊(尖端補償): base=" clickX "," clickY " -> offset=" clickX2 "," clickY2)

                if (hwnd && WinExist("ahk_id " hwnd)) {
                    try {
                        pt2 := Buffer(8, 0)
                        NumPut("int", clickX2, pt2, 0)
                        NumPut("int", clickY2, pt2, 4)
                        DllCall("ScreenToClient", "ptr", hwnd, "ptr", pt2)
                        cx2 := NumGet(pt2, 0, "int")
                        cy2 := NumGet(pt2, 4, "int")
                        if (cx2 >= 0 && cy2 >= 0) {
                            lParam2 := (cy2 << 16) | (cx2 & 0xFFFF)
                            PostMessage 0x201, 1, lParam2, , "ahk_id " hwnd
                            Sleep 20
                            PostMessage 0x202, 0, lParam2, , "ahk_id " hwnd
                            WriteLog("叉叉補點擊備援(PostMessage): client=" cx2 "," cy2)
                        }
                    } catch as e {
                        WriteLog("叉叉補點擊備援(PostMessage)失敗: " e.Message, "WARN")
                    }
                }
            }
            return true
        }
    } catch as e {
        ; 可選檢測：任何錯誤都不影響主流程。
        WriteLog("模板檢測略過（不影響主流程）: " . templatePath . " | " . e.Message, "WARN")
        return false
    } finally {
        if (topmostForClickHwnd && WinExist("ahk_id " topmostForClickHwnd)) {
            try WinSetAlwaysOnTop(0, "ahk_id " topmostForClickHwnd)
        }
        CoordMode "Mouse", oldMode
    }
    if (logIfMissing)
        WriteLog("模板未檢測到: " . templatePath, "INFO")
    return false
}

TryAssistLoginTemplateBeforeOcr() {
    static lastAttemptTick := 0
    static warnedMissingTemplate := false

    intervalMs := 1000
    nowTick := A_TickCount
    if (nowTick - lastAttemptTick < intervalMs)
        return
    lastAttemptTick := nowTick

    loginTemplate := A_ScriptDir "\登入.png"
    if !FileExist(loginTemplate) {
        if !warnedMissingTemplate {
            warnedMissingTemplate := true
            WriteLog("OCR 前模板輔助：找不到登入.png，略過此輔助機制", "WARN")
        }
        return
    }
    warnedMissingTemplate := false

    if ClickTemplateIfFound(loginTemplate, false)
        WriteLog("OCR 前模板輔助：已檢測到登入.png並點擊")
}

GetImageFileSize(path, &w, &h) {
    w := 0
    h := 0
    try {
        hBitmap := LoadPicture(path)
        if !hBitmap
            return false

        ; BITMAP 結構在 x64 需要 32 bytes，x86 為 24 bytes。
        bmpSize := (A_PtrSize = 8) ? 32 : 24
        bmp := Buffer(bmpSize, 0)
        if (DllCall("GetObject", "ptr", hBitmap, "int", bmpSize, "ptr", bmp.Ptr, "int") <= 0) {
            DllCall("DeleteObject", "ptr", hBitmap)
            return false
        }

        w := NumGet(bmp, 4, "int")
        h := NumGet(bmp, 8, "int")
        DllCall("DeleteObject", "ptr", hBitmap)
        return (w > 0 && h > 0)
    } catch {
        return false
    }
}
