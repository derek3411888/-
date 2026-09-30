#Requires AutoHotkey v2.0+
#SingleInstance Force

AssertLauncherHttp(condition, message) {
    if !condition
        throw Error(message)
}

try {
    repoRoot := A_ScriptDir "\.."
    launcherPath := repoRoot "\打包啟動器.ahk"
    helperPath := repoRoot "\LauncherHttp.ahk"
    launcherSource := FileRead(launcherPath, "UTF-8")

    AssertLauncherHttp(InStr(launcherSource, "#Include LauncherHttp.ahk"),
        "Launcher 必須載入具明確逾時的 HTTP helper")
    AssertLauncherHttp(FileExist(helperPath),
        "Launcher HTTP helper 不存在")

    helperSource := FileRead(helperPath, "UTF-8")
    AssertLauncherHttp(InStr(helperSource, 'ComObject("Msxml2.ServerXMLHTTP.6.0")'),
        "HTTP helper 必須使用支援 setTimeouts 的 ServerXMLHTTP")
    AssertLauncherHttp(InStr(StrLower(helperSource), ".settimeouts("),
        "HTTP helper 必須為每次請求設定 resolve/connect/send/receive 逾時")
    AssertLauncherHttp(!InStr(helperSource, 'ComObject("Msxml2.XMLHTTP.6.0")'),
        "Launcher 不得再使用可能無限等待的 XMLHTTP")
    AssertLauncherHttp(InStr(helperSource, "LauncherHttp_CreateRequest"),
        "文字與二進位下載必須共用同一個有界請求建立器")

    FileAppend("launcher-http-timeout-policy=ok`n", "*")
} catch as e {
    FileAppend("launcher-http-timeout-policy=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)
