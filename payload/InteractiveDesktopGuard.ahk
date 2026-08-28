#Requires AutoHotkey v2.0+

; Windows 11 的鎖定畫面有時仍回報 Default input desktop 與 Active WTS session，
; 不能只靠 OpenInputDesktop/WTS 判斷是否可安全送出滑鼠鍵盤。
InteractiveDesktopIsLockScreenIdentity(processName, className := "", title := "") {
    normalizedProcess := StrLower(Trim(processName, " `t`r`n"))
    if (normalizedProcess = "lockapp.exe" || normalizedProcess = "logonui.exe")
        return true

    normalizedClass := StrLower(Trim(className, " `t`r`n"))
    normalizedTitle := StrLower(Trim(title, " `t`r`n"))
    if (normalizedClass != "windows.ui.core.corewindow")
        return false

    return !!(InStr(normalizedTitle, "鎖定畫面")
        || InStr(normalizedTitle, "锁定画面")
        || InStr(normalizedTitle, "lock screen"))
}

GetForegroundLockScreenState() {
    foregroundHwnd := 0
    processName := ""
    className := ""
    title := ""
    inspectError := ""

    try foregroundHwnd := DllCall("user32\GetForegroundWindow", "ptr")
    catch as e
        inspectError := "foreground_query_failed:" e.Message

    if foregroundHwnd {
        try processName := WinGetProcessName("ahk_id " foregroundHwnd)
        catch as e
            inspectError .= (inspectError != "" ? ";" : "") "process_query_failed:" e.Message
        try className := WinGetClass("ahk_id " foregroundHwnd)
        catch as e
            inspectError .= (inspectError != "" ? ";" : "") "class_query_failed:" e.Message
        try title := WinGetTitle("ahk_id " foregroundHwnd)
        catch as e
            inspectError .= (inspectError != "" ? ";" : "") "title_query_failed:" e.Message
    }

    return {
        locked: InteractiveDesktopIsLockScreenIdentity(processName, className, title),
        hwnd: foregroundHwnd,
        processName: processName,
        className: className,
        title: title,
        inspectError: inspectError
    }
}
