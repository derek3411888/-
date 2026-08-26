#Requires AutoHotkey v2.0+
#Include ..\payload\WutheringServerNames.ahk

AssertEqual(actual, expected, description) {
    if (actual != expected)
        throw Error(description " | expected=" expected " actual=" actual)
}

try {
    supported := GetSupportedWutheringServers()
    AssertEqual(supported.Length, 5, "Global 正式伺服器數量")
    AssertEqual(JoinForTest(supported), "America|Europe|Asia|HMT(HK,MO,TW)|SEA", "正式名稱與順序")

    AssertEqual(IsServerTargetMatch("a", "Asia"), false, "單字母 a 絕不可誤判為 Asia")
    AssertEqual(IsServerTargetMatch("HMT(HK, MO, TW)", "Asia"), false, "HMT 絕不可誤判為 Asia")
    AssertEqual(IsServerTargetMatch("HMT(HK, MO, TW)", "HMT(HK,MO,TW)"), true, "HMT 空白差異")
    AssertEqual(IsServerTargetMatch("Asia", "Asia"), true, "Asia 精確命中")
    AssertEqual(IsServerTargetMatch("America", "America"), true, "America 精確命中")
    AssertEqual(IsServerTargetMatch("Europe", "Europe"), true, "Europe 精確命中")
    AssertEqual(IsServerTargetMatch("SEA", "SEA"), true, "SEA 精確命中")

    analysis := AnalyzeServerScheduleList("港澳台 | 亞洲 | Asia | 未知服")
    AssertEqual(JoinForTest(analysis.servers), "HMT(HK,MO,TW)|Asia", "舊別名正規化")
    AssertEqual(JoinForTest(analysis.duplicates), "Asia", "重複偵測")
    AssertEqual(JoinForTest(analysis.invalid), "未知服", "無效名稱偵測")
    FileAppend("server-name-regression=ok`n", "*")
} catch as e {
    FileAppend("server-name-regression=failed: " e.Message "`n", "**")
    ExitApp(1)
}
ExitApp(0)

JoinForTest(items) {
    result := ""
    for item in items
        result .= (result = "" ? "" : "|") item
    return result
}
