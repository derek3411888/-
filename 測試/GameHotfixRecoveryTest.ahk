#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameHotfixRecovery.ahk
GMTest_Run(TestHotfix)

HotfixBlock(text,x,y) => {text:text,boxPoint:[{x:x-30,y:y-12},{x:x+30,y:y-12},{x:x+30,y:y+12}]}
class HotfixFixture {
    tick := 0
    sent := false
    clicks := 0
    frame := 0
    state := "RUN"
    exits := true
    stale := false
    delayedStop := false
    Now() => this.tick
    Wait(ms) {
        this.tick += ms
        if this.delayedStop && this.tick >= 1200
            this.state := "STOP"
    }
    Intent() => this.state
    Alive() => !(this.sent && this.exits && this.tick >= 1000)
    Observe() => {valid:true,frame:++this.frame,capturedAt:this.tick-(this.stale ? 6000 : 0),candidate:{x:840,y:454,label:"确认"}}
    Confirm(obs) {
        this.clicks++
        return true
    }
}
TestHotfix() {
    for text in ["更新完成，游戏即将重启。","更新完成，遊戲即將重啟。","请重新启动游戏","請重新啟動遊戲"] {
        candidate := GH_Classify([HotfixBlock(text,640,360),HotfixBlock("确认",840,454)],1280,720)
        GMTest_Assert(IsObject(candidate) && candidate.x = 840,"completed hotfix selects the observed confirmation, both locales")
    }
    GMTest_Assert(!GH_Classify([HotfixBlock("確認離開",640,360),HotfixBlock("确认",840,454)],1280,720),"dungeon exit is not a hotfix")
    GMTest_Assert(!GH_Classify([HotfixBlock("更新完成",640,360),HotfixBlock("确认",440,454),HotfixBlock("退出",840,454)],1280,720),"ambiguous buttons do not authorize input")
    GMTest_Assert(!GH_Classify([HotfixBlock("正在更新",640,360),HotfixBlock("退出",840,454)],1280,720),"in-progress download is never closed")
    GMTest_Assert(!GH_Classify([HotfixBlock("尚未更新完成",640,360),HotfixBlock("退出",840,454)],1280,720),"negative completion text cannot authorize exit")
    io := HotfixFixture()
    GMTest_Assert(GH_ConfirmAndWait(io,3000) = "exited" && io.clicks = 1,"completed patch needs one confirmation and verified original exit")
    io := HotfixFixture(), io.exits := false
    GMTest_Assert(GH_ConfirmAndWait(io,1600) = "waiting" && io.clicks = 1,"click without process exit is not success")
    GMTest_Assert(GH_ConfirmAndWait(io,1600) = "waiting" && io.clicks = 1,"later observation chunks cannot repeat the click")
    io := HotfixFixture(), io.stale := true
    GMTest_Assert(GH_ConfirmAndWait(io,1600) = "waiting" && io.clicks = 0,"slow OCR cannot authorize stale input")
    io := HotfixFixture(), io.state := "STOP"
    GMTest_Assert(GH_ConfirmAndWait(io) = "stopped" && io.clicks = 0,"STOP forbids confirmation")
    io := HotfixFixture(), io.state := "PAUSE", io.delayedStop := true
    GMTest_Assert(GH_ConfirmAndWait(io,500) = "stopped" && io.clicks = 0,"PAUSE stays online without timeout or input and STOP exits it")
    io := HotfixFixture(), io.exits := false, io.delayedStop := true
    GMTest_Assert(GH_ConfirmAndWait(io,3000) = "stopped" && io.clicks = 1,"STOP interrupts post-confirmation wait without relaunch")
}
