#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off
#Include ..\payload\RemoteControlSelfHost.ahk

publicUrl := "srt://example.test:8890?streamid=publish:test&passphrase=12345678901234567890123456789012"
localUrl := StrReplace(publicUrl, "example.test", "192.168.0.194")
candidates := RCSH_BuildLiveCandidates(localUrl, localUrl "|" publicUrl "|" localUrl)

if (candidates.Length != 3)
    throw Error("Expected local, public and loopback candidates")
if (candidates[1] != localUrl || candidates[2] != publicUrl)
    throw Error("LAN route must stay ahead of the public fallback")
if (RCSH_DescribeLiveRoute(candidates[1], 1, candidates.Length) != "preferred")
    throw Error("Preferred route label is incorrect")
if (RCSH_DescribeLiveRoute(candidates[3], 3, candidates.Length) != "loopback")
    throw Error("Loopback route label is incorrect")

economy := RCSH_LiveQualityConfig("economy")
balanced := RCSH_LiveQualityConfig("")
smooth := RCSH_LiveQualityConfig("smooth")
if (economy.fps != 12 || economy.bitrateKbps != 1500 || economy.gop != 24)
    throw Error("Economy live profile is incorrect")
if (balanced.name != "balanced" || balanced.fps != 30
    || balanced.bitrateKbps != 3500 || balanced.gop != 60)
    throw Error("Balanced live profile must be the 720p30 default")
if (smooth.fps != 60 || smooth.bitrateKbps != 6000 || smooth.gop != 120)
    throw Error("Smooth live profile is incorrect")

if (A_Args.Length >= 1) {
    encoder := RCSH_DetectLiveHardwareEncoder(A_Args[1])
    if !(encoder = "h264_nvenc" || encoder = "h264_qsv"
        || encoder = "h264_amf" || encoder = "libx264")
        throw Error("Unexpected live encoder result: " encoder)
    FileAppend("encoder=" encoder "`n", "*")
}

ExitApp(0)

RC_Log(message, level := "INFO") {
    return
}
