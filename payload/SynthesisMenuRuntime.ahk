#Requires AutoHotkey v2.0
#Include SynthesisMenuRecovery.ahk

; Uses the synthesis script's existing ImagePut, RapidOcr and runtime paths.
; Every input remains tied to the original HWND and held process handle.
class SynthesisMenuIo {
    __New(hwnd, inputGate := 0, budgetClock := 0, pauseEpoch := 0) {
        this.inputGate := inputGate
        this.budgetClock := budgetClock, this.pauseEpochCallback := pauseEpoch
        this.hwnd := hwnd, this.sequence := 0, this.processHandle := 0
        this.pid := WinGetPID("ahk_id " hwnd)
        if WinGetClass("ahk_id " hwnd) != "UnrealWindow"
            throw Error("聲骸選單：非鳴潮遊戲視窗")
        name := WinGetProcessName("ahk_id " hwnd)
        if name != "Client-Win64-Shipping.exe" && name != "Wuthering Waves.exe"
            throw Error("聲骸選單：非鳴潮主程序")
        this.processHandle := DllCall("OpenProcess","uint",0x1000,"int",false,"uint",this.pid,"ptr")
        if !this.processHandle
            throw Error("聲骸選單：無法持有遊戲程序身分")
        created := Buffer(8), ended := Buffer(8), kernel := Buffer(8), userTime := Buffer(8)
        if !DllCall("GetProcessTimes","ptr",this.processHandle,"ptr",created,"ptr",ended,"ptr",kernel,"ptr",userTime)
            throw Error("聲骸選單：無法取得遊戲建立時間")
        this.started := String(NumGet(created,0,"Int64"))
        this.path := SMR_ProcessImage(this.processHandle)
        if this.path = ""
            throw Error("聲骸選單：無法確認遊戲映像路徑")
        this.key := hwnd ":" this.pid ":" this.started
    }
    __Delete() {
        if this.HasOwnProp("processHandle") && this.processHandle
            DllCall("CloseHandle","ptr",this.processHandle)
    }
    Now() => DllCall("GetTickCount64","UInt64")
    BudgetNow() => this.HasOwnProp("budgetClock") && IsObject(this.budgetClock) ? this.budgetClock.Call() : this.Now()
    PauseEpoch() => this.HasOwnProp("pauseEpochCallback") && IsObject(this.pauseEpochCallback) ? this.pauseEpochCallback.Call() : 0
    RetryAfterPause(obs) {
        if IsObject(this.inputGate)
            this.inputGate.Call()
        return obs.HasOwnProp("pauseEpoch") && obs.pauseEpoch != this.PauseEpoch()
    }
    Wait(ms) => Sleep(ms)
    Log(message) {
        global logger
        logger.log(message)
    }
    Alive() {
        try {
            exitCode := 0
            return DllCall("GetExitCodeProcess","ptr",this.processHandle,"uint*",&exitCode)
                && exitCode = 259 && WinGetPID("ahk_id " this.hwnd) = this.pid
                && WinGetClass("ahk_id " this.hwnd) = "UnrealWindow"
        }
        return false
    }
    Observe() {
        global ocrEngine
        if this.HasOwnProp("inputGate") && IsObject(this.inputGate)
            this.inputGate.Call()
        this.sequence += 1
        obs := {valid:false,key:"",frame:this.sequence,candidate:{kind:"invalid"},worldReady:false,pauseEpoch:this.PauseEpoch()}
        if !this.Alive()
            return obs
        path := RuntimeFiles_NewImagePath("synthesis_menu")
        try {
            capturedAt := this.Now()
            frame := ImagePutBuffer("ahk_id " this.hwnd)
            ImagePutFile({Buffer:frame},path)
            blocks := ocrEngine.ocr_from_file(path, , true)
            if !(blocks is Array) || !this.Alive()
                return obs
            obs.candidate := SMR_Classify(blocks,frame.width,frame.height)
            obs.width := frame.width, obs.height := frame.height
            obs.worldReady := obs.candidate.kind = "unknown" && this.HudReady(frame)
            obs.valid := true, obs.key := this.key, obs.capturedAt := capturedAt
        } catch as err {
            this.Log("聲骸選單截圖／OCR 失敗：" err.Message)
        } finally {
            try FileDelete(path)
        }
        return obs
    }
    HudReady(frame) {
        try {
            normalized := ImagePutBuffer({Buffer:frame,scale:[1280,720]})
            roi := normalized.Crop(780,580,500,140)
            hit := roi.ImageSearch(A_ScriptDir "\icon_main.png",40)
            return IsObject(hit) && hit.HasProp("Length") && hit.Length >= 2
                && IsNumber(hit[1]) && IsNumber(hit[2]) && hit[1] >= 0 && hit[1] < roi.width
                && hit[2] >= 0 && hit[2] < roi.height
        }
        return false
    }
    Foreground(obs) {
        if IsObject(this.inputGate)
            this.inputGate.Call()
        if !this.Alive() || !SMR_InputFresh(obs,this.key,this.Now())
            return false
        try {
            WinActivate("ahk_id " this.hwnd)
            if !WinWaitActive("ahk_id " this.hwnd, ,0.8)
                return false
            return this.FinalReady(obs)
        }
        return false
    }
    FinalReady(obs) {
        if IsObject(this.inputGate)
            this.inputGate.Call()
        try {
            WinGetClientPos(, ,&width,&height,"ahk_id " this.hwnd)
            return width = obs.width && height = obs.height && this.Alive()
                && WinActive("ahk_id " this.hwnd) && SMR_InputFresh(obs,this.key,this.Now())
        }
        return false
    }
    SendEsc(obs) {
        if !this.Foreground(obs)
            return false
        Send("{Esc}")
        return true
    }
    ConfirmExit(obs) {
        if !this.Foreground(obs)
            return false
        ; Recapture after foreground acquisition; never click stale OCR coordinates.
        fresh := this.Observe()
        if !fresh.valid || !SMR_SameExit(obs.candidate,fresh.candidate) || !this.Foreground(fresh)
            return false
        oldMode := A_CoordModeMouse
        try {
            CoordMode("Mouse","Client")
            MouseMove(fresh.candidate.x,fresh.candidate.y,0)
            if !this.FinalReady(fresh)
                return false
            Click()
            return true
        } finally {
            CoordMode("Mouse",oldMode)
        }
    }
}

SMR_ProcessImage(handle) {
    pathBuffer := Buffer(65536), chars := 32768
    if !DllCall("QueryFullProcessImageNameW","ptr",handle,"uint",0,"ptr",pathBuffer,"uint*",&chars)
        return ""
    path := StrGet(pathBuffer,chars,"UTF-16")
    imageFileHandle := DllCall("CreateFileW","str",path,"uint",0,"uint",7,"ptr",0,"uint",3,"uint",0x02000000,"ptr",0,"ptr")
    if !imageFileHandle || imageFileHandle = -1
        return ""
    try {
        count := DllCall("GetFinalPathNameByHandleW","ptr",imageFileHandle,"ptr",pathBuffer,"uint",32768,"uint",0,"uint")
        if !count || count >= 32768
            return ""
        final := StrGet(pathBuffer)
        if SubStr(final,1,8) = "\\?\UNC\"
            return "\\" SubStr(final,9)
        return SubStr(final,1,4) = "\\?\" ? SubStr(final,5) : final
    } finally DllCall("CloseHandle","ptr",imageFileHandle)
}
