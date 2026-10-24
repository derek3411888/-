#Requires AutoHotkey v2.0

; Control files are replaced while the child checks its input lease. FileRead
; does not share DELETE access, so it can collide with an in-flight rename.
; Never cache the text or treat a failed read as permission to continue.
CS_ReadControlText(path) {
    deadline := DllCall("GetTickCount64","UInt64")+250
    loop {
        try {
            controlFile := FileOpen(path,"r","UTF-8") ; share read/write/delete
            try return controlFile.Read()
            finally controlFile.Close()
        } catch OSError as err {
            if (err.Number != 32 && err.Number != 33) || DllCall("GetTickCount64","UInt64") >= deadline
                throw err
            ; Do not call the main script's pause-aware Sleep: file retries
            ; have a wall-clock bound and must still publish PAUSE/STOP.
            DllCall("Sleep","uint",10)
        }
    }
}

CS_WriteControlText(path,text) {
    temporary := path "." DllCall("GetCurrentProcessId","uint") ".new"
    deadline := DllCall("GetTickCount64","UInt64")+250
    try {
        loop {
            try {
                previousCritical := Critical("On")
                try {
                    ; Heartbeats supply a factory so every attempt refreshes
                    ; control/time. Do not let a parent timer change control
                    ; between that snapshot and publishing the complete file.
                    currentText := IsObject(text) ? text.Call() : text
                    controlFile := FileOpen(temporary,"w","UTF-8-RAW")
                    try controlFile.Write(currentText)
                    finally controlFile.Close()
                    ; Replace only a fully written sibling, never delete/truncate
                    ; the visible state. Windows can return ACCESS_DENIED while a
                    ; reader still holds the destination, even with share-delete.
                    if DllCall("MoveFileExW","str",temporary,"str",path,"uint",0x9)
                        return
                    replaceError := A_LastError
                } finally Critical(previousCritical)
                if (replaceError != 5 && replaceError != 32 && replaceError != 33)
                    || DllCall("GetTickCount64","UInt64") >= deadline
                    throw OSError(replaceError,"CS_WriteControlText",path)
                ; Retry the identical rename only. Never change permissions,
                ; remove the destination, or swallow a persistent denial.
                DllCall("Sleep","uint",10)
            } catch OSError as err {
                if (err.Number != 32 && err.Number != 33) || DllCall("GetTickCount64","UInt64") >= deadline
                    throw err
                DllCall("Sleep","uint",10)
            }
        }
    } finally {
        try FileDelete(temporary)
    }
}

CS_RestrictControl(requested,current) {
    if (requested != "RUN" && requested != "PAUSE") || (current != "RUN" && current != "PAUSE")
        return "STOP"
    return requested = "PAUSE" || current = "PAUSE" ? "PAUSE" : "RUN"
}

CS_CompletionResult(control) => control = "RUN" ? "success" : control = "PAUSE" ? "paused" : "stopped"

CS_DeferBeforeLaunch(io,state,control) {
    state.stage := control = "PAUSE" ? "deferred" : "stopped"
    if !io.Save(state)
        throw Error("無法保存合成延後狀態")
    return CS_CompletionResult(CS_RestrictControl(control,io.Control()))
}

; Write-ahead reservation is intentionally not retried after an unknown/crashed
; child. Losing proof may require operator recovery; it must never repeat input.
CS_Run(io, key, timeoutMs := 600000) {
    saved := io.Load(key)
    if IsObject(saved) {
        if saved.key = key && saved.stage = "success"
            return CS_CompletionResult(io.Control())
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
        control := io.Control()
        if control != "RUN"
            return CS_DeferBeforeLaunch(io,state,control)
        prepared := io.Prepare()
        control := io.Control()
        if control != "RUN"
            return CS_DeferBeforeLaunch(io,state,control)
        if !prepared
            throw Error("無法確認 LRMCAI／舊合成腳本已停止")
        io.Heartbeat(state,"RUN")
        control := io.Control()
        if control != "RUN"
            return CS_DeferBeforeLaunch(io,state,control)
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
            io.Heartbeat(state,control)
            control := CS_RestrictControl(control,io.Control())
            previousControl := control
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
                ; Keep the successful journal even if STOP/PAUSE arrived while
                ; reading the receipt or saving it, but do not authorize close.
                return CS_CompletionResult(io.Control())
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
