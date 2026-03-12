#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir

FIXED_LOG_FILE := "D:\LRMCAI\log\LRMCAI.log"
; 0 = 輸出完整日誌，>0 = 只輸出最後 N 行
LOG_OUTPUT_LAST_LINES := 0

Main()

Main() {
    global FIXED_LOG_FILE, LOG_OUTPUT_LAST_LINES

    logPath := Trim(FIXED_LOG_FILE, " `t`r`n")
    if (logPath = "") {
        MsgBox "未設定日誌路徑。", "讀取失敗", "Iconx"
        ExitApp
    }

    if !FileExist(logPath) {
        MsgBox "找不到日誌檔：`n" logPath, "讀取失敗", "Iconx"
        ExitApp
    }

    logText := ReadTextFileBestEffort(logPath)
    logText := NormalizeText(logText)
    if (logText = "") {
        MsgBox "日誌檔存在，但內容為空或無法解碼。`n" logPath, "讀取失敗", "Iconx"
        ExitApp
    }

    outText := "[來源檔案] " logPath "`n`n" FormatLogOutput(logText, LOG_OUTPUT_LAST_LINES)
    outPath := A_ScriptDir "\\lrmcai_logtext_" A_Now ".txt"

    try FileDelete outPath
    FileAppend outText, outPath, "UTF-8"

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