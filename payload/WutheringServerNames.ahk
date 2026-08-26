; 鳴潮 Global 目前只有五個正式區服。設定、OCR 與網頁端都以這份名稱為準，
; 避免自由文字、簡稱或 OCR 雜訊讓排程誤判。

GetSupportedWutheringServers() {
    return ["America", "Europe", "Asia", "HMT(HK,MO,TW)", "SEA"]
}

SplitServerScheduleTokens(raw) {
    out := []
    if !IsSet(raw)
        return out

    txt := StrReplace(String(raw), "`r", "`n")
    token := ""
    depth := 0
    Loop Parse, txt {
        ch := A_LoopField
        if (ch = "(" || ch = "（") {
            depth += 1
            token .= ch
            continue
        }
        if (ch = ")" || ch = "）") {
            if (depth > 0)
                depth -= 1
            token .= ch
            continue
        }

        if ((ch = "," || ch = ";" || ch = "；" || ch = "|" || ch = "`n")
            && depth = 0) {
            value := Trim(token, " `t`r`n")
            if (value != "")
                out.Push(value)
            token := ""
            continue
        }
        token .= ch
    }

    value := Trim(token, " `t`r`n")
    if (value != "")
        out.Push(value)
    return out
}

NormalizeWutheringServerAlias(text) {
    value := StrLower(Trim(String(text), " `t`r`n"))
    value := StrReplace(value, "（", "(")
    value := StrReplace(value, "）", ")")
    value := StrReplace(value, "，", ",")
    value := RegExReplace(value, "[\s　_\-－—]", "")
    return value
}

CanonicalizeWutheringServerName(text) {
    value := NormalizeWutheringServerAlias(text)
    if (value = "")
        return ""

    if (value = "america" || value = "美洲" || value = "美服" || value = "美洲服")
        return "America"
    if (value = "europe" || value = "歐洲" || value = "欧洲"
        || value = "歐服" || value = "欧服" || value = "歐洲服" || value = "欧洲服")
        return "Europe"
    if (value = "asia" || value = "亞洲" || value = "亚洲"
        || value = "亞服" || value = "亚服" || value = "亞洲服" || value = "亚洲服")
        return "Asia"
    if (value = "sea" || value = "東南亞" || value = "东南亚"
        || value = "東南亞服" || value = "东南亚服")
        return "SEA"
    if (value = "hmt" || value = "港澳台" || value = "港澳台服"
        || RegExMatch(value, "^hmt\((?:hk,?mo,?tw|hk/mo/tw)\)$"))
        return "HMT(HK,MO,TW)"
    return ""
}

AnalyzeServerScheduleList(raw) {
    servers := []
    invalid := []
    duplicates := []
    seen := Map()

    for token in SplitServerScheduleTokens(raw) {
        canonical := CanonicalizeWutheringServerName(token)
        if (canonical = "") {
            invalid.Push(token)
            continue
        }
        key := StrLower(canonical)
        if seen.Has(key) {
            duplicates.Push(canonical)
            continue
        }
        seen[key] := true
        servers.Push(canonical)
    }
    return {servers: servers, invalid: invalid, duplicates: duplicates}
}

ParseServerScheduleList(raw) {
    return AnalyzeServerScheduleList(raw).servers
}

DetectWutheringServerFromOcrText(text) {
    raw := Trim(String(text), " `t`r`n")
    if (raw = "")
        return ""

    ; 設定別名先走精確正規化；OCR 則只接受完整英文單字或明確中文名稱。
    exact := CanonicalizeWutheringServerName(raw)
    if (exact != "")
        return exact

    lower := StrLower(raw)
    if RegExMatch(lower, "i)(?:^|[^a-z])america(?:$|[^a-z])") || InStr(raw, "美洲")
        return "America"
    if RegExMatch(lower, "i)(?:^|[^a-z])europe(?:$|[^a-z])")
        || InStr(raw, "歐洲") || InStr(raw, "欧洲")
        return "Europe"
    if RegExMatch(lower, "i)(?:^|[^a-z])asia(?:$|[^a-z])")
        || InStr(raw, "亞洲") || InStr(raw, "亚洲")
        return "Asia"
    if RegExMatch(lower, "i)(?:^|[^a-z])sea(?:$|[^a-z])")
        || InStr(raw, "東南亞") || InStr(raw, "东南亚")
        return "SEA"
    if RegExMatch(lower, "i)(?:^|[^a-z])hmt(?:$|[^a-z])") || InStr(raw, "港澳台")
        return "HMT(HK,MO,TW)"

    compact := RegExReplace(lower, "[\s,，/|;；()（）]", "")
    if (InStr(compact, "hk") && InStr(compact, "mo") && InStr(compact, "tw"))
        return "HMT(HK,MO,TW)"
    return ""
}

IsServerTargetMatch(ocrText, targetText) {
    observed := DetectWutheringServerFromOcrText(ocrText)
    target := CanonicalizeWutheringServerName(targetText)
    return observed != "" && target != "" && observed = target
}

IsLikelyServerNameText(ocrText) {
    return DetectWutheringServerFromOcrText(ocrText) != ""
}
