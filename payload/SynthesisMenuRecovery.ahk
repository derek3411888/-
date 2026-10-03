#Requires AutoHotkey v2.0

SMR_Text(text) {
    for pair in [["確認","确认"],["確定","确定"],["離開","离开"],["挑戰","挑战"],
        ["數據塢","数据坞"],["數據屋","数据坞"],["取消","取消"]]
        text := StrReplace(text,pair[1],pair[2])
    return RegExReplace(text,"[\s。！？!?]+","")
}

SMR_Classify(blocks, width, height) {
    if !(blocks is Array) || !blocks.Length || width < 100 || height < 100
        return {kind:"invalid"}
    hints := 0, contexts := [], leftButtons := [], rightButtons := [], hasMenu := false, hasExitContext := false
    for block in blocks {
        if !IsObject(block) || !block.HasOwnProp("text") || !block.HasOwnProp("boxPoint")
            continue
        points := block.boxPoint
        if !(points is Array) || points.Length < 3
            continue
        try {
            x1 := points[1].x, y1 := points[1].y, x2 := points[3].x, y2 := points[3].y
            if !IsNumber(x1) || !IsNumber(y1) || !IsNumber(x2) || !IsNumber(y2)
                continue
            if x1 < 0 || y1 < 0 || x2 > width || y2 > height || x2 <= x1 || y2 <= y1
                continue
            x := (x1+x2)/2, y := (y1+y2)/2, nx := x/width, ny := y/height
            text := SMR_Text(block.text)
            if text = "数据坞"
                hasMenu := true
            if text = "提示" && nx >= 0.18 && nx <= 0.36 && ny >= 0.25 && ny <= 0.4
                hints += 1
            if nx >= 0.35 && nx <= 0.65 && ny >= 0.40 && ny <= 0.56 {
                contexts.Push(text)
                if text = "确认离开"
                    hasExitContext := true
            }
            if nx >= 0.23 && nx <= 0.45 && ny >= 0.56 && ny <= 0.72
                && text = "重新挑战"
                leftButtons.Push(text)
            if nx >= 0.56 && nx <= 0.76 && ny >= 0.56 && ny <= 0.72
                && RegExMatch(text,"^(确认|确定|退出)$")
                rightButtons.Push({x:x,y:y,text:text})
        }
    }
    ; Observed user screenshot: Prompt / Confirm leave / Retry challenge / Confirm.
    ; No fuzzy confirm-only click, fixed coordinates or exit-game fallback.
    if hints || leftButtons.Length || rightButtons.Length
        || hasExitContext {
        if hints = 1 && contexts.Length = 1 && contexts[1] = "确认离开"
            && leftButtons.Length = 1 && rightButtons.Length = 1 {
            b := rightButtons[1]
            return {kind:"exit",x:b.x,y:b.y,label:b.text}
        }
        return {kind:"blocked"}
    }
    return {kind:hasMenu ? "menu" : "unknown"}
}

SMR_SameExit(first, second) {
    return IsObject(first) && first.kind = "exit" && second.kind = "exit"
        && first.label = second.label && Abs(first.x-second.x) <= 12 && Abs(first.y-second.y) <= 12
}

SMR_InputFresh(obs, key, now) {
    if !IsObject(obs) || !obs.valid || obs.key != key || !obs.HasOwnProp("capturedAt")
        return false
    age := now-obs.capturedAt
    return age >= 0 && age <= 5000
}

; The production controller is exercised with a fake clock/capture/input boundary.
; No fixture path or test mode is used by the formal script.
SMR_OpenMenu(io, timeoutMs := 90000) {
    deadline := io.Now()+timeoutMs, key := "", previous := 0, previousAt := 0
    previousFrame := -1, menuHits := 0, worldHits := 0, exitSent := false
    awaitingWorld := false, clickAt := 0, escCount := 0, lastEsc := -10000
    while io.Now() < deadline {
        obs := io.Observe(), now := io.Now()
        if now >= deadline || !obs.valid || obs.key = "" {
            io.Log("選單恢復：畫面或身分無法驗證，停止輸入")
            return false
        }
        if key = ""
            key := obs.key
        if obs.key != key {
            io.Log("選單恢復：遊戲視窗／程序身分改變，停止輸入")
            return false
        }
        if obs.frame = previousFrame {
            io.Wait(400)
            continue
        }
        previousFrame := obs.frame, candidate := obs.candidate
        if candidate.kind = "invalid" {
            ; Successful captures can have no OCR during loading. No input, no
            ; carried-over stability evidence, but keep the bounded wait alive.
            previous := 0, menuHits := 0, worldHits := 0
            io.Wait(500)
            continue
        }
        menuHits := candidate.kind = "menu" ? menuHits+1 : 0
        if menuHits >= 2 && !awaitingWorld {
            io.Log("主選單已連續確認數據塢；允許聲骸合成")
            return true
        }
        if candidate.kind = "exit" {
            if !exitSent && SMR_SameExit(previous,candidate) && now-previousAt >= 300 && now-previousAt <= 5000 {
                if !io.ConfirmExit(obs)
                    return false
                exitSent := true, awaitingWorld := true, clickAt := io.Now()
                io.Log("退出副本：已點擊右側確認，等待提示消失及遊戲主畫面；尚未宣告退出成功")
            }
            previous := candidate, previousAt := now, worldHits := 0
        } else {
            previous := 0
            if candidate.kind = "blocked" {
                worldHits := 0
            } else if awaitingWorld {
                worldHits := obs.worldReady && now-clickAt >= 1500 ? worldHits+1 : 0
                if worldHits >= 2 {
                    awaitingWorld := false, lastEsc := -10000
                    io.Log("退出副本：提示已消失且主畫面連續就緒，再開選單驗證")
                }
            }
            if candidate.kind = "unknown" && !awaitingWorld && now-lastEsc >= 3000 {
                if escCount >= 6 || !io.SendEsc(obs)
                    return false
                escCount += 1, lastEsc := io.Now()
                io.Log("主選單：已在驗證前景送出 Esc，第 " escCount " 次")
            }
        }
        io.Wait(500)
    }
    io.Log("主選單恢復逾時；未確認成功，不再連續按 Esc 或確認")
    return false
}
