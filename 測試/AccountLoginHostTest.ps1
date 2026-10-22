$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'account-login-host'
try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $fn = [regex]::Match($source,'(?ms)^DetectWutheringAndExit\(&loginDetected := false\) \{.*?(?=^WutheringUpdateProcessAlive\()').Value
    if (-not $fn) { throw 'Missing production detection loop' }
    $fixture = @"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
global WUTHERING_NO_WINDOW_TOLERANCE := 3, tick := 100000, captures := 0, accountCalls := 0, scenario := "owned"
GMTest_Run(TestAccountLoginRoute)
TestAccountLoginRoute() {
    global accountCalls,captures,scenario
    for mode in ["owned","embedded"] {
        accountCalls := 0, captures := 0, scenario := mode
        result := DetectWutheringAndExit(&detected)
        GMTest_Assert(accountCalls = 1, "KURO account login must be handled before returning normal login UI: " mode)
        GMTest_Assert(result = "login" && detected, "click attempt still requires a subsequent real login-screen observation")
        GMTest_Assert(captures >= (mode = "owned" ? 1 : 2), "subsequent normal login observations still run")
    }
}
MonotonicTickMs() {
    global tick
    tick += 1000
    return tick
}
Sleep(ms) {
    global tick
    tick += ms
}
WaitForWutheringGameWindow(args*) => 12
GetWutheringGameHwnd() => 12
GetWutheringWindowIdentity(hwnd,&pid,&class,&reason) {
    pid := 42, class := "UnrealWindow", reason := ""
    return true
}
PositionWutheringWindowTopRight(args*) => true
GM_GameMaintenanceProbe(args*) {
    global scenario,accountCalls
    GMTest_Assert(scenario != "owned" || accountCalls = 1,"owned login must run before maintenance probe can block in main PrintWindow")
    return false
}
TryAssistLoginTemplateBeforeOcr() => 0
ClickTemplateIfFound(args*) => false
RuntimeFiles_NewImagePath(args*) => "$($context.RunRoot)\absent.png"
ImagePutBuffer(args*) {
    global scenario,accountCalls
    GMTest_Assert(scenario != "owned" || accountCalls = 1,"main PrintWindow is never called while the owned login is unresolved")
    return {width:1280,height:720}
}
ImagePutFile(args*) => 0
class RapidOcr {
    ocr_from_file(args*) {
        global captures,scenario
        captures++
        if scenario = "embedded" && captures = 1
            return [{text:"KURO GAMES"},{text:"登录"},{text:"其他登录方式"}]
        return [{text:"點擊連接"},{text:"伺服器 Asia"}]
    }
}
HandleWutheringAccountLogin(hwnd,blocks,width,height,capturedAt,&io) {
    global accountCalls,scenario
    if blocks.Length = 0 {
        if scenario = "owned" && accountCalls = 0 {
            accountCalls++
            return true
        }
        return false
    }
    if blocks[2].text != "登录"
        return false
    GMTest_Assert(hwnd = 12 && width = 1280 && height = 720 && capturedAt > 0,"route carries exact captured client and timestamp")
    accountCalls++
    return true
}
GH_IsCompletionText(args*) => false
HandleWutheringHotfix(args*) => "retry"
ShowTip(args*) => 0
WriteStep(args*) => 0
WriteStepResult(args*) => 0
WriteLog(args*) => 0
MuteWutheringAudioAtStartup(args*) => 0
TryMuteWutheringAudio(args*) => 0
$fn
"@
    $path = Join-Path $context.RunRoot 'account-login-route.ahk'
    [IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($true))
    $r = Invoke-GMTestProcess $path $context 20
    if ($r.Stdout) { $r.Stdout }
    if ($r.Stderr) { $r.Stderr }
    Assert-GMEqual $r.ExitCode 0 'production account-login route'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
