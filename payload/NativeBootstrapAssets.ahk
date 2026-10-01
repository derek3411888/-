#Requires AutoHotkey v2.0+

global NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE := Map()

NativeBootstrap_CanonicalPath(path) {
    path := Trim(String(path), ' "`t`r`n')
    if (path = "")
        return ""
    pathBuffer := Buffer(32768 * 2, 0)
    length := DllCall("Kernel32\GetFullPathNameW", "str", path, "uint", 32768,
        "ptr", pathBuffer, "ptr", 0, "uint")
    if (length <= 0 || length >= 32768)
        return ""
    return RTrim(StrGet(pathBuffer, length, "UTF-16"), "\")
}

NativeBootstrap_AppRoot() {
    root := Trim(EnvGet("PACK_APP_DIR"), ' "`t`r`n')
    if (root = "") {
        SplitPath(A_LineFile, , &moduleDir)
        root := RegExMatch(moduleDir, "i)\\payload$")
            ? RegExReplace(moduleDir, "i)\\payload$", "") : moduleDir
    } else if RegExMatch(root, "i)\\payload$") {
        root := RegExReplace(root, "i)\\payload$", "")
    }
    root := NativeBootstrap_CanonicalPath(root)
    if (root = "" || RegExMatch(root, "i)^[a-z]:$"))
        throw Error("Native bootstrap application root is invalid")
    return root
}

NativeBootstrap_HelperPath() {
    SplitPath(A_LineFile, , &moduleDir)
    helper := NativeBootstrap_CanonicalPath(moduleDir "\BootstrapAssets.exe")
    if (helper = "" || !FileExist(helper))
        throw Error("Native bootstrap helper is missing")
    return helper
}

NativeBootstrap_IsChildPath(path, root) {
    fullPath := NativeBootstrap_CanonicalPath(path)
    fullRoot := NativeBootstrap_CanonicalPath(root)
    if (fullPath = "" || fullRoot = "")
        return false
    return SubStr(StrLower(fullPath), 1, StrLen(fullRoot) + 1)
        = StrLower(fullRoot "\")
}

NativeBootstrap_Quote(value) {
    value := String(value)
    if InStr(value, '"') || InStr(value, "`r") || InStr(value, "`n")
        throw ValueError("Native bootstrap argument contains a forbidden character")
    return '"' value '"'
}

NativeBootstrap_ProcessCreated(processHandle) {
    times := Buffer(32, 0)
    if !DllCall("Kernel32\GetProcessTimes", "ptr", processHandle, "ptr", times,
        "ptr", times.Ptr + 8, "ptr", times.Ptr + 16, "ptr", times.Ptr + 24)
        throw OSError(A_LastError, "GetProcessTimes(native bootstrap)")
    return NumGet(times, 0, "Int64")
}

NativeBootstrap_ProcessImage(processHandle) {
    imageBuffer := Buffer(32768 * 2, 0)
    length := 32768
    if !DllCall("Kernel32\QueryFullProcessImageNameW", "ptr", processHandle,
        "uint", 0, "ptr", imageBuffer, "uint*", &length)
        throw OSError(A_LastError, "QueryFullProcessImageNameW(native bootstrap)")
    return NativeBootstrap_CanonicalPath(StrGet(imageBuffer, length, "UTF-16"))
}

NativeBootstrap_Dispatch(helperPath, arguments, workingDirectory) {
    command := NativeBootstrap_Quote(helperPath)
    for _, argument in arguments
        command .= " " NativeBootstrap_Quote(argument)
    startupInfo := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
    processInfo := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    commandBuffer := Buffer((StrLen(command) + 1) * 2, 0)
    StrPut(command, commandBuffer, "UTF-16")
    NumPut("UInt", startupInfo.Size, startupInfo)
    NumPut("UInt", 1, startupInfo, A_PtrSize = 8 ? 60 : 44) ; STARTF_USESHOWWINDOW
    NumPut("UShort", 0, startupInfo, A_PtrSize = 8 ? 64 : 48) ; SW_HIDE
    if !DllCall("Kernel32\CreateProcessW", "str", helperPath, "ptr", commandBuffer,
        "ptr", 0, "ptr", 0, "int", false, "uint", 0x08000000, "ptr", 0,
        "str", workingDirectory, "ptr", startupInfo, "ptr", processInfo, "int")
        throw OSError(A_LastError, "CreateProcessW(native bootstrap)")
    child := {handle: NumGet(processInfo, 0, "ptr"),
        thread: NumGet(processInfo, A_PtrSize, "ptr"),
        pid: NumGet(processInfo, 2 * A_PtrSize, "uint")}
    try {
        actualImage := NativeBootstrap_ProcessImage(child.handle)
        if (actualImage = "" || StrLower(actualImage) != StrLower(helperPath))
            throw Error("Native bootstrap child image mismatch")
        return child
    } catch as dispatchError {
        try DllCall("Kernel32\TerminateProcess", "ptr", child.handle, "uint", 1)
        try DllCall("Kernel32\WaitForSingleObject", "ptr", child.handle, "uint", 5000)
        DllCall("Kernel32\CloseHandle", "ptr", child.thread)
        DllCall("Kernel32\CloseHandle", "ptr", child.handle)
        throw dispatchError
    }
}

NativeBootstrap_StopChild(child) {
    wait := DllCall("Kernel32\WaitForSingleObject", "ptr", child.handle,
        "uint", 0, "uint")
    if (wait = 0)
        return true
    if (wait != 0x102)
        return false
    if !DllCall("Kernel32\TerminateProcess", "ptr", child.handle, "uint", 1)
        return false
    return DllCall("Kernel32\WaitForSingleObject", "ptr", child.handle,
        "uint", 5000, "uint") = 0
}

NativeBootstrap_Run(mode, operationArguments, timeoutMs, pollCallback := 0,
    cancelState := 0) {
    helper := NativeBootstrap_HelperPath()
    root := NativeBootstrap_AppRoot()
    parentHandle := DllCall("Kernel32\GetCurrentProcess", "ptr")
    parentPid := DllCall("Kernel32\GetCurrentProcessId", "uint")
    parentCreated := NativeBootstrap_ProcessCreated(parentHandle)
    parentImage := NativeBootstrap_ProcessImage(parentHandle)
    arguments := [mode, root]
    for _, argument in operationArguments
        arguments.Push(argument)
    arguments.Push(parentPid, parentCreated, parentImage)
    child := NativeBootstrap_Dispatch(helper, arguments, root)
    deadline := DllCall("Kernel32\GetTickCount64", "uint64")
        + Max(1000, Integer(timeoutMs))
    try {
        DllCall("Kernel32\CloseHandle", "ptr", child.thread)
        child.thread := 0
        loop {
            wait := DllCall("Kernel32\WaitForSingleObject", "ptr", child.handle,
                "uint", 100, "uint")
            if (wait = 0) {
                exitCode := 0
                if !DllCall("Kernel32\GetExitCodeProcess", "ptr", child.handle,
                    "uint*", &exitCode)
                    throw OSError(A_LastError, "GetExitCodeProcess(native bootstrap)")
                return exitCode
            }
            if (wait != 0x102)
                throw OSError(A_LastError, "WaitForSingleObject(native bootstrap)")
            if IsObject(pollCallback)
                try pollCallback.Call()
            if (IsObject(cancelState) && cancelState.cancel) {
                if !NativeBootstrap_StopChild(child)
                    throw Error("Native bootstrap cancellation could not stop its exact child")
                return 1223
            }
            if (DllCall("Kernel32\GetTickCount64", "uint64") >= deadline) {
                if !NativeBootstrap_StopChild(child)
                    throw Error("Native bootstrap timeout could not stop its exact child")
                return 1460
            }
        }
    } finally {
        if child.thread
            DllCall("Kernel32\CloseHandle", "ptr", child.thread)
        DllCall("Kernel32\CloseHandle", "ptr", child.handle)
    }
}

NativeBootstrap_StatePath(prefix, extension) {
    root := NativeBootstrap_AppRoot()
    token := DllCall("Kernel32\GetCurrentProcessId", "uint") "_"
        DllCall("Kernel32\GetTickCount64", "uint64") "_" Random(100000, 999999)
    return root "\執行暫存\原生啟動資產\" prefix "_" token extension
}

NativeBootstrap_FileSha256(filePath) {
    if !FileExist(filePath)
        return ""
    resultPath := NativeBootstrap_StatePath("hash", ".txt")
    try {
        exitCode := NativeBootstrap_Run("hash", [NativeBootstrap_CanonicalPath(filePath), resultPath], 130000)
        if (exitCode != 0 || !FileExist(resultPath))
            return ""
        hashText := StrLower(Trim(FileRead(resultPath, "UTF-8"), " `t`r`n"))
        return RegExMatch(hashText, "^[0-9a-f]{64}$") ? hashText : ""
    } catch {
        return ""
    } finally {
        try FileDelete(resultPath)
    }
}

NativeBootstrap_IsValidPortableExecutable(filePath) {
    try {
        canonicalPath := NativeBootstrap_CanonicalPath(filePath)
        root := NativeBootstrap_AppRoot()
        if (canonicalPath = "" || !FileExist(canonicalPath)
            || !NativeBootstrap_IsChildPath(canonicalPath, root))
            return false
        return NativeBootstrap_Run("validate-pe", [canonicalPath], 130000) = 0
    } catch {
        return false
    }
}

NativeBootstrap_PortableExecutableIdentity(filePath) {
    canonicalPath := NativeBootstrap_CanonicalPath(filePath)
    if (canonicalPath = "" || !FileExist(canonicalPath))
        return ""
    handle := DllCall("Kernel32\CreateFileW", "str", canonicalPath,
        "uint", 0, "uint", 0x7, "ptr", 0, "uint", 3,
        "uint", 0x80, "ptr", 0, "ptr")
    if (!handle || handle = -1)
        return ""
    try {
        fileInfoBuffer := Buffer(52, 0)
        if !DllCall("Kernel32\GetFileInformationByHandle", "ptr", handle,
            "ptr", fileInfoBuffer)
            return ""
        return Format("{1:08X}:{2:08X}:{3:08X}:{4:08X}:{5:08X}:{6:08X}:{7:08X}",
            NumGet(fileInfoBuffer, 28, "UInt"),
            NumGet(fileInfoBuffer, 44, "UInt"),
            NumGet(fileInfoBuffer, 48, "UInt"),
            NumGet(fileInfoBuffer, 32, "UInt"),
            NumGet(fileInfoBuffer, 36, "UInt"),
            NumGet(fileInfoBuffer, 24, "UInt"),
            NumGet(fileInfoBuffer, 20, "UInt"))
    } finally {
        DllCall("Kernel32\CloseHandle", "ptr", handle)
    }
}

NativeBootstrap_ForgetPortableExecutable(filePath) {
    global NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE
    key := StrLower(NativeBootstrap_CanonicalPath(filePath))
    if (key != "" && NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE.Has(key))
        NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE.Delete(key)
}

NativeBootstrap_IsValidPortableExecutableCached(filePath) {
    global NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE
    canonicalPath := NativeBootstrap_CanonicalPath(filePath)
    key := StrLower(canonicalPath)
    identity := NativeBootstrap_PortableExecutableIdentity(canonicalPath)
    if (key = "" || identity = "") {
        if (key != "" && NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE.Has(key))
            NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE.Delete(key)
        return false
    }
    if NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE.Has(key) {
        cached := NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE[key]
        if (cached.identity = identity)
            return cached.valid
    }
    valid := NativeBootstrap_IsValidPortableExecutable(canonicalPath)
    verifiedIdentity := NativeBootstrap_PortableExecutableIdentity(canonicalPath)
    if (verifiedIdentity = "" || verifiedIdentity != identity) {
        if NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE.Has(key)
            NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE.Delete(key)
        return false
    }
    NATIVE_BOOTSTRAP_PE_VALIDATION_CACHE[key] := {
        identity: verifiedIdentity, valid: valid
    }
    return valid
}

NativeBootstrap_InstallPortableExecutable(sourcePath, targetPath) {
    try {
        sourcePath := NativeBootstrap_CanonicalPath(sourcePath)
        targetPath := NativeBootstrap_CanonicalPath(targetPath)
        root := NativeBootstrap_AppRoot()
        if (sourcePath = "" || targetPath = "" || !FileExist(sourcePath)
            || !NativeBootstrap_IsChildPath(sourcePath, root)
            || !NativeBootstrap_IsChildPath(targetPath, root))
            return false
        NativeBootstrap_ForgetPortableExecutable(targetPath)
        if (NativeBootstrap_Run("install-pe", [sourcePath, targetPath], 130000) != 0)
            return false
        NativeBootstrap_ForgetPortableExecutable(targetPath)
        return FileExist(targetPath)
            && NativeBootstrap_IsValidPortableExecutableCached(targetPath)
    } catch {
        return false
    }
}

NativeBootstrap_ReadProgress(statusPath) {
    result := {received: 0, total: 0, state: ""}
    try text := FileRead(statusPath, "UTF-8")
    catch
        return result
    if RegExMatch(text, "m)^received=([0-9]+)\r?$", &received)
        result.received := Integer(received[1])
    if RegExMatch(text, "m)^total=([0-9]+)\r?$", &total)
        result.total := Integer(total[1])
    if RegExMatch(text, "m)^state=([a-z]+)\r?$", &state)
        result.state := state[1]
    return result
}

NativeBootstrap_FormatMegabytes(bytes) {
    return Format("{1:.1f} MB", Max(0, bytes) / 1048576)
}

NativeBootstrap_UpdateProgress(statusPath, textControl, progressControl,
    hintControl) {
    progress := NativeBootstrap_ReadProgress(statusPath)
    if (progress.total > 0) {
        percent := Min(99, Max(0, Floor(progress.received * 100 / progress.total)))
        progressControl.Value := percent
        textControl.Value := "正在下載 FFmpeg... " percent "%"
        hintControl.Value := NativeBootstrap_FormatMegabytes(progress.received)
            . " / " . NativeBootstrap_FormatMegabytes(progress.total)
    } else {
        nextValue := progressControl.Value + 4
        progressControl.Value := nextValue > 100 ? 0 : nextValue
        textControl.Value := "正在下載 FFmpeg..."
        hintControl.Value := NativeBootstrap_FormatMegabytes(progress.received)
    }
}

NativeBootstrap_RequestCancel(state, *) {
    state.cancel := true
}

NativeBootstrap_Download(url, outPath, title := "下載中") {
    statusPath := NativeBootstrap_StatePath("download", ".status")
    state := {cancel: false}
    window := 0
    partialPath := ""
    try {
        window := Gui("+ToolWindow -MinimizeBox -MaximizeBox", title)
        window.SetFont("s10", "Microsoft JhengHei UI")
        textControl := window.AddText("xm w420", "正在下載，請稍候...")
        progressControl := window.AddProgress("xm y+8 w420 h18", 0)
        hintControl := window.AddText("xm y+6 w420", "0.0 MB")
        window.OnEvent("Close", NativeBootstrap_RequestCancel.Bind(state))
        window.OnEvent("Escape", NativeBootstrap_RequestCancel.Bind(state))
        window.Show("AutoSize Center")
        callback := NativeBootstrap_UpdateProgress.Bind(statusPath,
            textControl, progressControl, hintControl)
        canonicalOutput := NativeBootstrap_CanonicalPath(outPath)
        if !NativeBootstrap_IsChildPath(canonicalOutput, NativeBootstrap_AppRoot())
            throw Error("Native bootstrap download output is outside the application root")
        partialPath := canonicalOutput ".native-bootstrap.partial"
        exitCode := NativeBootstrap_Run("download", [String(url),
            canonicalOutput, statusPath], 1230000,
            callback, state)
        ok := exitCode = 0 && FileExist(outPath)
        if ok {
            progressControl.Value := 100
            textControl.Value := "下載完成"
            hintControl.Value := NativeBootstrap_FormatMegabytes(FileGetSize(outPath))
            Sleep 200
        } else {
            textControl.Value := state.cancel ? "下載已取消" : "下載失敗"
            hintControl.Value := state.cancel ? "未留下未完成檔案"
                : "請稍後重試或手動放置 ffmpeg.exe"
            Sleep 300
        }
        return ok
    } catch {
        return false
    } finally {
        if IsObject(window)
            try window.Destroy()
        if (partialPath != "")
            try FileDelete(partialPath)
        try FileDelete(statusPath)
    }
}

NativeBootstrap_Extract(zipPath, destDir) {
    try {
        zipPath := NativeBootstrap_CanonicalPath(zipPath)
        destDir := NativeBootstrap_CanonicalPath(destDir)
        if (zipPath = "" || destDir = "")
            return false
        return NativeBootstrap_Run("extract", [zipPath, destDir], 330000) = 0
            && DirExist(destDir)
    } catch {
        return false
    }
}
