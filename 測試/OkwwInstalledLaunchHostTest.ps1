$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'okww-installed-host'
try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'payload/自動開啟OKWW.ahk'))
    $marker = '; ====================== 前檢查與四階段流程 ======================'
    $offset = $source.IndexOf($marker)
    if ($offset -lt 0) { throw 'Missing production manager flow' }
    # Execute the real entry branch; replace only process exit and external UI boundaries.
    $flow = [regex]::Replace($source.Substring($offset), '(?m)^\s*ExitApp\s*$', '    return')
    $fixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
global state := "not_found", launchCalls := 0, updateClicks := 0
try {
    RunFlow()
    if (launchCalls != 1 || updateClicks != 0)
        throw Error("installed launcher must start without upgrading; launches=" launchCalls " updates=" updateClicks)
    for result in ["capture_failed", "handoff_aborted", "final_ready", "final_handoff_failed"] {
        state := result
        RunFlow()
        if (launchCalls != 1 || updateClicks != 0)
            throw Error("terminal/unknown capture must not click: " result)
    }
    state := "found"
    RunFlow()
    if (updateClicks != 4 || launchCalls != 1)
        throw Error("legacy update flow must remain unchanged")
    FileAppend("PASS: installed launcher host routing`n", "*")
} catch as e {
    FileAppend(e.Message "`n", "**")
    ExitApp(1)
}
ExitApp(0)
DetectOCRText(args*) => state
StartInstalledOkww() {
    global launchCalls
    launchCalls++
    return "final_ready"
}
DoOCRClick(args*) {
    global updateClicks
    updateClicks++
    return true
}
WriteStep(args*) => 0
ShowTip(args*) => 0
Log(args*) => 0
RunFlow() {
__FLOW__
}
'@
    $path = Join-Path $context.RunRoot 'host.ahk'
    [IO.File]::WriteAllText($path, $fixture.Replace('__FLOW__', $flow), [Text.UTF8Encoding]::new($true))
    $result = Invoke-GMTestProcess -ScriptPath $path -Context $context
    if ($result.ExitCode -ne 0) { throw ($result.Stdout + $result.Stderr) }
    $result.Stdout
    $clickFn = [regex]::Match($source,'(?ms)^DoOCRClick\(.*?(?=^; ====================== 已安裝啟動器)').Value
    if (-not $clickFn) { throw 'Missing production OCR click' }
    $clickFixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
global targetHwnd := 11, clicks := 0
Block(t,x,y) => {text:t,boxPoint:[{x:x,y:y},{x:x+140,y:y},{x:x+140,y:y+30},{x:x,y:y+30}]}
global blocks := [Block("處理完成。請檢視日誌並點選「完成」。",600,400),Block("完成",420,150)]
try {
    if !DoOCRClick("完成","fixture","rightbottom","",1) || clicks != 1
        throw Error("legacy completion must click unique exact button")
    blocks := [Block("處理完成。請檢視日誌並點選「完成」。",600,400)]
    if DoOCRClick("完成","fixture","rightbottom","",1) || clicks != 1
        throw Error("instruction without button cannot click")
    blocks := [Block("完成",420,150),Block("完成",20,30)]
    if DoOCRClick("完成","fixture","rightbottom","",1) || clicks != 1
        throw Error("ambiguous completion cannot click")
    FileAppend("PASS: real legacy completion does not click instruction text or ambiguous buttons`n","*")
} catch as e {
    FileAppend(e.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
ShouldAbortOkwwHandoff(&reason := "") => false
CaptureAndOCR(args*) => {ok:true,blocks:blocks}
SleepOkwwWithAbort(ms,&reason := "") => false
IsValidHwnd(args*) => true
WaitForOkwwWindowActive(hwnd,ms,&reason) => true
WinActivate(args*) => 0
CapsLockGuard_EnsureOff(args*) => true
WriteLog(args*) => 0
Log(args*) => 0
ShowTip(args*) => 0
MouseMove(x,y) {
    if x != 490 || y != 165
        throw Error("completion instruction was selected instead of button")
}
MouseClick(button,x,y) {
    global clicks
    if button != "left" || x != 490 || y != 165
        throw Error("wrong completion click")
    clicks++
}
__FUNCTION__
'@
    $path = Join-Path $context.RunRoot 'legacy-completion.ahk'
    [IO.File]::WriteAllText($path, $clickFixture.Replace('__FUNCTION__', $clickFn), [Text.UTF8Encoding]::new($true))
    $result = Invoke-GMTestProcess -ScriptPath $path -Context $context
    if ($result.ExitCode -ne 0) { throw ($result.Stdout + $result.Stderr) }
    $result.Stdout
} finally { Complete-ProjectDevelopmentPaths -Context $context }
