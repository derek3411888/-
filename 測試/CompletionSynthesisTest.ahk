#Requires AutoHotkey v2.0
#Include *i ..\payload\CompletionSynthesis.ahk
#Warn VarUnset, Off
try {
    Assert(IsSet(CS_Run), "missing completion synthesis controller")
    f := FinishIo()
    Assert(CS_Run(f,"Asia|reward") = "success", "receipt plus zero exit must permit finish")
    Assert(f.launches = 1 && f.saved.stage = "success", "success is durable")
    Assert(CS_Run(f,"Asia|reward") = "success" && f.launches = 1, "repeat tick never repeats synthesis")
    f := FinishIo(), f.receiptText := ""
    Assert(CS_Run(f,"k") = "failed", "process absence without receipt cannot complete")
    Assert(CS_Run(f,"k") = "blocked" && f.launches = 1, "failure cannot relaunch each tick")
    f := FinishIo(), f.code := 2
    Assert(CS_Run(f,"k") = "failed", "success receipt cannot override nonzero exit")
    f := FinishIo(), f.receiptText := "another-token|success"
    Assert(CS_Run(f,"k") = "failed", "foreign or stale receipt is rejected")
    f := FinishIo(), f.exitAt := 100000
    Assert(CS_Run(f,"k",1000) = "failed" && f.cancelled, "timeout stops exact child and never completes")
    Assert(CS_Run(f,"k") = "blocked" && f.launches = 1, "timeout cannot repeat input")
    f := FinishIo(), f.exitAt := 100000, f.cancelWorks := false
    Assert(CS_Run(f,"k",1000) = "failed" && f.saved.stage = "uncertain", "unconfirmed cancellation preserves possible live ownership")
    Assert(CS_Run(f,"new-day") = "blocked" && f.launches = 1, "unknown child cannot be replaced on a new day")
    f := FinishIo(), f.desired := "PAUSE"
    Assert(CS_Run(f,"k") = "paused" && f.launches = 0, "pause before reservation cannot launch")
    f := FinishIo(), f.desired := "STOP"
    Assert(CS_Run(f,"k") = "stopped" && f.launches = 0, "stop cannot launch")
    f := FinishIo(), f.saved := {key:"k",token:"old",stage:"running"}
    Assert(CS_Run(f,"k") = "blocked" && f.launches = 0, "crash recovery never duplicates an unproven child")
    f := FinishIo(), f.saved := {key:"other-server",token:"old",stage:"running"}
    Assert(CS_Run(f,"k") = "blocked" && f.launches = 0, "unconfirmed child from another cycle cannot be replaced")
    f := FinishIo(), f.saved := {key:"old-day",token:"old",stage:"failed"}
    Assert(CS_Run(f,"new-day") = "success", "confirmed prior-cycle failure cannot permanently block new cycles")
    f := FinishIo(), f.persist := false
    Assert(CS_Run(f,"k") = "failed" && f.launches = 0, "failed write-ahead prevents launch")
    f := FinishIo(), f.prepared := false
    Assert(CS_Run(f,"k") = "failed" && f.launches = 0, "LRMCAI ownership failure prevents competing input")
    f := FinishIo(), f.pauseInPrepare := true
    Assert(CS_Run(f,"k") = "paused" && f.launches = 0, "pause during Prepare defers rather than poisons attempt")
    f.desired := "RUN", f.pauseInPrepare := false
    Assert(CS_Run(f,"k") = "success" && f.launches = 1, "resume after Prepare pause launches exactly once")
    f := FinishIo(), f.stopAt := 400, f.exitAt := 100000
    Assert(CS_Run(f,"k") = "stopped" && f.cancelled, "STOP cancels held child and preserves failure")
    f := FinishIo(), f.pauseAt := 200, f.resumeAt := 1200, f.exitAt := 1400
    Assert(CS_Run(f,"k",1000) = "success" && f.launches = 1, "pause keeps one child and excludes paused time from active timeout")
    Assert(!CS_LeaseAllowsInput("token|RUN|1000|0","token",4000), "expired parent heartbeat cannot allow input")
    Assert(!CS_LeaseAllowsInput("token|PAUSE|1000|0","token",1000), "PAUSE cannot allow input")
    Assert(!CS_LeaseAllowsInput("other|RUN|1000|0","token",1000), "other attempt cannot allow input")
    Assert(CS_LeaseAllowsInput("token|RUN|1000|0","token",1500), "fresh owned RUN allows input")
    Assert(!CS_LeaseAllowsInput("token|RUN|2000|0","token",1000), "future lease is not trusted")
    Assert(!CS_LeaseAllowsInput("token|RUN|1000","token",1500),"missing pause budget cannot permit completion input")
    Assert(IsSet(CS_GameIdentityMatches),"missing verified game identity binding")
    expected := {hwnd:11,pid:22,started:"134210000000000001",path:"E:\verified\Client-Win64-Shipping.exe"}
    actual := expected.Clone()
    Assert(CS_GameIdentityMatches(expected,actual),"exact parent-verified game identity accepted")
    for field in ["hwnd","pid","started","path"] {
        actual := expected.Clone(), actual.%field% := field = "path" ? "E:\other\Client-Win64-Shipping.exe" : "999"
        Assert(!CS_GameIdentityMatches(expected,actual),"changed " field " cannot receive synthesis input")
    }
    FileAppend("PASS: completion synthesis 35 assertions`n","*")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL: " err.Message " | " err.File ":" err.Line "`n","**")
    ExitApp(1)
}
Assert(ok,message) {
    if !ok
        throw Error(message)
}
class FinishIo {
    __New() {
        this.saved := 0, this.tick := 0, this.launches := 0, this.cancelled := false
        this.receiptText := "token|success", this.code := 0, this.exitAt := 600
        this.desired := "RUN", this.persist := true, this.prepared := true
        this.stopAt := -1, this.pauseAt := -1, this.resumeAt := -1, this.pauseInPrepare := false
        this.cancelWorks := true
    }
    Now() => this.tick
    Wait(ms) => this.tick += ms
    Control() {
        if this.stopAt >= 0 && this.tick >= this.stopAt
            return "STOP"
        if this.pauseAt >= 0 && this.tick >= this.pauseAt && this.tick < this.resumeAt
            return "PAUSE"
        return this.desired
    }
    Load(key) => this.saved
    Token() => "token"
    Save(state) {
        if !this.persist
            return false
        this.saved := state.Clone()
        return true
    }
    Prepare() {
        if this.pauseInPrepare
            this.desired := "PAUSE"
        return this.prepared
    }
    Launch(state) {
        this.launches += 1
        return {owned:true}
    }
    Poll(child) => {exited:this.tick >= this.exitAt,code:this.code}
    Receipt(state) => this.receiptText
    Heartbeat(state,control) {
    }
    Cancel(child) {
        if !this.cancelWorks
            throw Error("cancel unconfirmed")
        this.cancelled := true
        return true
    }
    Log(message) {
    }
}
