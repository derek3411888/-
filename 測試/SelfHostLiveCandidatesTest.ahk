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

ExitApp(0)
