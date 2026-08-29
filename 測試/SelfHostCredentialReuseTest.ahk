#Requires AutoHotkey v2.0+
#SingleInstance Force
#Warn VarUnset, Off
#Include ..\payload\RemoteControlSelfHost.ahk

testRoot := A_Temp "\WutheringSelfHostCredential_" A_TickCount
DirCreate(testRoot)
cfgPath := testRoot "\config.ini"
expectedToken := RCSH_RandomToken(48)

try {
    IniWrite(RCSH_DpapiProtect(expectedToken), cfgPath,
        "self_hosted", "device_token_dpapi")

    if !RCSH_LoadStoredCredential(cfgPath)
        throw Error("Stored DPAPI credential was not accepted")
    if (RCSH_DEVICE_TOKEN != expectedToken)
        throw Error("Stored DPAPI credential changed while loading")
    if !RCSH_ENROLLED
        throw Error("Stored DPAPI credential did not suppress duplicate enrollment")

    ; 這裡刻意不提供 RC_UID 等 enroll 所需欄位；若沒有走既有憑證的
    ; early return，測試會在建立 HTTP body 前直接失敗。
    RCSH_SERVER_URL := "https://127.0.0.1"
    RCSH_MODE := "shadow"
    if !RCSH_EnsureEnrolled()
        throw Error("Existing credential unexpectedly attempted enrollment")

    blankCfgPath := testRoot "\blank.ini"
    if RCSH_LoadStoredCredential(blankCfgPath)
        throw Error("Blank config unexpectedly retained an enrolled credential")
    if (RCSH_DEVICE_TOKEN != "" || RCSH_ENROLLED)
        throw Error("Blank config did not clear the previous credential state")
} finally {
    try DirDelete(testRoot, true)
}

FileAppend("self-host-credential-reuse=ok`n", "*")
ExitApp(0)

RC_IniReadSafe(file, section, key, default := "") {
    try return IniRead(file, section, key, default)
    catch
        return default
}

RC_Log(msg, level := "INFO") {
}
