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
    FileAppend("okww-auto-battle-ocr-regression=ok`n", "*")
} catch as e {
    FileAppend("okww-auto-battle-ocr-regression=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)
