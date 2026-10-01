#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameUpdateOcrPolicy.ahk
GMTest_Run(TestMaintenanceOcr)
TestMaintenanceOcr() {
    TestKuroSelfUpdateDialog()
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
    for pair in [["更新","update"],["下載","download"],["開始遊戲","play"],["進入遊戲","play"],["进入游戏","play"],["Start Game","play"],["繼續","resume"]] {
        blocks[1].text := pair[1]
        got := GMU_ClassifyLauncher(blocks,identity)
        GMTest_Assert(got.kind = pair[2] && IsObject(got.button),"verified button " pair[1])
    }
    GMTest_Assert(GMU_ClassifyLauncher([OcrFixture("版本更新公告")],identity).kind = "unknown","news body is not button")
    GMTest_Assert(GMU_ClassifyLauncher([{text:"開始遊戲",left:10,top:630,right:200,bottom:680}],identity).kind = "unknown","other row/column ignored")
    GMTest_Assert(GMU_ClassifyLauncher([{text:"進入遊戲",left:10,top:630,right:200,bottom:680}],identity).kind = "unknown","enter-game text outside action ROI is not clicked")
    GMTest_Assert(GMU_ClassifyLauncher([{text:"進入遊戲前請更新",left:1000,top:620,right:1200,bottom:680}],identity).kind = "unknown","enter-game instructions are not an exact action button")
    for pair in [["下載中 25%","downloading"],["安装中 12%","installing"],["Verifying 99%","verifying"]] {
        got := GMU_ClassifyLauncher([{text:pair[1],left:700,top:520,right:1100,bottom:560}],identity)
        GMTest_Assert(got.kind = pair[2] && got.percent != "","stage percent is known only with evidence")
    }
    got := GMU_ClassifyLauncher([
        {text:"↓ 58.9MB/s (127.1MB/25.0GB) 0.50%",left:700,top:540,right:1180,bottom:580},
        {text:"Ⅱ 暫停下載",left:980,top:620,right:1180,bottom:680}
    ],identity)
    GMTest_Assert(got.kind = "downloading" && got.percent = 0.5 && !IsObject(got.button),
        "official launcher pause-download UI proves active download without becoming a clickable action")
    got := GMU_ClassifyLauncher([{text:"❯ 更新",left:1000,top:620,right:1150,bottom:680}],identity)
    GMTest_Assert(got.kind = "update" && IsObject(got.button),
        "harmless leading OCR glyph does not hide the official update action")
    got := GMU_ClassifyLauncher([{text:"下載中",left:700,top:520,right:1100,bottom:560}],identity)
    GMTest_Assert(got.percent = "","unknown percentage stays unknown")
    identity.launcherVersion := "new-oem"
    GMTest_Assert(GMU_ClassifyLauncher(blocks,identity).kind = "unknown","unverified launcher version is not actionable")
    identity.launcherVersion := "fixture-v2", identity.layout := GMU_DefaultKuroLayout("fixture-v2")
    GMTest_Assert(identity.layout.verified && identity.layout.button.left >= 0.65
        && identity.layout.button.top >= 0.7 && identity.layout.button.right <= 1
        && identity.layout.button.bottom <= 1,"built-in official launcher layout is restricted to the lower-right action area")
    blocks[1] := {text:"開始遊戲",left:1000,top:620,right:1150,bottom:680}
    GMTest_Assert(GMU_ClassifyLauncher(blocks,identity).kind = "play",
        "current official launcher version can use the constrained built-in OCR layout")
}

TestKuroSelfUpdateDialog() {
    identity := {key:"launcher-dialog",provider:"kuro",clientWidth:800,clientHeight:500,verified:true,
        launcherVersion:"2.0",layout:GMU_DefaultKuroLayout("2.0"),modal:true}
    context := {text:"發現啟動器新版本，請更新啟動器",left:150,top:100,right:650,bottom:150}
    button := {text:"立即更新",left:460,top:340,right:610,bottom:380}
    result := GMU_ClassifyLauncher([context,button],identity)
    GMTest_Assert(result.kind = "launcher_update" && IsObject(result.button),"trusted self-update dialog has distinct action")
    button.text := "確認"
    GMTest_Assert(GMU_ClassifyLauncher([context,button],identity).kind = "launcher_update","traditional confirm allowed only in explicit self-update prompt")
    GMTest_Assert(GMU_ClassifyLauncher([button],identity).kind = "unknown","generic confirm without updater context is not clicked")
    context.text := "遊戲版本更新公告"
    GMTest_Assert(GMU_ClassifyLauncher([context,button],identity).kind = "unknown","game announcement is not launcher self-update")
    context.text := "啟動器更新中 37%", button.text := "取消"
    result := GMU_ClassifyLauncher([context,button],identity)
    GMTest_Assert(result.kind = "installing" && result.percent = 37 && !IsObject(result.button),"self-update progress is observed without canceling")
    context.text := "啟動器更新完成，請重新啟動啟動器", button.text := "立即重啟"
    result := GMU_ClassifyLauncher([context,button],identity)
    GMTest_Assert(result.kind = "launcher_restart" && IsObject(result.button),"explicit completed self-update can restart its launcher")
    context.text := "啟動器更新失敗，請重試"
    GMTest_Assert(GMU_ClassifyLauncher([context,button],identity).kind != "launcher_restart","failed update never accepts a restart-complete action")
    context.text := "遊戲版本更新公告"
    GMTest_Assert(GMU_ClassifyLauncher([context,button],identity).kind = "unknown","news cannot authorize launcher restart")
    identity.verified := false
    context.text := "發現啟動器新版本，請更新啟動器", button.text := "立即更新"
    GMTest_Assert(GMU_ClassifyLauncher([context,button],identity).kind = "unknown","other program cannot become a self-updater")
}
OcrFixture(text) {
    return {text:text,left:400,top:300,right:900,bottom:350}
}
