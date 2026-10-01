#Requires AutoHotkey v2.0+
#Include LauncherProcessCleanupPolicy.ahk

; Read-only classification. Never replace an active payload just because the
; launcher itself has exited and released its short-lived mutex.
LauncherStartup_Classify(proc, ahkPath, mainPath) {
    try {
        executable := LauncherCleanup_NormalizePath(proc.ExecutablePath)
        command := String(proc.CommandLine)
        pid := Integer(proc.ProcessId)
        created := String(proc.CreationDate)
        expectedExe := LauncherCleanup_NormalizePath(ahkPath)
        expectedMain := LauncherCleanup_NormalizePath(mainPath)
        if (executable = "" || command = "" || created = "" || pid <= 0)
            return {kind:"unknown", pid:pid, created:created}
        args := LauncherCleanup_ParseCommandLine(command)
        scriptPath := LauncherCleanup_NormalizePath(LauncherCleanup_GetScriptPath(args))
        if (scriptPath = "")
            return {kind:"unknown", pid:pid, created:created}
        if scriptPath != expectedMain
            return {kind:"unrelated", pid:pid, created:created}
        return {kind:executable = expectedExe ? "existing" : "same-script-other-runtime", pid:pid, created:created}
    } catch {
        return {kind:"unknown", pid:0, created:""}
    }
}

LauncherStartup_Inspect(ahkPath, mainPath) {
    try {
        records := ComObjGet("winmgmts:").ExecQuery("Select ProcessId, ExecutablePath, CommandLine, CreationDate from Win32_Process where Name like '%AutoHotkey%'")
        unknown := false
        for proc in records {
            record := LauncherStartup_Classify(proc, ahkPath, mainPath)
            if (record.kind = "existing" || record.kind = "same-script-other-runtime")
                return {allow:false, reason:"existing", pid:record.pid}
            if record.kind = "unknown"
                unknown := true
        }
        return {allow:!unknown, reason:unknown ? "uninspectable" : "clear", pid:0}
    } catch {
        return {allow:false, reason:"query-failed", pid:0}
    }
}

; CreateProcess returns the actual child handle atomically with its PID. A
; later OpenProcess(pid) can accidentally bind a reused PID after a fast exit.
LauncherStartup_Dispatch(ahkPath, command, appDir) {
    startupInfo := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
    processInfo := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    commandBuffer := Buffer((StrLen(command) + 1) * 2, 0)
    StrPut(command, commandBuffer, "UTF-16")
    NumPut("UInt", startupInfo.Size, startupInfo)
    if !DllCall("Kernel32\CreateProcessW", "str", ahkPath, "ptr", commandBuffer,
        "ptr", 0, "ptr", 0, "int", false, "uint", 0, "ptr", 0, "str", appDir,
        "ptr", startupInfo, "ptr", processInfo, "int")
        throw OSError(A_LastError, "CreateProcessW(payload)")
    child := {handle:NumGet(processInfo, 0, "ptr"), pid:NumGet(processInfo, 2*A_PtrSize, "uint")}
    DllCall("Kernel32\CloseHandle", "ptr", NumGet(processInfo, A_PtrSize, "ptr"))
    return child
}

LauncherStartup_ChildAlive(child) {
    return DllCall("Kernel32\WaitForSingleObject", "ptr", child.handle, "uint", 0, "uint") = 258
}

LauncherStartup_ReleaseChild(child) {
    DllCall("Kernel32\CloseHandle", "ptr", child.handle)
}

LauncherStartup_Start(ahkPath, mainPath, payloadArgs, appDir) {
    gate := LauncherStartup_Inspect(ahkPath, mainPath)
    if !gate.allow {
        WriteLog("主流程啟動已略過：" gate.reason " | existingPid=" gate.pid "；保留既有流程，不取代或重複啟動", "WARN")
        return {started:false, pid:0, reason:gate.reason}
    }
    child := LauncherStartup_Dispatch(ahkPath, '"' ahkPath '" "' mainPath '"' payloadArgs, appDir)
    childPid := child.pid
    WriteLog("主腳本啟動請求已送出 | childPid=" childPid "；尚未確認初始化成功")
    firstCreated := ""
    try {
    Loop 5 {
        Sleep 500
        if !LauncherStartup_ChildAlive(child)
            return {started:false, pid:childPid, reason:"child-exited"}
        try {
            records := ComObjGet("winmgmts:").ExecQuery("Select ProcessId, ExecutablePath, CommandLine, CreationDate from Win32_Process where ProcessId=" childPid)
            for proc in records {
                record := LauncherStartup_Classify(proc, ahkPath, mainPath)
                if (record.pid != childPid || record.kind != "existing")
                    continue
                if !LauncherStartup_ChildAlive(child)
                    return {started:false, pid:childPid, reason:"child-exited"}
                if (firstCreated != "" && record.created = firstCreated) {
                    WriteLog("本次主腳本程序身分已確認 | childPid=" childPid "；初始化、心跳與遊戲就緒仍需後續驗證")
                    return {started:true, pid:childPid, reason:"child-identity-confirmed"}
                }
                if (firstCreated != "" && record.created != firstCreated)
                    return {started:false, pid:childPid, reason:"child-identity-changed"}
                firstCreated := record.created
            }
        } catch {
            return {started:false, pid:childPid, reason:"child-query-failed"}
        }
    }
    WriteLog("無法確認本次新主腳本身分 | childPid=" childPid "；不把其他／舊 PID 視為啟動成功", "WARN")
    return {started:false, pid:childPid, reason:"child-unconfirmed"}
    } finally LauncherStartup_ReleaseChild(child)
}
