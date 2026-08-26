#Requires AutoHotkey v2.0+
#Include ..\payload\OkwwOcrTextMatchers.ahk

AssertEqual(actual, expected, description) {
    if (actual != expected)
        throw Error(description " | expected=" expected " actual=" actual)
}

try {
    AssertEqual(OKWW_ClassifyAutoBattleLabelText("自動戰鬥"), "exact", "精確標題")
    AssertEqual(
        OKWW_ClassifyAutoBattleLabelText("自動戰鬥在大世界,深渊,无音区等开啟自動戰鬥"),
        "merged_prefix", "標題與說明合併")
    AssertEqual(
        OKWW_ClassifyAutoBattleLabelText("Y4,自動戰鬥在大世界,深渊,无音区等开啟自動戰鬥"),
        "leading_noise", "2026-08-26 實機 OCR 列首雜訊")
    AssertEqual(
        OKWW_ClassifyAutoBattleLabelText("123456自動戰鬥"),
        "leading_noise", "六字元內的有界列首雜訊")
    AssertEqual(
        OKWW_ClassifyAutoBattleLabelText("1234567自動戰鬥"),
        "", "超過有界範圍不得命中")
    AssertEqual(
        OKWW_ClassifyAutoBattleLabelText("這是一段很長的說明自動戰鬥"),
        "", "說明文字中的關鍵字不得命中")
    AssertEqual(
        OKWW_ClassifyWindowOcrBlocks([{text: "应用更新"}, {text: "点击检查更新"}]),
        "update", "pythonw 更新頁不可當成主程式")
    AssertEqual(
        OKWW_ClassifyWindowOcrBlocks([{text: "点击检查更"}, {text: "检查更新"}, {text: "免责声明"}]),
        "update", "只有更新文字時尚未證明完整主程式外殼")
    AssertEqual(
        OKWW_ClassifyWindowOcrBlocks([
            {text: "应用更新"}, {text: "更新成功 v3.6.4 -> v3.6.5"},
            {text: "GitHub"}, {text: "Discord"}, {text: "常见问题"}
        ]),
        "shell", "2026-08-26 MyTUF 影片的完整 OKWW 更新首頁可安全接手")
    AssertEqual(OKWW_IsOperationalContentKind("shell"), true, "完整主程式外殼可進入導覽")
    AssertEqual(OKWW_IsOperationalContentKind("update"), false, "未完整載入的更新畫面不可接手")
    AssertEqual(
        OKWW_ClassifyWindowOcrBlocks([{text: "即時觸發"}, {text: "自動戰鬥"}]),
        "main", "繁體即時觸發主程式")
    AssertEqual(
        OKWW_ClassifyWindowOcrBlocks([{text: "實時觸發"}, {text: "自動戰鬥"}]),
        "main", "簡體用詞實時觸發主程式")
    AssertEqual(
        OKWW_ClassifyWindowOcrBlocks([{text: "OK-WW v3.6.5 Global"}]),
        "unknown", "只有標題不得當成主程式")
    FileAppend("okww-auto-battle-ocr-regression=ok`n", "*")
} catch as e {
    FileAppend("okww-auto-battle-ocr-regression=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)
