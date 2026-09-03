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

    FileAppend("reward-monitor-incident-policy=ok`n", "*")
} catch as e {
    FileAppend("reward-monitor-incident-policy=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)
