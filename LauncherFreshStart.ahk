#Requires AutoHotkey v2.0+
#Include LauncherStartupGuard.ahk
#Include payload\FreshLaunchIntent.ahk
#Include LauncherFreshWorkflow.ahk

LauncherFreshStart_IsFresh(args) {
    for arg in args {
        ; Unknown/helper/continuation arguments are never authority to replace
        ; an existing main. An ordinary no-argument launch is explicitly fresh.
        if StrLower(arg) != "--force-update"
            return false
    }
    return true
}

LauncherFreshStart_Prepare(root, fresh, io := unset) {
    if !IsSet(io)
        io := LauncherFreshStartIo(root)
    try {
        inventory := io.Inspect()
        if inventory.blocked
            return {ok:false, reason:inventory.reason}
        if inventory.owners.Length && !fresh
            return {ok:false, reason:"continuation-owner-still-running"}
        for owner in inventory.owners {
            if !io.Close(owner)
                return {ok:false, reason:"old-main-close-unconfirmed"}
        }
        after := io.Inspect()
        if after.blocked || after.owners.Length
            return {ok:false, reason:"old-main-not-drained"}
        return {ok:true, reason:inventory.owners.Length ? "fresh-takeover" : "clear"}
    } catch as err {
        return {ok:false, reason:"takeover-check-failed: " err.Message}
    }
}

LauncherFreshStart_Finish(root, fresh, io := unset) {
    ; Called only AFTER runtime acquisition: a direct-main start cannot race
    ; old-child cleanup or fresh journal replacement under this reservation.
    if !fresh
        return {ok:true,reason:"continuation-preserved"}
    if !IsSet(io)
        io := LauncherFreshStartIo(root)
    try {
        if !io.DrainAux()
            return {ok:false,reason:"old-auxiliary-not-drained"}
        if !io.DrainWorkflow()
            return {ok:false,reason:"old-workflow-not-drained"}
        if !io.ResetMaintenance()
            return {ok:false,reason:"old-maintenance-not-archived"}
        return {ok:true,reason:"fresh-workflow-drained"}
    } catch as err
        return {ok:false,reason:"fresh-finalization-failed: " err.Message}
}

class LauncherFreshStartIo {
    __New(root) {
        this.root := root
        this.runtime := root "\AutoHotkey64.exe"
        this.main := root "\payload\全自動.ahk"
    }
    Inspect() {
        owners := [], blocked := false, reason := ""
        for proc in ComObjGet("winmgmts:").ExecQuery("Select ProcessId,ExecutablePath,CommandLine,CreationDate,Name from Win32_Process where Name like '%AutoHotkey%'") {
            record := LauncherStartup_Classify(proc,this.runtime,this.main)
            if record.kind = "existing"
                owners.Push(proc)
            else if record.kind != "unrelated"
                blocked := true, reason := record.kind
        }
        ; Do not guess which of multiple old owners is authoritative.
        if owners.Length > 1
            blocked := true, reason := "multiple-main-owners"
        return {owners:owners,blocked:blocked,reason:reason}
    }
    Close(expected) {
        handle := LauncherCleanup_OpenNative(expected.ProcessId)
        if !handle
            return false
        previousHidden := A_DetectHiddenWindows
        try {
            if !LauncherCleanup_Alive(handle)
                return true
            current := LauncherCleanup_QueryIdentity(expected.ProcessId)
            if !IsObject(current) || String(current.CreationDate) != String(expected.CreationDate)
                || String(current.CommandLine) != String(expected.CommandLine)
                || LauncherStartup_Classify(current,this.runtime,this.main).kind != "existing"
                || LauncherCleanup_NormalizePath(LauncherCleanup_QueryImagePath(handle)) != LauncherCleanup_NormalizePath(this.runtime)
                return false
            DetectHiddenWindows(true)
            candidates := WinGetList("ahk_class AutoHotkey ahk_pid " expected.ProcessId)
            if candidates.Length != 1
                return false
            hwnd := candidates[1]
            if !LauncherCleanup_Alive(handle) || WinGetPID("ahk_id " hwnd) != expected.ProcessId
                return false
            ; AHK's standard File -> Exit is an ordinary OnExit path even in
            ; legacy releases. WM_CLOSE sent synchronously can merely hide the
            ; legacy main window. Validate the exact runtime's menu first.
            menu := DllCall("GetMenu","ptr",hwnd,"ptr"), caption := Buffer(256)
            if !menu || !DllCall("GetMenuStringW","ptr",menu,"uint",65405,"ptr",caption,"int",128,"uint",0)
                || !RegExMatch(StrReplace(StrGet(caption),"&",""),"i)^Exit\b")
                return false
            WriteLog("全新啟動：請求舊主流程正常關閉並等待錄影封口 | PID=" expected.ProcessId)
            response := 0
            DllCall("SetLastError","uint",0)
            sent := DllCall("SendMessageTimeoutW","ptr",hwnd,"uint",0x111,"ptr",65405,"ptr",0,
                "uint",2,"uint",1000,"uptr*",&response,"ptr")
            ; A timed-out handler may still be completing OnExit. Wait for the
            ; retained process, but never escalate an access denial to a kill.
            if !sent && A_LastError != 0 && A_LastError != 1460
                return false
            deadline := DllCall("GetTickCount64","uint64") + 90000
            while LauncherCleanup_Alive(handle) && DllCall("GetTickCount64","uint64") < deadline
                Sleep 100
            return !LauncherCleanup_Alive(handle)
        } finally {
            DetectHiddenWindows(previousHidden)
            LauncherCleanup_Close(handle)
        }
    }
    DrainAux() {
        ; Stop only exact owned AHK auxiliaries, after the old main's OnExit.
        for proc in ComObjGet("winmgmts:").ExecQuery("Select ProcessId,ExecutablePath,CommandLine,CreationDate,Name from Win32_Process where Name like '%AutoHotkey%'") {
            decision := LauncherCleanup_ProcessDecision(String(proc.Name),String(proc.CommandLine),this.root "\payload")
            if decision.role = "managed-全自動.ahk"
                return false
            if decision.stop && !LauncherCleanup_StopVerified(proc,this.root "\payload")
                return false
        }
        return true
    }
    DrainWorkflow() {
        return LauncherFreshWorkflow_Drain(this.root)
            && LauncherCleanup_WaitNativeHelpers(this.root "\payload").ok
    }
    ResetMaintenance() {
        return FMS_ArchiveAndReset(this.root)
    }
}
