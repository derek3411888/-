[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'launcher-cleanup-identity'
try {
    $launcher=@(Get-ChildItem -LiteralPath $project -Filter '*.ahk' | Where-Object {
        [IO.File]::ReadAllText($_.FullName).Contains('ExtractZipNative(workDir) {')
    })
    $source=[IO.File]::ReadAllText($launcher[0].FullName)
    if($source -match 'ProcessClose\(pid\)' -or $source -notmatch 'LauncherCleanup_StopVerified\(process, APP_DIR\)') {
        throw 'Launcher cleanup must use a retained, revalidated identity rather than ProcessClose(pid)'
    }
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __POLICY__
global fakeCurrent := 0, fakeAlive := true, fakeHandle := 99, killCount := 0, closeCount := 0, queryFails := false
global killedHandle := 0, fakeKillResult := true
Check(ok, message) {
    if !ok
        throw Error(message)
}
FakeQuery(pid) {
    global fakeCurrent, queryFails
    if queryFails
        throw Error("fixture inventory denied")
    return fakeCurrent
}
FakeKill(handle) {
    global killCount, killedHandle, fakeKillResult
    killCount += 1, killedHandle := handle
    return fakeKillResult
}
FakeClose(handle) {
    global closeCount
    closeCount += 1
}
FakeOpen(pid) {
    global fakeHandle
    return fakeHandle
}
FakeIsAlive(handle) {
    global fakeAlive
    return fakeAlive
}
try {
    appDir := "__ROOT__\payload"
    helperPath := appDir "\" Chr(0x9032) Chr(0x7A0B) Chr(0x7BA1) Chr(0x7406) Chr(0x5668) ".ahk"
    runtime := A_AhkPath
    original := {Name:"AutoHotkey64.exe",ProcessId:123,CreationDate:"20260101010000.000000+480",
        ExecutablePath:runtime,CommandLine:'"' runtime '" "' helperPath '"'}
    ops := {open:FakeOpen,query:FakeQuery,alive:FakeIsAlive,kill:FakeKill,close:FakeClose}
    for field in ["CreationDate","ExecutablePath","CommandLine","Name","ProcessId"] {
        fakeCurrent := original.Clone()
        fakeCurrent.%field% := field = "ProcessId" ? 456 : "different"
        killCount := 0, closeCount := 0
        Check(!LauncherCleanup_StopVerified(original,appDir,ops),"changed identity not rejected: " field)
        Check(killCount = 0 && closeCount = 1,"changed identity killed or leaked: " field)
    }
    fakeCurrent := original.Clone(), fakeAlive := false, killCount := 0
    Check(!LauncherCleanup_StopVerified(original,appDir,ops) && killCount = 0,"exited retained process authorized kill")
    fakeAlive := true, fakeHandle := 0
    Check(!LauncherCleanup_StopVerified(original,appDir,ops) && killCount = 0,"inaccessible handle authorized kill")
    fakeHandle := 99, queryFails := true
    Check(!LauncherCleanup_StopVerified(original,appDir,ops) && killCount = 0,"failed fresh inventory authorized kill")
    queryFails := false, fakeKillResult := false
    Check(!LauncherCleanup_StopVerified(original,appDir,ops),"failed termination/wait reported success")
    fakeKillResult := true, killCount := 0, closeCount := 0
    Check(LauncherCleanup_StopVerified(original,appDir,ops),"exact identity rejected")
    Check(killCount = 1 && killedHandle = 99 && closeCount = 1,"termination must use retained handle once")
    fakeCurrent := original.Clone()
    original.CreationDate := "", killCount := 0
    Check(!LauncherCleanup_StopVerified(original,appDir,ops) && killCount = 0,"missing creation identity accepted")

    ; Actual inert helper in a temporary installation. No formal script is run.
    DirCreate(appDir)
    FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`nSleep(30000)`nExitApp(0)`n",helperPath,"UTF-8")
    Run('"' runtime '" /ErrorStdOut "' helperPath '"',appDir,"Hide",&helperPid)
    child := LauncherCleanup_QueryIdentity(helperPid)
    Check(IsObject(child),"native fixture identity not observable")
    Check(LauncherCleanup_StopVerified(child,appDir),"native exact helper cleanup failed")
    ProcessWaitClose(helperPid,2)
    Check(!ProcessExist(helperPid),"native helper did not exit")
    FileAppend("PASS cleanup retained identity: changed PID/creation/image/command/name, exited/inaccessible/denied, exact native helper`n","*")
} catch as fixtureError {
    FileAppend(fixtureError.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
'@
    $fixture=$fixture.Replace('__POLICY__',(Join-Path $project 'LauncherProcessCleanupPolicy.ahk')).Replace('__ROOT__',$context.RunRoot)
    $path=Join-Path $context.RunRoot 'cleanup-identity.ahk'
    [IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($false))
    $result=Invoke-GMTestProcess -ScriptPath $path -Context $context
    if($result.Stdout){Write-Output $result.Stdout.TrimEnd()}
    if($result.ExitCode -ne 0){throw $result.Stderr}
} finally { Complete-ProjectDevelopmentPaths -Context $context }
