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
