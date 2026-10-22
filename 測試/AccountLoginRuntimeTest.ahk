#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameAccountLoginRuntime.ahk
#Include ..\payload\GameHotfixRecovery.ahk
global GM_CONTROLLER := {state:{phase:"NORMAL"},stableGateDay:1}, testState := "RUN"
global testPid := 42, testHwnd := 12, testWidth := 1280, testDay := 1, testClicks := 0
global afterActivate := "", beforeClick := "", allowDayRefresh := false, diagnosticLogs := [], diagnosticLevels := []
global testElapsed := 0, foregroundMode := "exact", requestReturn := true
GMTest_Run(TestRuntime)
class RuntimeFixture extends GameAccountLoginIo {
    __New() {
        this.hwnd := 12, this.pid := 42, this.tick := 10000, this.aliveFlag := true
        this.fresh := {candidate:{x:640,y:430,label:"登录"},width:1280,height:720,capturedAt:10000,
            originX:100,originY:50,targetHwnd:24,targetX:340,targetY:230,
            targetOriginX:400,targetOriginY:250,targetWidth:600,targetHeight:400,accountDialog:true}
    }
    __Delete() => 0
    Now() {
        global testElapsed
        return this.tick+testElapsed
    }
    Alive() => this.aliveFlag
    Observe() => this.fresh
    Rect(hwnd) {
        global testWidth
        return hwnd = 12 ? {x:100,y:50,w:testWidth,h:720} : {x:400,y:250,w:600,h:400}
    }
    RootAt(x,y) => 24
    SurfaceAllowed(hwnd) => hwnd = 24
    HasVisibleOwnedDialog() => true
    RequestForeground(hwnd) => TestActivate(hwnd)
}
ResetFixture() {
    global testState,testPid,testHwnd,testWidth,testDay,testClicks,afterActivate,beforeClick,allowDayRefresh,GM_CONTROLLER,diagnosticLogs,diagnosticLevels
    global testElapsed,foregroundMode,requestReturn
    testState := "RUN", testPid := 42, testHwnd := 12, testWidth := 1280, testDay := 1, testClicks := 0
    afterActivate := "", beforeClick := "", allowDayRefresh := false, GM_CONTROLLER.stableGateDay := 1
    diagnosticLogs := [], diagnosticLevels := []
    testElapsed := 0, foregroundMode := "exact", requestReturn := true
}
TestRuntime() {
    global testState,testPid,testHwnd,testWidth,testDay,testClicks,afterActivate,beforeClick,allowDayRefresh,diagnosticLogs,diagnosticLevels
    global testElapsed,foregroundMode,requestReturn
    ResetFixture(), io := RuntimeFixture(), obs := io.fresh.Clone()
    GMTest_Assert(io.Confirm(obs) && testClicks = 1,"actual Confirm reaches physical-click wrapper only after fresh verification")
    GMTest_Assert(io.HasOwnProp("lastFailure") && io.lastFailure = "","successful click leaves no failure diagnosis")
    for field in ["pause","stop","pid","hwnd","size","day","exit","stale","future"] {
        ResetFixture(), io := RuntimeFixture(), obs := io.fresh.Clone()
        switch field {
            case "pause": testState := "PAUSE"
            case "stop": testState := "STOP"
            case "pid": testPid := 99
            case "hwnd": testHwnd := 13
            case "size": testWidth := 1300
            case "day": testDay := 2
            case "exit": io.aliveFlag := false
            case "stale": obs.capturedAt := 4999
            case "future": obs.capturedAt := 10001
        }
        GMTest_Assert(!io.Confirm(obs) && testClicks = 0,"actual runtime guard rejects " field)
        expectedStage := field = "pause" || field = "stop" ? "intent" : (field = "exit" ? "process" : (field = "day" ? "day_gate" : "initial_guard"))
        GMTest_Assert(io.lastFailure = expectedStage,"failed Confirm identifies first rejected stage: " field)
        GMTest_Assert(diagnosticLogs.Length = 1 && InStr(diagnosticLogs[1],"stage=" expectedStage),"rejection reaches production diagnostic log")
        GMTest_Assert(diagnosticLevels[1] = "INFO","diagnostic metadata must not trigger WARN error screenshot capture/publication")
    }
    ResetFixture(), io := RuntimeFixture(), obs := io.fresh.Clone(), io.fresh.candidate := 0
    GMTest_Assert(!io.Confirm(obs) && testClicks = 0,"button disappears after activation: no click")
    GMTest_Assert(io.lastFailure = "fresh_candidate","missing fresh candidate is diagnosed separately from activation")
    ResetFixture(), io := RuntimeFixture(), obs := io.fresh.Clone(), io.fresh.candidate := {x:800,y:430,label:"登录"}
    GMTest_Assert(!io.Confirm(obs) && testClicks = 0,"changed button location after activation: no click")
    ResetFixture(), io := RuntimeFixture(), obs := io.fresh.Clone(), afterActivate := "PAUSE"
    GMTest_Assert(!io.Confirm(obs) && testClicks = 0,"PAUSE during activation is honored")
    GMTest_Assert(io.lastFailure = "activation_guard","activation guard rejection preserves its own diagnosis")
    ResetFixture(), io := RuntimeFixture(), obs := io.fresh.Clone(), foregroundMode := "", requestReturn := false
    GMTest_Assert(!io.Confirm(obs) && testClicks = 0 && testElapsed = 2500,"activation failure is bounded without physical input")
    GMTest_Assert(io.lastFailure = "activation_timeout" && diagnosticLogs.Length = 1,"timeout keeps activation diagnosis instead of generic click failure")
    GMTest_Assert(InStr(diagnosticLogs[1],"request_return=0") && InStr(diagnosticLogs[1],"foreground=99 relation="),"timeout records actual activation return and foreground evidence")
    ResetFixture(), io := RuntimeFixture(), obs := io.fresh.Clone(), requestReturn := false
    GMTest_Assert(io.Confirm(obs) && testClicks = 1,"native return alone does not reject an already verified foreground")
    ResetFixture(), io := RuntimeFixture(), obs := io.fresh.Clone(), beforeClick := "STOP"
    GMTest_Assert(!io.Confirm(obs) && testClicks = 0,"final physical-input guard honors STOP arriving after OCR")
    GMTest_Assert(io.lastFailure = "click_guard","click-wrapper failure cannot be reported as successful input")
    ResetFixture(), io := RuntimeFixture(), obs := io.fresh.Clone(), testDay := 2, allowDayRefresh := true
    GMTest_Assert(io.Confirm(obs) && testClicks = 1,"cross-day login rechecks new normal day before final input guard")
    ResetFixture(), io := RuntimeFixture(), io.fresh.candidate := 0
    blocks := [{text:"KURO GAMES"},{text:"帳號"},{text:"驗證碼"}]
    GMTest_Assert(HandleWutheringAccountLogin(12,blocks,1280,720,10000,&io),"non-actionable account modal must not fall through to normal account/server keywords")
}
WinGetClientPos(&x?,&y?,&w?,&h?,args*) {
    global testWidth
    w := testWidth, h := 720
}
WinGetPID(args*) {
    global testPid
    return testPid
}
GetWutheringGameHwnd() {
    global testHwnd
    return testHwnd
}
GMHost_StableIntent(args*) {
    global testState
    return testState
}
GetInteractiveDesktopState() => {ok:true}
RC_UnixMs() {
    global testDay
    return testDay*86400000
}
GMHost_RecheckStableDay(c) {
    global testDay,allowDayRefresh
    if testDay != c.stableGateDay {
        if !allowDayRefresh
            return {ok:false}
        c.stableGateDay := testDay
    }
    return {ok:true}
}
TestActivate(args*) {
    global afterActivate,testState,requestReturn
    if afterActivate != ""
        testState := afterActivate
    return requestReturn
}
ClickVerifiedWindowClientPoint(hwnd,x,y,pid,context,guard,prepare) {
    global testClicks,beforeClick,testState
    GMTest_Assert(hwnd = 24 && pid = 42 && x = 340 && y = 230,"exact owned-dialog client coordinates and physical-click action")
    if !prepare.Call()
        return false
    if beforeClick != ""
        testState := beforeClick
    if !guard.Call()
        return false
    testClicks++
    return true
}
; External I/O dependencies are not used by the isolated fixture constructor.
GetWutheringWindowIdentity(args*) => false
MPG_ReadHandleRecord(args*) => 0
ResolveManagedTargetExePath(args*) => ""
MonotonicTickMs() => 10000
WutheringUpdateProcessAlive(args*) => false
RuntimeFiles_NewImagePath(args*) => ""
ImagePutBuffer(args*) => 0
ImagePutFile(args*) => 0
GetWindowAtScreenPoint(args*) => 0
GetWindowRelationToTarget(args*) => "unrelated"
GetForegroundRelationToTarget(hwnd,&foreground) {
    global foregroundMode
    foreground := foregroundMode = "exact" ? hwnd : 99
    return foregroundMode
}
IsSafeInputWindowRelation(relation,policy) => relation = "exact" && policy = "root"
RawSleep(ms) {
    global testElapsed
    testElapsed += ms
}
class RapidOcr {
}
WriteStep(args*) => 0
WriteLog(message,level := "INFO",args*) {
    global diagnosticLogs,diagnosticLevels
    diagnosticLogs.Push(message)
    diagnosticLevels.Push(level)
}
