$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'account-login-click-guard'
try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $fn = [regex]::Match($source,'(?ms)^ClickVerifiedWindowClientPoint\(.*?(?=^SendKeyToVerifiedWindow\()').Value
    if (-not $fn) { throw 'Missing production physical-click helper' }
    $fixture = @"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
global clicks := 0, intent := "RUN", stopDuringMove := false, foregroundSafe := true, desktopSafe := true, legacyPrepares := 0
GMTest_Run(TestFinalClickGuard)
TestFinalClickGuard() {
    global clicks,intent,stopDuringMove,foregroundSafe,desktopSafe,legacyPrepares
    guard := (*) => intent = "RUN"
    GMTest_Assert(ClickVerifiedWindowClientPoint(24,340,230,42,"test",guard) && clicks = 1,"production helper accepts final caller guard")
    stopDuringMove := true
    GMTest_Assert(!ClickVerifiedWindowClientPoint(24,340,230,42,"test",guard) && clicks = 1,"STOP after mouse movement prevents physical click")
    stopDuringMove := false, intent := "RUN", foregroundSafe := false
    GMTest_Assert(!ClickVerifiedWindowClientPoint(24,340,230,42,"test",guard) && clicks = 1,"root-only foreground guard remains enforced")
    foregroundSafe := true, desktopSafe := false
    GMTest_Assert(!ClickVerifiedWindowClientPoint(24,340,230,42,"test",guard) && clicks = 1,"desktop lock before final input prevents click")
    desktopSafe := true
    GMTest_Assert(ClickVerifiedWindowClientPoint(24,340,230,42,"legacy") && clicks = 2,"existing callers remain compatible")
    baseline := legacyPrepares
    GMTest_Assert(ClickVerifiedWindowClientPoint(24,340,230,42,"login",guard,(*) => true) && clicks = 3 && legacyPrepares = baseline,"login callback does not invoke legacy activation fallback")
    GMTest_Assert(!ClickVerifiedWindowClientPoint(24,340,230,42,"login",guard,(*) => false) && clicks = 3 && legacyPrepares = baseline,"failed safe activation never falls back to physical Alt or caption input")
}
PrepareVerifiedWindowForInput(args*) {
    global legacyPrepares
    legacyPrepares++
    return true
}
WinGetClientPos(&x,&y,&w,&h,args*) {
    x := 400, y := 250, w := 600, h := 400
}
MouseMove(args*) => 0
RawSleep(args*) {
    global intent,stopDuringMove
    if stopDuringMove
        intent := "STOP"
}
WinGetPID(args*) => 42
GetForegroundRelationToTarget(hwnd,&foregroundHwnd) {
    foregroundHwnd := hwnd
    return "exact"
}
IsSafeInputWindowRelation(relation,policy) {
    global foregroundSafe
    GMTest_Assert(policy = "root","must not broaden generic input to arbitrary owned windows")
    return foregroundSafe
}
IsTargetWindowAtScreenPoint(hwnd,x,y,&hit,&relation) {
    hit := hwnd, relation := "exact"
    return true
}
GetInteractiveDesktopState() {
    global desktopSafe
    return {ok:desktopSafe}
}
MouseClick(button,x,y) {
    global clicks
    GMTest_Assert(button = "Left" && x = 740 && y = 480,"uses physical left click at verified dialog-relative point")
    clicks++
}
WriteLog(args*) => 0
$fn
"@
    $path = Join-Path $context.RunRoot 'account-login-click-guard.ahk'
    [IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($true))
    $r = Invoke-GMTestProcess $path $context 20
    if ($r.Stdout) { $r.Stdout }
    if ($r.Stderr) { $r.Stderr }
    Assert-GMEqual $r.ExitCode 0 'production physical-click final guard'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
