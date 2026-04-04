#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir

global RUN_ID := A_Now "@" A_TickCount
global STEP_SEQ := 0
global TOOLTIP_SLOT := 6

ShowTip(msg, duration := 5000) {
    global TOOLTIP_SLOT
    if (duration < 5000)
        duration := 5000
    ToolTip "          " msg, , , TOOLTIP_SLOT
    if (duration > 0)
        SetTimer(() => ToolTip(, , , TOOLTIP_SLOT), -duration)
}

WriteLog(msg, level := "INFO") {
    global RUN_ID
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    line := ts " [" level "] [" RUN_ID "] " msg "`r`n"
    try FileAppend(line, A_ScriptDir "\文字識別測試.log", "UTF-8")
}

JoinArray(items, sep := ",") {
    out := ""
    for idx, v in items {
        if (idx > 1)
            out .= sep
        out .= v
    }
    return out
}

BuildStartupReason() {
    parts := []
    if (A_Args.Length > 0)
        parts.Push("args=" JoinArray(A_Args, "|"))
    else
        parts.Push("args=<none>")
    parts.Push("source=" (A_Args.Length > 0 ? "arg-trigger" : "external-trigger(manual-or-scheduler)"))
    return JoinArray(parts, " | ")
}

LifecycleOnExit(exitReason, exitCode) {
    WriteLog("生命週期停止原因: reason=" exitReason " | exitCode=" exitCode)
}

WriteStep(stepName, detail := "", level := "INFO") {
    global STEP_SEQ
    STEP_SEQ += 1
    msg := "[STEP " Format("{:03}", STEP_SEQ) "] " stepName
    if (detail != "")
        msg .= " | " detail
    WriteLog(msg, level)
    ShowTip("📌 " stepName)
}

FIXED_LOG_FILE := "D:\LRMCAI\log\LRMCAI.log"
; 0 = 輸出完整日誌，>0 = 只輸出最後 N 行
LOG_OUTPUT_LAST_LINES := 0

WriteLog("生命週期啟動原因: " BuildStartupReason())
OnExit(LifecycleOnExit)

Main()

Main() {
    global FIXED_LOG_FILE, LOG_OUTPUT_LAST_LINES
    WriteStep("啟動", "腳本=" A_ScriptFullPath)

    logPath := Trim(FIXED_LOG_FILE, " `t`r`n")
    WriteStep("讀取設定", "logPath=" logPath)
    if (logPath = "") {
        WriteStep("設定檢查失敗", "日誌路徑為空", "ERROR")
        MsgBox "未設定日誌路徑。", "讀取失敗", "Iconx"
        ExitApp
    }

    if !FileExist(logPath) {
        WriteStep("檔案檢查失敗", "找不到日誌檔", "ERROR")
        MsgBox "找不到日誌檔：`n" logPath, "讀取失敗", "Iconx"
        ExitApp
    }

    WriteStep("讀取日誌", "開始解碼文字")
    logText := ReadTextFileBestEffort(logPath)
    logText := NormalizeText(logText)
    if (logText = "") {
        WriteStep("內容檢查失敗", "日誌為空或無法解碼", "ERROR")
        MsgBox "日誌檔存在，但內容為空或無法解碼。`n" logPath, "讀取失敗", "Iconx"
        ExitApp
    }

    outText := "[來源檔案] " logPath "`n`n" FormatLogOutput(logText, LOG_OUTPUT_LAST_LINES)
    outPath := A_ScriptDir "\\lrmcai_logtext_" A_Now ".txt"
    WriteStep("輸出整理", "outPath=" outPath)

    try FileDelete outPath
    FileAppend outText, outPath, "UTF-8"
    WriteStep("完成", "成功輸出結果")

    MsgBox "日誌讀取完成。`n`n輸出檔案：`n" outPath, "完成", "Iconi"
    ExitApp
}

ReadTextFileBestEffort(filePath) {
    txt := ""
    try txt := FileRead(filePath, "CP936")
    if (txt != "")
        return txt
    try txt := FileRead(filePath, "CP950")
    if (txt != "")
        return txt
    try txt := FileRead(filePath, "UTF-8")
    if (txt != "")
        return txt
    try txt := FileRead(filePath, "UTF-16")
    if (txt != "")
        return txt
    try txt := FileRead(filePath)
    return txt
}

NormalizeText(text) {
    if !IsSet(text)
        return ""
    t := StrReplace(text, "`r", "")
    t := RegExReplace(t, "\x1B\[[0-9;?]*[ -/]*[@-~]", "")
    t := RegExReplace(t, "[\x00-\x08\x0B\x0C\x0E-\x1F]", "")
    return Trim(t, "`n`t ")
}

FormatLogOutput(content, lastLines := 0) {
    if (lastLines <= 0)
        return content
    return TakeLastLines(content, lastLines)
}

TakeLastLines(text, maxLines := 200) {
    if (text = "")
        return ""

    lines := StrSplit(text, "`n")
    n := lines.Length
    start := (n > maxLines) ? (n - maxLines + 1) : 1
    out := ""
    Loop n - start + 1 {
        idx := start + A_Index - 1
        line := Trim(lines[idx], "`r`t ")
        if (line != "")
            out .= line "`n"
    }
    return Trim(out, "`r`n")
}