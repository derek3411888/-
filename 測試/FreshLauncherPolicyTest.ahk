#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include ..\LauncherFreshStart.ahk

WriteLog(*) => 0
Check(value,message) {
    if !value
        throw Error(message)
}
; The real orchestration runs against a bounded process boundary; actual
; WM_CLOSE/OnExit/mutex behavior is covered by FreshLauncherTakeoverTest.ps1.
class FixtureTakeoverIo {
    __New(kind := "existing") {
        this.kind := kind, this.alive := kind = "existing", this.stops := 0
        this.closeOk := true, this.drainOk := true, this.respawn := false
        this.auxAlive := true
        this.workflowAlive := true, this.workflowOk := true, this.reset := false
    }
    Inspect() => {blocked:this.kind = "unknown",reason:"unknown",owners:(this.alive || this.respawn) ? [1] : []}
    Close(*) {
        this.stops += 1
        if this.closeOk
            this.alive := false
        return this.closeOk
    }
    DrainAux() {
        if this.drainOk
            this.auxAlive := false
        return this.drainOk
    }
    DrainWorkflow() {
        if this.workflowOk
            this.workflowAlive := false
        return this.workflowOk
    }
    ResetMaintenance() {
        this.reset := true
        return !this.auxAlive && !this.workflowAlive
    }
}
try {
    Check(LauncherFreshStart_IsFresh([]),"manual/scheduler no-argument launch is fresh")
    Check(LauncherFreshStart_IsFresh(["--force-update"]),"explicit fresh update remains fresh")
    for flag in ["--resume-current-task","--restart-current-task","--continue-stopped-task","--cleanup-recordings","--folder-picker","restart","nextserver","unknown"]
        Check(!LauncherFreshStart_IsFresh([flag]),"helper/continuation/unknown flag must not take over: " flag)
    io := FixtureTakeoverIo()
    result := LauncherFreshStart_Prepare("fixture",true,io)
    Check(result.ok && !io.alive && io.auxAlive,"old main closes before runtime reservation, no early state write")
    result := LauncherFreshStart_Finish("fixture",true,io)
    Check(result.ok && !io.auxAlive && !io.workflowAlive && io.reset,"all children drain before fresh reset or installation")
    io := FixtureTakeoverIo()
    result := LauncherFreshStart_Prepare("fixture",false,io)
    Check(!result.ok && io.alive && io.auxAlive && io.stops = 0,"resume cannot close its own parent or erase the active run")
    io := FixtureTakeoverIo("unknown")
    Check(!LauncherFreshStart_Prepare("fixture",true,io).ok && io.stops = 0,"uninspectable process is not shutdown authority")
    io := FixtureTakeoverIo(), io.closeOk := false
    Check(!LauncherFreshStart_Prepare("fixture",true,io).ok && io.auxAlive,"denied/failed close cannot reach auxiliary cleanup or install")
    io := FixtureTakeoverIo(), io.respawn := true
    Check(!LauncherFreshStart_Prepare("fixture",true,io).ok && io.auxAlive,"replacement/second owner after close blocks update")
    io := FixtureTakeoverIo(), io.drainOk := false
    Check(!LauncherFreshStart_Finish("fixture",true,io).ok && !io.reset,"failed child drain blocks reset/install")
    io := FixtureTakeoverIo(), io.workflowOk := false
    Check(!LauncherFreshStart_Finish("fixture",true,io).ok && !io.reset,"surviving gameplay child blocks reset/install")
    io := FixtureTakeoverIo()
    Check(LauncherFreshStart_Finish("fixture",false,io).ok && io.auxAlive && io.workflowAlive && !io.reset,"internal continuation cannot stop gameplay or reset maintenance")
    paths := {targets:Map("client-win64-shipping.exe","C:\game\Client\Binaries\Win64\Client-Win64-Shipping.exe",
        "lrmcai.exe","C:\lrmc\LRMCAI.exe"),okwwRoot:"C:\ok-ww",recorder:"C:\app\ffmpeg.exe"}
    proc := {Name:"LRMCAI.exe",ExecutablePath:"C:\lrmc\LRMCAI.exe",CommandLine:'"C:\lrmc\LRMCAI.exe"',ProcessId:10,CreationDate:"created"}
    Check(LFW_Classify(proc,paths) = "owned","native exact configured path is owned")
    proc.ExecutablePath := "C:\other\LRMCAI.exe"
    Check(LFW_Classify(proc,paths) = "unrelated","same-name unrelated native installation is retained")
    proc.ExecutablePath := ""
    Check(LFW_Classify(proc,paths) = "unknown","unreadable native identity cannot admit install")
    proc := {Name:"pythonw.exe",ExecutablePath:"C:\ok-ww\python\pythonw.exe",CommandLine:'"C:\ok-ww\python\pythonw.exe" "C:\ok-ww\main.py"'}
    Check(LFW_Classify(proc,paths) = "owned","OKWW requires both own root and specific identity")
    proc.ExecutablePath := "C:\other\pythonw.exe"
    Check(LFW_Classify(proc,paths) = "unrelated","python name or matching command text alone is not authority")
    proc := {Name:"ffmpeg.exe",ExecutablePath:"C:\app\ffmpeg.exe",CommandLine:'"C:\app\ffmpeg.exe" "C:\video\wuthering_auto_recording_20261025_040000.mkv"'}
    Check(LFW_Classify(proc,paths) = "recorder","unsealed recording blocks rather than force-terminates")
    FileAppend("PASS fresh takeover mode, continuity, unknown identity, failed close and drain barriers`n","*")
} catch as err {
    FileAppend(err.Message "`n" err.Stack,"**")
    ExitApp(1)
}
ExitApp(0)
