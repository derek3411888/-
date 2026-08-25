#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off
#Include ..\payload\RemoteControlSelfHost.ahk

if (A_Args.Length < 2)
    throw Error("Usage: SelfHostLiveAutomaticFallbackTest.ahk <config.ini> <ffmpeg.exe>")

global TEST_FFMPEG_EXE := A_Args[2]
cfgPath := A_Args[1]
if !FileExist(cfgPath)
    throw Error("Config not found")
if !FileExist(TEST_FFMPEG_EXE)
    throw Error("FFmpeg not found")

serverUrl := RTrim(IniRead(cfgPath, "self_hosted", "server_url", ""), "/")
protectedToken := Trim(IniRead(cfgPath, "self_hosted", "device_token_dpapi", ""), " `t`r`n")
if (serverUrl = "" || protectedToken = "")
    throw Error("Self-hosted configuration is incomplete")

deviceToken := RCSH_DpapiUnprotect(protectedToken)
http := ComObject("WinHttp.WinHttpRequest.5.1")
http.SetTimeouts(5000, 5000, 5000, 5000)
http.Open("GET", serverUrl "/api/v1/device/control", false)
http.SetRequestHeader("Accept", "application/json")
http.SetRequestHeader("Authorization", "Bearer " deviceToken)
http.Send()
deviceToken := ""
if (http.Status != 200)
    throw Error("Device control request failed: HTTP " http.Status)
if !RegExMatch(http.ResponseText, '"publishUrl"\s*:\s*"([^"]+)"', &urlMatch)
    throw Error("Live publish URL is missing")

publishUrl := urlMatch[1]
global RCSH_LIVE_EXPIRES_AT := RC_UnixMs() + 60000
if !RCSH_StartLivePreview(publishUrl)
    throw Error("Unable to start public preview route")
publishUrl := ""

deadline := A_TickCount + 35000
while (A_TickCount < deadline) {
    if (RCSH_LIVE_ROUTE = "loopback" && RCSH_LIVE_PID > 0
        && ProcessExist(RCSH_LIVE_PID))
        break
    Sleep(250)
}
if (RCSH_LIVE_ROUTE != "loopback" || RCSH_LIVE_PID <= 0
    || !ProcessExist(RCSH_LIVE_PID)) {
    RCSH_StopLivePreview("automatic fallback test failed")
    throw Error("Automatic localhost fallback did not become active")
}

Sleep(8000)
if !ProcessExist(RCSH_LIVE_PID) {
    RCSH_StopLivePreview("automatic fallback stability failed")
    throw Error("Localhost fallback was not stable for 8 seconds")
}
RCSH_StopLivePreview("automatic fallback test complete")
ExitApp(0)

ResolveScreenRecordingFfmpegExePath(_) {
    global TEST_FFMPEG_EXE
    return TEST_FFMPEG_EXE
}

RC_UnixMs() {
    return DateDiff(A_NowUTC, "19700101000000", "Seconds") * 1000 + A_MSec
}

RC_Log(message, level := "INFO") {
    ; The regression can be launched as a GUI process without stdout.
    ; Production logging is covered by the real payload implementation.
    return
}
