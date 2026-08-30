#Requires AutoHotkey v2.0+
#SingleInstance Force

#Include TestRuntimePaths.ahk
#Include ..\payload\RuntimeFilePaths.ahk

AssertTrue(condition, message) {
    if !condition
        throw Error(message)
}

testParent := TestRuntime_EnsureDir("runtime-paths")
testRoot := testParent "\wuthering_runtime_paths_test_" DllCall("GetCurrentProcessId") "_" A_TickCount
programRoot := testRoot "\程式"
diagnosticsDir := programRoot "\診斷快照"
legacyLocal := testRoot "\local"
oldDiagnosticsEnv := EnvGet("WUTHERING_DIAGNOSTICS_DIR")
oldLocalAppData := EnvGet("LOCALAPPDATA")
oldPackAppDir := EnvGet("PACK_APP_DIR")
oldPackDataDir := EnvGet("PACK_DATA_DIR")

try {
    EnvSet("PACK_APP_DIR", programRoot "\payload")
    EnvSet("PACK_DATA_DIR", testRoot "\外部設定")
    EnvSet("WUTHERING_DIAGNOSTICS_DIR", testRoot "\外部診斷")
    EnvSet("LOCALAPPDATA", legacyLocal)

    AssertTrue(StrLower(RuntimeFiles_ProgramRoot()) = StrLower(programRoot), "程式根目錄解析錯誤")
    AssertTrue(StrLower(RuntimeFiles_ConfigDir()) = StrLower(programRoot "\config"), "設定未固定在程式根目錄")
    AssertTrue(StrLower(RuntimeFiles_DiagnosticsDir()) = StrLower(diagnosticsDir), "診斷圖未固定在程式根目錄")
    AssertTrue(StrLower(RuntimeFiles_LogDir("單元測試")) = StrLower(programRoot "\log\單元測試"), "Log 未固定在程式根目錄")
    AssertTrue(StrLower(RuntimeFiles_RecordingsDir()) = StrLower(programRoot "\操作過程"), "錄影成品未固定在程式根目錄")
    AssertTrue(StrLower(RuntimeFiles_RecordingStagingDir()) = StrLower(programRoot "\操作過程\錄影暫存"), "錄影暫存未固定在程式根目錄")

    deleteGuardBlocked := false
    try TestRuntime_DeleteCaseDir(TestRuntime_DevelopmentRoot())
    catch
        deleteGuardBlocked := true
    AssertTrue(deleteGuardBlocked, "測試刪除 guard 不得允許刪除 .dev-runtime 根目錄")

    deleteGuardBlocked := false
    try TestRuntime_DeleteCaseDir(TestRuntime_RepoRoot())
    catch
        deleteGuardBlocked := true
    AssertTrue(deleteGuardBlocked, "測試刪除 guard 不得允許刪除 repo 根目錄")

    escapedExtensionPath := TestRuntime_NewFile("runtime-paths", "extension_guard",
        ".\..\..\outside.txt")
    AssertTrue(TestRuntime_IsWithinDevelopmentRoot(escapedExtensionPath),
        "測試副檔名不得將輸出帶離 .dev-runtime")
    AssertTrue(!InStr(escapedExtensionPath, "\..\"),
        "測試副檔名未正確移除路徑跳脫字元")

    EnvSet("PACK_APP_DIR", TestRuntime_RepoRoot() "\payload")
    AssertTrue(StrLower(RuntimeFiles_ProgramRoot())
        = StrLower(TestRuntime_RepoRoot() "\.dev-runtime\runtime"),
        "原始碼執行產物未導向 .dev-runtime")
    EnvSet("PACK_APP_DIR", programRoot "\payload")

    legacyConfig := testRoot "\legacy_config"
    DirCreate(legacyConfig)
    FileAppend("[test]`nvalue=1", legacyConfig "\config.ini", "UTF-8-RAW")
    configMoved := RuntimeFiles_MigrateLegacyConfig(legacyConfig)
    AssertTrue(configMoved = 1, "舊設定搬移數量錯誤: " configMoved)
    AssertTrue(FileExist(programRoot "\config\config.ini"), "舊設定未搬入程式資料夾")
    AssertTrue(!FileExist(legacyConfig "\config.ini"), "舊設定來源未清除")

    legacyDir := legacyLocal "\WutheringAuto\diagnostics"
    DirCreate(legacyDir)
    FileAppend("latest", legacyDir "\latest.jpg", "UTF-8-RAW")
    FileAppend("error", legacyDir "\error_20260823_000000.jpg", "UTF-8-RAW")

    moved := RuntimeFiles_MigrateLegacyDiagnosticImages()
    AssertTrue(moved = 2, "舊圖片搬移數量錯誤: " moved)
    AssertTrue(FileExist(diagnosticsDir "\latest.jpg"), "latest.jpg 未搬入程式資料夾")
    AssertTrue(FileExist(diagnosticsDir "\error_20260823_000000.jpg"), "錯誤圖未搬入程式資料夾")
    AssertTrue(!FileExist(legacyDir "\latest.jpg"), "舊 latest.jpg 未清除")

    Loop 3
        FileAppend(String(A_Index), diagnosticsDir "\error_test_" A_Index ".png", "UTF-8-RAW")
    RuntimeFiles_PruneDiagnosticImages(2)
    remaining := 0
    Loop Files, diagnosticsDir "\error_*.*", "F"
        remaining += 1
    AssertTrue(remaining = 2, "錯誤圖保留數量錯誤: " remaining)

    tempPath := RuntimeFiles_NewImagePath("unit_test")
    FileAppend("temp", tempPath, "UTF-8-RAW")
    FileSetTime(DateAdd(A_Now, -2, "Days"), tempPath, "M")
    deleted := RuntimeFiles_DeleteStaleTempImages(24)
    AssertTrue(deleted = 1 && !FileExist(tempPath), "逾期暫存圖片未清理")

    genericTemp := RuntimeFiles_NewTempPath("unit_test", ".txt", "測試")
    FileAppend("temp", genericTemp, "UTF-8-RAW")
    AssertTrue(InStr(StrLower(genericTemp), StrLower(programRoot "\執行暫存\測試\")) = 1,
        "一般暫存未放在程式根目錄: " genericTemp)
    FileSetTime(DateAdd(A_Now, -2, "Days"), genericTemp, "M")
    staleDeleted := RuntimeFiles_DeleteStaleRuntimeFiles(24)
    AssertTrue(staleDeleted = 1 && !FileExist(genericTemp), "逾期一般暫存未清理")

    legacyRecording := testRoot "\legacy_recording"
    DirCreate(legacyRecording)
    FileAppend("status", legacyRecording "\recording_status.ini", "UTF-8-RAW")
    FileAppend("log", legacyRecording "\recording_worker.log", "UTF-8-RAW")
    recordingMoved := RuntimeFiles_MigrateLegacyRecordingMetadata(legacyRecording)
    AssertTrue(recordingMoved.moved = 2 && recordingMoved.deferredSessions = 0,
        "舊錄影狀態搬移錯誤")
    AssertTrue(FileExist(programRoot "\操作過程\錄影暫存\recording_status.ini"),
        "錄影狀態未搬入程式資料夾")

    deferredRoot := testRoot "\legacy_recording_active"
    DirCreate(deferredRoot "\wuthering_auto_recording_20260830_040000_123")
    FileAppend("status", deferredRoot "\recording_status.ini", "UTF-8-RAW")
    deferred := RuntimeFiles_MigrateLegacyRecordingMetadata(deferredRoot)
    AssertTrue(deferred.moved = 0 && deferred.deferredSessions = 1,
        "未完成錄影不應被強制搬移")
    AssertTrue(FileExist(deferredRoot "\recording_status.ini"), "未完成錄影狀態遭提前移除")

    FileAppend("RuntimeFilePaths test passed`n", "*")
} catch as e {
    FileAppend("RuntimeFilePaths test failed: " e.Message "`n", "**")
    ExitApp(1)
} finally {
    EnvSet("WUTHERING_DIAGNOSTICS_DIR", oldDiagnosticsEnv)
    EnvSet("LOCALAPPDATA", oldLocalAppData)
    EnvSet("PACK_APP_DIR", oldPackAppDir)
    EnvSet("PACK_DATA_DIR", oldPackDataDir)
    try TestRuntime_DeleteCaseDir(testRoot)
}

ExitApp(0)
