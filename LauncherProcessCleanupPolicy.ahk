#Requires AutoHotkey v2.0+

; Launcher 更新 payload 前的純判斷策略。
; 只允許終止目前 payload 目錄內、名稱完全相符的互動式主／管理腳本。
; 錄影同步與收尾 worker 必須在主程式退出及 payload 更新期間繼續工作；
; 任何無法解析、未知或非 AHK 命令列一律保留，避免再以 `payload` 子字串誤殺。

LauncherCleanup_ParseCommandLine(commandLine) {
    args := []
    argc := 0
    argv := DllCall("Shell32\CommandLineToArgvW", "str", String(commandLine),
        "int*", &argc, "ptr")
    if (!argv || argc <= 0)
        return args
    try {
        Loop argc {
            argPtr := NumGet(argv, (A_Index - 1) * A_PtrSize, "ptr")
            args.Push(argPtr ? StrGet(argPtr, "UTF-16") : "")
        }
    } finally {
        DllCall("Kernel32\LocalFree", "ptr", argv, "ptr")
    }
    return args
}

LauncherCleanup_NormalizePath(pathValue) {
    path := RTrim(StrReplace(Trim(String(pathValue), ' "`t`r`n'), "/", "\"), "\")
    if (path = "")
        return ""
    ; Win32 路徑比較不需要保留 extended-length 前綴；移除後才能和 APP_DIR
    ; 的一般絕對路徑做完整、大小寫不敏感的相等比較。
    if (SubStr(path, 1, 8) = "\\?\UNC\")
        path := "\\" SubStr(path, 9)
    else if (SubStr(path, 1, 4) = "\\?\")
        path := SubStr(path, 5)

    pathBuffer := Buffer(32768 * 2, 0)
    length := DllCall("Kernel32\GetFullPathNameW", "str", path, "uint", 32768,
        "ptr", pathBuffer, "ptr", 0, "uint")
    if (length > 0 && length < 32768)
        path := RTrim(StrGet(pathBuffer, length, "UTF-16"), "\")
    return StrLower(path)
}

LauncherCleanup_GetScriptPath(args) {
    ; AutoHotkey 可在 script 前帶 /restart 等 interpreter 參數，因此不能假設
    ; script 永遠是 argv[2]；但只接受真正以 .ahk 結尾的完整 token。
    if !IsObject(args)
        return ""
    for index, argValue in args {
        if (index = 1)
            continue
        candidate := Trim(String(argValue), ' "`t`r`n')
        if (candidate ~= "i)\.ahk$")
            return candidate
    }
    return ""
}

LauncherCleanup_GetNamedArg(args, name) {
    target := StrLower(Trim(String(name), " `t`r`n"))
    matches := []
    if !IsObject(args)
        return {valid: false, value: ""}
    for index, argValue in args {
        if (StrLower(Trim(String(argValue), " `t`r`n")) != target)
            continue
        if (index >= args.Length)
            return {valid: false, value: ""}
        matches.Push(String(args[index + 1]))
    }
    if (matches.Length != 1)
        return {valid: false, value: ""}
    return {valid: true, value: matches[1]}
}

LauncherCleanup_ProcessDecision(processName, commandLine, appDir) {
    name := StrLower(Trim(String(processName), " `t`r`n"))
    if !(name ~= "^autohotkey(?:32|64)?\.exe$")
        return {stop: false, role: "non-ahk", scriptPath: ""}

    args := LauncherCleanup_ParseCommandLine(commandLine)
    scriptPath := LauncherCleanup_NormalizePath(LauncherCleanup_GetScriptPath(args))
    appRoot := LauncherCleanup_NormalizePath(appDir)
    if (scriptPath = "" || appRoot = "")
        return {stop: false, role: "unparseable", scriptPath: scriptPath}

    recordingWorker := LauncherCleanup_NormalizePath(appRoot "\RecordingFinalizeWorker.ahk")
    if (scriptPath = recordingWorker) {
        modeArg := LauncherCleanup_GetNamedArg(args, "--mode")
        workerMode := modeArg.valid ? StrLower(Trim(modeArg.value, " `t`r`n")) : ""
        if (workerMode = "finalize" || workerMode = "sync")
            return {stop: false, role: "recording-worker-" workerMode, scriptPath: scriptPath}
        ; 即使命令列不完整也採 fail-safe 保留；無效 worker 會由自己的參數驗證退出，
        ; Launcher 不應在無法證明安全時強制終止它。
        return {stop: false, role: "recording-worker-unknown", scriptPath: scriptPath}
    }

    stoppableScripts := [
        "全自動.ahk",
        "進程管理器.ahk",
        "開啟LRMC.ahk",
        "自動開啟OKWW.ahk",
        "聲骸合成.ahk"
    ]
    for scriptName in stoppableScripts {
        if (scriptPath = LauncherCleanup_NormalizePath(appRoot "\" scriptName))
            return {stop: true, role: "managed-" scriptName, scriptPath: scriptPath}
    }

    return {stop: false, role: "unknown-ahk", scriptPath: scriptPath}
}
