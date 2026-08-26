#Requires AutoHotkey v2.0
#SingleInstance Force
#Warn VarUnset, Off
#Include ..\payload\RemoteControlSelfHost.ahk

if (A_Args.Length < 2)
    throw Error("Usage: SelfHostLiveLoopbackTest.ahk <config.ini> <ffmpeg.exe>")

cfgPath := A_Args[1]
ffmpegExe := A_Args[2]
if !FileExist(cfgPath)
    throw Error("Config not found")
if !FileExist(ffmpegExe)
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

if !RegExMatch(http.ResponseText, '"publishUrl"\s*:\s*"([^"]+)"', &match)
    throw Error("Live publish URL is missing")
publishUrl := match[1]
localUrl := RegExReplace(publishUrl, "i)^srt://[^:/?]+:", "srt://127.0.0.1:", &replaceCount, 1)
publishUrl := ""
if (replaceCount != 1)
    throw Error("Unable to replace SRT host")

quality := RCSH_LiveQualityConfig(RCSH_ReadLiveQualityProfile())
cmd := '"' ffmpegExe '" -hide_banner -loglevel error -f gdigrab -framerate ' quality.fps ' -i desktop '
    . '-t 15 -vf "scale=-2:720" -an -c:v libx264 -preset ultrafast -tune zerolatency '
    . '-pix_fmt yuv420p -b:v ' quality.bitrateKbps 'k -maxrate ' quality.bitrateKbps
    . 'k -bufsize ' quality.bufferKbps 'k -g ' quality.gop ' -bf 0 '
    . '-metadata comment=WUTHERING_RUNTIME_PREVIEW_LOOPBACK_TEST -f mpegts "' localUrl '"'
pid := 0
Run(cmd, , "Hide", &pid)
localUrl := ""
if (pid <= 0)
    throw Error("Loopback FFmpeg returned no PID")

Sleep(10000)
if !ProcessExist(pid)
    throw Error("Loopback FFmpeg exited before 10 seconds")

ProcessWaitClose(pid, 12)
if ProcessExist(pid)
    ProcessClose(pid)
ExitApp(0)
