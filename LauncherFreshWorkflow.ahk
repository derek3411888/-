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

LFW_Record(proc) {
    record := {}
    for field in ["ProcessId","Name","ExecutablePath","CommandLine","CreationDate"]
        record.%field% := LauncherCleanup_NativeRecordValue(proc,field)
    if record.ExecutablePath != ""
        record.ExecutablePath := MPG_CanonicalPath(record.ExecutablePath)
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
    Wait() => Sleep(50)
}

LauncherFreshWorkflow_Drain(root,io := unset) {
    if !IsSet(io)
        io := LauncherFreshWorkflowIo(root)
    deadline := io.Now() + 10000, clear := 0
    loop {
        owned := []
        for record in io.Inventory() {
            kind := LFW_Classify(record,io.paths)
            if kind = "unknown" || kind = "recorder" {
                WriteLog("全新啟動：舊流程身分或錄影收尾未確認，尚未更新 | kind=" kind,"WARN")
                return false
            }
            if kind = "owned"
                owned.Push(record)
        }
        if !owned.Length {
            clear += 1
            if clear >= 2
                return true
        } else {
            clear := 0
            for record in owned {
                if !io.Close(record)
                    return false
                WriteLog("全新啟動：已關閉原設定安裝的舊流程 | PID=" record.ProcessId " name=" record.Name)
            }
        }
        if io.Now() >= deadline
            return false
        io.Wait()
    }
}
