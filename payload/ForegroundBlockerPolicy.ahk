#Requires AutoHotkey v2.0+

; AHK 的 WinExist("ahk_id ...") 會受 DetectHiddenWindows 影響。Windows 通知在
; SWP_HIDEWINDOW 後仍可能短暫保有 foreground；此時必須直接向 Win32 查詢，
; 否則會把仍存在的 ShellExperienceHost 視窗誤判成已銷毀。
ForegroundBlockerIsWindowHandleAlive(hwnd) {
    return !!(hwnd && DllCall("user32\IsWindow", "ptr", hwnd, "int"))
}

ForegroundBlockerReadWindowIdentity(hwnd) {
    state := {
        exists: false,
        hwnd: hwnd,
        pid: 0,
        processName: "",
        className: "",
        title: "",
        inspectError: ""
    }
    if !ForegroundBlockerIsWindowHandleAlive(hwnd)
        return state

    state.exists := true
    try {
        pid := 0
        DllCall("user32\GetWindowThreadProcessId", "ptr", hwnd, "uint*", &pid, "uint")
        state.pid := pid
    } catch as e {
        state.inspectError := "pid_query_failed:" e.Message
    }

    if (state.pid > 0) {
        try state.processName := ProcessGetName(state.pid)
        catch as e
            state.inspectError .= (state.inspectError != "" ? ";" : "")
                . "process_query_failed:" e.Message
    }

    try {
        classBuffer := Buffer(1024, 0)
        classChars := DllCall("user32\GetClassNameW", "ptr", hwnd,
            "ptr", classBuffer.Ptr, "int", classBuffer.Size // 2, "int")
        if (classChars > 0)
            state.className := StrGet(classBuffer.Ptr, classChars, "UTF-16")
    } catch as e {
        state.inspectError .= (state.inspectError != "" ? ";" : "")
            . "class_query_failed:" e.Message
    }

    try {
        titleChars := DllCall("user32\GetWindowTextLengthW", "ptr", hwnd, "int")
        titleBuffer := Buffer((Max(0, titleChars) + 1) * 2, 0)
        copiedChars := DllCall("user32\GetWindowTextW", "ptr", hwnd,
            "ptr", titleBuffer.Ptr, "int", titleBuffer.Size // 2, "int")
        if (copiedChars > 0)
            state.title := StrGet(titleBuffer.Ptr, copiedChars, "UTF-16")
    } catch as e {
        state.inspectError .= (state.inspectError != "" ? ";" : "")
            . "title_query_failed:" e.Message
    }
    return state
}

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
