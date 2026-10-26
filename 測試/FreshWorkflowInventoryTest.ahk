#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include ..\LauncherFreshWorkflow.ahk
FileEncoding("UTF-8")
logs := []
WriteLog(message,*) => logs.Push(message)
Check(value,message) {
    if !value
        throw Error(message)
}
class ImageProbeFixture {
    __New() {
        this.record := {ProcessId:"10",Name:"pythonw.exe",CreationDate:"20261027040000.123456+480",ExecutablePath:"",CommandLine:""}
        this.path := "C:\other\pythonw.exe", this.handle := 100, this.waitResult := 258
        this.started := 134375184001234560, this.createdCalls := 0, this.opened := 0, this.closed := 0
        this.changed := false, this.queryFails := false
    }
    Open(*) {
        this.opened += 1
        return this.handle
    }
    Wait(*) => this.waitResult
    Image(*) {
        if this.queryFails
            throw Error("query failure")
        return this.path
    }
    Created(*) {
        this.createdCalls += 1
        return this.started + (this.changed && this.createdCalls > 1 ? 1 : 0)
    }
    Canonical(value) => value
    Close(*) => this.closed += 1
    Ops() => {open:ObjBindMethod(this,"Open"),wait:ObjBindMethod(this,"Wait"),
        image:ObjBindMethod(this,"Image"),created:ObjBindMethod(this,"Created"),
        canonical:ObjBindMethod(this,"Canonical"),close:ObjBindMethod(this,"Close")}
}
class InventoryFixture {
    __New(snapshots,paths) {
        this.snapshots := snapshots, this.paths := paths, this.reads := 0
        this.tick := 0, this.closed := [], this.closeOk := true, this.fail := false, this.inventoryDelay := 0
    }
    Inventory() {
        this.reads += 1
        this.tick += this.inventoryDelay
        if this.fail
            throw Error("inventory failure")
        return this.snapshots[Min(this.reads,this.snapshots.Length)]
    }
    Now() => this.tick
    Wait() => this.tick += 1000
    Close(record) {
        this.closed.Push(record.ProcessId)
        return this.closeOk
    }
}
try {
    ; A real harmless current process, with the same WMI missing-image shape
    ; observed on MYDESKPC. No production process is started or terminated.
    selfPid := DllCall("GetCurrentProcessId","uint")
    current := LauncherCleanup_QueryIdentity(selfPid)
    candidate := {ProcessId:selfPid,Name:current.Name,CreationDate:current.CreationDate,
        ExecutablePath:"",CommandLine:""}
    observed := LFW_Record(candidate)
    Check(observed.ExecutablePath = MPG_CanonicalPath(A_AhkPath),
        "missing WMI image must resolve from a read-only handle of the same live process")
    Check(observed.CommandLine = "","fallback must not invent command/termination authority")
    paths := {targets:Map("lrmcai.exe","C:\lrmc\LRMCAI.exe"),okwwRoot:"C:\ok-ww",recorder:"C:\app\ffmpeg.exe"}
    probe := ImageProbeFixture(), candidate := probe.record.Clone()
    result := LFW_ResolveImage(candidate,probe.Ops())
    candidate.ExecutablePath := result.image
    Check(LFW_Classify(candidate,paths) = "unrelated" && probe.closed = 1,
        "MYDESKPC unrelated Python missing WMI path must not block the installation")
    probe := ImageProbeFixture(), probe.path := "C:\ok-ww\python\pythonw.exe"
    candidate := probe.record.Clone(), result := LFW_ResolveImage(candidate,probe.Ops())
    candidate.ExecutablePath := result.image
    Check(LFW_Classify(candidate,paths) = "unknown","own Python without command remains protected")
    candidate.CommandLine := '"C:\ok-ww\python\pythonw.exe" "C:\ok-ww\main.py"'
    Check(LFW_Classify(candidate,paths) = "owned","verified own Python still reaches exact close guard")
    probe := ImageProbeFixture(), candidate := probe.record.Clone(), probe.started := 99999999
    Check(LFW_ResolveImage(candidate,probe.Ops()).image = "","native creation must match the original WMI creation, not only a later WMI response")
    for condition in ["denied","exited","image-missing","creation-missing","changed","query-failure","pid-reused","wrong-name","no-creation"] {
        probe := ImageProbeFixture(), candidate := probe.record.Clone()
        switch condition {
            case "denied": probe.handle := 0
            case "exited": probe.waitResult := 0
            case "image-missing": probe.path := ""
            case "creation-missing": probe.started := 0
            case "changed": probe.changed := true
            case "query-failure": probe.queryFails := true
            case "pid-reused": probe.started += 10
            case "wrong-name": candidate.Name := "ffmpeg.exe"
            case "no-creation": candidate.CreationDate := ""
        }
        result := LFW_ResolveImage(candidate,probe.Ops())
        Check(result.image = "","uncertain fallback cannot grant authority: " condition)
        Check(probe.closed = (condition = "denied" || condition = "no-creation" ? 0 : 1),"query handle released: " condition)
    }
    for stamp in ["20261027040000.123456+480","20261026200000.123456+000","20261026150000.123456-300"]
        Check(LFW_CreationMatches(stamp,134375184001234569),"offsets and sub-microsecond truncation match one process")
    for stamp in ["20261027040000.123457+480","20261027040000.123455+480","20261027040000.123456+000",
        "20261027040000.******+480","20261027040000.123456+***","20261327040000.123456+480","created",""]
        Check(!LFW_CreationMatches(stamp,134375184001234560),"wrong or incomplete time cannot match a process: " stamp)
    unknown := {ProcessId:"10",Name:"pythonw.exe",ExecutablePath:"",CreationDate:"created",CommandLine:"secret-not-for-log"}
    unrelated := unknown.Clone(), unrelated.ExecutablePath := "C:\other\pythonw.exe"
    recorder := {ProcessId:"20",Name:"ffmpeg.exe",ExecutablePath:"C:\app\ffmpeg.exe",CreationDate:"created",
        CommandLine:'"C:\app\ffmpeg.exe" "C:\video\wuthering_auto_recording_20261027_040000.mkv"'}
    own := {ProcessId:"30",Name:"LRMCAI.exe",ExecutablePath:"C:\lrmc\LRMCAI.exe",CreationDate:"created",CommandLine:'"C:\lrmc\LRMCAI.exe"'}
    io := InventoryFixture([[],[]],paths)
    Check(LauncherFreshWorkflow_Drain("fixture",io) && io.reads = 2,"MYTUF clear inventory retains two-pass behavior")
    io := InventoryFixture([[unrelated],[unrelated]],paths)
    Check(LauncherFreshWorkflow_Drain("fixture",io) && !io.closed.Length,"unrelated background tools are never closed")
    io := InventoryFixture([[unknown],[unrelated],[unrelated]],paths)
    Check(LauncherFreshWorkflow_Drain("fixture",io) && io.reads = 3 && !io.closed.Length,
        "temporary unreadable process must be re-observed instead of immediately rejecting a fresh launch")
    io := InventoryFixture([[unknown,own]],paths)
    Check(!LauncherFreshWorkflow_Drain("fixture",io) && io.tick >= 10000 && !io.closed.Length,
        "persistent unknown is bounded and cannot start destructive cleanup")
    io := InventoryFixture([[recorder],[],[]],paths)
    Check(LauncherFreshWorkflow_Drain("fixture",io) && io.reads = 3 && !io.closed.Length,"normal recording seal is wait-only")
    io := InventoryFixture([[recorder]],paths)
    Check(!LauncherFreshWorkflow_Drain("fixture",io) && io.tick >= 10000 && !io.closed.Length,"live recorder remains protected at deadline")
    io := InventoryFixture([[own],[],[]],paths)
    Check(LauncherFreshWorkflow_Drain("fixture",io) && io.closed.Length = 1,"exact owned cleanup still precedes clear passes")
    io := InventoryFixture([[own]],paths), io.closeOk := false
    Check(!LauncherFreshWorkflow_Drain("fixture",io) && io.closed.Length = 1,"denied close blocks and is not repeatedly forced")
    io := InventoryFixture([[]],paths), io.fail := true
    Check(!LauncherFreshWorkflow_Drain("fixture",io),"inventory error cannot be interpreted as clear")
    io := InventoryFixture([[],[]],paths), io.inventoryDelay := 6000
    Check(!LauncherFreshWorkflow_Drain("fixture",io),"a clear inventory arriving after the deadline cannot authorize installation")
    joined := LauncherCleanup_Join(logs,"`n")
    Check(InStr(joined,"PID=10") && InStr(joined,"name=pythonw.exe"),"blocked inventory records contain actionable PID/name")
    Check(!InStr(joined,"secret-not-for-log"),"diagnostic must not expose process command lines")
    FileAppend("PASS fresh workflow: actual query handle, missing WMI image, ownership, PID reuse, denial, bounded drain and recorder protection`n","*")
} catch as err {
    FileAppend(err.Message "`n" err.Stack,"**")
    ExitApp(1)
}
ExitApp(0)
