#Requires AutoHotkey v2.0+
#Include ..\payload\ForegroundBlockerPolicy.ahk

AssertEqual(actual, expected, description) {
    if (actual != expected)
        throw Error(description " | expected=" expected " actual=" actual)
}

try {
    DetectHiddenWindows(false)
    hiddenProbe := Gui(, "foreground-hidden-window-probe")
    hiddenHwnd := hiddenProbe.Hwnd
    hiddenIdentity := ForegroundBlockerReadWindowIdentity(hiddenHwnd)
    AssertEqual(ForegroundBlockerIsWindowHandleAlive(hiddenHwnd), true,
        "Win32 必須辨識仍存在的隱藏 HWND")
    AssertEqual(hiddenIdentity.exists, true,
        "隱藏 HWND 的身分讀取不得受 DetectHiddenWindows 影響")
    AssertEqual(hiddenIdentity.pid > 0, true, "隱藏 HWND 必須能讀取 PID")
    AssertEqual(hiddenIdentity.className != "", true, "隱藏 HWND 必須能讀取 class")
    AssertEqual(hiddenIdentity.title, "foreground-hidden-window-probe",
        "隱藏 HWND 必須能讀取標題")
    hiddenProbe.Destroy()
    AssertEqual(ForegroundBlockerIsWindowHandleAlive(hiddenHwnd), false,
        "已銷毀 HWND 不得視為仍存在")

    AssertEqual(ForegroundBlockerCanUseOkwwHeaderFallback("pythonw.exe",
        "Qt6111QWindowIcon", "OK-WW v3.6.6 Global  - OK-WW", 1216, 816), true,
        "MyTUF 實機 OKWW 主窗必須允許安全頂部中央後備")
    AssertEqual(ForegroundBlockerCanUseOkwwHeaderFallback("python.exe",
        "Qt6111QWindowIcon", "OK-WW v3.6.6 Global  - OK-WW", 1216, 816), false,
        "其他 Python host 不得使用 OKWW 實體點擊後備")
    AssertEqual(ForegroundBlockerCanUseOkwwHeaderFallback("pythonw.exe",
        "Qt6111QWindowIcon", "OK-WW v3.6.6 Global  - OK-WW", 600, 400), false,
        "小型啟動畫面或對話框不得使用 OKWW 實體點擊後備")
    AssertEqual(ForegroundBlockerCanUseOkwwHeaderFallback("pythonw.exe",
        "Qt6111QWindowIcon", "unrelated Global tool", 1216, 816), false,
        "其他 Qt 視窗不得使用 OKWW 實體點擊後備")

    AssertEqual(ForegroundBlockerClassifyIdentity("ShellExperienceHost.exe",
        "Windows.UI.Core.CoreWindow", "新通知"), "windows_notification",
        "MyTUF 實機通知識別必須命中")
    AssertEqual(ForegroundBlockerClassifyIdentity("SHELLEXPERIENCEHOST.EXE",
        "WINDOWS.UI.CORE.COREWINDOW", "New notification"), "windows_notification",
        "英文 Windows 通知識別必須命中")
    AssertEqual(ForegroundBlockerClassifyIdentity("ShellExperienceHost.exe",
        "Windows.UI.Core.CoreWindow", "開始"), "",
        "其他 ShellExperienceHost 介面不能誤判")
    AssertEqual(ForegroundBlockerClassifyIdentity("pythonw.exe",
        "Windows.UI.Core.CoreWindow", "新通知"), "",
        "只有標題相同不能誤判")
    AssertEqual(ForegroundBlockerClassifyIdentity("ShellExperienceHost.exe",
        "Qt6111QWindowIcon", "新通知"), "",
        "只有程序與標題相同不能誤判")
    AssertEqual(ForegroundBlockerShouldWaitWithoutRecreate("windows_notification", false),
        true, "通知佔用前景時必須等待且不重建程式")
    AssertEqual(ForegroundBlockerShouldWaitWithoutRecreate("windows_notification", true),
        false, "目標本身結構損壞時仍允許重建")
    AssertEqual(ForegroundBlockerShouldWaitWithoutRecreate("", false), false,
        "一般前景拒絕維持原有修復政策")
    FileAppend("foreground-blocker-policy=ok`n", "*")
} catch as e {
    FileAppend("foreground-blocker-policy=failed: " e.Message "`n", "**")
    ExitApp(1)
}
ExitApp(0)
