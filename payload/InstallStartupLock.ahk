#Requires AutoHotkey v2.0+

; Shared only by launcher updates and direct restart-worker dispatch. The
; running task is protected by the process preflight, not a lifetime lock.
InstallStartupLock_Normalize(path) {
    pathBuffer := Buffer(65536, 0)
    size := DllCall("GetFullPathNameW", "str", path, "uint", 32768, "ptr", pathBuffer, "ptr", 0, "uint")
    if !size || size >= 32768
        throw Error("Cannot resolve installation path")
    return StrLower(RTrim(StrGet(pathBuffer, size, "UTF-16"), "\"))
}

InstallStartupLock_Acquire(root) {
    hash := 2166136261
    Loop Parse, InstallStartupLock_Normalize(root)
        hash := Mod(((hash ^ Ord(A_LoopField)) & 0xFFFFFFFF) * 16777619, 0x100000000)
    handle := DllCall("CreateMutexW", "ptr", 0, "int", false,
        "str", "Local\WutheringInstallStartup_" Format("{:08X}", hash), "ptr")
    if !handle
        return 0
    wait := DllCall("WaitForSingleObject", "ptr", handle, "uint", 0, "uint")
    if wait = 0 || wait = 128
        return handle
    DllCall("CloseHandle", "ptr", handle)
    return wait = 258 ? -1 : 0
}

InstallStartupLock_Release(handle) {
    if handle > 0 {
        DllCall("ReleaseMutex", "ptr", handle)
        DllCall("CloseHandle", "ptr", handle)
    }
}

InstallStartupLock_MainAbsent(scriptPath) {
    expected := InstallStartupLock_Normalize(scriptPath)
    try {
        for proc in InstallStartupLock_QueryProcesses() {
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
                    if arg ~= "i)\.ahk$" {
                        foundScript := true
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
    return ComObjGet("winmgmts:").ExecQuery("Select CommandLine from Win32_Process where Name like 'AutoHotkey%'")
}
