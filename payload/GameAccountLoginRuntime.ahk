#Requires AutoHotkey v2.0
#Include GameAccountLogin.ahk

class GameAccountLoginIo {
    attempts := 0
    lastAttempt := 0
    lastReport := ""
    lastFailure := ""
    handle := 0
    __New(hwnd) {
        this.hwnd := hwnd
        pid := 0, className := "", reason := ""
        if !GetWutheringWindowIdentity(hwnd,&pid,&className,&reason) || className != "UnrealWindow"
            throw Error("登入點擊：遊戲視窗身分未通過")
        this.pid := pid
        this.handle := DllCall("OpenProcess","UInt",0x101000,"Int",false,"UInt",pid,"Ptr")
        if !this.handle
            throw Error("登入點擊：無法持有原遊戲程序")
        record := MPG_ReadHandleRecord(this.handle,pid)
        if !IsObject(record) || record.path != ResolveManagedTargetExePath("Client-Win64-Shipping.exe")
            throw Error("登入點擊：遊戲安裝路徑未通過")
        this.ocr := RapidOcr()
    }
    __Delete() {
        if this.handle
            DllCall("CloseHandle","Ptr",this.handle)
    }
    Now() => MonotonicTickMs()
    Alive() => WutheringUpdateProcessAlive(this.handle)
    Rect(hwnd) {
        WinGetClientPos(&x,&y,&w,&h,"ahk_id " hwnd)
        return {x:x,y:y,w:w,h:h}
    }
    RootAt(x,y) {
        hit := GetWindowAtScreenPoint(x,y)
        return hit ? DllCall("GetAncestor","Ptr",hit,"UInt",2,"Ptr") : 0
    }
    SurfaceAllowed(hwnd) {
        try {
            if !hwnd || WinGetPID("ahk_id " hwnd) != this.pid
                return false
            if hwnd = this.hwnd
                return WinGetClass("ahk_id " hwnd) = "UnrealWindow"
            ; A same-PID window alone is insufficient: it must be an owned dialog.
            return WinGetClass("ahk_id " hwnd) = "#32770"
                && GetWindowRelationToTarget(hwnd,this.hwnd) = "same_root_owner"
        }
        return false
    }
    VisibleStack() {
        stack := []
        ; WinGetList is top-to-bottom Z order. Examine every overlapping window,
        ; not just sample points: a small foreign overlay must never enter OCR.
        for hwnd in WinGetList() {
            if WinGetMinMax("ahk_id " hwnd) = -1
                continue
            cloaked := 0
            if DllCall("dwmapi\DwmGetWindowAttribute","Ptr",hwnd,"UInt",14,"UInt*",&cloaked,"UInt",4) != 0
                throw Error("無法驗證登入擷取的視窗可見性")
            if cloaked
                continue
            WinGetPos(&x,&y,&w,&h,"ahk_id " hwnd)
            stack.Push({hwnd:hwnd,rect:{x:x,y:y,w:w,h:h}})
            if hwnd = this.hwnd
                break
        }
        return stack
    }
    Unoccluded(rect,stack) {
        for entry in stack {
            if entry.hwnd = this.hwnd
                return true
            r := entry.rect
            if r.x < rect.x+rect.w && r.x+r.w > rect.x && r.y < rect.y+rect.h && r.y+r.h > rect.y
                && !this.SurfaceAllowed(entry.hwnd)
                return false
        }
        return false
    }
    Surface(rect) {
        owned := false
        if rect.w < 500 || rect.h < 280
            return {ok:false,owned:false}
        for fx in [0.01,0.5,0.99] {
            for fy in [0.01,0.5,0.99] {
                root := this.RootAt(Round(rect.x+rect.w*fx),Round(rect.y+rect.h*fy))
                if !this.SurfaceAllowed(root)
                    return {ok:false,owned:false}
                owned := owned || root != this.hwnd
            }
        }
        return {ok:true,owned:owned}
    }
    HasVisibleOwnedDialog() {
        for entry in this.VisibleStack() {
            if entry.hwnd != this.hwnd && this.SurfaceAllowed(entry.hwnd)
                return true
        }
        return false
    }
    Capture(rect) => ImagePutBuffer({Screenshot:[rect.x,rect.y,rect.w,rect.h]})
    RequestForeground(hwnd) => DllCall("SetForegroundWindow","Ptr",hwnd,"Int")
    Intent() {
        global GM_CONTROLLER
        if !IsObject(GM_CONTROLLER) || GM_CONTROLLER.state.phase = "SKIPPED_UPDATE_DAY"
            return "STOP"
        intent := GMHost_StableIntent(GM_CONTROLLER)
        return intent = "RUN" && !GetInteractiveDesktopState().ok ? "PAUSE" : intent
    }
    FinalGuard(obs,requireDay := true) {
        global GM_CONTROLLER
        try {
            rect := this.Rect(this.hwnd)
            target := this.Rect(obs.targetHwnd)
            age := this.Now()-obs.capturedAt
            return this.Intent() = "RUN" && this.Alive() == true
                && GetWutheringGameHwnd() = this.hwnd && WinGetPID("ahk_id " this.hwnd) = this.pid
                && rect.x = obs.originX && rect.y = obs.originY && rect.w = obs.width && rect.h = obs.height
                && target.x = obs.targetOriginX && target.y = obs.targetOriginY
                && target.w = obs.targetWidth && target.h = obs.targetHeight
                && this.SurfaceAllowed(obs.targetHwnd)
                && this.RootAt(rect.x+obs.candidate.x,rect.y+obs.candidate.y) = obs.targetHwnd
                && age >= 0 && age <= 5000
                && (!requireDay || Floor((RC_UnixMs()+28800000)/86400000) = GM_CONTROLLER.stableGateDay)
        }
        return false
    }
    Observe() {
        obs := {candidate:0,accountDialog:false,capturedAt:this.Now(),width:0,height:0}
        path := RuntimeFiles_NewImagePath("account_login")
        try {
            rect := this.Rect(this.hwnd)
            stack := this.VisibleStack(), beforeTargets := Map()
            for entry in stack {
                if this.SurfaceAllowed(entry.hwnd)
                    beforeTargets[entry.hwnd] := this.Rect(entry.hwnd)
            }
            if this.Intent() != "RUN" || this.Alive() != true
                || !this.Unoccluded(rect,stack) || !this.Surface(rect).ok
                return obs
            ; PrintWindow(main UnrealWindow) omits the owned KURO login dialog.
            ; Capture only the verified visible client, never PrintWindow the dialog.
            frame := this.Capture(rect)
            obs.width := frame.width, obs.height := frame.height
            obs.originX := rect.x, obs.originY := rect.y
            ImagePutFile({Buffer:frame},path)
            blocks := this.ocr.ocr_from_file(path,,true)
            obs.accountDialog := GL_IsAccountDialog(blocks)
            obs.candidate := GL_Classify(blocks,frame.width,frame.height)
            if IsObject(obs.candidate) {
                obs.targetHwnd := this.RootAt(rect.x+obs.candidate.x,rect.y+obs.candidate.y)
                if !beforeTargets.Has(obs.targetHwnd) {
                    obs.candidate := 0
                    return obs
                }
                ; Pin dialog geometry BEFORE capture, not after a potentially slow OCR.
                target := beforeTargets[obs.targetHwnd]
                obs.targetOriginX := target.x, obs.targetOriginY := target.y
                obs.targetWidth := target.w, obs.targetHeight := target.h
                obs.targetX := rect.x+obs.candidate.x-target.x
                obs.targetY := rect.y+obs.candidate.y-target.y
                if !this.Unoccluded(rect,this.VisibleStack()) || !this.Surface(rect).ok || !this.FinalGuard(obs,false)
                    obs.candidate := 0
            }
        } finally {
            try FileDelete(path)
        }
        return obs
    }
    Activate(obs) {
        if !this.FinalGuard(obs)
            return this.Reject("activation_initial_guard")
        ; Login activation never uses the generic helper's Alt/caption-click fallback.
        requested := this.RequestForeground(obs.targetHwnd)
        deadline := this.Now()+2500
        loop {
            if !this.FinalGuard(obs)
                return this.Reject("activation_guard","request_return=" requested " age_ms=" (this.Now()-obs.capturedAt))
            relation := GetForegroundRelationToTarget(obs.targetHwnd,&foreground)
            if IsSafeInputWindowRelation(relation,"root")
                return true
            if this.Now() >= deadline
                return this.Reject("activation_timeout","request_return=" requested " foreground=" foreground " relation=" relation)
            RawSleep(50)
        }
    }
    Reject(stage,detail := "") {
        this.lastFailure := stage
        ; Diagnostic metadata only: never record account text, OCR contents or secrets.
        ; WARN invokes desktop error snapshots in the host; keep this text-only.
        try WriteLog("帳號登入未點擊 | stage=" stage " hwnd=" this.hwnd " pid=" this.pid " " detail,"INFO")
        return false
    }
    Confirm(obs) {
        global GM_CONTROLLER
        this.lastFailure := ""
        if this.Intent() != "RUN"
            return this.Reject("intent")
        if this.Alive() != true
            return this.Reject("process")
        if !GMHost_RecheckStableDay(GM_CONTROLLER).ok
            return this.Reject("day_gate")
        if !this.FinalGuard(obs)
            return this.Reject("initial_guard","age_ms=" (this.Now()-obs.capturedAt) " gate_day=" GM_CONTROLLER.stableGateDay
                " current_day=" Floor((RC_UnixMs()+28800000)/86400000))
        if !this.Activate(obs)
            return false
        ; Activation may reveal a different page. Re-OCR before physical input.
        fresh := this.Observe()
        if fresh.width != obs.width || fresh.height != obs.height
            || !GH_Same(obs.candidate,fresh.candidate) || !this.FinalGuard(fresh)
            || fresh.targetHwnd != obs.targetHwnd
            return this.Reject("fresh_candidate")
        clicked := ClickVerifiedWindowClientPoint(fresh.targetHwnd,fresh.targetX,fresh.targetY,
            this.pid,"KURO 帳號登入",(*) => this.FinalGuard(fresh),(*) => this.Activate(fresh))
        if !clicked && this.lastFailure = ""
            return this.Reject("click_guard")
        return clicked
    }
}

HandleWutheringAccountLogin(hwnd,blocks,width,height,capturedAt,&io) {
    static lastBlockedReport := 0
    backgroundAccount := GL_IsAccountDialog(blocks)
    try {
        if !IsObject(io) || io.hwnd != hwnd || io.Alive() != true {
            replacement := GameAccountLoginIo(hwnd)
            if IsObject(io) {
                ; A recreated HWND must not reset this detection session's budget.
                replacement.attempts := io.attempts, replacement.lastAttempt := io.lastAttempt
            }
            io := replacement
        }
        if !backgroundAccount && !io.HasVisibleOwnedDialog()
            return false
        obs := io.Observe()
        if !IsObject(obs.candidate) {
            if MonotonicTickMs()-lastBlockedReport >= 30000 {
                lastBlockedReport := MonotonicTickMs()
                WriteStep("帳號登入等待","帳號／所屬彈窗尚未取得唯一可安全點擊的登入按鈕；不輸入密碼、不處理驗證碼", "WARN")
            }
            return true
        }
        result := GL_Attempt(io,obs)
        report := result "|" io.attempts
        if report != io.lastReport {
            io.lastReport := report
            WriteStep("帳號登入",result = "clicked"
                ? "已實體點擊登入；等待帳號視窗消失及後續登入／主畫面驗證，尚未宣告成功"
                : (result = "limit" ? "登入已嘗試 3 次仍未完成；停止重複點擊，保留目前伺服器進度"
                    : "偵測到登入按鈕；等待新鮮畫面及安全輸入條件"))
        }
    } catch as err {
        WriteLog("帳號登入點擊未完成：" err.Message,"WARN")
        ; Unknown account-dialog/capture failures must not become server-ready UI.
        return true
    }
    ; Account dialog must not fall through as a ready server-selection screen.
    return true
}
