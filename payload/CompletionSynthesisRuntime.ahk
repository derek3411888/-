#Requires AutoHotkey v2.0
#Include CompletionSynthesis.ahk

CS_RewardSynthesisStatus(key, pendingAt) {
    try {
        saved := CompletionSynthesisIo().Load(key "|" pendingAt)
        return IsObject(saved) && saved.key = key "|" pendingAt ? saved.stage : "none"
    }
    return "unknown"
}

CS_RewardAlreadySucceeded(key, pendingAt) {
    return key != "" && pendingAt != "" && CS_RewardSynthesisStatus(key,pendingAt) = "success"
}

CS_CompleteReward(state) {
    static busy := false
    if busy
        return "blocked"
    busy := true
    try return CS_Run(CompletionSynthesisIo(),state.key "|" state.pendingAt)
    catch as err {
        WriteLog("收尾合成狀態無法確認，保留本服及完成訊號：" err.Message,"ERROR")
        return "failed"
    }
    finally busy := false
}

class CompletionSynthesisIo {
    __New() {
        this.root := RuntimeFiles_RuntimeDir("completion-synthesis")
        this.statePath := this.root "\state.txt"
    }
    Now() => DllCall("GetTickCount64","UInt64")
    Wait(ms) => RawSleep(ms)
    Log(message) => WriteLog(message,"WARN")
    Control() {
        global REMOTE_STOP_IN_PROGRESS, EXITING_FROM_TRAY, REMOTE_CONTROL_ACTIVE
        global __RESTART_IN_PROGRESS
        return (REMOTE_STOP_IN_PROGRESS || EXITING_FROM_TRAY || __RESTART_IN_PROGRESS) ? "STOP"
            : (REMOTE_CONTROL_ACTIVE && RC_IsPaused()) ? "PAUSE" : "RUN"
    }
    Token() {
        guid := Buffer(16), text := Buffer(78)
        if DllCall("ole32\CoCreateGuid","ptr",guid,"uint") != 0
            throw Error("無法建立合成身分")
        DllCall("ole32\StringFromGUID2","ptr",guid,"ptr",text,"int",39)
        return RegExReplace(StrGet(text),"[^A-Za-z0-9-]","")
    }
    Load(key) {
        if !FileExist(this.statePath)
            return 0
        parts := StrSplit(Trim(FileRead(this.statePath,"UTF-8"),"`r`n"),"`n","`r")
        if parts.Length != 3
            throw Error("合成持久狀態損毀；禁止重複啟動")
        return {key:parts[1],token:parts[2],stage:parts[3]}
    }
    Atomic(path,text) {
        temp := path ".new"
        try FileDelete(temp)
        FileAppend(text,temp,"UTF-8-RAW")
        FileMove(temp,path,1)
    }
    Save(state) {
        try {
            if InStr(state.key,"`n") || InStr(state.key,"`r")
                return false
            this.Atomic(this.statePath,state.key "`n" state.token "`n" state.stage)
            return true
        }
        return false
    }
    Prepare() {
        mayStop := () => this.Control() = "RUN"
        if !mayStop()
            return false
        ; The old launcher must stop too, otherwise it can reopen LRMCAI.
        CloseManagedAhkForSelfHealing("開啟LRMC\.ahk|聲骸合成\.ahk")
        if !mayStop()
            return false
        CloseExactProcessForSelfHealing("LRMCAI.exe","收尾合成前停止 LRMCAI",mayStop)
        return mayStop() && this.Drained()
    }
    Drained() {
        try {
            ; The legacy enumerator intentionally skips unreadable candidates;
            ; for ownership admission, unknown is not evidence of absence.
            for proc in ComObjGet("winmgmts:").ExecQuery("Select ProcessId,CommandLine from Win32_Process where Name like '%AutoHotkey%'") {
                if proc.ProcessId = DllCall("GetCurrentProcessId")
                    continue
                command := String(proc.CommandLine)
                if command = ""
                    return false
                for name in ["開啟LRMC.ahk","聲骸合成.ahk"]
                    if InStr(StrLower(command),StrLower(A_ScriptDir "\" name))
                        return false
            }
            for item in EnumerateAuxManagedAhkProcesses()
                if item.name ~= "i)^(開啟LRMC\.ahk|聲骸合成\.ahk)$"
                    return false
            expected := ResolveManagedTargetExePath("LRMCAI.exe")
            for proc in ComObjGet("winmgmts:").ExecQuery("Select ProcessId from Win32_Process where Name='LRMCAI.exe'") {
                record := ReadManagedProcessRecord(proc.ProcessId + 0)
                if !IsObject(record) || expected = "" || StrLower(record.path) = StrLower(expected)
                    return false
            }
            return true
        }
        return false
    }
    Heartbeat(state,control) => this.Atomic(this.root "\" state.token ".lease",state.token "|" control "|" this.Now() "|" state.pausedMs)
    Receipt(state) {
        path := this.root "\" state.token ".receipt"
        return FileExist(path) ? Trim(FileRead(path,"UTF-8")," `t`r`n") : ""
    }
    Launch(state) {
        global AhkExe
        game := this.GameIdentity()
        command := '"' AhkExe '" "' A_ScriptDir '\聲骸合成.ahk" --completion "' state.token
            . '" "' this.root '\' state.token '.receipt" "' this.root '\' state.token '.lease" '
            . DllCall("GetCurrentProcessId") ' ' game.hwnd ' ' game.pid ' ' game.started ' "' game.path '"'
        return CS_HeldChild(command,A_ScriptDir)
    }
    GameIdentity() {
        ; This selector already filters GM_CONTROLLER's verified install and
        ; rejects ambiguous same-name windows. Never guess another installation.
        hwnd := GMHost_GetManagedGameHwnd()
        if !hwnd || WinGetClass("ahk_id " hwnd) != "UnrealWindow"
            throw Error("收尾合成未取得已驗證安裝的唯一遊戲視窗")
        pid := WinGetPID("ahk_id " hwnd), record := ReadManagedProcessRecord(pid)
        expected := ResolveManagedTargetExePath("Client-Win64-Shipping.exe")
        if !IsObject(record) || expected = "" || StrLower(record.path) != StrLower(expected)
            throw Error("收尾合成遊戲程序不屬於已驗證安裝")
        actual := ReadManagedProcessRecord(pid)
        record.hwnd := hwnd
        if IsObject(actual)
            actual.hwnd := GMHost_GetManagedGameHwnd()
        if !CS_GameIdentityMatches(record,actual)
            throw Error("收尾合成遊戲程序身分在啟動前改變")
        return record
    }
    Poll(child) => child.Poll()
    Cancel(child) => child.Cancel()
}

class CS_HeldChild {
    __New(command,workingDir) {
        this.handle := 0
        startup := Buffer(104,0), info := Buffer(24,0), cmd := Buffer((StrLen(command)+1)*2)
        NumPut("uint",104,startup), StrPut(command,cmd)
        if !DllCall("CreateProcessW","ptr",0,"ptr",cmd,"ptr",0,"ptr",0,"int",false,
            "uint",0x08000000,"ptr",0,"str",workingDir,"ptr",startup,"ptr",info)
            throw OSError()
        this.handle := NumGet(info,0,"ptr")
        DllCall("CloseHandle","ptr",NumGet(info,8,"ptr"))
    }
    __Delete() {
        if this.handle
            DllCall("CloseHandle","ptr",this.handle)
    }
    Poll() {
        code := 0
        if !DllCall("GetExitCodeProcess","ptr",this.handle,"uint*",&code)
            throw OSError()
        return {exited:code != 259,code:code}
    }
    Cancel() {
        if !this.Poll().exited {
            DllCall("TerminateProcess","ptr",this.handle,"uint",2)
            if DllCall("WaitForSingleObject","ptr",this.handle,"uint",5000,"uint") != 0
                throw Error("合成子程序取消未確認")
        }
        return true
    }
}
