#Requires AutoHotkey v2.0

; Completed in-game hotfix only. Official version-day gating remains upstream.
GH_IsCompletionText(text) {
    return RegExMatch(RegExReplace(text,"\s",""),"^(更新完成[，,。.!！]?((游戏|遊戲)即[将將]重[启啟][。.!！]?)?|(游戏|遊戲)即[将將]重[启啟][。.!！]?|请重新启动游戏[。.!！]?|請重新啟動遊戲[。.!！]?)$") != 0
}

GH_Classify(blocks,width,height) {
    if !(blocks is Array) || width < 500 || height < 280
        return 0
    context := false, buttons := []
    for block in blocks {
        if !block.HasOwnProp("text")
            continue
        text := RegExReplace(block.text,"\s","")
        if GH_IsCompletionText(text)
            context := true
        if !RegExMatch(text,"^(确认|確認|确定|確定|退出)$") || !block.HasOwnProp("boxPoint")
            continue
        try {
            p := block.boxPoint
            x := (p[1].x+p[3].x)/2, y := (p[1].y+p[3].y)/2
            if p[1].x >= 0 && p[1].y >= 0 && p[3].x <= width && p[3].y <= height
                && p[3].x > p[1].x && p[3].y > p[1].y
                && x >= width*0.2 && x <= width*0.8 && y >= height*0.4 && y <= height*0.85
                buttons.Push({x:Round(x),y:Round(y),label:text})
        }
    }
    return context && buttons.Length = 1 ? buttons[1] : 0
}

GH_Same(first,second) {
    return IsObject(first) && IsObject(second) && first.label = second.label
        && Abs(first.x-second.x) <= 12 && Abs(first.y-second.y) <= 12
}

; One click per held game process. A completed mouse call is not exit evidence.
GH_ConfirmAndWait(io,timeoutMs := 30000) {
    deadline := io.Now()+timeoutMs, previous := 0
    while io.Now() < deadline {
        intent := io.Intent()
        if intent = "STOP"
            return "stopped"
        if intent != "RUN" {
            pausedAt := io.Now(), previous := 0
            io.Wait(250)
            deadline += Max(0,io.Now()-pausedAt)
            continue
        }
        alive := io.Alive()
        if alive == "unknown"
            return "unverified"
        if !alive
            return io.sent ? "exited" : "changed"
        if !io.sent {
            obs := io.Observe()
            if io.Now() >= deadline
                break
            if obs.valid && io.Now()-obs.capturedAt >= 0 && io.Now()-obs.capturedAt <= 5000 {
                if IsObject(previous) && obs.frame != previous.frame
                    && obs.capturedAt-previous.capturedAt >= 300
                    && obs.capturedAt-previous.capturedAt <= 5000
                    && GH_Same(previous.candidate,obs.candidate) && io.Intent() = "RUN" {
                    if io.Confirm(obs)
                        io.sent := true
                }
                previous := obs
            } else
                previous := 0
        }
        io.Wait(400)
    }
    return "waiting"
}
