#Requires AutoHotkey v2.0+
#SingleInstance Force

#Include ..\payload\RewardMonitorIncidentPolicy.ahk

AssertRewardIncident(condition, message) {
    if !condition
        throw Error(message)
}

try {
    confirmed := [
        {pid: 0, hwnd: 0},
        {pid: 0, hwnd: 0},
        {pid: 0, hwnd: 0}
    ]
    AssertRewardIncident(RewardMonitor_IsConfirmedProcessExit(confirmed, 3),
        "連續三次程序與視窗皆不存在時應確認退出")

    processReturned := [
        {pid: 0, hwnd: 0},
        {pid: 8292, hwnd: 0},
        {pid: 0, hwnd: 0}
    ]
    AssertRewardIncident(!RewardMonitor_IsConfirmedProcessExit(processReturned, 3),
        "中途程序恢復時不得誤判退出")

    staleWindow := [
        {pid: 0, hwnd: 0},
        {pid: 0, hwnd: 12345},
        {pid: 0, hwnd: 0}
    ]
    AssertRewardIncident(!RewardMonitor_IsConfirmedProcessExit(staleWindow, 3),
        "仍有遊戲視窗時不得誤判退出")
    AssertRewardIncident(!RewardMonitor_IsConfirmedProcessExit(confirmed, 4),
        "樣本不足時不得確認退出")

    formatted := RewardMonitor_FormatProcessSamples(confirmed)
    AssertRewardIncident(InStr(formatted, "s1(pid=0,hwnd=0)") > 0,
        "程序樣本摘要缺少第一筆")

    excerpt := RewardMonitor_CompactExcerpt("old`n`nline2`r`nline3`nline4`nline5", 3, 200)
    AssertRewardIncident(excerpt = "line3 || line4 || line5",
        "LRMCAI 尾端摘要未保留最後三行")
    shortExcerpt := RewardMonitor_CompactExcerpt("1234567890", 1, 8)
    AssertRewardIncident(StrLen(shortExcerpt) <= 80,
        "摘要長度下限處理異常")

    abandonState := {
        taskAbandonHits: 0,
        taskAbandonFirstAt: "",
        taskAbandonLastAt: "",
        lastTaskAbandonLine: ""
    }
    normalLine := "2026-09-10 10:15:00,000 - LRMCAI - INFO - 執行任務"
    AssertRewardIncident(!RewardMonitor_IsTaskAbandonLine(normalLine),
        "task-abandon-normal-line-false-positive")
    abandonLines := [
        "2026-09-10 10:15:03,213 - LRMCAI - INFO - 传送重试次数过多，放弃该任务!",
        "2026-09-10 10:15:19,187 - LRMCAI - INFO - 傳送重試次數過多，放棄該任務!",
        "2026-09-10 10:15:35,144 - LRMCAI - INFO - 传送重试次数过多,放弃该任务!",
        "2026-09-10 10:15:51,073 - LRMCAI - INFO - 传送重试次数过多，放弃该任务!",
        "2026-09-10 10:16:07,111 - LRMCAI - INFO - 传送重试次数过多，放弃该任务!"
    ]
    for line in abandonLines {
        AssertRewardIncident(RewardMonitor_IsTaskAbandonLine(line),
            "task-abandon-zh-pattern-not-matched")
        RewardMonitor_RecordTaskAbandon(abandonState, line, 90)
    }
    AssertRewardIncident(RewardMonitor_HasTaskAbandonBurst(abandonState, 5),
        "task-abandon-five-hit-burst-not-detected")
    AssertRewardIncident(RewardMonitor_ShouldHoldCompletion(abandonState, 5, 90,
        "20260910101800"), "task-abandon-burst-must-defeat-reward-completion")
    burstSummary := RewardMonitor_FormatTaskAbandonBurst(abandonState, 5, 90)
    AssertRewardIncident(InStr(burstSummary, "hits=5/5") > 0,
        "task-abandon-summary-missing-count")

    RewardMonitor_RecordTaskAbandon(abandonState,
        "2026-09-10 10:20:00,000 - LRMCAI - INFO - 传送重试次数过多，放弃该任务!", 90)
    AssertRewardIncident(abandonState.taskAbandonHits = 1,
        "task-abandon-window-did-not-reset")
    AssertRewardIncident(RewardMonitor_IsTaskAbandonWindowActive(abandonState, 90,
        "20260910102130"), "task-abandon-quiet-window-ended-too-early")
    AssertRewardIncident(!RewardMonitor_IsTaskAbandonWindowActive(abandonState, 90,
        "20260910102131"), "task-abandon-quiet-window-did-not-expire")

    defaultWindowState := {
        taskAbandonHits: 0,
        taskAbandonFirstAt: "",
        taskAbandonLastAt: "",
        lastTaskAbandonLine: ""
    }
    RewardMonitor_RecordTaskAbandon(defaultWindowState,
        "2026-09-10 11:00:00,000 - LRMCAI - INFO - 传送重试次数过多，放弃该任务!")
    AssertRewardIncident(RewardMonitor_IsTaskAbandonWindowActive(defaultWindowState,
        , "20260910110130"), "task-abandon-default-90s-window-ended-too-early")
    AssertRewardIncident(!RewardMonitor_IsTaskAbandonWindowActive(defaultWindowState,
        , "20260910110131"), "task-abandon-default-90s-window-did-not-expire")
    AssertRewardIncident(InStr(RewardMonitor_FormatTaskAbandonBurst(defaultWindowState),
        "window=90s") > 0, "task-abandon-default-summary-is-not-90s")

    rollingState := {
        taskAbandonHits: 0,
        taskAbandonFirstAt: "",
        taskAbandonLastAt: "",
        lastTaskAbandonLine: ""
    }
    for timestamp in ["101500", "101559", "101758"] {
        RewardMonitor_RecordTaskAbandon(rollingState,
            "2026-09-10 " SubStr(timestamp, 1, 2) ":" SubStr(timestamp, 3, 2) ":"
                SubStr(timestamp, 5, 2) ",000 - LRMCAI - INFO - 传送重试次数过多，放弃该任务!", 90)
    }
    AssertRewardIncident(rollingState.taskAbandonHits = 1,
        "task-abandon-window-used-adjacent-gap")

    FileAppend("reward-monitor-incident-policy=ok`n", "*")
} catch as e {
    detail := e.Message
    try detail .= " | what=" e.What
    try detail .= " | file=" e.File
    try detail .= " | line=" e.Line
    try detail .= " | extra=" e.Extra
    FileAppend("reward-monitor-incident-policy=failed: " detail "`n", "**")
    ExitApp(1)
}

ExitApp(0)
