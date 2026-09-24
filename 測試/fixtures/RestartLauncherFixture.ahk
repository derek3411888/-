#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
try {
    request := EnvGet("WUTHERING_RESTART_REQUEST")
    root := IniRead(request, "request", "root")
    if ProcessExist(Integer(IniRead(request, "request", "parent_pid")))
        throw Error("Updater started before parent exit")
    flag := A_Args[1]
    if (flag != "--restart-current-task" && flag != "--resume-current-task")
        throw Error("Unexpected updater flag")
    FileAppend(flag "`n", root "\launcher-starts.txt", "UTF-8")
    ahk := IniRead(request, "request", "ahk")
    target := IniRead(request, "request", "script")
    mode := flag = "--resume-current-task" ? "restart resume" : "restart"
    if (IniRead(root "\fixture.ini", "test", "scenario", "") = "wrong-mode")
        mode := "restart"
    Run('"' ahk '" /ErrorStdOut=UTF-8 "' target '" ' mode, , "Hide")
    ExitApp 0
} catch as e {
    ExitApp 1
}
