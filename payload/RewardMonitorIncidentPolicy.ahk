#Requires AutoHotkey v2.0+

; 收尾監測的遊戲退出判斷與事故文字整理保持為純函數，讓正式流程與
; 回歸測試使用完全相同的規則。

RewardMonitor_IsConfirmedProcessExit(samples, requiredHits := 3) {
    if !IsObject(samples)
        return false
    needed := 3
    try needed := Max(1, Integer(requiredHits))
    if (samples.Length < needed)
        return false

    firstIndex := samples.Length - needed + 1
    Loop needed {
        sample := samples[firstIndex + A_Index - 1]
        if !IsObject(sample)
            return false
        pid := 0
        hwnd := 0
        try pid := sample.HasOwnProp("pid") ? Integer(sample.pid) : 0
        try hwnd := sample.HasOwnProp("hwnd") ? Integer(sample.hwnd) : 0
        ; 任一樣本仍看得到程序或視窗，都只能視為載入／重建中的短暫狀態。
        if (pid > 0 || hwnd > 0)
            return false
    }
    return true
}

RewardMonitor_FormatProcessSamples(samples, maxChars := 360) {
    if !IsObject(samples)
        return "samples=none"
    text := ""
    for index, sample in samples {
        pid := 0
        hwnd := 0
        try pid := sample.HasOwnProp("pid") ? Integer(sample.pid) : 0
        try hwnd := sample.HasOwnProp("hwnd") ? Integer(sample.hwnd) : 0
        text .= (text != "" ? "," : "") "s" index "(pid=" pid ",hwnd=" hwnd ")"
    }
    limit := 360
    try limit := Max(40, Integer(maxChars))
    return SubStr(text != "" ? text : "samples=none", 1, limit)
}

RewardMonitor_CompactExcerpt(text, maxLines := 4, maxChars := 520) {
    lineLimit := 4
    charLimit := 520
    try lineLimit := Max(1, Integer(maxLines))
    try charLimit := Max(80, Integer(maxChars))

    source := StrReplace(String(text), "`r", "")
    nonEmpty := []
    for line in StrSplit(source, "`n") {
        cleaned := Trim(line, " `t`r`n")
        if (cleaned != "")
            nonEmpty.Push(cleaned)
    }
    if (nonEmpty.Length = 0)
        return ""

    firstIndex := Max(1, nonEmpty.Length - lineLimit + 1)
    result := ""
    Loop nonEmpty.Length - firstIndex + 1 {
        line := nonEmpty[firstIndex + A_Index - 1]
        result .= (result != "" ? " || " : "") line
    }
    if (StrLen(result) > charLimit)
        result := "..." SubStr(result, -(charLimit - 3))
    return result
}
