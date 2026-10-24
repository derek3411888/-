#Requires AutoHotkey v2.0
#Include InteractiveDesktopGuard.ahk

; Caps Lock only: never remap a key, force a held key up, or change another lock.
class CapsLockGuard {
    __New(keyboard := unset) {
        this.keyboard := IsSet(keyboard) ? keyboard : CapsLockKeyboard()
        this.busy := false, this.retryAfter := 0
    }
    Check(allowed := true) {
        if !(IsObject(allowed) ? allowed.Call() : allowed)
            return "disabled"
        if this.busy
            return "busy"
        this.busy := true
        try {
            now := this.keyboard.Now()
            if now < this.retryAfter
                return "cooldown"
            state := this.keyboard.Read()
            if state.down
                return "held"
            if !state.on
                return "off"
            if !this.keyboard.InputAllowed()
                return "disabled"
            priorCritical := Critical("On")
            try {
                if !(IsObject(allowed) ? allowed.Call() : allowed)
                    return "disabled"
                ; Desktop inspection may yield. Re-read the key at the final
                ; input boundary instead of acting on the earlier snapshot.
                state := this.keyboard.Read()
                if state.down
                    return "held"
                if !state.on
                    return "off"
                this.retryAfter := now + 1000
                this.keyboard.TurnOff()
            } finally Critical(priorCritical)
            this.keyboard.Wait(30)
            state := this.keyboard.Read()
            if state.on || state.down
                return "failed"
            this.retryAfter := 0
            return "cleared"
        } catch {
            try this.retryAfter := this.keyboard.Now() + 1000
            return "failed"
        } finally {
            this.busy := false
        }
    }
}

class CapsLockKeyboard {
    Now() => DllCall("GetTickCount64", "UInt64")
    Read() => {on:!!GetKeyState("CapsLock", "T"),
        down:!!(DllCall("user32\GetAsyncKeyState", "int", 0x14, "short") & 0x8000)}
    TurnOff() => SetCapsLockState("Off")
    InputAllowed() {
        input := 0
        try {
            locked := GetForegroundLockScreenState()
            if locked.locked || locked.inspectError != ""
                return false
            input := DllCall("user32\OpenInputDesktop", "uint", 0, "int", false, "uint", 1, "ptr")
            current := DllCall("user32\GetThreadDesktop", "uint", DllCall("GetCurrentThreadId", "uint"), "ptr")
            if !input || !current
                return false
            names := []
            for desktop in [current, input] {
                name := Buffer(512), needed := 0, flag := Buffer(4)
                if !DllCall("user32\GetUserObjectInformationW", "ptr", desktop, "int", 2,
                    "ptr", name, "uint", 512, "uint*", &needed)
                    return false
                names.Push(StrGet(name))
                if !DllCall("user32\GetUserObjectInformationW", "ptr", desktop, "int", 6,
                    "ptr", flag, "uint", 4, "uint*", &needed) || !NumGet(flag, 0, "int")
                    return false
            }
            return names[1] != "" && names[1] = names[2]
        } catch {
            return false
        } finally {
            if input
                DllCall("user32\CloseDesktop", "ptr", input)
        }
    }
    ; Do not enter the main script's pause-aware Sleep from inside this guard.
    Wait(ms) => DllCall("Sleep", "uint", ms)
}

CapsLockGuard_EnsureOff(logFn := 0, allowed := true) {
    static guard := CapsLockGuard(), lastReport := ""
    result := guard.Check(allowed)
    if result = "off"
        lastReport := ""
    else if result != lastReport && IsObject(logFn) {
        if result = "cleared" {
            try logFn.Call("Caps Lock 防護：偵測到大寫鎖定，已關閉並確認")
        } else if result = "held" {
            try logFn.Call("Caps Lock 防護：按鍵仍為按下狀態，等待放開後再解除鎖定；不反覆送鍵", "WARN")
        } else if result = "failed" {
            try logFn.Call("Caps Lock 防護：尚未確認解除鎖定，稍後重查；不改變原流程判定", "WARN")
        }
        if result = "cleared" || result = "held" || result = "failed"
            lastReport := result
    }
    return result
}
