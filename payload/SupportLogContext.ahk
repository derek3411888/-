; SupportLogContext.ahk - bounded and redacted diagnostic log excerpts for support requests.
#Requires AutoHotkey v2.0+

SupportLog_Redact(text) {
    safe := String(text)
    safe := RegExReplace(safe, "i)(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}", "$1[REDACTED]")
    safe := RegExReplace(safe, "i)((?:password|passwd|pwd|token|api[_-]?key|secret|authorization)\s*[:=]\s*)[^,\s;]+", "$1[REDACTED]")
    safe := RegExReplace(safe, "i)\b(?:gh[opusr]_[A-Za-z0-9]{12,}|sk-(?:proj-)?[A-Za-z0-9_-]{12,})\b", "[REDACTED]")
    return safe
}

SupportLog_ReadRecentFile(logPath, maxChars := 12000, maxBytes := 65536, maxLines := 120) {
    result := {
        available: false,
        fileName: "",
        excerpt: "",
        truncated: false,
        sourceBytes: 0
    }
    path := Trim(String(logPath), " `t`r`n")
    if (path = "" || !FileExist(path))
        return result

    try SplitPath(path, &fileName)
    catch
        fileName := ""
    result.fileName := fileName

    try result.sourceBytes := FileGetSize(path)
    catch
        return result

    file := ""
    try {
        file := FileOpen(path, "r", "UTF-8")
        if !IsObject(file)
            return result
        startAt := Max(0, result.sourceBytes - Max(4096, maxBytes))
        if (startAt > 0) {
            file.Pos := startAt
            result.truncated := true
        }
        text := file.Read()
        file.Close()
        file := ""
    } catch {
        try {
            if IsObject(file)
                file.Close()
        }
        return result
    }

    text := StrReplace(text, "`r", "")
    lines := StrSplit(text, "`n")
    if (result.truncated && lines.Length > 0)
        lines.RemoveAt(1)
    if (lines.Length > maxLines) {
        firstLine := lines.Length - maxLines + 1
        kept := []
        Loop maxLines
            kept.Push(lines[firstLine + A_Index - 1])
        lines := kept
        result.truncated := true
    }

    excerpt := ""
    for index, line in lines
        excerpt .= (index > 1 ? "`n" : "") line
    excerpt := Trim(excerpt, " `t`r`n")
    if (StrLen(excerpt) > maxChars) {
        excerpt := SubStr(excerpt, StrLen(excerpt) - maxChars + 1)
        newlineAt := InStr(excerpt, "`n")
        if (newlineAt > 0)
            excerpt := SubStr(excerpt, newlineAt + 1)
        result.truncated := true
    }

    excerpt := SupportLog_Redact(excerpt)
    result.excerpt := excerpt
    result.available := excerpt != ""
    return result
}

SupportLog_CurrentSummary(maxChars := 12000, maxBytes := 65536, maxLines := 120) {
    global logger
    logPath := ""
    try {
        if IsObject(logger)
            logPath := logger.logFile
    }
    if (Trim(String(logPath), " `t`r`n") = "") {
        fallbackPath := RuntimeFiles_LogFallbackPath("全自動")
        if FileExist(fallbackPath)
            logPath := fallbackPath
    }
    return SupportLog_ReadRecentFile(logPath, maxChars, maxBytes, maxLines)
}
