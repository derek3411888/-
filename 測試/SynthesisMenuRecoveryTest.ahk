#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include *i ..\payload\SynthesisMenuRecovery.ahk
#Warn VarUnset, Off
GMTest_Run(TestSynthesisMenuRecovery)

SBlock(text, x, y, w := 100, h := 24) {
    return {text:text, boxPoint:[{x:x,y:y},{x:x+w,y:y},{x:x+w,y:y+h},{x:x,y:y+h}]}
}
SDialog() {
    ; Hand-transcribed from the user's 1280x720 screenshot, 2026-10-03.
    return [SBlock("提示",300,222,46), SBlock("确认离开",593,337,82),
        SBlock("重新挑战",391,443,80), SBlock("确认",822,443,40)]
}
TestSynthesisMenuRecovery() {
    GMTest_Assert(IsSet(SMR_Classify), "missing dungeon-exit handler: ESC must not toggle away the exit confirmation")
    GMTest_Assert(IsSet(SMR_InputFresh), "input freshness must include capture and OCR latency")
    stamp := {valid:true,key:"game-1",capturedAt:1000}
    GMTest_Assert(SMR_InputFresh(stamp,"game-1",5800), "fresh capture within budget is allowed")
    GMTest_Assert(!SMR_InputFresh(stamp,"game-1",6600), "foreground acquisition cannot extend screenshot lifetime")
    GMTest_Assert(!SMR_InputFresh(stamp,"game-1",12000), "slow OCR makes original screenshot stale")
    GMTest_Assert(!SMR_InputFresh(stamp,"game-2",2000), "other identity cannot reuse screenshot")
    GMTest_Assert(!SMR_InputFresh(stamp,"game-1",500), "future capture timestamp fails closed")
    got := SMR_Classify(SDialog(),1280,720)
    GMTest_Assert(got.kind = "exit" && got.x = 842 && got.y = 455, "observed dialog selects right confirmation, never retry")
    trad := [SBlock("提示",300,222,46),SBlock("確認離開",593,337,82),
        SBlock("重新挑戰",391,443,80),SBlock("確定",822,443,40)]
    GMTest_Assert(SMR_Classify(trad,1280,720).kind = "exit", "traditional wording supported")
    for text in ["确认退出游戏", "确认删除声骸", "是否购买", "确认离开队伍", "确认离开并删除记录"] {
        blocks := SDialog(), blocks[2].text := text
        GMTest_Assert(SMR_Classify(blocks,1280,720).kind != "exit", "reject unrelated confirmation: " text)
    }
    blocks := SDialog(), blocks.RemoveAt(3)
    GMTest_Assert(SMR_Classify(blocks,1280,720).kind = "blocked", "missing dungeon companion fails closed")
    blocks := SDialog(), blocks[4] := SBlock("确认",391,443,40)
    GMTest_Assert(SMR_Classify(blocks,1280,720).kind = "blocked", "wrong button side is not actionable")
    blocks := SDialog(), blocks.Push(SBlock("确认",900,443,40))
    GMTest_Assert(SMR_Classify(blocks,1280,720).kind = "blocked", "ambiguous confirmation cannot click")
    blocks := SDialog(), blocks.Push(SBlock("设置",1050,80))
    GMTest_Assert(SMR_Classify(blocks,1280,720).kind = "exit", "background settings label cannot hide a modal")
    GMTest_Assert(SMR_Classify([SBlock("设置",1050,80)],1280,720).kind = "unknown", "settings alone is not synthesis menu")
    GMTest_Assert(SMR_Classify([SBlock("数据坞",900,300)],1280,720).kind = "menu", "actual synthesis destination is menu evidence")
    GMTest_Assert(SMR_Classify(false,1280,720).kind = "invalid", "failed OCR is not a clear world frame")
    GMTest_Assert(SMR_Classify([],1280,720).kind = "invalid", "empty loading frame is not world evidence")
    GMTest_Assert(SMR_Classify([SBlock("确认离开",593,337,82)],1280,720).kind = "blocked", "partial exit prompt waits instead of ESC-cancelling")
    for extra in ["确认离开", "额外文字"] {
        partial := [SBlock("确认离开",593,337,82), SBlock(extra,590,365,90)]
        GMTest_Assert(SMR_Classify(partial,1280,720).kind = "blocked", "extra center OCR block must not make exit prompt eligible for ESC")
        ambiguous := SDialog(), ambiguous.Push(partial[2])
        GMTest_Assert(SMR_Classify(ambiguous,1280,720).kind = "blocked", "extra center context cannot authorize exit click")
    }
    blocks := SDialog()
    for b in blocks
        for p in b.boxPoint
            p.x *= 1.5, p.y *= 1.5
    got := SMR_Classify(blocks,1920,1080)
    GMTest_Assert(got.kind = "exit" && got.x = 1263 && got.y = 682.5, "scaled screenshot yields scaled OCR target")

    normal := SMenuFixture(["world","menu","menu"])
    GMTest_Assert(SMR_OpenMenu(normal) && normal.actions = "esc", "normal path preserved without click")
    dungeon := SMenuFixture(["world","exit","exit","loading","world","world","world","menu","menu"])
    GMTest_Assert(SMR_OpenMenu(dungeon) && dungeon.actions = "esc,confirm,esc", "exit once then wait for world before opening synthesis menu")
    initial := SMenuFixture(["exit","exit","world","world","world","world","menu","menu"])
    GMTest_Assert(SMR_OpenMenu(initial) && initial.actions = "confirm,esc", "already-open exit prompt is not dismissed")
    stickyDialog := SMenuFixture(["exit","exit"])
    GMTest_Assert(!SMR_OpenMenu(stickyDialog,6000) && stickyDialog.actions = "confirm", "persistent dialog never double-clicked or cancelled with ESC")
    blocked := SMenuFixture(["blocked"])
    GMTest_Assert(!SMR_OpenMenu(blocked,3000) && blocked.actions = "", "unrecognized modal never clicked or escaped")
    changed := SMenuFixture(["exit","wrong_identity"])
    GMTest_Assert(!SMR_OpenMenu(changed) && changed.actions = "", "identity change cancels before click")
    denied := SMenuFixture(["exit","exit"]), denied.allowInput := false
    GMTest_Assert(!SMR_OpenMenu(denied) && denied.actions = "", "foreground failure aborts safely")
    loading := SMenuFixture(["exit","exit","loading"])
    GMTest_Assert(!SMR_OpenMenu(loading,6000) && loading.actions = "confirm", "loading cannot be success or receive ESC")
    emptyLoading := SMenuFixture(["exit","exit","empty","world","world","world","menu","menu"])
    GMTest_Assert(SMR_OpenMenu(emptyLoading) && emptyLoading.actions = "confirm,esc", "empty OCR during return loading waits without failing or sending keys")
    changedTarget := SMenuFixture(["exit","moved_exit","world","world","menu","menu"])
    GMTest_Assert(!SMR_OpenMenu(changedTarget,1800) && !InStr(changedTarget.actions,"confirm"), "inconsistent popup coordinates cannot authorize click")
}

class SMenuFixture {
    __New(frames) {
        this.frames := frames, this.index := 0, this.tick := 0, this.actions := "", this.allowInput := true
    }
    Now() => this.tick
    Wait(ms) => this.tick += ms
    Log(message) {
    }
    Observe() {
        this.index += 1
        kind := this.frames[Min(this.index,this.frames.Length)]
        candidate := kind = "exit" || kind = "moved_exit" ? SMR_Classify(SDialog(),1280,720)
            : {kind:kind = "world" || kind = "loading" ? "unknown" : kind = "empty" ? "invalid" : kind}
        if kind = "moved_exit"
            candidate.x += 100
        return {key:kind = "wrong_identity" ? "other-process" : "game-1",frame:this.index,
            candidate:candidate,worldReady:kind = "world",valid:kind != "invalid"}
    }
    SendEsc(observation) => this.Input("esc")
    ConfirmExit(observation) => this.Input("confirm")
    Input(action) {
        if !this.allowInput
            return false
        this.actions .= (this.actions = "" ? "" : ",") action
        return true
    }
}
