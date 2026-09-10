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

RewardMonitor_IsTaskAbandonLine(line) {
    text := String(line)
    return text ~= "i)(?:传送重试次数过多|傳送重試次數過多)[，, ]*(?:放弃该任务|放棄該任務)"
}

RewardMonitor_ExtractLogTimestamp(line, fallbackTimestamp := "") {
    text := String(line)
    if RegExMatch(text,
        "^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})",
        &match) {
        return match[1] match[2] match[3] match[4] match[5] match[6]
    }
    fallback := Trim(String(fallbackTimestamp), " `t`r`n")
    return fallback ~= "^\d{14}$" ? fallback : A_Now
}

RewardMonitor_RecordTaskAbandon(state, line, windowSeconds := 120, fallbackTimestamp := "") {
    if !IsObject(state)
        throw TypeError("收尾監測任務放棄狀態必須是物件")

    window := 120
    try window := Max(1, Integer(windowSeconds))
    timestamp := RewardMonitor_ExtractLogTimestamp(line, fallbackTimestamp)
    firstTimestamp := ""
    previousHits := 0
    try firstTimestamp := state.HasOwnProp("taskAbandonFirstAt") ? state.taskAbandonFirstAt : ""
    try previousHits := state.HasOwnProp("taskAbandonHits") ? Integer(state.taskAbandonHits) : 0

    withinWindow := false
    if (firstTimestamp ~= "^\d{14}$") {
        elapsed := -1
        try elapsed := DateDiff(timestamp, firstTimestamp, "Seconds")
        withinWindow := elapsed >= 0 && elapsed <= window
    }

    if withinWindow {
        state.taskAbandonHits := previousHits + 1
    } else {
        state.taskAbandonHits := 1
        state.taskAbandonFirstAt := timestamp
    }
    state.taskAbandonLastAt := timestamp
    state.lastTaskAbandonLine := String(line)
    return state.taskAbandonHits
}

RewardMonitor_HasTaskAbandonBurst(state, requiredHits := 5) {
    if !IsObject(state)
        return false
    hits := 0
    needed := 5
    try hits := state.HasOwnProp("taskAbandonHits") ? Integer(state.taskAbandonHits) : 0
    try needed := Max(1, Integer(requiredHits))
    return hits >= needed
}

RewardMonitor_IsTaskAbandonWindowActive(state, windowSeconds := 120,
    currentTimestamp := "") {
    if !IsObject(state)
        return false
    hits := 0
    lastAt := ""
    window := 120
    try hits := state.HasOwnProp("taskAbandonHits") ? Integer(state.taskAbandonHits) : 0
    try lastAt := state.HasOwnProp("taskAbandonLastAt") ? state.taskAbandonLastAt : ""
    try window := Max(1, Integer(windowSeconds))
    if (hits <= 0 || !(lastAt ~= "^\d{14}$"))
        return false

    nowTimestamp := RewardMonitor_ExtractLogTimestamp("", currentTimestamp)
    elapsed := -1
    try elapsed := DateDiff(nowTimestamp, lastAt, "Seconds")
    return elapsed >= 0 && elapsed <= window
}

RewardMonitor_ShouldHoldCompletion(state, requiredHits := 5, windowSeconds := 120,
    currentTimestamp := "") {
    ; A confirmed burst must permanently defeat reward completion until the
    ; caller restarts and clears the state. A smaller number of task abandons
    ; delays completion until the observation window has stayed quiet.
    return RewardMonitor_HasTaskAbandonBurst(state, requiredHits)
        || RewardMonitor_IsTaskAbandonWindowActive(state, windowSeconds, currentTimestamp)
}

RewardMonitor_FormatTaskAbandonBurst(state, requiredHits := 5, windowSeconds := 120,
    maxLineChars := 420) {
    if !IsObject(state)
        return "task_abandon_state=none"
    hits := 0
    firstAt := ""
    lastAt := ""
    lastLine := ""
    try hits := state.HasOwnProp("taskAbandonHits") ? Integer(state.taskAbandonHits) : 0
    try firstAt := state.HasOwnProp("taskAbandonFirstAt") ? state.taskAbandonFirstAt : ""
    try lastAt := state.HasOwnProp("taskAbandonLastAt") ? state.taskAbandonLastAt : ""
    try lastLine := state.HasOwnProp("lastTaskAbandonLine") ? state.lastTaskAbandonLine : ""
    needed := 5
    window := 120
    lineLimit := 420
    try needed := Max(1, Integer(requiredHits))
    try window := Max(1, Integer(windowSeconds))
    try lineLimit := Max(80, Integer(maxLineChars))
    return (
        "hits=" hits "/" needed
        . " window=" window "s first=" (firstAt != "" ? firstAt : "-")
        . " last=" (lastAt != "" ? lastAt : "-")
        . " line=" SubStr(lastLine != "" ? lastLine : "-", 1, lineLimit)
    )
}
