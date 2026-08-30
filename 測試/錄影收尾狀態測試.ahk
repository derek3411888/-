#Requires AutoHotkey v2.0+
#SingleInstance Off

#Include TestRuntimePaths.ahk

requestedOutput := A_Args.Length >= 1 ? A_Args[1] : ""
outputPath := TestRuntime_ResolveOutputPath(requestedOutput,
    "recording-finalize", "recording_finalize_result.ini")
repoRoot := TestRuntime_RepoRoot()
if (A_Args.Length >= 2 && TestRuntime_CanonicalPath(A_Args[2]) != TestRuntime_CanonicalPath(repoRoot))
    throw Error("錄影收尾測試只能使用當前 repo")
workerPath := repoRoot "\payload\RecordingFinalizeWorker.ahk"
ahkExe := repoRoot "\payload\AutoHotkey64.exe"
testRoot := TestRuntime_NewCaseDir("recording-finalize", "recording_worker")
sessionBase := "wuthering_auto_recording_20260822_123456"
sessionDir := testRoot "\" sessionBase "_1"
destinationDir := testRoot "\destination"

try {
    DirCreate(sessionDir)
    FileAppend("WUTHERING_RECORDING_SESSION_V2", sessionDir "\.wuthering_recording_session", "UTF-8")
    FileAppend("TEST_SEGMENT", sessionDir "\segment_00000.mkv", "UTF-8")
    ini := sessionDir "\session.ini"
    IniWrite(destinationDir, ini, "recording", "destination_dir")
    IniWrite(sessionBase, ini, "recording", "base_name")
    IniWrite("", ini, "recording", "ffmpeg_exe")
    IniWrite("", ini, "recording", "config_path")
    IniWrite("0", ini, "recording", "capture_active")
    IniWrite("0", ini, "recording", "auto_merge")
    IniWrite("5", ini, "recording", "keep_final_count")

    cmd := '"' ahkExe '" "' workerPath '" --mode finalize --session "' sessionDir '"'
    exitCode := RunWait(cmd, A_ScriptDir, "Hide")
    statusPath := testRoot "\recording_status.ini"
    copiedSegment := destinationDir "\" sessionBase "_segments\segment_00000.mkv"
    state := IniRead(statusPath, "recording", "state", "")
    resultPath := IniRead(statusPath, "recording", "result_path", "")
    ok := exitCode = 0
        && state = "complete"
        && !DirExist(sessionDir)
        && FileExist(copiedSegment)
        && resultPath = destinationDir "\" sessionBase "_segments"
    result := "status=" (ok ? "ok" : "error") "`r`n"
        . "exit_code=" exitCode "`r`n"
        . "recording_state=" state "`r`n"
        . "result_path=" resultPath "`r`n"
        . "segment_copied=" (FileExist(copiedSegment) ? "1" : "0") "`r`n"
        . "session_cleaned=" (!DirExist(sessionDir) ? "1" : "0")
    try FileDelete(outputPath)
    FileAppend(result, outputPath, "UTF-8")
    CleanupRecordingWorkerTest(testRoot)
    ExitApp(ok ? 0 : 1)
} catch as e {
    try FileDelete(outputPath)
    FileAppend("status=error`r`nmessage=" e.Message "`r`nline=" e.Line, outputPath, "UTF-8")
    CleanupRecordingWorkerTest(testRoot)
    ExitApp(1)
}

CleanupRecordingWorkerTest(path) {
    try TestRuntime_DeleteCaseDir(path)
}
