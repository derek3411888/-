#Requires AutoHotkey v2.0
; Each integration case uses an isolated request/nonce and can briefly overlap
; the previous synthetic successor while Windows tears it down.  Do not let
; AutoHotkey's process-wide single-instance replacement make the next case
; disappear before it can write its ACK.
#SingleInstance Off
#Warn All, StdOut
#Include ..\..\payload\ScriptRestartHandoff.ahk

root := ""
OnExit(RecordFixtureExit)
try {
    request := EnvGet("WUTHERING_RESTART_REQUEST")
    parentPid := Integer(IniRead(request, "request", "parent_pid"))
    root := IniRead(request, "request", "root")
    if ProcessExist(parentPid)
        throw Error("Successor started before its parent exited")
    actual := ""
    for arg in A_Args
        actual .= (actual = "" ? "" : " ") arg
    FileAppend(actual "`n", root "\child-starts.txt", "UTF-8")
    if (InStr(IniRead(root "\fixture.ini", "test", "scenario", ""), "noack") = 1)
        ExitApp 0
    adoptedRecorder := Integer(IniRead(request, "request", "recording_pid", "0"))
    if !RestartHandoff_Acknowledge(adoptedRecorder)
        throw Error("Successor failed to acknowledge its handoff")
    if adoptedRecorder {
        if !ProcessExist(adoptedRecorder)
            throw Error("Successful restart did not preserve the recorder")
        FileAppend("adopted", root "\recorder-adopted.txt", "UTF-8")
        ; The synthetic successor is short-lived, so it owns normal finalization.
        RestartHandoff_FinalizeOrphan(request)
    }
    ExitApp 0
} catch as e {
    ; Launcher-spawned children have no inherited stdout handle. Reporting an
    ; expected rejection to stdout used to throw and leave a blocking dialog.
    if root != ""
        try FileAppend(e.Message "`n", root "\child-error.txt", "UTF-8")
    ExitApp 1
}

RecordFixtureExit(reason, code) {
    global root
    if root != ""
        try FileAppend("[exit]`npid=" DllCall("GetCurrentProcessId", "uint") "`ncode=" code "`n", root "\child-exit.ini", "UTF-8")
}
