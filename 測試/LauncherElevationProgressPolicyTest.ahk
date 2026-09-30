#Requires AutoHotkey v2.0+
#SingleInstance Force

AssertLauncherElevation(condition, message) {
    if !condition
        throw Error(message)
}

try {
    launcherSource := FileRead(A_ScriptDir "\..\打包啟動器.ahk", "UTF-8")
    AssertLauncherElevation(InStr(launcherSource, ";@Ahk2Exe-UpdateManifest 1"),
        "編譯後的 Launcher 必須在任何更新工作前由 Windows 要求管理員權限")
    AssertLauncherElevation(InStr(launcherSource, 'WriteStep("等待管理員授權"'),
        "直接執行 .ahk 時也必須清楚顯示正在等待 UAC")
    for stage in ["管理員權限", "準備更新", "檢查更新", "解壓 Payload", "啟動主流程"]
        AssertLauncherElevation(InStr(launcherSource, 'WriteStep("' stage '"'),
            "Launcher 缺少可見進度階段：" stage)
    firstWorkDir := InStr(launcherSource, 'WriteStep("工作目錄"')
    adminCheck := InStr(launcherSource, "if !A_IsAdmin")
    AssertLauncherElevation(!firstWorkDir || (adminCheck && firstWorkDir > adminCheck),
        "工作目錄不得在權限確認之前成為最後一個可見狀態")
    FileAppend("launcher-elevation-progress-policy=ok`n", "*")
} catch as e {
    FileAppend("launcher-elevation-progress-policy=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)
