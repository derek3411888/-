#Requires AutoHotkey v2.0+

; 只辨識已由實機 Log 證實會長時間佔用 foreground 的 Windows 通知視窗。
; 三項識別必須同時命中，避免對其他 ShellExperienceHost 介面送出任何訊息。
ForegroundBlockerClassifyIdentity(processName, className := "", title := "") {
    normalizedProcess := StrLower(Trim(processName, " `t`r`n"))
    normalizedClass := StrLower(Trim(className, " `t`r`n"))
    normalizedTitle := StrLower(Trim(title, " `t`r`n"))

    if (normalizedProcess != "shellexperiencehost.exe")
        return ""
    if (normalizedClass != "windows.ui.core.corewindow")
        return ""

    ; Windows 的繁／簡中介面目前都回報「新通知」；英文介面為
    ; "New notification"。採完整相等，不用模糊包含比對。
    if (normalizedTitle = "新通知" || normalizedTitle = "new notification")
        return "windows_notification"
    return ""
}

ForegroundBlockerShouldWaitWithoutRecreate(blockerKind, recreateRecommended := false) {
    return (!recreateRecommended && blockerKind = "windows_notification")
}
