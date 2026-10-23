#Requires AutoHotkey v2.0

; Write-ahead reservation is intentionally not retried after an unknown/crashed
; child. Losing proof may require operator recovery; it must never repeat input.
CS_Run(io, key, timeoutMs := 600000) {
    saved := io.Load(key)
    if IsObject(saved) {
        if saved.key = key && saved.stage = "success"
            return "success"
        if (saved.key = key && saved.stage != "success" && saved.stage != "deferred")
            || saved.stage = "running" || saved.stage = "reserved" || saved.stage = "uncertain" {
            io.Log("收尾合成已有未確認／失敗紀錄，保留本服並停止自動重試")
            return "blocked"
        }
    }
    control := io.Control()
    if control != "RUN"
        return control = "PAUSE" ? "paused" : "stopped"
    state := {key:key,token:io.Token(),stage:"reserved",pausedMs:0}
    if !io.Save(state)
        return "failed"
    child := 0
    try {
        prepared := io.Prepare()
        control := io.Control()
        if control != "RUN" {
            state.stage := control = "PAUSE" ? "deferred" : "stopped"
            if !io.Save(state)
                throw Error("無法保存合成延後狀態")
            return control = "PAUSE" ? "paused" : "stopped"
        }
        if !prepared
            throw Error("無法確認 LRMCAI／舊合成腳本已停止")
        io.Heartbeat(state,"RUN")
        child := io.Launch(state)
        if !IsObject(child)
            throw Error("合成子程序未取得受持有的程序身分")
        state.stage := "running"
        if !io.Save(state)
            throw Error("無法保存合成子程序啟動狀態")
        lastTick := io.Now(), activeMs := 0, previousControl := "RUN"
        loop {
            now := io.Now(), control := io.Control()
            elapsed := Max(0,now-lastTick)
            if previousControl = "PAUSE"
                state.pausedMs += elapsed
            else
                activeMs += elapsed
            lastTick := now
            previousControl := control
            io.Heartbeat(state,control)
            if control = "STOP" {
                io.Cancel(child)
                state.stage := "stopped", io.Save(state)
                return "stopped"
            }
            result := io.Poll(child)
            if result.exited {
                if result.code != 0 || io.Receipt(state) != state.token "|success"
                    throw Error("合成未同時取得成功收據及正常結束碼")
                state.stage := "success"
                if !io.Save(state)
                    throw Error("成功證據無法持久保存")
                return "success"
            }
            if activeMs >= timeoutMs
                throw Error("收尾合成超過主動執行時限")
            io.Wait(200)
        }
    } catch as err {
        cancelled := true
        if IsObject(child) {
            try cancelled := io.Cancel(child)
            catch
                cancelled := false
        }
        state.stage := cancelled ? "failed" : "uncertain"
        try io.Save(state)
        io.Log("收尾合成未確認成功；不標記完成、不關閉、不跳服：" err.Message)
        return "failed"
    }
}

CS_LeaseAllowsInput(text, token, now) {
    parts := StrSplit(Trim(text," `t`r`n"),"|")
    if parts.Length != 4 || parts[1] != token || parts[2] != "RUN" || !IsNumber(parts[3])
        || !IsNumber(parts[4]) || Number(parts[4]) < 0 || Number(parts[4]) > now
        return false
    age := now-Number(parts[3])
    return age >= 0 && age <= 2500
}

CS_GameIdentityMatches(expected,actual) {
    try return IsObject(expected) && IsObject(actual) && expected.hwnd > 0 && expected.pid > 0
        && expected.started != "" && expected.path != "" && actual.hwnd = expected.hwnd && actual.pid = expected.pid
        && String(actual.started) == String(expected.started) && StrLower(actual.path) = StrLower(expected.path)
    return false
}
