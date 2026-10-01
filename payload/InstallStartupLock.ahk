#Requires AutoHotkey v2.0+

; Two separate reservations: startup serializes launcher/worker dispatch;
; runtime excludes installation writes and effectful main initialization.
; Main never waits on startup (a worker can hold it while waiting for ACK).
InstallStartupLock_Normalize(path) {
    path := StrReplace(String(path), "/", "\")
    if SubStr(path, 1, 8) = "\\?\UNC\"
        path := "\\" SubStr(path, 9)
    else if SubStr(path, 1, 4) = "\\?\"
        path := SubStr(path, 5)
    pathBuffer := Buffer(65536, 0)
    size := DllCall("GetFullPathNameW", "str", path, "uint", 32768, "ptr", pathBuffer, "ptr", 0, "uint")
    if !size || size >= 32768
        throw Error("Cannot resolve installation path")
    return StrLower(RTrim(StrGet(pathBuffer, size, "UTF-16"), "\"))
}

InstallStartupLock_Acquire(root, purpose := "Startup") {
    hash := 2166136261
    Loop Parse, InstallStartupLock_Normalize(root)
        hash := Mod(((hash ^ Ord(A_LoopField)) & 0xFFFFFFFF) * 16777619, 0x100000000)
    handle := DllCall("CreateMutexW", "ptr", 0, "int", false,
        "str", "Local\WutheringInstall" purpose "_" Format("{:08X}", hash), "ptr")
    if !handle
        return 0
    wait := DllCall("WaitForSingleObject", "ptr", handle, "uint", 0, "uint")
    if wait = 0 || wait = 128
        return handle
    DllCall("CloseHandle", "ptr", handle)
    return wait = 258 ? -1 : 0
}

InstallStartupLock_AcquireRuntime(root) {
    return InstallStartupLock_Acquire(root, "Runtime")
}

InstallStartupLock_EnterMain(scriptPath) {
    SplitPath(scriptPath, , &payloadDir)
    SplitPath(payloadDir, , &root)
    handle := InstallStartupLock_AcquireRuntime(root)
    if handle <= 0
        return handle
    ; Old releases do not own the runtime mutex. Concurrent new entrants lose
    ; the mutex and exit immediately; allow their WMI snapshots to disappear.
    Loop 20 {
        if InstallStartupLock_MainAbsent(scriptPath, DllCall("GetCurrentProcessId", "uint"))
            return handle
        Sleep 100
    }
    InstallStartupLock_Release(handle)
    return -1
}

InstallStartupLock_Release(handle) {
    if handle > 0 {
        DllCall("ReleaseMutex", "ptr", handle)
        DllCall("CloseHandle", "ptr", handle)
    }
}

InstallStartupLock_MainAbsent(scriptPath, ownPid := 0) {
    expected := InstallStartupLock_Normalize(scriptPath)
    try {
        for proc in InstallStartupLock_QueryProcesses() {
            if ownPid && proc.ProcessId = ownPid
                continue
            if !proc.CommandLine
                return false
            argc := 0
            argv := DllCall("Shell32\CommandLineToArgvW", "str", proc.CommandLine, "int*", &argc, "ptr")
            if !argv
                return false
            foundScript := false
            try {
                Loop argc - 1 {
                    arg := StrGet(NumGet(argv, A_Index*A_PtrSize, "ptr"), "UTF-16")
                    if StrLower(arg) = "/include"
                        return false ; next .ahk can be an include, not the main
                    if arg ~= "i)\.ahk$" {
                        foundScript := true
                        ; Relative tokens are relative to the TARGET's CWD,
                        ; which WMI does not provide. Never infer unrelated.
                        if !(arg ~= "i)^(?:[a-z]:[\\/]|\\\\[^\\]+\\[^\\]+\\)")
                            return false
                        if InstallStartupLock_Normalize(arg) = expected
                            return false
                        break
                    }
                }
            } finally DllCall("LocalFree", "ptr", argv)
            if !foundScript
                return false
        }
        return true
    } catch {
        return false
    }
}

InstallStartupLock_QueryProcesses() {
    return ComObjGet("winmgmts:").ExecQuery("Select ProcessId, CommandLine from Win32_Process where Name like '%AutoHotkey%'")
}
