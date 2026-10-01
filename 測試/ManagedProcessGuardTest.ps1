$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'managed-process-guard'
try {
    $guard=Join-Path $root 'payload\ManagedProcessGuard.ahk'
    Assert-GMTrue (Test-Path -LiteralPath $guard) 'Missing exact-identity guard: same-named processes must not be terminated'
    $child=Join-Path $context.RunRoot 'guard-child.ahk'
    [IO.File]::WriteAllText($child,"#Requires AutoHotkey v2.0`n#NoTrayIcon`nSleep(15000)`nExitApp(0)`n",[Text.UTF8Encoding]::new($true))
    $fixture=Join-Path $context.RunRoot 'guard-test.ahk'
    $body=@"
#Requires AutoHotkey v2.0
#NoTrayIcon
#Include $root\測試\GameMaintenanceFixtures.ahk
#Include $guard
GMTest_Run(TestExactProcess)
TestExactProcess() {
    expected := A_AhkPath
    GMTest_Assert(!IsObject(MPG_ReadRecord(DllCall("GetCurrentProcessId"),expected)),"cannot adopt self for termination")
    FileCreateShortcut(expected,A_ScriptDir "\runtime.lnk")
    GMTest_Assert(MPG_CanonicalPath(A_ScriptDir "\runtime.lnk") = MPG_CanonicalPath(expected),"shortcut resolves configured executable")
    GMTest_Assert(MPG_CanonicalPath(A_ScriptDir "\missing.exe") = "","missing path cannot be trusted")
    Run('"' A_AhkPath '" "$child"',A_ScriptDir,"Hide",&childPid)
    Sleep(300)
    record := MPG_ReadRecord(childPid,expected)
    GMTest_Assert(IsObject(record),"isolated child has verified PID path and creation time")
    GMTest_Assert(!IsObject(MPG_ReadRecord(childPid,A_ScriptDir "\missing.exe")),"unrelated configured path cannot adopt child")
    stale := record.Clone(), stale.started .= "-stale"
    GMTest_Assert(!MPG_CloseRecord(stale) && !!ProcessExist(childPid),"creation mismatch preserves isolated child")
    wrong := record.Clone(), wrong.path := A_ScriptDir "\missing.exe"
    GMTest_Assert(!MPG_CloseRecord(wrong) && !!ProcessExist(childPid),"path mismatch preserves isolated child")
    GMTest_Assert(!GMU_ProcessIdentityMatches(record,childPid+1,record.path,record.started),"different PID is rejected")
    GMTest_Assert(!GMU_ProcessIdentityMatches(record,childPid,record.path,""),"empty creation identity is rejected")
    GMTest_Assert(!MPG_CloseRecord({}) && !MPG_CloseRecord(0),"malformed cleanup records fail closed")
    GMTest_Assert(MPG_CloseRecord(record),"matching isolated child can close")
    GMTest_Assert(!ProcessExist(childPid),"only owned child exited")
    GMTest_Assert(MPG_CloseRecord(record),"already closed exact child is idempotent")
}
"@
    [IO.File]::WriteAllText($fixture,$body,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess -ScriptPath $fixture -Context $context
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'Exact process guard regression'
    $mainSource=[IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $cleanup=[regex]::Match($mainSource,'(?ms)^CloseExactProcessForSelfHealing\([^\n]*\) \{.*?^\}').Value
    Assert-GMTrue ([bool]$cleanup) 'Missing main cleanup implementation'
    # Replace only OS process enumeration; retain the real cleanup decision logic.
    $cleanup=$cleanup.Replace('ComObjGet(', 'TestWmi(')
    $fixture=Join-Path $context.RunRoot 'main-cleanup-test.ahk'
    $body=@"
#Requires AutoHotkey v2.0
#NoTrayIcon
#Include $root\測試\GameMaintenanceFixtures.ahk
global recordedPids := [], processes := [{ProcessId:900001,Name:"LRMCAI.exe"},{ProcessId:900002,Name:"LRMCAI.exe"}]
GMTest_Run(TestMainCleanup)
TestMainCleanup() {
    global recordedPids
    count := CloseExactProcessForSelfHealing("LRMCAI.exe","fixture")
    GMTest_Assert(count = 1 && recordedPids.Length = 1 && recordedPids[1] = 900001,"cleanup preserves same filename at an unrelated full path")
}
TestWmi(*) {
    global processes
    return {ExecQuery:(*) => processes}
}
ResolveManagedTargetExePath(*) => "C:\verified\LRMCAI.exe"
ReadManagedProcessRecord(pid) => {pid:pid,path:pid=900001?"C:\verified\LRMCAI.exe":"D:\unrelated\LRMCAI.exe",started:"20261001090000.000000+480"}
CloseOkwwProcessPid(pid,*) {
    global recordedPids
    recordedPids.Push(pid)
    return true
}
CloseManagedProcessRecord(record,*) => CloseOkwwProcessPid(record.pid)
WriteLog(*) => 0
$cleanup
"@
    [IO.File]::WriteAllText($fixture,$body,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess -ScriptPath $fixture -Context $context
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'Main cleanup same-name isolation'
    $extracted=''
    foreach($name in @('IsOkwwPythonProcess','CloseOkwwPythonProcesses')) {
        $function=[regex]::Match($mainSource,'(?ms)^'+$name+'\([^\n]*\) \{.*?^\}').Value
        Assert-GMTrue ([bool]$function) "Missing cleanup function $name"
        $extracted+=$function.Replace('ComObjGet(', 'TestWmi(')+"`n"
    }
    $fixture=Join-Path $context.RunRoot 'python-cleanup-reuse.ahk'
    $body=@"
#Requires AutoHotkey v2.0
#NoTrayIcon
#Include $root\測試\GameMaintenanceFixtures.ahk
#Include $guard
global reads := 0, accepted := []
GMTest_Run(TestPythonIdentity)
TestPythonIdentity() {
    global accepted
    CloseOkwwPythonProcesses()
    GMTest_Assert(accepted.Length = 1 && accepted[1].path = "C:\OKWW\pythonw.exe"
        && accepted[1].started = "original","Python classification must retain its original immutable identity through close")
}
TestWmi(*) => {ExecQuery:(*) => [{ProcessId:900010,Name:"pythonw.exe",CommandLine:"ok-ww",CreationDate:"original"}]}
ResolveManagedTargetExePath(*) => "C:\OKWW\ok-ww.exe"
ReadManagedProcessRecord(*) {
    global reads
    reads++
    return reads = 1 ? {pid:900010,path:"C:\OKWW\pythonw.exe",started:"original"}
        : {pid:900010,path:"D:\unrelated\pythonw.exe",started:"replacement"}
}
CloseManagedProcessRecord(record,*) {
    global accepted
    accepted.Push(record)
    return false
}
WriteLog(*) => 0
$extracted
"@
    [IO.File]::WriteAllText($fixture,$body,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess -ScriptPath $fixture -Context $context
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'Python cleanup must not adopt a reused PID'
    $guardSource=[IO.File]::ReadAllText($guard)
    $close=[regex]::Match($guardSource,'(?ms)^MPG_CloseRecord\([^\n]*\) \{.*?^\}').Value
    Assert-GMTrue ([bool]$close) 'Missing handle-bound close implementation'
    $close=$close.Replace('DllCall(', 'TestNative(').Replace('ProcessExist(', 'TestProcessExist(').Replace('MPG_ReadHandleRecord(', 'TestReadHandle(')
    $body=@"
#Requires AutoHotkey v2.0
#NoTrayIcon
#Include $root\測試\GameMaintenanceFixtures.ahk
#Include $root\payload\GameUpdateAdapters.ahk
global terminatedHandle := 0, pidReused := false, unsafePidClose := 0
GMTest_Run(TestBoundHandle)
TestBoundHandle() {
    global terminatedHandle, pidReused, unsafePidClose
    record := {pid:900001,path:"C:\owned\fixture.exe",started:"original"}
    GMTest_Assert(MPG_CloseRecord(record),"owned handle reports termination")
    GMTest_Assert(pidReused && terminatedHandle = 77 && unsafePidClose = 0,"PID reuse after query cannot retarget the fixed process handle")
}
TestReadHandle(handle,pid) {
    global pidReused
    GMTest_Assert(handle = 77 && pid = 900001,"identity queried on the opened object")
    pidReused := true
    return {pid:900001,path:"C:\owned\fixture.exe",started:"original"}
}
TestProcessExist(*) => 900001
TestNative(name,args*) {
    global terminatedHandle
    if name = "GetCurrentProcessId"
        return 42
    if name = "OpenProcess"
        return 77
    if name = "TerminateProcess" {
        terminatedHandle := args[2]
        return true
    }
    if name = "WaitForSingleObject"
        return 0
    return true
}
TestUnsafePidClose(pid) {
    global unsafePidClose
    unsafePidClose := pid
    return true
}
GMU_ProcessIdentityMatches(record,pid,path,started) => record.pid = pid && record.path = path && record.started = started
$close
"@
    $fixture=Join-Path $context.RunRoot 'same-handle-close.ahk'
    [IO.File]::WriteAllText($fixture,$body,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess -ScriptPath $fixture -Context $context
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'Same-handle validation and termination'
    $needle='TestNative("TerminateProcess","ptr",handle,"uint",0)'
    Assert-GMTrue ($body.Contains($needle)) 'Missing termination seam for regression mutation'
    $mutant=$body.Replace($needle,'TestUnsafePidClose(record.pid)')
    $fixture=Join-Path $context.RunRoot 'reject-pid-reacquire.ahk'
    [IO.File]::WriteAllText($fixture,$mutant,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess -ScriptPath $fixture -Context $context
    Assert-GMTrue ($result.ExitCode -ne 0 -and ($result.Stdout+$result.Stderr).Contains('PID reuse after query cannot retarget')) 'Test must reject termination by a reacquired bare PID'
    Write-Output 'PASS: regression rejected bare-PID termination after identity query'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
