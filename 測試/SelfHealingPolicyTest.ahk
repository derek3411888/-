#Requires AutoHotkey v2.0+
#Include ..\payload\SelfHealingPolicy.ahk

AssertEqual(actual, expected, description) {
    if (actual != expected)
        throw Error(description " | expected=" expected " actual=" actual)
}

try {
    first := SelfHealBuildPolicy("OKWW_F11_SEND_FAILED", "OKWW快捷鍵", "", 0, -1)
    AssertEqual(first.consecutive, 1, "首次錯誤")
    AssertEqual(first.cooldownSec, 0, "首次不延遲")
    AssertEqual(first.category, "okww", "OKWW 分類")
    AssertEqual(first.circuitOpen, false, "首次不熔斷")

    second := SelfHealBuildPolicy("OKWW_F11_SEND_FAILED", "OKWW快捷鍵",
        first.fingerprint, first.consecutive, 5000)
    AssertEqual(second.consecutive, 2, "同錯誤連續計數")
    AssertEqual(second.cooldownSec, 15, "第二次退避")

    fourth := SelfHealBuildPolicy("OKWW_F11_SEND_FAILED", "OKWW快捷鍵",
        second.fingerprint, 3, 60000)
    AssertEqual(fourth.consecutive, 4, "第四次連續計數")
    AssertEqual(fourth.cooldownSec, 300, "第四次熔斷冷卻")
    AssertEqual(fourth.circuitOpen, true, "第四次開啟熔斷")

    changed := SelfHealBuildPolicy("GAME_READY_CHECK_TIMEOUT", "遊戲可操作驗證",
        fourth.fingerprint, fourth.consecutive, 1000)
    AssertEqual(changed.consecutive, 1, "不同錯誤重置連續計數")
    AssertEqual(changed.category, "game", "遊戲分類")

    expired := SelfHealBuildPolicy("GAME_READY_CHECK_TIMEOUT", "遊戲可操作驗證",
        changed.fingerprint, 3, 2700001)
    AssertEqual(expired.consecutive, 1, "超過 45 分鐘視為新故障")
    AssertEqual(SelfHealCooldownSeconds(9), 1800, "退避上限 30 分鐘")
    FileAppend("self-healing-policy=ok`n", "*")
} catch as e {
    FileAppend("self-healing-policy=failed: " e.Message "`n", "**")
    ExitApp(1)
}
ExitApp(0)
