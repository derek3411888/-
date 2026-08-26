#Requires AutoHotkey v2.0+

; 純策略函式：不讀寫檔案、不操作程序，方便獨立回歸測試。
; 主流程只針對可確認身分的程序做修復，策略本身負責同錯誤計數、退避與熔斷。

SelfHealNormalizeToken(value, fallback := "UNKNOWN") {
    token := StrUpper(Trim(value, " `t`r`n"))
    token := RegExReplace(token, "[^A-Z0-9_\-/]+", "_")
    token := Trim(token, "_")
    return token != "" ? token : fallback
}

SelfHealFailureFingerprint(reasonCode, stage := "") {
    code := SelfHealNormalizeToken(reasonCode, "UNSPECIFIED")
    normalizedStage := SelfHealNormalizeToken(stage, "UNSPECIFIED_STAGE")
    return code "|" normalizedStage
}

SelfHealFailureCategory(reasonCode) {
    code := SelfHealNormalizeToken(reasonCode, "UNSPECIFIED")
    if (InStr(code, "OKWW_") = 1)
        return "okww"
    if (InStr(code, "SERVER_SWITCH_") = 1)
        return "server_switch"
    if (InStr(code, "SYNTHESIS_") = 1)
        return "synthesis"
    if (InStr(code, "LRMCAI_") = 1)
        return "lrmc"
    if (InStr(code, "GAME_") = 1 || InStr(code, "UE4_") = 1)
        return "game"
    return "runtime"
}

SelfHealCooldownSeconds(consecutiveCount) {
    count := Max(1, consecutiveCount + 0)
    if (count <= 1)
        return 0
    if (count = 2)
        return 15
    if (count = 3)
        return 60
    if (count = 4)
        return 300
    if (count = 5)
        return 600
    return 1800
}

SelfHealActionLabel(category, circuitOpen := false) {
    prefix := circuitOpen ? "熔斷後" : "重啟前"
    switch category {
        case "okww":
            return prefix "精確清除 OKWW 管理器、啟動器與已識別的 OKWW Python"
        case "server_switch":
            return prefix "重建鳴潮登入視窗；維持禁止進錯服"
        case "synthesis":
            return prefix "清除聲骸合成子程序與過期重啟旗標"
        case "lrmc":
            return prefix "精確停止 LRMCAI，保留可接續狀態後重建"
        case "game":
            return prefix "精確停止鳴潮主程序與依附的 OKWW，再乾淨重建"
        default:
            return prefix "清理本專案管理的輔助程序後乾淨重建"
    }
}

; 同一 fingerprint 在 45 分鐘內才算連續；時間拉開後視為新的單次故障。
SelfHealBuildPolicy(reasonCode, stage, previousFingerprint := "", previousCount := 0,
    elapsedSincePreviousMs := -1) {
    fingerprint := SelfHealFailureFingerprint(reasonCode, stage)
    sameWindow := (fingerprint = previousFingerprint
        && elapsedSincePreviousMs >= 0 && elapsedSincePreviousMs <= 2700000)
    consecutive := sameWindow ? Min(100, Max(0, previousCount + 0) + 1) : 1
    category := SelfHealFailureCategory(reasonCode)
    circuitOpen := consecutive >= 4
    cooldownSec := SelfHealCooldownSeconds(consecutive)
    return {
        fingerprint: fingerprint,
        consecutive: consecutive,
        category: category,
        circuitOpen: circuitOpen,
        cooldownSec: cooldownSec,
        action: SelfHealActionLabel(category, circuitOpen)
    }
}
