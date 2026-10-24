#Requires AutoHotkey v2.0
#Warn All, StdOut
#Include ..\payload\CompletionSynthesisRuntime.ahk
#Include ..\payload\SynthesisCompletionChild.ahk
global TestRoot := A_ScriptDir "\..\.dev-runtime\diagnostics\game-maintenance\20261023-restart-synthesis\adapter"
global REMOTE_STOP_IN_PROGRESS := false, EXITING_FROM_TRAY := false, REMOTE_CONTROL_ACTIVE := false
global __RESTART_IN_PROGRESS := false
global TestPaused := false
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
    RunFileSharingTests(io,child,state)
    RunParentControlDuringContentionTest(io,state)
    RunCompletionCommitContentionTests()
    RunConcurrentControlFileTest(io,state)
    RunParentExitDuringContentionTest(io,state)
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
    FileAppend("PASS: completion synthesis runtime plus real control-file sharing regression; no-input isolated children only`n","*")
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
RunFileSharingTests(io,child,state) {
    leasePath := io.root "\" state.token ".lease"
    ; Hold DELETE access just as an overlapping atomic replacement does. The
    ; production FileRead reader currently rejects this compatible writer.
    sharing := TestFileLock(leasePath,0x10000,7)
    allowed := false, detail := ""
    try allowed := child.EnsureRun()
    catch as err
        detail := err.Message
    finally sharing.Close()
    Assert(allowed,"lease reader must coexist with atomic replacement: " detail)

    ; A compatible reader may still delay Windows' replace operation. Release
    ; only this test's own handle; no permission change or process termination.
    sharing := TestFileLock(leasePath,0x80000000,7)
    release := () => sharing.Close()
    SetTimer(release,-70)
    wrote := false, detail := ""
    try {
        io.Heartbeat(state,"PAUSE")
        wrote := true
    } catch as err
        detail := err.Message " | " err.What " | " err.Extra
    finally {
        SetTimer(release,0)
        sharing.Close()
    }
    Assert(wrote,"heartbeat atomically replaces a record after a brief reader overlap: " detail)
    Assert(InStr(FileRead(leasePath,"UTF-8"),"|PAUSE|"),"replacement publishes PAUSE, not a cached RUN")

    ; A blocked read can recover, but the new STOP/expired record must still
    ; be checked. The I/O retry must never cache or return a prior RUN decision.
    for mode in ["RUN","STOP","expired"] {
        io.Heartbeat(state,"RUN")
        sharing := TestFileLock(leasePath,0x80000000,0)
        release := TestReleaseLease.Bind(sharing,io,state,mode)
        SetTimer(release,-70)
        allowed := false, detail := ""
        try allowed := child.EnsureRun()
        catch as err
            detail := err.Message
        finally {
            SetTimer(release,0)
            sharing.Close()
        }
        Assert(mode = "RUN" ? allowed : !allowed,"read contention obeys latest lease " mode ": " detail)
    }
    io.Heartbeat(state,"RUN")
    sharing := TestFileLock(leasePath,0x80000000,0)
    started := A_TickCount, allowed := false
    try allowed := child.EnsureRun()
    catch {
    } finally sharing.Close()
    Assert(!allowed && A_TickCount-started < 1000,"persistent read lock is bounded and never permits input")

    ; Failure must leave the complete prior lease intact, never truncate it.
    prior := FileRead(leasePath,"UTF-8")
    sharing := TestFileLock(leasePath,0x80000000,3)
    started := A_TickCount, wrote := false
    try {
        io.Heartbeat(state,"STOP")
        wrote := true
    } catch {
    } finally sharing.Close()
    Assert(!wrote && A_TickCount-started < 1000,"persistent replacement lock fails within a bound")
    Assert(FileRead(leasePath,"UTF-8") = prior,"failed replacement retains complete prior lease")
    io.Heartbeat(state,"RUN")

    for path in [io.statePath,child.receiptPath] {
        if path = child.receiptPath
            child.Finish(true)
        sharing := TestFileLock(path,0x10000,7)
        verified := false
        try verified := path = io.statePath ? io.Load(state.key).token = state.token : io.Receipt(state) = state.token "|success"
        finally sharing.Close()
        Assert(verified,"state and receipt reads tolerate an overlapping rename handle")
    }
}
TestReleaseLease(sharing,io,state,mode) {
    sharing.Close()
    if mode = "expired"
        io.Atomic(io.root "\" state.token ".lease",state.token "|RUN|" (io.Now()-3000) "|0")
    else
        io.Heartbeat(state,mode)
}
RunParentControlDuringContentionTest(io,state) {
    global REMOTE_STOP_IN_PROGRESS, REMOTE_CONTROL_ACTIVE, TestPaused
    path := io.root "\" state.token ".lease"
    for control in ["PAUSE","STOP"] {
        io.Heartbeat(state,"RUN")
        sharing := TestFileLock(path,0x80000000,3)
        release := TestChangeParentControl.Bind(sharing,control)
        SetTimer(release,-70)
        try {
            io.Heartbeat(state,"RUN")
            lease := CS_ReadControlText(path)
            Assert(InStr(lease,"|" control "|"),"retry must publish latest parent " control ", never stale RUN")
            Assert(!CS_LeaseAllowsInput(lease,state.token,io.Now()),"control change during write retry cannot allow input")
        } finally {
            SetTimer(release,0)
            sharing.Close()
            REMOTE_STOP_IN_PROGRESS := false, REMOTE_CONTROL_ACTIVE := false, TestPaused := false
        }
    }
    io.Heartbeat(state,"RUN")
}
TestChangeParentControl(sharing,control) {
    global REMOTE_STOP_IN_PROGRESS, REMOTE_CONTROL_ACTIVE, TestPaused
    REMOTE_STOP_IN_PROGRESS := control = "STOP"
    REMOTE_CONTROL_ACTIVE := true, TestPaused := control = "PAUSE"
    sharing.Close()
}
RunCompletionCommitContentionTests() {
    global REMOTE_STOP_IN_PROGRESS, REMOTE_CONTROL_ACTIVE, TestPaused
    for control in ["PAUSE","STOP"] {
        for boundary in ["receipt","success-save"] {
            io := ContendedFinishIo(boundary,control)
            try {
                result := CS_Run(io,"isolated-completion")
                expectedResult := control = "PAUSE" ? "paused" : "stopped"
                Assert(io.contended && result = expectedResult && io.Load("").stage = "success",
                    "real " boundary " contention preserves proof and honors parent " control)
                Assert(CS_Run(io,"isolated-completion") = expectedResult && io.launches = 1,
                    "committed proof cannot override parent control or repeat synthesis")
                REMOTE_STOP_IN_PROGRESS := false, REMOTE_CONTROL_ACTIVE := false, TestPaused := false
                Assert(CS_Run(io,"isolated-completion") = "success" && io.launches = 1,
                    "resume reuses verified proof after real contention")
            } finally {
                REMOTE_STOP_IN_PROGRESS := false, REMOTE_CONTROL_ACTIVE := false, TestPaused := false
            }
        }
    }
}
class ContendedFinishIo extends CompletionSynthesisIo {
    __New(boundary,control) {
        global TestRoot
        this.root := TestRoot "\commit-" this.Token()
        DirCreate(this.root)
        this.statePath := this.root "\state.txt"
        this.boundary := boundary, this.controlTo := control, this.launches := 0, this.contended := false
    }
    Prepare() => true
    Launch(state) {
        this.launches += 1
        this.Atomic(this.root "\" state.token ".receipt",state.token "|success")
        return {owned:true} ; no actual script or input is launched
    }
    Poll(child) => {exited:true,code:0}
    Cancel(child) => true
    Save(state) {
        if this.boundary != "success-save" || state.stage != "success" || this.contended
            return super.Save(state)
        sharing := TestFileLock(this.statePath,0x80000000,3)
        release := TestChangeParentControl.Bind(sharing,this.controlTo)
        this.contended := true, SetTimer(release,-70)
        try return super.Save(state)
        finally {
            SetTimer(release,0)
            sharing.Close()
        }
    }
    Receipt(state) {
        if this.boundary != "receipt" || this.contended
            return super.Receipt(state)
        sharing := TestFileLock(this.root "\" state.token ".receipt",0x80000000,0)
        release := TestChangeParentControl.Bind(sharing,this.controlTo)
        this.contended := true, SetTimer(release,-70)
        try return super.Receipt(state)
        finally {
            SetTimer(release,0)
            sharing.Close()
        }
    }
}
RunConcurrentControlFileTest(io,state) {
    global TestRoot
    tag := state.token, path := io.root "\" tag ".lease"
    fixture := TestRoot "\concurrent-" DllCall("GetCurrentProcessId") ".ahk"
    ready := TestRoot "\" tag ".ready", stop := TestRoot "\" tag ".stop", resultPath := TestRoot "\" tag ".result"
    source := '#Requires AutoHotkey v2.0`n#NoTrayIcon`n#Include "' A_ScriptDir '\..\payload\CompletionSynthesis.ahk"`n'
    source .= 'path := "' path '", token := "' tag '"`n'
    source .= 'try {`n    FileAppend("ready","' ready '","UTF-8")`n'
    source .= '    deadline := A_TickCount+10000, reads := 0`n'
    source .= '    while !FileExist("' stop '") && A_TickCount < deadline {`n'
    source .= '        text := CS_ReadControlText(path)`n'
    source .= '        if !CS_LeaseAllowsInput(text,token,DllCall("GetTickCount64","UInt64"))`n'
    source .= '            throw Error("partial, missing or stale control record")`n'
    source .= '        reads += 1`n        Sleep(1)`n    }`n'
    source .= '    if !FileExist("' stop '") || reads < 10`n        throw Error("reader did not observe concurrent updates")`n'
    source .= '    FileAppend("PASS reads=" reads,"' resultPath '","UTF-8")`n    ExitApp(0)`n'
    source .= '} catch as err {`n    FileAppend("FAIL " err.Message,"' resultPath '","UTF-8")`n    ExitApp(2)`n}`n'
    FileAppend(source,fixture,"UTF-8-RAW")
    io.Heartbeat(state,"RUN")
    held := CS_HeldChild('"' A_AhkPath '" /ErrorStdOut=UTF-8 "' fixture '"',TestRoot)
    try {
        deadline := A_TickCount+3000
        while !FileExist(ready) && !held.Poll().exited && A_TickCount < deadline
            Sleep(10)
        Assert(FileExist(ready),"no-input concurrent reader started")
        loop 200 {
            io.Heartbeat(state,"RUN")
            Sleep(1)
        }
        FileAppend("stop",stop,"UTF-8")
        deadline := A_TickCount+3000
        while !held.Poll().exited && A_TickCount < deadline
            Sleep(10)
        result := held.Poll()
        Assert(result.exited && result.code = 0 && InStr(FileRead(resultPath,"UTF-8"),"PASS reads="),
            "real concurrent process reads complete leases throughout 200 replacements")
    } finally {
        if !held.Poll().exited
            held.Cancel()
    }
}
RunParentExitDuringContentionTest(io,state) {
    global TestRoot
    fixture := TestRoot "\parent-" DllCall("GetCurrentProcessId") ".ahk"
    FileAppend("#Requires AutoHotkey v2.0`n#NoTrayIcon`nSleep(30000)`n",fixture,"UTF-8-RAW")
    parent := CS_HeldChild('"' A_AhkPath '" /ErrorStdOut=UTF-8 "' fixture '"',TestRoot)
    path := io.root "\" state.token ".lease"
    context := CS_ChildContext(["--completion",state.token,io.root "\" state.token ".receipt",path,
        String(DllCall("GetProcessId","ptr",parent.handle,"uint")),"11","22","134210000000000001","E:\verified\Client-Win64-Shipping.exe"])
    io.Heartbeat(state,"RUN")
    sharing := TestFileLock(path,0x80000000,0)
    release := TestExitParentAndRelease.Bind(parent,sharing)
    SetTimer(release,-70)
    allowed := false
    try allowed := context.EnsureRun()
    catch {
    } finally {
        SetTimer(release,0)
        sharing.Close()
        parent.Cancel()
    }
    Assert(!allowed,"parent exiting during a file retry must never permit child input")
}
TestExitParentAndRelease(parent,sharing) {
    parent.Cancel()
    sharing.Close()
}
class TestFileLock {
    __New(path,access,share) {
        this.handle := DllCall("CreateFileW","str",path,"uint",access,"uint",share,
            "ptr",0,"uint",3,"uint",0,"ptr",0,"ptr")
        if this.handle = -1
            throw OSError(A_LastError,"test file lock")
    }
    Close() {
        if this.handle && this.handle != -1 {
            DllCall("CloseHandle","ptr",this.handle)
            this.handle := 0
        }
    }
    __Delete() => this.Close()
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
RC_IsPaused() {
    global TestPaused
    return TestPaused
}
