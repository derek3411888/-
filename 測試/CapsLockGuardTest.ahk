#Requires AutoHotkey v2.0
#Include *i ..\payload\CapsLockGuard.ahk

; Breaks caught: unconditional toggling, missing off action, repeated held-key
; injection, false successful readback, unbounded retries and ignored disable gate.
try {
    if !IsSet(CapsLockGuard)
        throw Error("Caps Lock guard is missing")
    io := CapsTestKeyboard(false), guard := CapsLockGuard(io)
    AssertCaps(guard.Check() = "off" && io.writes = 0, "already off must not emit input")
    io := CapsTestKeyboard(true), guard := CapsLockGuard(io)
    AssertCaps(guard.Check() = "cleared" && !io.on && io.writes = 1, "locked state must be cleared and verified")
    AssertCaps(guard.Check() = "off" && io.writes = 1, "repeat check must not toggle it back on")
    io := CapsTestKeyboard(true), io.down := true, guard := CapsLockGuard(io)
    Loop 4
        AssertCaps(guard.Check() = "held" && io.writes = 0, "held Caps Lock must not be repeatedly injected")
    io.down := false
    AssertCaps(guard.Check() = "cleared" && io.writes = 1, "release must allow pending correction")
    io := CapsTestKeyboard(true), guard := CapsLockGuard(io)
    AssertCaps(guard.Check(false) = "disabled" && io.reads = 0 && io.writes = 0, "disabled gate must leave keyboard untouched")
    io.desktopAllowed := false
    AssertCaps(guard.Check() = "disabled" && io.writes = 0 && io.on, "non-interactive desktop must not receive Caps Lock input")
    io := CapsTestKeyboard(true), io.holdOnDesktopCheck := true, guard := CapsLockGuard(io)
    AssertCaps(guard.Check() = "held" && io.writes = 0, "key pressed during desktop inspection must not be injected")
    io := CapsTestKeyboard(true), guard := CapsLockGuard(io), permission := {allowed:true}
    io.onInputCheck := (*) => permission.allowed := false
    AssertCaps(guard.Check(() => permission.allowed) = "disabled" && io.writes = 0, "new PAUSE or STOP during inspection must win before input")
    io := CapsTestKeyboard(true), guard := CapsLockGuard(io)
    AssertCaps(guard.Check(() => false) = "disabled" && io.reads = 0, "already denied live gate must not inspect keyboard")
    io := CapsTestKeyboard(true), io.ignoreWrite := true, guard := CapsLockGuard(io)
    AssertCaps(guard.Check() = "failed" && io.on && io.writes = 1, "failed readback cannot report success")
    AssertCaps(guard.Check() = "cooldown" && io.writes = 1, "failed correction must not spam input")
    io.tick += 1000, io.ignoreWrite := false
    AssertCaps(guard.Check() = "cleared" && io.writes = 2, "retry after cooldown must recheck and recover")
    io := CapsTestKeyboard(true), io.throwRead := true, guard := CapsLockGuard(io)
    AssertCaps(guard.Check() = "failed" && io.writes = 0, "read failure must not inject blindly")
    io.throwRead := false, io.tick += 1000, io.throwWrite := true
    AssertCaps(guard.Check() = "failed", "write error must not escape into workflow recovery")
    io.throwWrite := false, io.tick += 1000
    AssertCaps(guard.Check() = "cleared", "exception must not leave guard busy forever")
    FileAppend("PASS: Caps Lock off/on/held/release/disabled/readback/cooldown/error protection`n", "*")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL: " err.Message "`n", "**")
    ExitApp(1)
}

AssertCaps(ok, detail) {
    if !ok
        throw Error(detail)
}

; Only OS reads/writes are replaced: production guard decisions run unchanged.
class CapsTestKeyboard {
    __New(on) {
        this.on := on, this.down := false, this.tick := 2000
        this.writes := 0, this.reads := 0, this.ignoreWrite := false
        this.throwRead := false, this.throwWrite := false
        this.desktopAllowed := true
        this.holdOnDesktopCheck := false, this.onInputCheck := 0
    }
    Now() => this.tick
    InputAllowed() {
        if this.holdOnDesktopCheck
            this.down := true
        if IsObject(this.onInputCheck)
            this.onInputCheck.Call()
        return this.desktopAllowed
    }
    Read() {
        this.reads += 1
        if this.throwRead
            throw Error("keyboard query unavailable")
        return {on:this.on, down:this.down}
    }
    TurnOff() {
        this.writes += 1
        if this.throwWrite
            throw Error("keyboard write unavailable")
        if !this.ignoreWrite
            this.on := false
    }
    Wait(ms) => this.tick += ms
}
