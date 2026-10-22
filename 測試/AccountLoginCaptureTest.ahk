#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameAccountLoginRuntime.ahk
#Include ..\payload\GameHotfixRecovery.ahk
global GM_CONTROLLER := {state:{phase:"NORMAL"},stableGateDay:1}, captureKind := "", clicks := 0
global surfacePid := 42, surfaceClass := "#32770", surfaceRelation := "same_root_owner"
global sampleDay := 1
global ocrHook := 0
GMTest_Run(TestOwnedCapture)
class CaptureFixture extends GameAccountLoginIo {
    __New() {
        this.hwnd := 12, this.pid := 42, this.tick := 10000, this.hitRoot := 24
        this.foreign := false, this.moved := false, this.intentValue := "RUN", this.blockAtClick := false
        this.overlay := false, this.dialogMoved := false, this.noOwned := false
        this.ocr := RapidOcr()
    }
    __Delete() => 0
    Now() => this.tick
    Alive() => true
    Intent() => this.intentValue
    Rect(hwnd) => hwnd = 12 ? {x:this.moved ? 101 : 100,y:50,w:1280,h:720} : {x:this.dialogMoved ? 420 : 400,y:250,w:600,h:400}
    RootAt(x,y) => this.hitRoot
    SurfaceAllowed(hwnd) => !this.foreign && (hwnd = 12 || hwnd = 24)
    VisibleStack() {
        if this.noOwned
            return [{hwnd:12,rect:this.Rect(12)}]
        stack := [{hwnd:24,rect:this.Rect(24)},{hwnd:12,rect:this.Rect(12)}]
        if this.overlay
            stack.InsertAt(1,{hwnd:77,rect:{x:250,y:170,w:100,h:50}})
        return stack
    }
    Capture(rect) {
        global captureKind
        captureKind := "visible-client"
        return {width:rect.w,height:rect.h}
    }
}
TestOwnedCapture() {
    global captureKind, clicks, surfacePid, surfaceClass, surfaceRelation, sampleDay, ocrHook
    io := CaptureFixture()
    owns := (hwnd) => GameAccountLoginIo.Prototype.SurfaceAllowed.Call(io,hwnd)
    GMTest_Assert(owns(24),"production ownership accepts same-PID owned dialog")
    surfacePid := 99
    GMTest_Assert(!owns(24),"cross-process owned dialog rejected")
    surfacePid := 42, surfaceRelation := "same_process"
    GMTest_Assert(!owns(24),"same-PID unrelated window rejected")
    surfaceRelation := "same_root_owner", surfaceClass := "OtherWindow"
    GMTest_Assert(!owns(24),"unrecognized owned-window class rejected")
    surfaceClass := "UnrealWindow"
    GMTest_Assert(owns(12),"exact main game remains accepted")
    surfaceClass := "#32770"
    GMTest_Assert(io.HasVisibleOwnedDialog(),"owned login dialog is detected even when main PrintWindow omits it")
    obs := io.Observe()
    GMTest_Assert(captureKind = "visible-client" && obs.accountDialog && IsObject(obs.candidate),"visible client OCR finds the omitted modal")
    GMTest_Assert(obs.targetHwnd = 24 && obs.targetX = 340 && obs.targetY = 230,"game OCR point converts to exact owned-dialog client coordinates")
    GMTest_Assert(io.FinalGuard(obs),"same owned modal is allowed without weakening the global root-only game guard")
    io.overlay := true, captureKind := ""
    GMTest_Assert(io.HasVisibleOwnedDialog(),"obstructed modal still claims the account flow")
    blocked := io.Observe()
    GMTest_Assert(!IsObject(blocked.candidate) && captureKind = "","foreign overlay BETWEEN sample points prevents full-client screenshot")
    io.overlay := false, sampleDay := 2
    observedNextDay := io.Observe()
    GMTest_Assert(IsObject(observedNextDay.candidate) && !io.FinalGuard(observedNextDay),"observation remains possible across midnight; input still awaits day recheck")
    sampleDay := 1
    ocrHook := (*) => io.dialogMoved := true
    movedDuringOcr := io.Observe()
    GMTest_Assert(!IsObject(movedDuringOcr.candidate),"dialog moving during OCR invalidates the pre-capture target rectangle")
    ocrHook := 0, io.dialogMoved := false
    io.moved := true
    GMTest_Assert(!io.FinalGuard(obs),"main-window movement invalidates old screen coordinates")
    io.moved := false, io.hitRoot := 99
    GMTest_Assert(!io.FinalGuard(obs),"replacement/foreign window at button blocks click")
    io.hitRoot := 24, io.foreign := true, captureKind := ""
    obs := io.Observe()
    GMTest_Assert(!IsObject(obs.candidate) && captureKind = "","foreign overlay prevents capture and input")
    io.foreign := false, obs := io.Observe(), io.intentValue := "STOP"
    GMTest_Assert(!io.FinalGuard(obs),"STOP still blocks owned-modal path")
    io.intentValue := "RUN", io.hitRoot := 12
    io.noOwned := true
    GMTest_Assert(!io.HasVisibleOwnedDialog(),"ordinary main window does not trigger fallback OCR")
    obs := io.Observe()
    GMTest_Assert(obs.targetHwnd = 12,"in-window login remains supported")
    failing := FailingCaptureFixture()
    GMTest_Assert(HandleWutheringAccountLogin(12,[{text:"background"}],1280,720,10000,&failing),"owned capture failure cannot fall through as ordinary login-ready screen")
    failing := FailingStackFixture()
    GMTest_Assert(HandleWutheringAccountLogin(12,[{text:"background"}],1280,720,10000,&failing),"owned-window enumeration failure cannot release account flow")
}
class FailingCaptureFixture extends CaptureFixture {
    Observe() {
        throw Error("fixture capture failed")
    }
}
class FailingStackFixture extends CaptureFixture {
    VisibleStack() {
        throw Error("fixture enumeration failed")
    }
}
class RapidOcr {
    ocr_from_file(args*) {
        global ocrHook
        if IsObject(ocrHook)
            ocrHook.Call()
        return [{text:"KURO GAMES"},{text:"登录",boxPoint:[{x:600,y:410},{x:680,y:410},{x:680,y:450}]}]
    }
}
GetWutheringGameHwnd() => 12
WinGetPID(args*) {
    global surfacePid
    return surfacePid
}
WinGetClass(args*) {
    global surfaceClass
    return surfaceClass
}
GMHost_StableIntent(args*) => "RUN"
GetInteractiveDesktopState() => {ok:true}
RC_UnixMs() {
    global sampleDay
    return sampleDay*86400000
}
GMHost_RecheckStableDay(args*) => {ok:true}
GetWutheringWindowIdentity(args*) => false
MPG_ReadHandleRecord(args*) => 0
ResolveManagedTargetExePath(args*) => ""
MonotonicTickMs() => 10000
WutheringUpdateProcessAlive(args*) => false
RuntimeFiles_NewImagePath(args*) => A_ScriptDir "\absent-capture-test.png"
ImagePutBuffer(args*) => 0
ImagePutFile(args*) => 0
PrepareVerifiedWindowForInput(args*) => true
GetForegroundRelationToTarget(args*) => "exact"
IsSafeInputWindowRelation(args*) => true
RawSleep(args*) => 0
ClickVerifiedWindowClientPoint(args*) => false
ForceActivateWindowForInput(args*) => false
ClickWutheringClientPointForInput(args*) => false
GetWindowAtScreenPoint(args*) => 0
GetWindowRelationToTarget(args*) {
    global surfaceRelation
    return surfaceRelation
}
WriteStep(args*) => 0
WriteLog(args*) => 0
