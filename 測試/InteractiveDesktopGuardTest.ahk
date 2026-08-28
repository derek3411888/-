#Requires AutoHotkey v2.0+
#Include ..\payload\InteractiveDesktopGuard.ahk

AssertEqual(actual, expected, description) {
    if (actual != expected)
        throw Error(description " | expected=" expected " actual=" actual)
}

try {
    AssertEqual(InteractiveDesktopIsLockScreenIdentity("LockApp.exe"), true,
        "LockApp 必須視為鎖定畫面")
    AssertEqual(InteractiveDesktopIsLockScreenIdentity("LOGONUI.EXE"), true,
        "LogonUI 必須視為鎖定畫面")
    AssertEqual(InteractiveDesktopIsLockScreenIdentity("ShellExperienceHost.exe",
        "Windows.UI.Core.CoreWindow", "新通知"), false,
        "一般通知視窗不能誤判為鎖定畫面")
    AssertEqual(InteractiveDesktopIsLockScreenIdentity("",
        "Windows.UI.Core.CoreWindow", "Windows 預設鎖定畫面"), true,
        "無法讀取程序名稱時仍應以鎖定畫面標題辨識")
    AssertEqual(InteractiveDesktopIsLockScreenIdentity("pythonw.exe",
        "Qt6111QWindowIcon", "OK-WW v3.6.6 Global - OK-WW"), false,
        "OKWW 不能誤判為鎖定畫面")
    FileAppend("interactive-desktop-guard=ok`n", "*")
} catch as e {
    FileAppend("interactive-desktop-guard=failed: " e.Message "`n", "**")
    ExitApp(1)
}
ExitApp(0)
