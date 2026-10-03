#Requires AutoHotkey v2.0
#Include GameHotfixRecovery.ahk

class GameHotfixIo {
    __New(hwnd) {
        this.hwnd := hwnd, this.sent := false, this.handle := 0, this.frame := 0
        this.pid := WinGetPID("ahk_id " hwnd)
        if GMHost_GetManagedGameHwnd() != hwnd
            throw Error("更新確認：遊戲安裝／視窗身分未通過")
        this.handle := DllCall("OpenProcess","UInt",0x101000,"Int",false,"UInt",this.pid,"Ptr")
        if !this.handle
            throw Error("更新確認：無法持有原遊戲程序；不送輸入")
        this.record := MPG_ReadHandleRecord(this.handle,this.pid)
        if !IsObject(this.record) || this.record.path != ResolveManagedTargetExePath("Client-Win64-Shipping.exe")
            throw Error("更新確認：原程序路徑未通過")
        this.ocr := RapidOcr()
    }
    __Delete() {
        if this.HasOwnProp("handle") && this.handle
            DllCall("CloseHandle","Ptr",this.handle)
    }
    Now() => MonotonicTickMs()
    Wait(ms) => Sleep(ms)
    Alive() => WutheringUpdateProcessAlive(this.handle)
    Intent() {
        global GM_CONTROLLER
        if GM_CONTROLLER.state.phase = "SKIPPED_UPDATE_DAY"
            return "STOP"
        intent := GMHost_StableIntent(GM_CONTROLLER)
        return intent = "RUN" && !GetInteractiveDesktopState().ok ? "PAUSE" : intent
    }
    Observe() {
        obs := {valid:false,frame:++this.frame,capturedAt:this.Now(),candidate:0}
        if this.Alive() != true || GMHost_GetManagedGameHwnd() != this.hwnd
            return obs
        path := RuntimeFiles_NewImagePath("hotfix_confirm")
        try {
            frame := ImagePutBuffer("ahk_id " this.hwnd)
            ImagePutFile({Buffer:frame},path)
            blocks := this.ocr.ocr_from_file(path, , true)
            obs.candidate := GH_Classify(blocks,frame.width,frame.height)
            obs.width := frame.width, obs.height := frame.height
            obs.valid := IsObject(obs.candidate)
        } catch as err {
            WriteLog("小更新確認 OCR 失敗：" err.Message,"WARN")
        } finally {
            try FileDelete(path)
        }
        return obs
    }
    FinalGuard(obs) {
        global GM_CONTROLLER
        age := this.Now()-obs.capturedAt
        try {
            WinGetClientPos(, ,&width,&height,"ahk_id " this.hwnd)
            return this.Intent() = "RUN" && this.Alive() == true
                && WinGetPID("ahk_id " this.hwnd) = this.pid
                && GMHost_GetManagedGameHwnd() = this.hwnd
                && age >= 0 && age <= 5000 && width = obs.width && height = obs.height
                && Floor((RC_UnixMs()+28800000)/86400000) = GM_CONTROLLER.stableGateDay
        }
        return false
    }
    Confirm(obs) {
        global GM_CONTROLLER
        if this.sent || this.Intent() != "RUN" || !GMHost_RecheckStableDay(GM_CONTROLLER).ok
            return false
        if !ForceActivateWindowForInput(this.hwnd,3000,"平日小更新確認","exact")
            return false
        fresh := this.Observe()
        if !fresh.valid || !GH_Same(obs.candidate,fresh.candidate) || !this.FinalGuard(fresh)
            return false
        return ClickWutheringClientPointForInput(this.hwnd,fresh.candidate.x,fresh.candidate.y,
            "平日小更新完成確認",false,"left_click",1,(*) => this.FinalGuard(fresh))
    }
}

HandleWutheringHotfix(hwnd) {
    ; Stay online after uncertain input rather than relaunching or consuming
    ; crash retries. The held process handle is retained through all wait chunks.
    try io := GameHotfixIo(hwnd)
    catch as err {
        WriteStep("小更新確認等待",err.Message,"WARN")
        Sleep(1000)
        return "retry"
    }
    loop {
        result := GH_ConfirmAndWait(io)
        if result != "waiting"
            return result
        WriteStep("小更新確認等待",io.sent ? "確認已送出；等待原遊戲退出，不重複點擊" : "等待同一更新完成畫面與可安全點擊的確認按鈕")
    }
}
