#Requires AutoHotkey v2.0
#Include ..\payload\SynthesisMenuRecovery.ahk
try {
    fixture := PauseBudgetIo()
    if !SMR_OpenMenu(fixture,90000)
        throw Error("120-second PAUSE consumed the 90-second active menu budget")
    if !SMR_OpenMenu(StaleAfterPauseIo(),90000)
        throw Error("pause-invalidated screenshot must be recaptured instead of poisoning the attempt")
    capturePause := PausedAfterCaptureIo()
    if !SMR_OpenMenu(capturePause,90000) || capturePause.escCalls != 0
        throw Error("PAUSE during post-capture gate cannot reuse pre-pause capture or send Esc")
    if SMR_InputFresh({valid:true,key:"g",capturedAt:0},"g",120000)
        throw Error("pause-excluding budget must never extend physical screenshot freshness")
    FileAppend("PASS: 120s PAUSE preserves menu budget but not screenshot freshness`n","*")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL: " err.Message "`n","**")
    ExitApp(1)
}
class StaleAfterPauseIo extends PauseBudgetIo {
    Observe() {
        obs := super.Observe()
        obs.pauseEpoch := this.pausedMs
        return obs
    }
    SendEsc(obs) {
        super.SendEsc(obs)
        return false
    }
    RetryAfterPause(obs) => obs.pauseEpoch != this.pausedMs
}
class PausedAfterCaptureIo extends PauseBudgetIo {
    __New() {
        super.__New()
        this.escCalls := 0
    }
    Observe() {
        obs := super.Observe(), obs.pauseEpoch := this.pausedMs, obs.capturedAt := this.tick
        return obs
    }
    BudgetNow() {
        if this.frame = 1 && !this.pausedMs
            this.tick += 120000, this.pausedMs += 120000
        return super.BudgetNow()
    }
    RetryAfterPause(obs) => obs.pauseEpoch != this.pausedMs
    SendEsc(obs) {
        this.escCalls += 1
        return true
    }
}
class PauseBudgetIo {
    __New() {
        this.tick := 0, this.pausedMs := 0, this.frame := 0
    }
    Now() => this.tick
    BudgetNow() => this.tick-this.pausedMs
    Wait(ms) => this.tick += ms
    Observe() {
        this.frame += 1
        return {valid:true,key:"g",frame:this.frame,candidate:{kind:this.frame = 1 ? "unknown" : "menu"},worldReady:false}
    }
    SendEsc(obs) {
        this.tick += 120000, this.pausedMs += 120000
        return true
    }
    ConfirmExit(obs) => false
    Log(message) {
    }
}
