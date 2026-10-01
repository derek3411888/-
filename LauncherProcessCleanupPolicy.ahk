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

; Inventory is only a candidate. Bind one process object, then re-read the
; candidate's complete identity before terminating that retained object.
LauncherCleanup_StopVerified(candidate, appDir, ops := unset) {
    if !IsSet(ops)
        ops := {open:LauncherCleanup_Open, query:LauncherCleanup_QueryIdentity,
            alive:LauncherCleanup_Alive, kill:LauncherCleanup_KillAndWait, close:LauncherCleanup_Close}
    ownedHandle := 0
    try {
        expected := {ProcessId:Integer(candidate.ProcessId), CreationDate:String(candidate.CreationDate),
            ExecutablePath:String(candidate.ExecutablePath), CommandLine:String(candidate.CommandLine),
            Name:String(candidate.Name)}
        decision := LauncherCleanup_ProcessDecision(expected.Name, expected.CommandLine, appDir)
        if !decision.stop || decision.role = "managed-全自動.ahk"
            return false
        if expected.ProcessId <= 0 || expected.CreationDate = "" || expected.ExecutablePath = "" || expected.CommandLine = ""
            return false
        ownedHandle := ops.open.Call(expected.ProcessId)
        if !ownedHandle || !ops.alive.Call(ownedHandle)
            return false
        current := ops.query.Call(expected.ProcessId)
        if !IsObject(current) || current.ProcessId != expected.ProcessId
            || String(current.CreationDate) != expected.CreationDate
            || LauncherCleanup_NormalizePath(current.ExecutablePath) != LauncherCleanup_NormalizePath(expected.ExecutablePath)
            || String(current.CommandLine) != expected.CommandLine || String(current.Name) != expected.Name
            return false
        currentDecision := LauncherCleanup_ProcessDecision(current.Name, current.CommandLine, appDir)
        if !currentDecision.stop || currentDecision.role != decision.role || !ops.alive.Call(ownedHandle)
            return false
        return ops.kill.Call(ownedHandle)
    } catch {
        return false
    } finally {
        if ownedHandle
            ops.close.Call(ownedHandle)
    }
}

; Native helpers can outlive their parent briefly while completing an atomic
; write.  Updating payload while one of those exact images is still mapped can
; fail or partially publish an update.  This path is deliberately wait-only:
; it opens query/synchronize handles, never requests terminate access, and
; ignores same-name processes whose complete image path belongs elsewhere.
LauncherCleanup_NativeHelperNames() {
    return [
        "GameMaintenanceWorker.exe",
        "PerformanceTelemetryWorker.exe",
        "RuntimeUtilities.exe",
        "BootstrapAssets.exe",
        "LauncherMaintenance.exe"
    ]
}

LauncherCleanup_IsNativeHelperName(processName) {
    candidate := StrLower(Trim(String(processName), " `t`r`n"))
    for helperName in LauncherCleanup_NativeHelperNames() {
        if (candidate = StrLower(helperName))
            return true
    }
    return false
}

LauncherCleanup_NativeRecordValue(record, fieldName) {
    try {
        value := record.%fieldName%
        return String(value)
    } catch {
        return ""
    }
}

LauncherCleanup_ClassifyNativeRecord(record, appDir) {
    name := LauncherCleanup_NativeRecordValue(record, "Name")
    if !LauncherCleanup_IsNativeHelperName(name)
        return {kind:"ignore",pid:0,path:"",name:name,creation:""}

    imagePath := LauncherCleanup_NormalizePath(LauncherCleanup_NativeRecordValue(record, "ExecutablePath"))
    if (imagePath = "")
        return {kind:"unknown",pid:0,path:"",name:name,creation:"",reason:"unverifiable-path"}

    expectedPath := LauncherCleanup_NormalizePath(appDir "\" name)
    if (expectedPath = "")
        return {kind:"unknown",pid:0,path:imagePath,name:name,creation:"",reason:"unverifiable-root"}
    if (imagePath != expectedPath)
        return {kind:"foreign",pid:0,path:imagePath,name:name,creation:""}

    pidText := LauncherCleanup_NativeRecordValue(record, "ProcessId")
    creation := LauncherCleanup_NativeRecordValue(record, "CreationDate")
    pid := 0
    try pid := Integer(pidText)
    if (pid <= 0 || creation = "")
        return {kind:"unknown",pid:pid,path:imagePath,name:name,creation:creation,reason:"unverifiable-identity"}
    return {kind:"owned",pid:pid,path:imagePath,name:name,creation:creation,reason:""}
}

LauncherCleanup_NativeIdentityMatches(expected, current) {
    return current.kind = "owned" && current.pid = expected.pid
        && current.creation = expected.creation
        && current.path = expected.path
        && StrLower(current.name) = StrLower(expected.name)
}

; Convert a WMI candidate into a retained handle.  A missing candidate after a
; failed open is an ordinary stale-exit race; a live but changed PID identity is
; unknown and therefore blocks publication.
LauncherCleanup_BindNativeCandidate(candidate, appDir, ops) {
    retained := 0
    try {
        retained := ops.open.Call(candidate.pid)
        if !retained {
            freshRecord := ops.query.Call(candidate.pid)
            if !IsObject(freshRecord)
                return {kind:"stale",handle:0,pid:candidate.pid,path:candidate.path,reason:"exited"}
            fresh := LauncherCleanup_ClassifyNativeRecord(freshRecord, appDir)
            if !LauncherCleanup_NativeIdentityMatches(candidate, fresh)
                return {kind:"unknown",handle:0,pid:candidate.pid,path:candidate.path,reason:"identity-changed"}
            return {kind:"unknown",handle:0,pid:candidate.pid,path:candidate.path,reason:"unverifiable-open"}
        }

        if !ops.alive.Call(retained)
            return {kind:"stale",handle:0,pid:candidate.pid,path:candidate.path,reason:"exited"}

        retainedImage := LauncherCleanup_NormalizePath(ops.image.Call(retained))
        retainedCreation := ops.created.Call(retained)
        if (retainedImage = "" || retainedCreation <= 0)
            return {kind:"unknown",handle:0,pid:candidate.pid,path:candidate.path,reason:"unverifiable-handle"}

        freshRecord := ops.query.Call(candidate.pid)
        if !IsObject(freshRecord) {
            if !ops.alive.Call(retained)
                return {kind:"stale",handle:0,pid:candidate.pid,path:candidate.path,reason:"exited"}
            return {kind:"unknown",handle:0,pid:candidate.pid,path:candidate.path,reason:"unverifiable-refresh"}
        }
        fresh := LauncherCleanup_ClassifyNativeRecord(freshRecord, appDir)
        if !LauncherCleanup_NativeIdentityMatches(candidate, fresh)
            return {kind:"unknown",handle:0,pid:candidate.pid,path:candidate.path,reason:"identity-changed"}
        if (retainedImage != candidate.path || ops.created.Call(retained) != retainedCreation)
            return {kind:"unknown",handle:0,pid:candidate.pid,path:candidate.path,reason:"identity-changed"}
        if !ops.alive.Call(retained)
            return {kind:"stale",handle:0,pid:candidate.pid,path:candidate.path,reason:"exited"}

        result := {kind:"bound",handle:retained,pid:candidate.pid,path:candidate.path,
            creation:candidate.creation,handleCreation:retainedCreation,reason:""}
        retained := 0
        return result
    } finally {
        if retained
            ops.close.Call(retained)
    }
}

LauncherCleanup_NativeDrainResult(ok, reason, startTick, ops, waited := false, pid := 0, imagePath := "") {
    elapsed := 0
    try elapsed := Max(0, ops.now.Call() - startTick)
    return {ok:ok,reason:reason,waited:waited,pid:pid,path:imagePath,elapsed:elapsed}
}

; Require two clear inventories separated by a short poll.  This closes the
; race where a child starts just after its parent exits.  Every live owned
; candidate is re-bound and revalidated on each pass, so stale exits and PID
; reuse cannot authorize a payload swap.
LauncherCleanup_WaitNativeHelpers(appDir, timeoutMs := 45000, ops := unset) {
    if !IsSet(ops)
        ops := LauncherCleanup_NativeDrainDefaultOps()
    limit := 0
    try limit := Integer(timeoutMs)
    catch
        limit := 0
    if (limit <= 0)
        limit := 1
    if (limit > 45000)
        limit := 45000

    startTick := 0
    try startTick := ops.now.Call()
    catch
        return {ok:false,reason:"clock-error",waited:false,pid:0,path:"",elapsed:0}

    appRoot := LauncherCleanup_NormalizePath(appDir)
    if (appRoot = "")
        return LauncherCleanup_NativeDrainResult(false,"unverifiable-root",startTick,ops)

    clearPasses := 0
    waited := false
    Loop {
        try elapsed := Max(0, ops.now.Call() - startTick)
        catch
            return {ok:false,reason:"clock-error",waited:waited,pid:0,path:"",elapsed:0}
        if (elapsed >= limit)
            return LauncherCleanup_NativeDrainResult(false,"timeout",startTick,ops,waited)

        try records := ops.inventory.Call()
        catch
            return LauncherCleanup_NativeDrainResult(false,"inventory-error",startTick,ops,waited)
        if !IsObject(records)
            return LauncherCleanup_NativeDrainResult(false,"inventory-error",startTick,ops,waited)

        retained := []
        failure := 0
        try {
            for record in records {
                candidate := LauncherCleanup_ClassifyNativeRecord(record, appRoot)
                if (candidate.kind = "ignore" || candidate.kind = "foreign")
                    continue
                if (candidate.kind = "unknown") {
                    failure := candidate
                    break
                }
                try bound := LauncherCleanup_BindNativeCandidate(candidate, appRoot, ops)
                catch {
                    failure := {pid:candidate.pid,path:candidate.path,reason:"operation-error"}
                    break
                }
                if (bound.kind = "unknown") {
                    failure := bound
                    break
                }
                if (bound.kind = "bound")
                    retained.Push(bound)
            }

            if IsObject(failure)
                return LauncherCleanup_NativeDrainResult(false,failure.reason,startTick,ops,waited,
                    failure.pid,failure.path)

            if (retained.Length = 0) {
                clearPasses += 1
                if (clearPasses >= 2)
                    return LauncherCleanup_NativeDrainResult(true,"clear",startTick,ops,waited)
                remaining := limit - Max(0, ops.now.Call() - startTick)
                if (remaining <= 0)
                    return LauncherCleanup_NativeDrainResult(false,"timeout",startTick,ops,waited)
                try ops.sleep.Call(Min(50,remaining))
                catch
                    return LauncherCleanup_NativeDrainResult(false,"wait-error",startTick,ops,waited)
                continue
            }

            clearPasses := 0
            waited := true
            for item in retained {
                remaining := limit - Max(0, ops.now.Call() - startTick)
                if (remaining <= 0)
                    return LauncherCleanup_NativeDrainResult(false,"timeout",startTick,ops,waited,
                        item.pid,item.path)
                try waitResult := ops.wait.Call(item.handle,Min(100,remaining))
                catch
                    return LauncherCleanup_NativeDrainResult(false,"wait-error",startTick,ops,waited,
                        item.pid,item.path)
                if (waitResult != 0 && waitResult != 258)
                    return LauncherCleanup_NativeDrainResult(false,"wait-error",startTick,ops,waited,
                        item.pid,item.path)
            }
        } finally {
            for item in retained {
                try ops.close.Call(item.handle)
            }
        }
    }
}

LauncherCleanup_NativeDrainDefaultOps() {
    return {inventory:LauncherCleanup_QueryNativeHelpers,open:LauncherCleanup_OpenNative,
        query:LauncherCleanup_QueryIdentity,alive:LauncherCleanup_Alive,
        image:LauncherCleanup_QueryImagePath,created:LauncherCleanup_QueryCreationTime,
        wait:LauncherCleanup_WaitHandle,close:LauncherCleanup_Close,
        now:LauncherCleanup_MonotonicMilliseconds,sleep:LauncherCleanup_SleepMilliseconds}
}

LauncherCleanup_QueryNativeHelpers() {
    conditions := []
    for helperName in LauncherCleanup_NativeHelperNames()
        conditions.Push("Name='" helperName "'")
    query := "Select ProcessId, CreationDate, ExecutablePath, Name from Win32_Process where "
        . LauncherCleanup_Join(conditions," OR ")
    records := []
    for record in ComObjGet("winmgmts:").ExecQuery(query)
        records.Push(record)
    return records
}

LauncherCleanup_Join(values, separator) {
    result := ""
    for index, value in values
        result .= (index = 1 ? "" : separator) value
    return result
}

LauncherCleanup_OpenNative(pid) {
    ; SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION.  No terminate right.
    return DllCall("Kernel32\OpenProcess", "uint", 0x00101000, "int", false, "uint", pid, "ptr")
}

LauncherCleanup_QueryImagePath(handle) {
    capacity := 32768
    imageBuffer := Buffer(capacity * 2,0)
    if !DllCall("Kernel32\QueryFullProcessImageNameW", "ptr", handle, "uint", 0,
        "ptr", imageBuffer, "uint*", &capacity, "int")
        return ""
    return StrGet(imageBuffer,capacity,"UTF-16")
}

LauncherCleanup_QueryCreationTime(handle) {
    created := Buffer(8,0), exited := Buffer(8,0), kernel := Buffer(8,0), user := Buffer(8,0)
    if !DllCall("Kernel32\GetProcessTimes", "ptr", handle, "ptr", created, "ptr", exited,
        "ptr", kernel, "ptr", user, "int")
        return 0
    return NumGet(created,0,"int64")
}

LauncherCleanup_WaitHandle(handle, milliseconds) {
    return DllCall("Kernel32\WaitForSingleObject", "ptr", handle, "uint", milliseconds, "uint")
}

LauncherCleanup_MonotonicMilliseconds() {
    return DllCall("Kernel32\GetTickCount64", "uint64")
}

LauncherCleanup_SleepMilliseconds(milliseconds) {
    DllCall("Kernel32\Sleep", "uint", milliseconds)
}

LauncherCleanup_Open(pid) {
    return DllCall("Kernel32\OpenProcess", "uint", 0x00101001, "int", false, "uint", pid, "ptr")
}

LauncherCleanup_QueryIdentity(pid) {
    for record in ComObjGet("winmgmts:").ExecQuery("Select ProcessId, CreationDate, ExecutablePath, CommandLine, Name from Win32_Process where ProcessId=" Integer(pid))
        return record
    return 0
}

LauncherCleanup_Alive(handle) {
    return DllCall("Kernel32\WaitForSingleObject", "ptr", handle, "uint", 0, "uint") = 258
}

LauncherCleanup_KillAndWait(handle) {
    if !DllCall("Kernel32\TerminateProcess", "ptr", handle, "uint", 0, "int")
        return false
    return DllCall("Kernel32\WaitForSingleObject", "ptr", handle, "uint", 5000, "uint") = 0
}

LauncherCleanup_Close(handle) {
    DllCall("Kernel32\CloseHandle", "ptr", handle)
}
