#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include GameMaintenanceFixtures.ahk
#Include *i ..\payload\RemoteRestartDrain.ahk
GMTest_Run(TestDrain)
TestDrain() {
    if !IsSet(RRD_Decide)
        throw Error("Missing complete managed-flow drain admission")
    targets := Map("lrmcai.exe","c:\fixture\lrmcai.exe","ok-ww.exe","c:\okww\ok-ww.exe",
        "wuthering waves.exe","c:\game\wuthering waves.exe","client-win64-shipping.exe","c:\game\client.exe")
    scripts := ["c:\product\payload\聲骸合成.ahk","c:\product\payload\開啟LRMC.ahk"]
    decide := (records) => RRD_Decide(records,targets,scripts,1)
    GMTest_Assert(decide([]).ok,"fresh absence allows updater")
    for name,path in targets {
        GMTest_Assert(!decide([{pid:2,name:name,path:path,known:true,cmd:""}]).ok,"owned application remaining blocks updater: " name)
        GMTest_Assert(decide([{pid:2,name:name,path:"c:\unrelated\" name,known:true,cmd:""}]).ok,"other installation remains untouched: " name)
        GMTest_Assert(!decide([{pid:2,name:name,path:"",known:false,cmd:""}]).ok,"unknown identity is not absence: " name)
    }
    GMTest_Assert(!decide([{pid:2,name:"pythonw.exe",path:"c:\okww\venv\pythonw.exe",known:true,cmd:"worker"}]).ok,"OKWW descendant survives without title still blocks")
    GMTest_Assert(decide([{pid:2,name:"python.exe",path:"c:\other\python.exe",known:true,cmd:"other"}]).ok,"unrelated python stays out of scope")
    GMTest_Assert(!decide([{pid:2,name:"AutoHotkey64.exe",path:"c:\other\AutoHotkey64.exe",known:true,
        cmd:'"c:\other\AutoHotkey64.exe" /ErrorStdOut "c:\product\payload\聲骸合成.ahk"'}]).ok,"same script under another runtime blocks even with switches")
    GMTest_Assert(!decide([{pid:2,name:"AutoHotkey64.exe",path:"",known:false,cmd:""}]).ok,"unreadable candidate blocks, no broad kill")
    for token in ['聲骸合成.ahk','"c:\product\payload\..\payload\聲骸合成.ahk"','"c:/product/payload/聲骸合成.ahk"']
        GMTest_Assert(!decide([{pid:2,name:"AutoHotkey64.exe",path:"c:\other\AutoHotkey64.exe",known:true,
            cmd:'"c:\other\AutoHotkey64.exe" /ErrorStdOut ' token}]).ok,"relative or equivalent script path must block: " token)
    GMTest_Assert(decide([{pid:1,name:"AutoHotkey64.exe",path:"",known:false,cmd:""}]).ok,"current parent not counted as child")
    GMTest_Assert(!decide([{pid:2,name:"ffmpeg.exe",path:"c:\tools\ffmpeg.exe",known:true,cmd:"managed-recorder"}]).ok,"remaining owned recording blocks updater")
    GMTest_Assert(decide([{pid:2,name:"ffmpeg.exe",path:"c:\tools\ffmpeg.exe",known:true,cmd:"other-recorder"}]).ok,"unrelated recording never stopped")
}
ReadManagedProcessRecord(args*) => 0
ResolveManagedTargetExePath(args*) => ""
GMHost_CanonicalPath(path) {
    result := Buffer(65536)
    length := DllCall("GetFullPathNameW","str",path,"uint",32768,"ptr",result,"ptr",0,"uint")
    return length ? StrGet(result) : ""
}
IsManagedByCurrentScriptFfmpegCommand(command) => command = "managed-recorder"
ParseManagedCommandLine(command) {
    args := [],count := 0
    argv := DllCall("Shell32\CommandLineToArgvW","str",command,"int*",&count,"ptr")
    if !argv
        return args
    try Loop count
        args.Push(StrGet(NumGet(argv,(A_Index-1)*A_PtrSize,"ptr")))
    finally DllCall("LocalFree","ptr",argv)
    return args
}
