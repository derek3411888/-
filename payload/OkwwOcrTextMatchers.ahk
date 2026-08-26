; OKWW OCR 文字判斷保持為無副作用的獨立函式，讓實際流程與回歸測試共用同一份規則。

OKWW_ClassifyAutoBattleLabelText(cleanText) {
    expectedLabel := "自動戰鬥"
    if (cleanText = expectedLabel)
        return "exact"

    labelPos := InStr(cleanText, expectedLabel)
    if (labelPos = 1)
        return "merged_prefix"

    ; RapidOCR 可能把列首圖示辨識成「x,」或實機曾出現的「Y4,」。
    ; 最多接受 6 個列首雜訊字元；呼叫端仍會同時限制主內容第一列，
    ; 並要求右側同一列精確命中已啟用／未啟用，不能只靠 contains 通過。
    leadingNoiseLength := labelPos - 1
    if (leadingNoiseLength >= 1 && leadingNoiseLength <= 6)
        return "leading_noise"

    return ""
}

OKWW_NormalizeWindowText(text) {
    clean := StrLower(String(text))
    clean := StrReplace(clean, "`r", "")
    clean := StrReplace(clean, "`n", "")
    clean := StrReplace(clean, "`t", "")
    clean := StrReplace(clean, " ", "")
    clean := StrReplace(clean, "　", "")
    clean := StrReplace(clean, "实", "實")
    clean := StrReplace(clean, "时", "時")
    clean := StrReplace(clean, "触", "觸")
    clean := StrReplace(clean, "发", "發")
    clean := StrReplace(clean, "应", "應")
    clean := StrReplace(clean, "用", "用")
    clean := StrReplace(clean, "检", "檢")
    clean := StrReplace(clean, "查", "查")
    clean := StrReplace(clean, "启", "啟")
    clean := StrReplace(clean, "动", "動")
    clean := StrReplace(clean, "战", "戰")
    clean := StrReplace(clean, "斗", "鬥")
    return clean
}

OKWW_CountSameLengthDifferences(leftText, rightText, stopAfter := 1) {
    if (StrLen(leftText) != StrLen(rightText))
        return -1
    differences := 0
    Loop StrLen(leftText) {
        if (SubStr(leftText, A_Index, 1) != SubStr(rightText, A_Index, 1)) {
            differences += 1
            if (differences > stopAfter)
                return differences
        }
    }
    return differences
}

; pythonw 的完整主程式預設可能停在「應用更新」首頁，且左側導覽可能收合成
; 只有圖示。因此不能把所有含更新文字的畫面都當成尚未啟動；需再確認完整
; OK-WW 外殼的 GitHub／Discord／常見問題等標記。真正主內容則仍以
; 「實時／即時觸發」或「自動戰鬥」辨識。
OKWW_ClassifyWindowOcrBlocks(blocks) {
    if !IsObject(blocks)
        return "unknown"

    hasMainMarker := false
    hasAutoBattle := false
    hasUpdateMarker := false
    shellMarkers := Map()
    for block in blocks {
        if !IsObject(block) || !block.HasOwnProp("text")
            continue
        clean := OKWW_NormalizeWindowText(block.text)
        if (clean = "")
            continue

        if (InStr(clean, "應用更新") || InStr(clean, "檢查更新")
            || InStr(clean, "免責聲明") || InStr(clean, "免责声明")
            || InStr(clean, "更新成功"))
            hasUpdateMarker := true

        ; 這些是完整 pythonw 主程式頂列／首頁才會同時出現的元素。
        ; 至少命中兩類，避免單一 OCR 雜訊把尚未完成的啟動頁誤判為可操作。
        if InStr(clean, "github")
            shellMarkers["github"] := true
        if InStr(clean, "discord")
            shellMarkers["discord"] := true
        if (InStr(clean, "qq群") || InStr(clean, "qq頻道") || InStr(clean, "qq频道"))
            shellMarkers["qq"] := true
        if (InStr(clean, "常見問題") || InStr(clean, "常见问题"))
            shellMarkers["faq"] := true
        if (InStr(clean, "分享下載連結") || InStr(clean, "分享下载链接"))
            shellMarkers["share"] := true
        if (InStr(clean, "贊助") || InStr(clean, "赞助"))
            shellMarkers["sponsor"] := true
        if (InStr(clean, "相關項目") || InStr(clean, "相关项目"))
            shellMarkers["projects"] := true

        for expected in ["實時觸發", "即時觸發"] {
            if (clean = expected || OKWW_CountSameLengthDifferences(clean, expected, 1) = 1) {
                hasMainMarker := true
                break
            }
        }
        if (clean = "自動戰鬥" || InStr(clean, "自動戰鬥") = 1)
            hasAutoBattle := true
    }

    if (hasMainMarker || hasAutoBattle)
        return "main"
    if (shellMarkers.Count >= 2)
        return "shell"
    if hasUpdateMarker
        return "update"
    return "unknown"
}

OKWW_IsOperationalContentKind(kind) {
    return kind = "main" || kind = "shell"
}
