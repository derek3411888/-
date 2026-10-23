#Requires AutoHotkey v2.0

; Read-only admission: never mistake a skipped/unreadable process for absence.
; Termination remains in the existing path/creation-time guarded helpers.
RRD_AssertDrained(&detail) {
    try {
        targets := Map()
        for name in ["LRMCAI.exe","ok-ww.exe","Client-Win64-Shipping.exe","Wuthering Waves.exe"]
            targets[StrLower(name)] := StrLower(ResolveManagedTargetExePath(name))
        scripts := []
        for name in ["聲骸合成.ahk","開啟LRMC.ahk","自動開啟OKWW.ahk"]
            scripts.Push(StrLower(GMHost_CanonicalPath(A_ScriptDir "\" name)))
        records := []
        query := "Select ProcessId,Name,CommandLine,CreationDate from Win32_Process where "
            . "Name='LRMCAI.exe' or Name='ok-ww.exe' or Name='Client-Win64-Shipping.exe' or "
            . "Name='Wuthering Waves.exe' or Name='python.exe' or Name='pythonw.exe' or "
            . "Name='ffmpeg.exe' or Name like '%AutoHotkey%'"
        for proc in ComObjGet("winmgmts:").ExecQuery(query) {
            record := ReadManagedProcessRecord(proc.ProcessId + 0,String(proc.CreationDate))
            records.Push({pid:proc.ProcessId + 0,name:String(proc.Name),known:IsObject(record),
                path:IsObject(record) ? record.path : "",cmd:String(proc.CommandLine)})
        }
        result := RRD_Decide(records,targets,scripts,DllCall("GetCurrentProcessId"))
        detail := result.detail
        return result.ok
    } catch as err {
        detail := "無法驗證受管程序已全部退出：" err.Message
        return false
    }
}

RRD_Decide(records,targets,scripts,selfPid) {
    SplitPath(targets["ok-ww.exe"],,&okwwRoot)
    for record in records {
        if record.pid = selfPid
            continue
        name := StrLower(record.name), path := StrLower(record.path)
        reason := ""
        if !record.known
            reason := "程序身分不可讀"
        else if targets.Has(name) {
            expected := targets[name]
            if expected = "" || path = expected
                reason := "目標程式尚未退出"
        } else if InStr(name,"autohotkey") {
            if record.cmd = ""
                reason := "子腳本命令列不可讀"
            else {
                for argument in ParseManagedCommandLine(record.cmd) {
                    if !RegExMatch(argument,"i)\.ahk$")
                        continue
                    if !RegExMatch(argument,"i)^(?:[A-Z]:[\\/]|\\\\)") {
                        reason := "子腳本相對路徑無法證明屬於其他安裝"
                        continue
                    }
                    canonical := StrLower(GMHost_CanonicalPath(argument))
                    if canonical = ""
                        reason := "子腳本絕對路徑無法確認"
                    for script in scripts
                        if script != "" && canonical = script
                            reason := "受管子腳本尚未退出"
                }
            }
        } else if name = "python.exe" || name = "pythonw.exe" {
            if okwwRoot = "" || InStr(path,okwwRoot "\") = 1
                reason := "OKWW 子程序尚未退出或路徑未確認"
        } else if name = "ffmpeg.exe" {
            if record.cmd = "" || IsManagedByCurrentScriptFfmpegCommand(record.cmd)
                reason := "受管錄影尚未退出或命令列不可讀"
        }
        if reason != ""
            return {ok:false,detail:reason " | " record.name " PID=" record.pid}
    }
    return {ok:true,detail:"受管遊戲、LRMCAI、OKWW、子腳本與錄影均已確認退出"}
}
