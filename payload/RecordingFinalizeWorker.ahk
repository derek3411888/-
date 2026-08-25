#Requires AutoHotkey v2.0+
#SingleInstance Off

; 錄影分段的背景同步／收尾工具。
; --mode sync     ：錄影進行中，只複製已封口的分段（略過最新一段）。
; --mode finalize ：錄影停止後補傳全部分段、無損合併、驗證並安全清理。

mode := StrLower(WorkerArgValue("--mode", "sync"))
sessionDir := WorkerNormalizePath(WorkerArgValue("--session", ""))
if (mode != "sync" && mode != "finalize")
    ExitApp(2)
if !WorkerIsSafeSessionDir(sessionDir)
    ExitApp(3)

mutexHandle := WorkerAcquireSessionMutex(sessionDir)
if (mutexHandle <= 0) {
    if (mode = "sync")
        ExitApp(0)

    ; 上一個主程序若在補傳中意外退出，sync worker 可能仍短暫持有 mutex。
    ; finalize 不可假裝成功後消失；等候最多 90 秒，再交給下次啟動恢復。
    Loop 90 {
        Sleep 1000
        mutexHandle := WorkerAcquireSessionMutex(sessionDir)
        if (mutexHandle > 0)
            break
    }
    if (mutexHandle <= 0) {
        detail := "收尾等待既有同步工具 90 秒仍未取得鎖；保留工作階段供下次恢復"
        WorkerWriteState(sessionDir, "finalize_waiting", detail)
        WorkerLog(sessionDir, detail, "WARN")
        ExitApp(7)
    }
}

try {
    if (mode = "sync")
        ExitApp(WorkerSyncSession(sessionDir, false) ? 0 : 4)

    ; finalize 只會在螢幕擷取程序已停止後執行；同步把狀態寫成非錄影中。
    try IniWrite("0", sessionDir "\session.ini", "recording", "capture_active")

    ; 正常流程已退出後仍由這個背景 worker 負責收尾。若家中共用資料夾暫時
    ; 離線，只針對網路同步／複製失敗每分鐘重試，最多兩小時；本機分段與
    ; 合併檔始終保留。電腦關機中斷時，下次主程式啟動還會再次恢復。
    Loop 120 {
        if WorkerFinalizeSession(sessionDir)
            ExitApp(0)
        state := ""
        try state := IniRead(sessionDir "\session.ini", "recording", "state", "")
        if (state != "sync_waiting" && state != "copy_waiting"
            && state != "complete_upload_pending")
            ExitApp(5)
        WorkerLog(sessionDir, "目的端仍不可用，60 秒後重試（" A_Index "/120）", "WARN")
        Sleep 60000
    }
    ExitApp(6)
} catch as e {
    detail := "背景收尾未處理例外: " e.Message " | line=" e.Line " | what=" e.What
    try WorkerWriteState(sessionDir, "worker_error", SubStr(detail, 1, 1000))
    WorkerLog(sessionDir, detail " | stack=" StrReplace(e.Stack, "`n", " <- "), "ERROR")
    ExitApp(9)
}

WorkerArgValue(name, defaultValue := "") {
    target := StrLower(name)
    for idx, arg in A_Args {
        if (StrLower(arg) = target && idx < A_Args.Length)
            return A_Args[idx + 1]
    }
    return defaultValue
}

WorkerNormalizePath(pathValue) {
    p := Trim(pathValue, ' "`t`r`n')
    if (p = "")
        return ""
    p := StrReplace(p, "/", "\")
    if (StrLen(p) > 3)
        p := RTrim(p, "\")
    return p
}

WorkerIsSafeSessionDir(sessionDir) {
    if (sessionDir = "" || !DirExist(sessionDir))
        return false
    SplitPath(sessionDir, &leaf)
    if !RegExMatch(leaf, "^wuthering_auto_recording_\d{8}_\d{6}(?:_\d+)?$")
        return false
    return FileExist(sessionDir "\.wuthering_recording_session")
        && FileExist(sessionDir "\session.ini")
}

WorkerHashText(textValue) {
    hash := 2166136261
    Loop Parse, StrLower(textValue) {
        hash := (hash ^ Ord(A_LoopField)) & 0xFFFFFFFF
        hash := Mod(hash * 16777619, 0x100000000)
    }
    return Format("{:08X}", hash)
}

WorkerAcquireSessionMutex(sessionDir) {
    name := "Local\WutheringRecordingWorker_" WorkerHashText(sessionDir)
    handle := DllCall("CreateMutexW", "ptr", 0, "int", true, "str", name, "ptr")
    lastErr := A_LastError
    if (!handle)
        return 0
    if (lastErr = 183) {
        DllCall("CloseHandle", "ptr", handle)
        return -1
    }
    return handle
}

WorkerLog(sessionDir, message, level := "INFO") {
    root := ""
    SplitPath(sessionDir, , &root)
    if (root = "")
        root := A_Temp
    line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " [" level "] " message "`r`n"
    try FileAppend(line, root "\recording_worker.log", "UTF-8")
}

WorkerReadSession(sessionDir) {
    ini := sessionDir "\session.ini"
    return {
        destinationDir: WorkerNormalizePath(IniRead(ini, "recording", "destination_dir", "")),
        baseName: Trim(IniRead(ini, "recording", "base_name", ""), ' "`t`r`n'),
        ffmpegExe: WorkerNormalizePath(IniRead(ini, "recording", "ffmpeg_exe", "")),
        configPath: WorkerNormalizePath(IniRead(ini, "recording", "config_path", "")),
        captureActive: IniRead(ini, "recording", "capture_active", "0") = "1",
        autoMerge: IniRead(ini, "recording", "auto_merge", "1") = "1",
        keepFinalCount: WorkerToIntRange(IniRead(ini, "recording", "keep_final_count", "5"), 5, 1, 50)
    }
}

WorkerIsSafeBaseName(baseName) {
    return RegExMatch(baseName, "^wuthering_auto_recording_\d{8}_\d{6}$") ? true : false
}

WorkerWriteState(sessionDir, state, detail := "") {
    ini := sessionDir "\session.ini"
    updatedAt := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    updatedMs := WorkerUnixMs()
    try IniWrite(state, ini, "recording", "state")
    try IniWrite(detail, ini, "recording", "state_detail")
    try IniWrite(updatedAt, ini, "recording", "state_updated_at")
    try IniWrite(updatedMs, ini, "recording", "state_updated_unix_ms")

    status := WorkerBuildRecordingStatus(sessionDir, state, detail, updatedAt, updatedMs)
    WorkerPersistRecordingStatus(status)
    WorkerPublishRecordingStatus(status)
}

WorkerUnixMs() {
    ft := Buffer(8, 0)
    DllCall("GetSystemTimeAsFileTime", "ptr", ft.Ptr)
    t := NumGet(ft, 0, "Int64")
    return (t // 10000) - 11644473600000
}

WorkerBuildRecordingStatus(sessionDir, state, detail, updatedAt, updatedMs) {
    cfg := WorkerReadSession(sessionDir)
    destinationSegments := ""
    finalPath := ""
    resultPath := ""
    if (cfg.destinationDir != "" && WorkerIsSafeBaseName(cfg.baseName)) {
        destinationSegments := cfg.destinationDir "\" cfg.baseName "_segments"
        if cfg.autoMerge
            finalPath := cfg.destinationDir "\" cfg.baseName ".mkv"
        resultPath := cfg.autoMerge ? finalPath : destinationSegments
    }

    root := ""
    SplitPath(sessionDir, , &root)
    workerLogPath := root != "" ? root "\recording_worker.log" : ""
    return {
        state: state,
        detail: detail,
        updatedAt: updatedAt,
        updatedMs: updatedMs,
        sessionDir: sessionDir,
        destinationDir: cfg.destinationDir,
        destinationSegments: destinationSegments,
        finalPath: finalPath,
        resultPath: resultPath,
        failureStorage: sessionDir,
        workerLogPath: workerLogPath,
        baseName: cfg.baseName,
        autoMerge: cfg.autoMerge,
        captureActive: cfg.captureActive,
        configPath: cfg.configPath,
        root: root
    }
}

WorkerPersistRecordingStatus(status) {
    if (status.root = "")
        return false
    statusPath := status.root "\recording_status.ini"
    try {
        IniWrite(status.state, statusPath, "recording", "state")
        IniWrite(status.detail, statusPath, "recording", "state_detail")
        IniWrite(status.updatedAt, statusPath, "recording", "state_updated_at")
        IniWrite(status.updatedMs, statusPath, "recording", "state_updated_unix_ms")
        IniWrite(status.sessionDir, statusPath, "recording", "local_session_dir")
        IniWrite(status.destinationDir, statusPath, "recording", "destination_dir")
        IniWrite(status.destinationSegments, statusPath, "recording", "destination_segments_dir")
        IniWrite(status.finalPath, statusPath, "recording", "final_path")
        IniWrite(status.resultPath, statusPath, "recording", "result_path")
        IniWrite(status.failureStorage, statusPath, "recording", "failure_storage")
        IniWrite(status.workerLogPath, statusPath, "recording", "worker_log_path")
        IniWrite(status.baseName, statusPath, "recording", "base_name")
        IniWrite(status.autoMerge ? "1" : "0", statusPath, "recording", "auto_merge")
        IniWrite(status.captureActive ? "1" : "0", statusPath, "recording", "capture_active")
        return true
    } catch {
        return false
    }
}

WorkerJsonEsc(textValue) {
    s := textValue
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return s
}

WorkerPublishRecordingStatus(status) {
    cfgPath := status.configPath
    if (cfgPath = "" || !FileExist(cfgPath))
        return false

    try {
        enabled := IniRead(cfgPath, "remote_control", "enabled", "0")
        projectId := Trim(IniRead(cfgPath, "remote_control", "project_id", ""), " `t`r`n")
        apiKey := Trim(IniRead(cfgPath, "remote_control", "api_key", ""), " `t`r`n")
        collection := Trim(IniRead(cfgPath, "remote_control", "collection", "ahk_clients"), " `t`r`n")
        uid := Trim(IniRead(cfgPath, "remote_control", "uid", ""), " `t`r`n")
        timeoutMs := WorkerToIntRange(IniRead(cfgPath, "remote_control", "http_timeout_ms", "2500"), 2500, 800, 10000)
    } catch {
        return false
    }
    if (enabled != "1")
        return false
    if (projectId = "" || apiKey = "" || collection = "" || uid = "")
        return false

    detail := SubStr(status.detail, 1, 1000)
    body := "{"
    body .= '"fields":{'
    body .= '"recordingStatusAvailable":{"booleanValue":true},'
    body .= '"recordingEnabled":{"booleanValue":true},'
    body .= '"recordingActive":{"booleanValue":' (status.captureActive ? "true" : "false") '},'
    body .= '"recordingState":{"stringValue":"' WorkerJsonEsc(status.state) '"},'
    body .= '"recordingStateDetail":{"stringValue":"' WorkerJsonEsc(detail) '"},'
    body .= '"recordingStateUpdatedAt":{"integerValue":"' status.updatedMs '"},'
    body .= '"recordingLocalSessionDir":{"stringValue":"' WorkerJsonEsc(status.sessionDir) '"},'
    body .= '"recordingDestinationDir":{"stringValue":"' WorkerJsonEsc(status.destinationDir) '"},'
    body .= '"recordingDestinationSegmentsDir":{"stringValue":"' WorkerJsonEsc(status.destinationSegments) '"},'
    body .= '"recordingFinalPath":{"stringValue":"' WorkerJsonEsc(status.finalPath) '"},'
    body .= '"recordingResultPath":{"stringValue":"' WorkerJsonEsc(status.resultPath) '"},'
    body .= '"recordingFailureStorage":{"stringValue":"' WorkerJsonEsc(status.failureStorage) '"},'
    body .= '"recordingWorkerLogPath":{"stringValue":"' WorkerJsonEsc(status.workerLogPath) '"},'
    body .= '"recordingBaseName":{"stringValue":"' WorkerJsonEsc(status.baseName) '"},'
    body .= '"recordingAutoMerge":{"booleanValue":' (status.autoMerge ? "true" : "false") '}'
    body .= "}"
    body .= "}"

    url := "https://firestore.googleapis.com/v1/projects/" projectId
        . "/databases/(default)/documents/" collection "/" uid "?key=" apiKey
    for fieldName in [
        "recordingStatusAvailable", "recordingEnabled", "recordingActive", "recordingState",
        "recordingStateDetail", "recordingStateUpdatedAt", "recordingLocalSessionDir",
        "recordingDestinationDir", "recordingDestinationSegmentsDir", "recordingFinalPath",
        "recordingResultPath", "recordingFailureStorage", "recordingWorkerLogPath",
        "recordingBaseName", "recordingAutoMerge"
    ]
        url .= "&updateMask.fieldPaths=" fieldName
    ; 背景收尾只需知道 PATCH 是否成功，不下載整份 client 文件。
    url .= "&mask.fieldPaths=recordingStateUpdatedAt"

    try {
        http := ComObject("WinHttp.WinHttpRequest.5.1")
        http.SetTimeouts(timeoutMs, timeoutMs, timeoutMs, timeoutMs)
        http.Open("PATCH", url, false)
        http.SetRequestHeader("Content-Type", "application/json; charset=utf-8")
        http.Send(body)
        return http.Status >= 200 && http.Status < 300
    } catch {
        ; 網路回報失敗不可影響本機錄影保全；狀態已先寫入 recording_status.ini。
        return false
    }
}

WorkerTrySelfHostedUpload(sessionDir, mode) {
    cfg := WorkerReadSession(sessionDir)
    if (cfg.configPath = "" || !FileExist(cfg.configPath))
        return true
    serverUrl := ""
    selfHostedMode := "disabled"
    protectedToken := ""
    try {
        serverUrl := Trim(IniRead(cfg.configPath, "self_hosted", "server_url", ""), " `t`r`n/")
        selfHostedMode := StrLower(Trim(IniRead(cfg.configPath, "self_hosted", "mode", "shadow"), " `t`r`n"))
        protectedToken := Trim(IniRead(cfg.configPath, "self_hosted", "device_token_dpapi", ""), " `t`r`n")
    } catch {
        return true
    }
    if (serverUrl = "" || selfHostedMode = "disabled")
        return true
    if (protectedToken = "") {
        WorkerLog(sessionDir, "中央上傳等待裝置憑證；本機影片不受影響", "WARN")
        try IniWrite("credential_waiting", sessionDir "\session.ini", "self_hosted", "upload_state")
        return false
    }

    uploader := A_ScriptDir "\SelfHostMediaUpload.ps1"
    powershell := A_WinDir "\System32\WindowsPowerShell\v1.0\powershell.exe"
    if !FileExist(uploader) || !FileExist(powershell) {
        WorkerLog(sessionDir, "中央上傳工具缺失；本機影片與分段已保留", "ERROR")
        try IniWrite("uploader_missing", sessionDir "\session.ini", "self_hosted", "upload_state")
        return false
    }
    try IniWrite(mode = "finalize" ? "finalizing" : "uploading",
        sessionDir "\session.ini", "self_hosted", "upload_state")
    cmd := '"' powershell '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'
        . uploader '" -Mode "' mode '" -SessionDir "' sessionDir '"'
    exitCode := -1
    try exitCode := RunWait(cmd, A_ScriptDir, "Hide")
    catch as e {
        WorkerLog(sessionDir, "啟動中央上傳工具失敗: " e.Message, "WARN")
    }
    if (exitCode = 0) {
        try IniWrite(mode = "finalize" ? "finalize_accepted" : "uploaded",
            sessionDir "\session.ini", "self_hosted", "upload_state")
        try IniWrite(WorkerUnixMs(), sessionDir "\session.ini", "self_hosted", "last_success_unix_ms")
        return true
    }
    try IniWrite("retry_pending", sessionDir "\session.ini", "self_hosted", "upload_state")
    try IniWrite(exitCode, sessionDir "\session.ini", "self_hosted", "last_exit_code")
    WorkerLog(sessionDir, "中央片段上傳暫時失敗，exit=" exitCode "；保留本機來源供續傳", "WARN")
    return false
}

WorkerToIntRange(value, defaultValue, minValue, maxValue) {
    n := defaultValue
    try n := Integer(Trim(value, " `t`r`n"))
    if (n < minValue)
        n := minValue
    if (n > maxValue)
        n := maxValue
    return n
}

WorkerGetSegments(sessionDir) {
    files := []
    Loop Files, sessionDir "\segment_*.mkv", "F" {
        files.Push({path: A_LoopFileFullPath, name: A_LoopFileName, size: A_LoopFileSize + 0})
    }

    ; 檔名包含固定寬度流水號，字典序即時間序；為相容舊 AHK 版本手動排序。
    i := 1
    while (i <= files.Length - 1) {
        j := i + 1
        while (j <= files.Length) {
            if (StrCompare(files[i].name, files[j].name) > 0) {
                tmp := files[i]
                files[i] := files[j]
                files[j] := tmp
            }
            j += 1
        }
        i += 1
    }
    return files
}

WorkerCopyFileVerified(sourcePath, targetPath) {
    sourceSize := 0
    try sourceSize := FileGetSize(sourcePath)
    if (sourceSize <= 0)
        return false

    if FileExist(targetPath) {
        try {
            if (FileGetSize(targetPath) = sourceSize)
                return true
        }
    }

    targetDir := ""
    SplitPath(targetPath, , &targetDir)
    if (targetDir = "")
        return false
    try DirCreate(targetDir)

    partialPath := targetPath ".partial"
    try FileDelete(partialPath)
    try {
        FileCopy(sourcePath, partialPath, 1)
        if (!FileExist(partialPath) || FileGetSize(partialPath) != sourceSize)
            throw Error("複製後大小不一致")
        FileMove(partialPath, targetPath, 1)
        return FileExist(targetPath) && FileGetSize(targetPath) = sourceSize
    } catch {
        try FileDelete(partialPath)
        return false
    }
}

WorkerSyncSession(sessionDir, includeNewest, skipCentral := false) {
    cfg := WorkerReadSession(sessionDir)
    if (cfg.destinationDir = "" || !WorkerIsSafeBaseName(cfg.baseName)) {
        WorkerLog(sessionDir, "session.ini 缺少 destination_dir/base_name", "ERROR")
        return false
    }

    files := WorkerGetSegments(sessionDir)
    if (files.Length = 0)
        return true

    copyCount := includeNewest ? files.Length : Max(0, files.Length - 1)
    if (copyCount <= 0)
        return true

    ; 中央 HTTPS 上傳與使用者選擇的本機／網路目的地互相獨立。
    ; 中央失敗只留下續傳狀態，不能阻塞既有目的端複製。
    if !skipCentral
        WorkerTrySelfHostedUpload(sessionDir, "sync")

    destinationSegments := cfg.destinationDir "\" cfg.baseName "_segments"
    try DirCreate(destinationSegments)
    catch as e {
        WorkerWriteState(sessionDir, "sync_waiting", "無法建立目的資料夾: " e.Message)
        WorkerLog(sessionDir, "目的資料夾目前無法使用: " cfg.destinationDir " | " e.Message, "WARN")
        return false
    }
    segmentMarker := destinationSegments "\.wuthering_recording_segments"
    try {
        if !FileExist(segmentMarker)
            FileAppend(cfg.baseName, segmentMarker, "UTF-8")
    } catch as e {
        WorkerWriteState(sessionDir, "sync_waiting", "無法建立目的端安全標記: " e.Message)
        WorkerLog(sessionDir, "目的端分段資料夾無法建立安全標記，停止同步: " destinationSegments, "WARN")
        return false
    }

    copied := 0
    Loop copyCount {
        item := files[A_Index]
        target := destinationSegments "\" item.name
        if !WorkerCopyFileVerified(item.path, target) {
            WorkerWriteState(sessionDir, "sync_waiting", "補傳失敗: " item.name)
            WorkerLog(sessionDir, "分段補傳失敗，保留本機檔案: " item.name, "WARN")
            return false
        }
        copied += 1
    }

    WorkerWriteState(sessionDir, includeNewest ? "segments_synced" : "recording",
        "已驗證目的端分段 " copied " 個")
    return true
}

WorkerBuildConcatList(sessionDir, files) {
    listPath := sessionDir "\concat.ffconcat"
    content := "ffconcat version 1.0`r`n"
    for _, item in files
        content .= "file '" item.name "'`r`n"
    try FileDelete(listPath)
    FileAppend(content, listPath, "UTF-8-RAW")
    return listPath
}

WorkerHasMergeSpace(sessionDir, requiredBytes) {
    freeMb := 0
    try freeMb := DriveGetSpaceFree(sessionDir)
    catch
        return true ; 無法查詢時交由 ffmpeg 的實際寫入結果判斷。
    requiredMb := Ceil(requiredBytes / 1048576) + 256
    return freeMb >= requiredMb
}

WorkerMergeSegments(sessionDir, cfg, files, &mergedPath) {
    mergedPath := sessionDir "\" cfg.baseName ".mkv"
    totalBytes := 0
    for _, item in files
        totalBytes += item.size

    if !WorkerHasMergeSpace(sessionDir, totalBytes) {
        WorkerWriteState(sessionDir, "merge_waiting", "本機空間不足，分段已保留")
        WorkerLog(sessionDir, "本機空間不足，無法建立完整影片；所有分段已保留", "ERROR")
        return false
    }
    if (cfg.ffmpegExe = "" || !FileExist(cfg.ffmpegExe)) {
        WorkerWriteState(sessionDir, "merge_waiting", "找不到 ffmpeg.exe")
        WorkerLog(sessionDir, "找不到 ffmpeg.exe，無法合併；所有分段已保留", "ERROR")
        return false
    }

    ; 只有先前 ffmpeg 正常退出後寫入的精確驗證資訊仍吻合，才重用合併檔。
    ; 單看「大於來源一半」會把中途斷電留下的截斷檔誤認成完整影片。
    recordedMergedSize := 0
    recordedSourceBytes := 0
    recordedSegmentCount := 0
    try recordedMergedSize := Integer(IniRead(sessionDir "\session.ini", "recording", "merged_size", "0"))
    try recordedSourceBytes := Integer(IniRead(sessionDir "\session.ini", "recording", "merged_source_bytes", "0"))
    try recordedSegmentCount := Integer(IniRead(sessionDir "\session.ini", "recording", "merged_segment_count", "0"))
    if FileExist(mergedPath) {
        actualMergedSize := 0
        try actualMergedSize := FileGetSize(mergedPath)
        if (recordedMergedSize > 0
            && actualMergedSize = recordedMergedSize
            && recordedSourceBytes = totalBytes
            && recordedSegmentCount = files.Length) {
            WorkerLog(sessionDir, "已驗證並重用先前完成的本機合併檔: " mergedPath)
            return true
        }
        try FileDelete(mergedPath)
    }

    listPath := WorkerBuildConcatList(sessionDir, files)
    tempMerged := mergedPath ".merging"
    try FileDelete(tempMerged)
    WorkerWriteState(sessionDir, "merging", "正在無損合併 " files.Length " 個分段")

    cmd := '"' cfg.ffmpegExe '" -hide_banner -loglevel warning -y -f concat -safe 0 -i "' listPath
        . '" -map 0 -c copy -f matroska "' tempMerged '"'
    exitCode := -1
    try exitCode := RunWait(cmd, sessionDir, "Hide")
    catch as e {
        WorkerLog(sessionDir, "啟動 ffmpeg 合併失敗: " e.Message, "ERROR")
    }

    minExpected := Max(1024, Floor(totalBytes * 0.5))
    if (exitCode != 0 || !FileExist(tempMerged) || FileGetSize(tempMerged) < minExpected) {
        WorkerWriteState(sessionDir, "merge_waiting", "ffmpeg 合併失敗，exit=" exitCode)
        WorkerLog(sessionDir, "ffmpeg 合併失敗，exit=" exitCode "；所有分段已保留", "ERROR")
        try FileDelete(tempMerged)
        return false
    }

    FileMove(tempMerged, mergedPath, 1)
    finalSize := FileGetSize(mergedPath)
    IniWrite(finalSize, sessionDir "\session.ini", "recording", "merged_size")
    IniWrite(totalBytes, sessionDir "\session.ini", "recording", "merged_source_bytes")
    IniWrite(files.Length, sessionDir "\session.ini", "recording", "merged_segment_count")
    WorkerLog(sessionDir, "本機無損合併完成: " mergedPath)
    return true
}

WorkerPruneFinalRecordings(destinationDir, keepCount) {
    files := []
    Loop Files, destinationDir "\wuthering_auto_recording_*.mkv", "F" {
        files.Push({path: A_LoopFileFullPath, modified: A_LoopFileTimeModified})
    }
    if (files.Length <= keepCount)
        return

    i := 1
    while (i <= files.Length - 1) {
        j := i + 1
        while (j <= files.Length) {
            if (StrCompare(files[i].modified, files[j].modified) < 0) {
                tmp := files[i]
                files[i] := files[j]
                files[j] := tmp
            }
            j += 1
        }
        i += 1
    }
    Loop files.Length - keepCount {
        try FileDelete(files[keepCount + A_Index].path)
    }
}

WorkerCleanupVerifiedSession(sessionDir, cfg) {
    destinationSegments := cfg.destinationDir "\" cfg.baseName "_segments"
    segmentMarker := destinationSegments "\.wuthering_recording_segments"
    ; 只清理由安全 base_name 推導、而且確實由本工具建立並標記的專用資料夾。
    SplitPath(destinationSegments, &segmentLeaf)
    if (WorkerIsSafeBaseName(cfg.baseName)
        && segmentLeaf = cfg.baseName "_segments"
        && DirExist(destinationSegments)
        && FileExist(segmentMarker)) {
        try DirDelete(destinationSegments, true)
    }
    if WorkerIsSafeSessionDir(sessionDir)
        try DirDelete(sessionDir, true)
}

WorkerFinalizeSession(sessionDir) {
    cfg := WorkerReadSession(sessionDir)
    if !WorkerIsSafeBaseName(cfg.baseName) {
        WorkerWriteState(sessionDir, "finalize_waiting", "不安全或無效的 base_name")
        WorkerLog(sessionDir, "拒絕處理不安全或無效的 base_name: " cfg.baseName, "ERROR")
        return false
    }
    files := WorkerGetSegments(sessionDir)
    if (files.Length = 0) {
        WorkerWriteState(sessionDir, "finalize_waiting", "找不到可用分段")
        WorkerLog(sessionDir, "收尾時找不到任何分段，保留工作目錄", "ERROR")
        return false
    }

    ; 封口後立即補齊中央分段並送出 expectedSegments。失敗時後面的本機
    ; 合併仍照常進行，但最後不清除 staging，讓同一 worker／下次啟動續傳。
    centralComplete := WorkerTrySelfHostedUpload(sessionDir, "finalize")

    ; 先把所有可播放分段補到目的端；即使稍後合併失敗仍能逐段回看。
    if !WorkerSyncSession(sessionDir, true, true)
        return false

    if !cfg.autoMerge {
        if !centralComplete {
            WorkerWriteState(sessionDir, "complete_upload_pending",
                "本機分段已驗證；中央影片仍待續傳，來源已保留")
            return false
        }
        WorkerWriteState(sessionDir, "complete", "已補傳並驗證全部分段，自動合併已停用")
        WorkerLog(sessionDir, "全部分段已補傳；設定為不自動合併")
        if WorkerIsSafeSessionDir(sessionDir)
            try DirDelete(sessionDir, true)
        return true
    }

    mergedPath := ""
    if !WorkerMergeSegments(sessionDir, cfg, files, &mergedPath)
        return false

    try DirCreate(cfg.destinationDir)
    destinationFinal := cfg.destinationDir "\" cfg.baseName ".mkv"
    WorkerWriteState(sessionDir, "copying_final", "正在複製完整影片到目的端")
    if !WorkerCopyFileVerified(mergedPath, destinationFinal) {
        WorkerWriteState(sessionDir, "copy_waiting", "完整影片目的端複製失敗")
        WorkerLog(sessionDir, "完整影片複製失敗，保留本機合併檔與全部分段: " destinationFinal, "WARN")
        return false
    }


    if !centralComplete {
        WorkerWriteState(sessionDir, "complete_upload_pending",
            "本機完整影片已驗證；中央影片仍待續傳，來源已保留")
        WorkerLog(sessionDir, "本機收尾完成，但中央續傳尚未完成；不清除 staging", "WARN")
        return false
    }

    WorkerWriteState(sessionDir, "complete", "完整影片已驗證: " destinationFinal)
    WorkerLog(sessionDir, "錄影收尾完成並驗證: " destinationFinal)
    WorkerPruneFinalRecordings(cfg.destinationDir, cfg.keepFinalCount)
    WorkerCleanupVerifiedSession(sessionDir, cfg)
    return true
}
