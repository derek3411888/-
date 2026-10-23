#Requires AutoHotkey v2.0
#Warn All, StdOut
#Include ..\payload\CompletionSynthesisRuntime.ahk
#Include ..\payload\SynthesisCompletionChild.ahk
global TestRoot := A_ScriptDir "\..\.dev-runtime\diagnostics\game-maintenance\20261023-restart-synthesis\adapter"
global REMOTE_STOP_IN_PROGRESS := false, EXITING_FROM_TRAY := false, REMOTE_CONTROL_ACTIVE := false
global __RESTART_IN_PROGRESS := false
global AhkExe := A_AhkPath
global BoundGameRecord := {hwnd:11,pid:22,started:"134210000000000001",path:"E:\verified\Client-Win64-Shipping.exe"}
DirCreate(TestRoot)
RunRuntimeTests()
RunRuntimeTests() {
global __RESTART_IN_PROGRESS, TestRoot, BoundGameRecord
try {
    io := AdapterIo()
    Assert(io.Prepare(), "already absent is a successful drain even when helper counts are zero")
    io.remaining := 1
    Assert(!io.Prepare(), "fresh inventory with a competing child blocks launch")
    io.remaining := 0
    __RESTART_IN_PROGRESS := true
    Assert(io.Control() = "STOP", "in-flight restart stops completion child")
    __RESTART_IN_PROGRESS := false
    state := {key:"Asia|2026-10-23",token:io.Token(),stage:"running",pausedMs:0}
    Assert(io.Save(state), "real atomic state persistence succeeds")
    loaded := io.Load("unused")
    Assert(loaded.key = "Asia|2026-10-23" && loaded.token = state.token && loaded.stage = "running", "persisted attempt survives controller reload")
    io.Heartbeat(state,"RUN")
    lease := FileRead(io.root "\" state.token ".lease","UTF-8")
    Assert(CS_LeaseAllowsInput(lease,state.token,io.Now()), "real heartbeat authorizes only fresh attempt")
    child := CS_ChildContext(["--completion",state.token,io.root "\" state.token ".receipt",io.root "\" state.token ".lease",String(DllCall("GetCurrentProcessId")),"11","22","134210000000000001","E:\verified\Client-Win64-Shipping.exe"])
    Assert(child.EnsureRun(), "child verifies parent handle and live lease without input")
    Assert(child.Finish(true) = 0 && io.Receipt(state) = state.token "|success", "actual receipt writer carries unique token and successful code")
    Assert(child.Finish(false) = 2 && io.Receipt(state) = state.token "|failed", "failure never writes successful receipt")
    Assert(child.BindGame().hwnd = 11,"child binds exactly parent-verified game record via held-identity boundary")
    BoundGameRecord.path := "E:\another-install\Client-Win64-Shipping.exe", rejected := false
    try child.BindGame()
    catch
        rejected := true
    Assert(rejected,"child rejects another installation before any input")
    BoundGameRecord.path := "E:\verified\Client-Win64-Shipping.exe"
    Assert(io.GameIdentity().hwnd = 11,"parent adapter uses managed selector and validates known install record")
    state.pausedMs := 120000, io.Heartbeat(state,"RUN"), wall := io.Now()
    active := child.BudgetNow()
    Assert(Abs((wall-active)-120000) < 100,"parent cumulative pause survives OS suspension and does not alter wall clock")
    for expectedCode in [0,2] {
        fixture := TestRoot "\exit-" expectedCode "-" DllCall("GetCurrentProcessId") ".ahk"
        FileAppend("#Requires AutoHotkey v2.0`nSleep(100)`nExitApp(" expectedCode ")`n",fixture,"UTF-8-RAW")
        held := CS_HeldChild('"' A_AhkPath '" /ErrorStdOut=UTF-8 "' fixture '"',TestRoot)
        deadline := A_TickCount+5000
        while !held.Poll().exited && A_TickCount < deadline
            Sleep(20)
        result := held.Poll()
        Assert(result.exited && result.code = expectedCode, "held process handle reports real child exit " expectedCode)
    }
    fixture := TestRoot "\cancel-" DllCall("GetCurrentProcessId") ".ahk"
    FileAppend("#Requires AutoHotkey v2.0`nSleep(30000)`nExitApp(0)`n",fixture,"UTF-8-RAW")
    held := CS_HeldChild('"' A_AhkPath '" /ErrorStdOut=UTF-8 "' fixture '"',TestRoot)
    Assert(held.Cancel() && held.Poll().exited && held.Poll().code = 2, "cancel confirms same held child exit, not name/PID absence")
    FileAppend("PASS: completion synthesis runtime 16 assertions; no-input isolated children only`n","*")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL: " err.Message " | " err.File ":" err.Line "`n","**")
    ExitApp(1)
}
}
Assert(ok,message) {
    if !ok
        throw Error(message)
}
class AdapterIo extends CompletionSynthesisIo {
    __New() {
        super.__New()
        this.remaining := 0
    }
    Drained() => this.remaining = 0
}
RuntimeFiles_RuntimeDir(category) {
    global TestRoot
    return TestRoot
}
RawSleep(ms) => Sleep(ms)
WriteLog(args*) {
}
CloseManagedAhkForSelfHealing(args*) => 0
CloseExactProcessForSelfHealing(args*) => 0
EnumerateAuxManagedAhkProcesses() => []
ResolveManagedTargetExePath(name) => "E:\verified\Client-Win64-Shipping.exe"
ReadManagedProcessRecord(pid) {
    global BoundGameRecord
    return BoundGameRecord.Clone()
}
GMHost_GetManagedGameHwnd() => 11
WinGetClass(args*) => "UnrealWindow"
WinGetPID(args*) => 22
SynthesisEnsureInputAllowed() => true
SynthesisActiveTick() => DllCall("GetTickCount64","UInt64")
SynthesisPauseEpoch() => 0
class SynthesisMenuIo {
    __New(args*) {
        global BoundGameRecord
        for name,value in BoundGameRecord.OwnProps()
            this.%name% := value
    }
    Alive() => true
}
RC_IsPaused() => false
