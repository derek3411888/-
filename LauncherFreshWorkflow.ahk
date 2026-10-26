#Requires AutoHotkey v2.0+
#Include LauncherProcessCleanupPolicy.ahk
#Include payload\ManagedProcessGuard.ahk
#Include payload\FreshMaintenanceState.ahk

LFW_ConfiguredPath(config,key,section := "paths",fallback := "") {
    raw := Trim(IniRead(config,section,key,fallback),' "`t`r`n')
    if raw = ""
        return ""
    if RegExMatch(raw,"i)\.lnk$")
        try FileGetShortcut(raw,&raw)
        catch
            return ""
    if !RegExMatch(raw,"i)^(?:[a-z]:\\|\\\\[^\\]+\\[^\\]+\\)")
        return ""
    return MPG_CanonicalPath(raw)
}

LFW_Paths(root) {
    config := root "\config\config.ini", targets := Map()
    entry := LFW_ConfiguredPath(config,"WUTHERING"), gameRoot := ""
    SplitPath(entry,&name,&directory)
    if StrLower(name) = "wuthering waves.exe"
        gameRoot := directory
    else if StrLower(name) = "client-win64-shipping.exe" {
        ; Accept only the publisher's known layout, not an arbitrary parent.
        if RegExMatch(directory,"i)^(.*)\\Client\\Binaries\\Win64$",&layout)
            gameRoot := layout[1]
    }
    targets["client-win64-shipping.exe"] := gameRoot = "" ? "" : MPG_CanonicalPath(gameRoot "\Client\Binaries\Win64\Client-Win64-Shipping.exe")
    targets["wuthering waves.exe"] := gameRoot = "" ? "" : MPG_CanonicalPath(gameRoot "\Wuthering Waves.exe")
    targets["lrmcai.exe"] := LFW_ConfiguredPath(config,"LRMC")
    targets["ok-ww.exe"] := LFW_ConfiguredPath(config,"OKWW")
    SplitPath(targets["ok-ww.exe"],,&okwwRoot)
    recorder := LFW_ConfiguredPath(config,"ffmpeg_exe","screen_recording",root "\tools\ffmpeg\bin\ffmpeg.exe")
    return {targets:targets,okwwRoot:okwwRoot,recorder:recorder}
}

LFW_Classify(record,paths) {
    name := StrLower(LauncherCleanup_NativeRecordValue(record,"Name"))
    if !paths.targets.Has(name) && name != "python.exe" && name != "pythonw.exe" && name != "ffmpeg.exe"
        return "unrelated"
    image := LauncherCleanup_NativeRecordValue(record,"ExecutablePath")
    if image = ""
        return "unknown"
    image := LauncherCleanup_NormalizePath(image)
    if paths.targets.Has(name) {
        expected := paths.targets[name]
        if expected = ""
            return "unknown" ; a launcher URI/missing path is not kill authority
        return image = LauncherCleanup_NormalizePath(expected) ? "owned" : "unrelated"
    }
    command := LauncherCleanup_NativeRecordValue(record,"CommandLine")
    if name = "ffmpeg.exe" {
        if paths.recorder = "" || image != LauncherCleanup_NormalizePath(paths.recorder)
            return "unrelated"
        if command = ""
            return "unknown"
        for arg in LauncherCleanup_ParseCommandLine(command)
            if RegExMatch(arg,"i)(?:^|[\\/])wuthering_auto_recording_\d{8}_\d{6}\.mkv$")
                return "recorder" ; never force-stop a recorder in the launcher
        return "unrelated"
    }
    titleMatched := false
    if record.HasOwnProp("titles")
        for title in record.titles
            if RegExMatch(title,"i)^OK-WW\s+v[\d.]+\s+Global(?:\s*-\s*OK-WW)?\s*$")
                titleMatched := true
    if paths.okwwRoot = ""
        return titleMatched ? "unknown" : "unrelated"
    if InStr(image,LauncherCleanup_NormalizePath(paths.okwwRoot) "\") != 1
        return "unrelated"
    if command = ""
        return "unknown"
    return titleMatched || RegExMatch(command,"i)ok-ww|okww") ? "owned" : "unknown"
}

; Some live processes expose Name/CreationDate to WMI but omit the image.
; Resolve only through a query-only retained handle with the SAME creation
; time as the WMI candidate. Do not perform one slow WMI query per process.
; A missing field is not proof of an old workflow (or kill authority).
LFW_CreationMatches(creation,started) {
    if started <= 0 || !RegExMatch(creation,"^\d{14}\.\d{6}[+-]\d{3}$")
        return false
    try {
        stamp := ComObject("WbemScripting.SWbemDateTime")
        stamp.Value := creation
        expected := Integer(stamp.GetFileTime(false)) ; UTC, never local offset twice
        ; WMI preserves microseconds; GetProcessTimes has 100ns precision.
        return expected > 0 && started // 10 = expected // 10
    } catch {
        return false
    }
}

LFW_ResolveImage(record,ops := unset) {
    if !IsSet(ops)
        ops := LFW_ImageProbeOps()
    handle := 0
    try {
        pid := Integer(record.ProcessId), name := StrLower(record.Name), creation := record.CreationDate
        if pid <= 0 || name = "" || creation = ""
            return {image:"",reason:"missing-identity"}
        handle := ops.open.Call(pid)
        if !handle
            return {image:"",reason:"query-handle-unavailable"}
        if ops.wait.Call(handle,0) != 258
            return {image:"",reason:"not-running-or-wait-failed"}
        started := ops.created.Call(handle)
        image := ops.canonical.Call(ops.image.Call(handle))
        if started <= 0 || image = ""
            return {image:"",reason:"query-image-unavailable"}
        SplitPath(image,&imageName)
        if !LFW_CreationMatches(creation,started) || StrLower(imageName) != name
            return {image:"",reason:"identity-changed"}
        if ops.created.Call(handle) != started || ops.wait.Call(handle,0) != 258
            return {image:"",reason:"process-changed-or-exited"}
        return {image:image,reason:"query-handle-verified"}
    } catch {
        return {image:"",reason:"identity-query-failed"}
    } finally {
        if handle
            ops.close.Call(handle)
    }
}

LFW_ImageProbeOps() {
    return {open:LauncherCleanup_OpenNative,wait:LauncherCleanup_WaitHandle,
        image:LauncherCleanup_QueryImagePath,created:LauncherCleanup_QueryCreationTime,
        canonical:MPG_CanonicalPath,close:LauncherCleanup_Close}
}

LFW_Record(proc,ops := unset) {
    record := {}
    for field in ["ProcessId","Name","ExecutablePath","CommandLine","CreationDate"]
        record.%field% := LauncherCleanup_NativeRecordValue(proc,field)
    if record.ExecutablePath != ""
        record.ExecutablePath := MPG_CanonicalPath(record.ExecutablePath)
    record.imageObservation := "wmi-path"
    if record.ExecutablePath = "" {
        resolved := IsSet(ops) ? LFW_ResolveImage(record,ops) : LFW_ResolveImage(record)
        record.ExecutablePath := resolved.image
        record.imageObservation := resolved.reason
    }
    record.titles := []
    if RegExMatch(record.Name,"i)^pythonw?\.exe$")
        for hwnd in WinGetList("ahk_pid " record.ProcessId)
            try record.titles.Push(WinGetTitle("ahk_id " hwnd))
    return record
}

class LauncherFreshWorkflowIo {
    __New(root) => this.paths := LFW_Paths(root)
    Inventory() {
        records := []
        query := "Select ProcessId,Name,ExecutablePath,CommandLine,CreationDate from Win32_Process where ("
            . "Name='LRMCAI.exe' OR Name='ok-ww.exe' OR Name='python.exe' OR Name='pythonw.exe' OR "
            . "Name='Client-Win64-Shipping.exe' OR Name='Wuthering Waves.exe' OR Name='ffmpeg.exe')"
        for proc in ComObjGet("winmgmts:").ExecQuery(query)
            records.Push(LFW_Record(proc))
        return records
    }
    Close(expected) {
        ; Reuse the existing retained-handle identity guard. Snapshot PID/name
        ; alone is never authority to terminate a process.
        if expected.CreationDate = "" || expected.CommandLine = "" || LFW_Classify(expected,this.paths) != "owned"
            return false
        bound := MPG_ReadRecord(Integer(expected.ProcessId),expected.ExecutablePath)
        if !IsObject(bound)
            return !ProcessExist(Integer(expected.ProcessId))
        current := LauncherCleanup_QueryIdentity(Integer(expected.ProcessId))
        if !IsObject(current)
            return !ProcessExist(Integer(expected.ProcessId))
        current := LFW_Record(current)
        if current.CreationDate != expected.CreationDate || current.CommandLine != expected.CommandLine
            || current.ExecutablePath != expected.ExecutablePath || LFW_Classify(current,this.paths) != "owned"
            return false
        return MPG_CloseRecord(bound)
    }
    Now() => DllCall("GetTickCount64","uint64")
    Wait() => Sleep(200)
}

LauncherFreshWorkflow_Drain(root,io := unset) {
    if !IsSet(io)
        io := LauncherFreshWorkflowIo(root)
    deadline := io.Now() + 10000, clear := 0, reported := Map()
    loop {
        if io.Now() >= deadline {
            WriteLog("全新啟動：舊流程檢查等待逾時（10 秒）；保留檔案，不開始更新","WARN")
            return false
        }
        try records := io.Inventory()
        catch {
            WriteLog("全新啟動：程序清單讀取失敗；保留檔案，不開始更新 | reason=inventory-error","WARN")
            return false
        }
        if io.Now() >= deadline {
            WriteLog("全新啟動：程序清單回應已超過等待期限；不開始更新 | reason=inventory-timeout","WARN")
            return false
        }
        owned := [], blocked := ""
        for record in records {
            kind := LFW_Classify(record,io.paths)
            if kind = "unknown" || kind = "recorder" {
                reason := kind = "recorder" ? "recording-still-running"
                    : (record.ExecutablePath = "" ? LauncherCleanup_NativeRecordValue(record,"imageObservation")
                    : (record.CommandLine = "" ? "command-unavailable" : "scope-unconfirmed"))
                blocked := "kind=" kind " PID=" record.ProcessId " name=" record.Name " reason=" reason
                break
            }
            if kind = "owned"
                owned.Push(record)
        }
        if blocked != "" {
            ; A process may be exiting or WMI may temporarily omit fields.
            ; Re-observe within the existing budget, without closing anything
            ; from this inventory until every candidate is accounted for.
            clear := 0
            if !reported.Has(blocked) {
                WriteLog("全新啟動：等待舊流程身分或錄影收尾確認；尚未更新 | " blocked,"WARN")
                reported[blocked] := true
            }
        } else if !owned.Length {
            clear += 1
            if clear >= 2
                return true
        } else {
            clear := 0
            for record in owned {
                if !io.Close(record) {
                    WriteLog("全新啟動：舊流程關閉未確認；保留檔案，不開始更新 | PID=" record.ProcessId " name=" record.Name,"WARN")
                    return false
                }
                WriteLog("全新啟動：已關閉原設定安裝的舊流程 | PID=" record.ProcessId " name=" record.Name)
            }
        }
        io.Wait()
    }
}
