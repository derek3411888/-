#Requires AutoHotkey v2.0
#Warn VarUnset, Off
#Include ..\payload\RemoteControlSelfHost.ahk

token := RCSH_RandomToken(48)
if !RegExMatch(token, "^[A-Za-z0-9_-]{64}$")
    throw Error("Unexpected random token: " token)

encoded := RCSH_UrlEncode("繁體 中文")
if (encoded != "%E7%B9%81%E9%AB%94%20%E4%B8%AD%E6%96%87")
    throw Error("Unexpected URL encoding: " encoded)

FileAppend("self-host-buffer-regression=ok`n", "*")
ExitApp(0)
