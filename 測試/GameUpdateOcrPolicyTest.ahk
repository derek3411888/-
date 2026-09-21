#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameUpdateOcrPolicy.ahk
GMTest_Run(TestMaintenanceOcr)
TestMaintenanceOcr() {
    identity := {key:"game-p1-h1",provider:"kuro",clientWidth:1280,clientHeight:720,verified:true}
    for text in ["無法連接伺服器，請檢查網路","網路異常","连接超时","正在更新游戏","維護公告","Server connection timed out",""] {
        result := GMU_ClassifyMaintenance([OcrFixture(text)],identity)
        GMTest_Assert(!result.confirmed,"not maintenance: " text)
    }
    for text in ["伺服器維護中，暫時無法登入","服务器正在维护，请稍后重试","The server is under maintenance.","Server maintenance is in progress"] {
        candidate := GMU_ClassifyMaintenance([OcrFixture(text)],identity)
        GMTest_Assert(candidate.confirmed,"explicit maintenance candidate: " text)
    }
    candidate := GMU_ClassifyMaintenance([OcrFixture("伺服器維護中")],identity)
    first := GMU_ConfirmMaintenance(0,candidate,1000,"frame-1")
    GMTest_Assert(!first.confirmed && first.count = 1,"one frame never confirmed")
    repeat := GMU_ConfirmMaintenance(first,candidate,1500,"frame-1")
    GMTest_Assert(!repeat.confirmed,"same screenshot cannot count twice")
    stable := GMU_ConfirmMaintenance(first,candidate,1500,"frame-2")
    GMTest_Assert(stable.confirmed,"two distinct consistent captures")
    identity.key := "game-p2-h1", candidate := GMU_ClassifyMaintenance([OcrFixture("伺服器維護中")],identity)
    GMTest_Assert(!GMU_ConfirmMaintenance(first,candidate,1500,"frame-3").confirmed,"same HWND reused by other PID resets evidence")
    identity.key := "game-p1-h2", candidate := GMU_ClassifyMaintenance([OcrFixture("伺服器維護中")],identity)
    GMTest_Assert(!GMU_ConfirmMaintenance(first,candidate,1500,"frame-4").confirmed,"recreated dialog resets identity")
    identity.key := "game-p1-h1", candidate := GMU_ClassifyMaintenance([OcrFixture("伺服器維護中")],identity)
    GMTest_Assert(!GMU_ConfirmMaintenance(first,candidate,20000,"frame-5").confirmed,"stale observations cannot combine")
    identity.verified := false
    GMTest_Assert(!GMU_ClassifyMaintenance([OcrFixture("伺服器維護中")],identity).confirmed,"wrong PID or failed capture cannot certify maintenance")
    identity.verified := true
    GMTest_Assert(!GMU_ClassifyMaintenance([{text:"伺服器維護中",left:5,top:5,right:300,bottom:30}],identity).confirmed,"announcement outside game prompt ROI ignored")
    GMTest_Assert(!GMU_ClassifyMaintenance([],identity).confirmed,"empty capture not maintenance")
    GMTest_Assert(!GMU_ConfirmMaintenance(stable,{confirmed:false},2000,"frame-6").confirmed,"disappeared notice resets")
    ; A synthetic layout is permitted only in this fixture; no production layout invented.
    identity := {key:"launcher-p3-h3",provider:"kuro",clientWidth:1280,clientHeight:720,verified:true,launcherVersion:"fixture-v1"}
    blocks := [{text:"更新",left:1000,top:620,right:1150,bottom:680}]
    GMTest_Assert(GMU_ClassifyLauncher(blocks,identity).kind = "unknown","no real verified layout means unknown")
    identity.layout := {verified:true,launcherVersion:"fixture-v1",button:{left:0.7,top:0.8,right:0.98,bottom:0.98},status:{left:0.5,top:0.65,right:0.98,bottom:0.95}}
    for pair in [["更新","update"],["下載","download"],["開始遊戲","play"],["Start Game","play"],["繼續","resume"]] {
        blocks[1].text := pair[1]
        got := GMU_ClassifyLauncher(blocks,identity)
        GMTest_Assert(got.kind = pair[2] && IsObject(got.button),"verified button " pair[1])
    }
    GMTest_Assert(GMU_ClassifyLauncher([OcrFixture("版本更新公告")],identity).kind = "unknown","news body is not button")
    GMTest_Assert(GMU_ClassifyLauncher([{text:"開始遊戲",left:10,top:630,right:200,bottom:680}],identity).kind = "unknown","other row/column ignored")
    for pair in [["下載中 25%","downloading"],["安装中 12%","installing"],["Verifying 99%","verifying"]] {
        got := GMU_ClassifyLauncher([{text:pair[1],left:700,top:520,right:1100,bottom:560}],identity)
        GMTest_Assert(got.kind = pair[2] && got.percent != "","stage percent is known only with evidence")
    }
    got := GMU_ClassifyLauncher([{text:"下載中",left:700,top:520,right:1100,bottom:560}],identity)
    GMTest_Assert(got.percent = "","unknown percentage stays unknown")
    identity.launcherVersion := "new-oem"
    GMTest_Assert(GMU_ClassifyLauncher(blocks,identity).kind = "unknown","unverified launcher version is not actionable")
}
OcrFixture(text) {
    return {text:text,left:400,top:300,right:900,bottom:350}
}
