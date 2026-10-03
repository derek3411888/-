#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\SynthesisMenuRuntime.ahk
global ocrEngine := 0
global logger := 0
global captureClock := 1000
GMTest_Run(TestCaptureAge)

; Only OS capture/OCR are replaced; exercise the unchanged runtime Observe().
; These doubles have no windows, keys, mouse, real image files or game effects.
ImagePutBuffer(spec) => {width:1280,height:720}
ImagePutFile(spec,path) {
}
RuntimeFiles_NewImagePath(prefix) => TestRuntime_NewFile("synthesis-capture-age",prefix,"png")
class SlowOcrBoundary {
    ocr_from_file(path, unused := "", options := true) {
        global captureClock
        captureClock += 6000
        return [{text:"数据坞",boxPoint:[{x:900,y:300},{x:990,y:300},{x:990,y:325}]}]
    }
}
class CaptureAgeRuntime extends SynthesisMenuIo {
    __New() {
        this.sequence := 0, this.key := "fixture-identity", this.hwnd := 1
    }
    Now() {
        global captureClock
        return captureClock
    }
    Alive() => true
    HudReady(frame) => false
}
TestCaptureAge() {
    global ocrEngine, captureClock
    ocrEngine := SlowOcrBoundary(), captureClock := 1000
    runtime := CaptureAgeRuntime()
    obs := runtime.Observe()
    GMTest_Assert(obs.valid, "test must reach successful real Observe output")
    GMTest_Assert(obs.capturedAt = 1000 && runtime.Now()-obs.capturedAt = 6000,
        "capture timestamp must precede six-second OCR latency, not start after it")
}
