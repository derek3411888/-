#Requires AutoHotkey v2.0+
#Include ..\payload\ForegroundBlockerPolicy.ahk

AssertEqual(actual, expected, description) {
    if (actual != expected)
        throw Error(description " | expected=" expected " actual=" actual)
}

try {
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
