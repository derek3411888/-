#Requires AutoHotkey v2.0
#SingleInstance Force

sourcePath := A_ScriptDir "\..\payload\全自動.ahk"
source := FileRead(sourcePath, "UTF-8")
launcherSource := FileRead(A_ScriptDir "\..\打包啟動器.ahk", "UTF-8")

AssertTrue(condition, message) {
    if !condition
        throw Error(message)
}

ExtractFunction(name, nextName) {
    global source
    startAt := InStr(source, "`n" name "(")
    endAt := InStr(source, "`n" nextName "(", false, startAt + 1)
    AssertTrue(startAt > 0 && endAt > startAt, "找不到函式區段: " name)
    return SubStr(source, startAt, endAt - startAt)
}

startBlock := ExtractFunction("StartFfmpegScreenRecording", "EnsureScreenRecordingSessionBeforeStart")
AssertTrue(InStr(startBlock, 'outPath := destinationDir "\" baseName ".mkv"'),
    "正式錄影沒有直接建立單一目的端 MKV")
AssertTrue(InStr(startBlock, "-f matroska"), "單檔輸出未使用 Matroska")
AssertTrue(!InStr(startBlock, "-f segment"), "正式錄影仍使用 FFmpeg segment muxer")
AssertTrue(!InStr(startBlock, "segment_%05d"), "正式錄影仍產生編號分段")
AssertTrue(!InStr(startBlock, "SelfHostMediaUpload"), "正式錄影啟動仍包含中央上傳")

stopBlock := ExtractFunction("StopFfmpegScreenRecording", "NormalizeScreenRecordingStopMode")
AssertTrue(InStr(stopBlock, "GenerateConsoleCtrlEvent"), "停止錄影未先送 Ctrl+C")
AssertTrue(InStr(stopBlock, "+ 30000"), "單檔錄影未保留 30 秒正常封口時間")

AssertTrue(!InStr(source, 'LaunchRecordingWorker("finalize"'),
    "主流程仍會啟動舊版錄影合併 worker")
AssertTrue(InStr(source, 'IniWrite "direct"'), "設定未固定遷移為 direct 模式")
AssertTrue(InStr(source, "direct_mode_legacy_cleanup_completed"),
    "單檔模式沒有一次性舊錄影清理旗標")
AssertTrue(InStr(source, 'A_Args[1] = "cleanup-recordings"'),
    "缺少不啟動主流程的錄影清理模式")
AssertTrue(InStr(source, "!A_IsAdmin && !CLEANUP_RECORDINGS_ONLY"),
    "只清理錄影仍會被不必要的系統管理員提權擋住")
AssertTrue(InStr(source, 'if CLEANUP_RECORDINGS_ONLY {')
    && InStr(source, "錄影清理模式退出：略過遊戲聲音"),
    "只清理錄影退出時仍可能碰觸遊戲、錄影程序或遠端控制")
AssertTrue(InStr(launcherSource, 'LauncherHasArg("--cleanup-recordings")')
    && InStr(launcherSource, 'payloadArgs := " cleanup-recordings"'),
    "啟動器沒有把安全錄影清理模式轉送給新版 payload")
cleanupBlock := ExtractFunction("PurgeLegacyRecordingFilesForDirectMode", "StartFfmpegScreenRecording")
AssertTrue(InStr(cleanupBlock, "wuthering_auto_recording_*.mkv")
    && InStr(cleanupBlock, "wuthering_auto_recording_*.mp4"),
    "舊錄影清理沒有嚴格限制正式錄影檔名前綴")
AssertTrue(InStr(cleanupBlock, ".wuthering_recording_segments")
    && InStr(cleanupBlock, ".wuthering_recording_session"),
    "遞迴清理資料夾前沒有要求安全標記")

FileAppend("Screen recording direct-output policy tests passed`n", "*")
ExitApp 0
