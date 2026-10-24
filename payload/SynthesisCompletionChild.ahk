#Requires AutoHotkey v2.0
#Include CompletionSynthesis.ahk
#Include InteractiveDesktopGuard.ahk

class CS_ChildContext {
    __New(args) {
        this.enabled := args.Length > 0 && args[1] = "--completion"
        this.parentHandle := 0
        this.pausedMs := 0
        if !this.enabled
            return
        if args.Length != 9 || !RegExMatch(args[2],"^[A-Za-z0-9-]{8,64}$") || !IsInteger(args[5])
            || !IsInteger(args[6]) || !IsInteger(args[7]) || !IsInteger(args[8]) || args[9] = ""
            throw Error("收尾合成參數不完整")
        this.token := args[2], this.receiptPath := args[3], this.leasePath := args[4]
        this.expectedGame := {hwnd:Integer(args[6]),pid:Integer(args[7]),started:args[8],path:args[9]}
        this.parentHandle := DllCall("OpenProcess","uint",0x1000,"int",false,"uint",Integer(args[5]),"ptr")
        if !this.parentHandle
            throw Error("無法持有合成主程序身分")
    }
    __Delete() {
        if this.parentHandle
            DllCall("CloseHandle","ptr",this.parentHandle)
    }
    EnsureRun() {
        if !this.enabled
            return true
        loop {
            code := 0
            if !DllCall("GetExitCodeProcess","ptr",this.parentHandle,"uint*",&code) || code != 259
                throw Error("收尾合成主程序已退出；禁止任何輸入")
            lease := CS_ReadControlText(this.leasePath), now := DllCall("GetTickCount64","UInt64")
            ; The parent can exit during a bounded file-contention wait.
            if !DllCall("GetExitCodeProcess","ptr",this.parentHandle,"uint*",&code) || code != 259
                throw Error("收尾合成主程序已退出；禁止任何輸入")
            parts := StrSplit(Trim(lease," `t`r`n"),"|")
            if parts.Length != 4 || parts[1] != this.token || !IsNumber(parts[3]) || !IsNumber(parts[4])
                || Number(parts[4]) < this.pausedMs || Number(parts[4]) > now
                throw Error("收尾合成控制租約無法驗證")
            this.pausedMs := Number(parts[4])
            age := now-Number(parts[3])
            if age < 0 || age > 2500 || parts[2] = "STOP"
                throw Error("收尾合成租約過期或已停止")
            if CS_LeaseAllowsInput(lease,this.token,now)
                return true
            if parts[2] != "PAUSE"
                throw Error("未知收尾合成控制狀態")
            Sleep(100)
        }
    }
    BudgetNow() {
        this.EnsureRun()
        return DllCall("GetTickCount64","UInt64")-this.pausedMs
    }
    BindGame() {
        this.EnsureRun()
        identity := this.OpenGameIdentity()
        actual := {hwnd:identity.hwnd,pid:identity.pid,started:identity.started,path:identity.path}
        if !CS_GameIdentityMatches(this.expectedGame,actual) || !identity.Alive()
            throw Error("收尾合成拒絕非主程序確認的遊戲 HWND／PID／建立時間／映像")
        return identity
    }
    OpenGameIdentity() => SynthesisMenuIo(this.expectedGame.hwnd,SynthesisEnsureInputAllowed,SynthesisActiveTick,SynthesisPauseEpoch)
    Finish(success) {
        if !this.enabled
            return success ? 0 : 2
        text := this.token "|" (success ? "success" : "failed")
        CS_WriteControlText(this.receiptPath,text)
        return success ? 0 : 2
    }
}

; Desktop must be the same interactive desktop receiving input. Lock identities
; are checked independently because Windows can report Default while locked.
SynthesisDesktopAllowsInput() {
    input := 0
    try {
        session := 0, statePtr := 0, stateSize := 0
        if !DllCall("ProcessIdToSessionId","uint",DllCall("GetCurrentProcessId"),"uint*",&session)
            return false
        if !DllCall("wtsapi32\WTSQuerySessionInformationW","ptr",0,"uint",session,"int",8,
            "ptr*",&statePtr,"uint*",&stateSize)
            return false
        try {
            if stateSize < 4 || NumGet(statePtr,0,"int") != 0
                return false
        } finally DllCall("wtsapi32\WTSFreeMemory","ptr",statePtr)
        locked := GetForegroundLockScreenState()
        if locked.locked || locked.inspectError != ""
            return false
        input := DllCall("user32\OpenInputDesktop","uint",0,"int",false,"uint",1,"ptr")
        current := DllCall("user32\GetThreadDesktop","uint",DllCall("GetCurrentThreadId","uint"),"ptr")
        if !input || !current
            return false
        names := []
        for desktop in [current,input] {
            name := Buffer(512), needed := 0, flag := Buffer(4)
            if !DllCall("user32\GetUserObjectInformationW","ptr",desktop,"int",2,"ptr",name,"uint",512,"uint*",&needed)
                return false
            names.Push(StrGet(name))
            if !DllCall("user32\GetUserObjectInformationW","ptr",desktop,"int",6,"ptr",flag,"uint",4,"uint*",&needed)
                || !NumGet(flag,0,"int")
                return false
        }
        return names[1] != "" && names[1] = names[2]
    } catch {
        return false
    } finally {
        if input
            DllCall("user32\CloseDesktop","ptr",input)
    }
}
