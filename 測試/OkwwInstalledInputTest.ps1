$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'okww-installed-input'
try {
    $sourcePath = Join-Path $root 'payload/自動開啟OKWW.ahk'
    $source = [IO.File]::ReadAllText($sourcePath)
    $fn = [regex]::Match($source,'(?ms)^ClickInstalledOkww\(.*?(?=^StartInstalledOkww\()').Value
    if (-not $fn) { throw 'Missing production installed input helper' }
    $fixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
global clicks := 0, moves := 0, safe := true, loseAfterMove := false, cancelled := false
try {
    s := {x:632,y:31,hwnd:24}, point := {x:490,y:165}
    originalMode := A_CoordModeMouse
    Check(ClickInstalledOkww(s,point) && clicks = 1 && moves = 1,"verified physical click")
    safe := false
    Check(!ClickInstalledOkww(s,point) && clicks = 1 && moves = 1,"unsafe input never moves")
    safe := true, loseAfterMove := true
    Check(!ClickInstalledOkww(s,point) && clicks = 1 && moves = 2,"foreground/identity change after movement prevents click")
    safe := true, loseAfterMove := false, cancelled := true
    Check(!ClickInstalledOkww(s,point) && clicks = 1,"cancel during movement prevents click")
    Check(A_CoordModeMouse = originalMode,"coordinate mode restored on every return")
    FileAppend("PASS: production physical-input helper (OS boundaries isolated)`n","*")
} catch as e {
    FileAppend(e.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
Check(value,label) {
    if !value
        throw Error(label)
}
InstalledOkwwInputSafe(args*) => safe
CapsLockGuard_EnsureOff(args*) => true
WriteLog(args*) => 0
Log(args*) => 0
SleepOkwwWithAbort(ms,&reason) => cancelled
MouseMove(x,y) {
    global moves,safe
    Check(x=1122 && y=196,"client origin converted to physical screen coordinates")
    moves++
    if loseAfterMove
        safe := false
}
MouseClick(button,x,y) {
    global clicks
    Check(button="left" && x=1122 && y=196,"physical left button uses converted point")
    clicks++
}
__FUNCTION__
'@
    $path = Join-Path $context.RunRoot 'input.ahk'
    [IO.File]::WriteAllText($path,$fixture.Replace('__FUNCTION__',$fn),[Text.UTF8Encoding]::new($true))
    $result = Invoke-GMTestProcess -ScriptPath $path -Context $context
    if ($result.ExitCode -ne 0) { throw ($result.Stdout+$result.Stderr) }
    $result.Stdout
    $guard = [regex]::Match($source,'(?ms)^InstalledOkwwInputSafe\(.*?(?=^ClickInstalledOkww\()').Value
    if (-not $guard) { throw 'Missing production installed input guard' }
    $guard = $guard.Replace('DllCall(', 'GuardDll(')
    $guardFixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include __ROOT__\payload\OkwwInstalledLaunch.ahk
global now := 1000, cancel := false, active := true, enabled := true, hung := false, hitRoot := 24
global identity := {hwnd:24,pid:42,path:"ok-ww.exe",started:"123",kind:"upgrade",x:632,y:31,w:1100,h:800}
try {
    s := identity.Clone(), s.capturedAt := 1000, point := {x:784,y:76}
    Check(InstalledOkwwInputSafe(s,point),"fresh identity/geometry/exact foreground accepts")
    now := 6001
    Check(!InstalledOkwwInputSafe(s,point),"stale capture rejects")
    now := 999
    Check(!InstalledOkwwInputSafe(s,point),"future timestamp rejects")
    now := 1000, identity.started := "124"
    Check(!InstalledOkwwInputSafe(s,point),"PID reuse rejects")
    identity.started := "123", identity.x := 633
    Check(!InstalledOkwwInputSafe(s,point),"moved window rejects")
    identity.x := 632, active := false
    Check(!InstalledOkwwInputSafe(s,point),"foreground lost rejects")
    active := true, enabled := false
    Check(!InstalledOkwwInputSafe(s,point),"disabled owner rejects")
    enabled := true, hung := true
    Check(!InstalledOkwwInputSafe(s,point),"hung window rejects")
    hung := false, hitRoot := 25
    Check(!InstalledOkwwInputSafe(s,point),"overlay under click rejects")
    hitRoot := 24, cancel := true
    Check(!InstalledOkwwInputSafe(s,point),"deadline or cancel rejects")
    FileAppend("PASS: real installed input guard rejects stale/reused/moved/covered/inactive/cancelled targets`n","*")
} catch as e {
    FileAppend(e.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
Check(value,label) {
    if !value
        throw Error(label)
}
ShouldAbortOkwwHandoff(&reason) => cancel
InstalledOkwwIdentity(hwnd) => identity
WinActive(args*) => active
GuardDll(name,args*) {
    switch name {
        case "GetTickCount64": return now
        case "IsWindowEnabled": return enabled
        case "IsHungAppWindow": return hung
        case "WindowFromPoint":
            Check(args[2] = (107 << 32 | 1416),"hit testing uses the actual screen point")
            return 77
        case "GetAncestor": return hitRoot
    }
    throw Error("unexpected native boundary: " name)
}
__GUARD__
'@
    $guardPath = Join-Path $context.RunRoot 'guard.ahk'
    [IO.File]::WriteAllText($guardPath,$guardFixture.Replace('__ROOT__',$root).Replace('__GUARD__',$guard),[Text.UTF8Encoding]::new($true))
    $result = Invoke-GMTestProcess -ScriptPath $guardPath -Context $context
    if ($result.ExitCode -ne 0) { throw ($result.Stdout+$result.Stderr) }
    $result.Stdout
    $out = Join-Path $context.RunRoot 'validate.stdout.log'
    $err = Join-Path $context.RunRoot 'validate.stderr.log'
    $p = Start-Process -FilePath (Join-Path $root 'AutoHotkey64.exe') -ArgumentList ('/ErrorStdOut=UTF-8 /Validate "'+$sourcePath+'"') -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    [void]$p.Handle
    try {
        if (-not $p.WaitForExit(15000)) { $p.Kill(); throw 'Manager syntax validation timed out' }
        $p.WaitForExit()
        $text = (Read-GMTestOutput $out)+(Read-GMTestOutput $err)
        if ($p.ExitCode -ne 0 -or $text -match '(?i)warning:|error:') { throw "Manager syntax: $text" }
    } finally { $p.Dispose() }
    'PASS: formal manager /Validate; no production code executed'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
