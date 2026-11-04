#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include ..\payload\OkwwInstalledLaunch.ahk

Check(value, label) {
    if !value
        throw Error(label)
}
Block(text, x := 420, y := 150) {
    return {text:text, boxPoint:[{x:x,y:y},{x:x+140,y:y},{x:x+140,y:y+30},{x:x,y:y+30}]}
}
Frame(text := "啟動應用程式") {
    return {ok:true, reason:"", hwnd:11, pid:12, path:"D:\ok-ww\ok-ww.exe", started:"1234",
        kind:"upgrade", x:100, y:200, w:800, h:600, capturedAt:100, blocks:[Block(text)]}
}
DoneFrame() {
    f := Frame("完成")
    f.blocks.Push({text:"處理完成。請檢視日誌並點選「完成」。"})
    return f
}
global frames := [], frameIndex := 0, clicks := 0, actions := "", aborted := false, rejectClick := false
CaptureFixture() {
    global frameIndex
    frameIndex++
    return frames[Min(frameIndex, frames.Length)]
}
ClickFixture(snapshot, point) {
    global clicks, actions
    Check(point.x = 490 && point.y = 165, "client coordinates preserved")
    clicks++
    actions .= (point.HasOwnProp("action") ? point.action : "start") "|"
    return !rejectClick
}
RunCase(input, abort := false, reject := false) {
    global frames := input, frameIndex := 0, clicks := 0, actions := "", aborted := abort, rejectClick := reject
    return OKWW_StartInstalled(CaptureFixture, ClickFixture, (*) => aborted, (*) => false, 6)
}
try {
    for text in ["啟動應用程式", "启动应用程序", "启动应用", "啟動應用"]
        Check(IsObject(OKWW_InstalledLaunchButton(Frame(text))), "supports installed label " text)
    for text in ["自動啟動應用程式", "啟動應用程式失敗", "停止應用程式", "升级APP", ""]
        Check(!IsObject(OKWW_InstalledLaunchButton(Frame(text))), "rejects non-button " text)
    f := Frame(), f.blocks.Push(Block("啟動應用程式", 20, 30))
    Check(!IsObject(OKWW_InstalledLaunchButton(f)), "ambiguous buttons cannot click")
    f := Frame(), f.blocks := [Block("啟動應用程式", 790)]
    Check(!IsObject(OKWW_InstalledLaunchButton(f)), "out-of-bounds cannot click")
    f := Frame(), f.kind := "final"
    Check(!IsObject(OKWW_InstalledLaunchButton(f)), "only launcher eligible")
    f := Frame(), f.blocks.Push({text:"正在下載"})
    Check(!IsObject(OKWW_InstalledLaunchButton(f)), "busy launcher cannot click")
    f := Frame(), f.w := 1100, f.h := 800
    f.blocks := [Block("動雁用程式",740,60),{text:"已安装"},{text:"使用 PyAppify 1.2.3 打包"}]
    Check(IsObject(OKWW_InstalledLaunchButton(f)), "recorded PyAppify OCR confusion requires installed context and upper-right ROI")
    f.blocks.Pop()
    Check(!IsObject(OKWW_InstalledLaunchButton(f)), "OCR confusion without PyAppify context is rejected")
    f.blocks.Push({text:"使用 PyAppify 1.2.3 打包"}), f.blocks[1] := Block("動雁用程式",20,300)
    Check(!IsObject(OKWW_InstalledLaunchButton(f)), "OCR confusion outside start-button ROI is rejected")
    ready := {ok:false, reason:"final_ready"}
    Check(RunCase([DoneFrame(),DoneFrame(),Frame(),Frame(),ready]) = "final_ready"
        && actions = "complete|start|", "update completion must click Done then Start before final handoff")
    Check(RunCase([DoneFrame()]) = "final_timeout" && actions = "complete|",
        "persistent completion screen is clicked once and is not final success")
    Check(RunCase([Frame("完成")]) = "not_found" && clicks = 0,
        "Done without update completion context cannot click")
    f := DoneFrame(), f.blocks.RemoveAt(1), f.blocks.Push(Block("啟動應用程式"))
    Check(RunCase([f]) = "not_found" && clicks = 0, "completion instruction is not a button or permission to click Start behind it")
    f := DoneFrame(), f.blocks.Push(Block("完成",20,30))
    Check(RunCase([f]) = "not_found" && clicks = 0, "ambiguous Done buttons cannot click")
    f := DoneFrame(), f.blocks.Push({text:"正在下載"})
    Check(RunCase([f]) = "final_timeout" && actions = "complete|", "historical download log must not block explicit completed dialog")
    f := DoneFrame(), f.blocks[1] := Block("完成",790)
    Check(RunCase([f]) = "not_found" && clicks = 0, "Done outside client cannot click")
    for badPoint in [0, {x:420}, {x:"bad",y:150}] {
        f := DoneFrame(), f.blocks[1].boxPoint[1] := badPoint
        Check(RunCase([f]) = "not_found" && clicks = 0, "malformed completion geometry fails closed")
    }
    f := DoneFrame(), f.blocks := [Block("完成"),{text:"處理完成。"},{text:"請檢視日誌並點選「完成」。"}]
    Check(RunCase([f]) = "final_timeout" && actions = "complete|", "split completion instruction still recognizes exact button")
    Check(RunCase([DoneFrame(),DoneFrame(),ready]) = "final_ready" && actions = "complete|", "completion may auto-start real final")
    f := DoneFrame(), f.started := "5678"
    Check(RunCase([DoneFrame(),f,DoneFrame(),f,DoneFrame(),f]) = "not_found" && clicks = 0,
        "completion also requires stable process identity")
    Check(RunCase([DoneFrame()], true) = "handoff_aborted" && clicks = 0, "cancel blocks completion input")
    Check(RunCase([DoneFrame()], false, true) = "click_rejected" && clicks = 1, "rejected completion is not retried")
    Check(RunCase([DoneFrame(),{ok:false,reason:"capture_failed"},DoneFrame(),ready]) = "final_ready" && clicks = 0,
        "completion failed capture resets stability")
    Check(RunCase([Frame(), Frame(), Frame(), ready]) = "final_ready" && clicks = 1,
        "launch once then wait for real handoff despite launcher remaining")
    Check(RunCase([ready]) = "final_ready" && clicks = 0, "auto-started final needs no click")
    Check(RunCase([Frame()]) = "final_timeout" && clicks = 1, "click alone is not success")
    Check(RunCase([Frame()], true) = "handoff_aborted" && clicks = 0, "cancel before input")
    Check(RunCase([Frame()], false, true) = "click_rejected" && clicks = 1, "rejected click is not retried")
    Check(RunCase([{ok:false,reason:"capture_failed"}]) = "not_found" && clicks = 0, "capture failure does not click")
    f := Frame(), f.started := "5678"
    Check(RunCase([Frame(),f,Frame(),f,Frame(),f]) = "not_found" && clicks = 0, "PID reuse breaks stability")
    Check(RunCase([Frame(),{ok:false,reason:"capture_failed"},Frame(),ready]) = "final_ready" && clicks = 0,
        "failed capture resets stability")
    Check(RunCase([{ok:false,reason:"final_handoff_failed"}]) = "final_handoff_failed" && clicks = 0,
        "handoff failure is terminal")
    FileAppend("PASS: installed launcher policy and bounded flow`n", "*")
} catch as e {
    FileAppend(e.Message "`n", "**")
    ExitApp(1)
}
ExitApp(0)
