#Requires AutoHotkey v2.0+
#SingleInstance Force

#Include ..\payload\RuntimeFilePaths.ahk

AssertTrue(condition, message) {
    if !condition
        throw Error(message)
}

testRoot := A_Temp "\wuthering_runtime_paths_test_" DllCall("GetCurrentProcessId") "_" A_TickCount
diagnosticsDir := testRoot "\程式\診斷快照"
legacyLocal := testRoot "\local"
oldDiagnosticsEnv := EnvGet("WUTHERING_DIAGNOSTICS_DIR")
oldLocalAppData := EnvGet("LOCALAPPDATA")

try {
    EnvSet("WUTHERING_DIAGNOSTICS_DIR", diagnosticsDir)
    EnvSet("LOCALAPPDATA", legacyLocal)

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

    FileAppend("RuntimeFilePaths test passed`n", "*")
} catch as e {
    FileAppend("RuntimeFilePaths test failed: " e.Message "`n", "**")
    ExitApp(1)
} finally {
    EnvSet("WUTHERING_DIAGNOSTICS_DIR", oldDiagnosticsEnv)
    EnvSet("LOCALAPPDATA", oldLocalAppData)
    try DirDelete(testRoot, 1)
}

ExitApp(0)
