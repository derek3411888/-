#Requires AutoHotkey v2.0+
#SingleInstance Force
#Warn VarUnset, Off
#Include TestRuntimePaths.ahk
#Include ..\payload\RemoteControlSelfHost.ahk

testRoot := TestRuntime_NewCaseDir("self-host-device", "fresh_device")
cfgPath := testRoot "\config.ini"
try {
    RCSH_EnsureDefaults(cfgPath)
    actual := IniRead(cfgPath, "self_hosted", "server_url", "")
    if (actual != "https://220.135.218.98")
        throw Error("Fresh device did not receive the fixed HTTPS server URL: " actual)
    if (RCSH_NormalizeServerUrl(actual) != actual)
        throw Error("Fresh device server URL was rejected by the HTTPS validator")
} finally {
    try TestRuntime_DeleteCaseDir(testRoot)
}
ExitApp(0)

RC_IniReadSafe(file, section, key, default := "") {
    try return IniRead(file, section, key, default)
    catch
        return default
}
