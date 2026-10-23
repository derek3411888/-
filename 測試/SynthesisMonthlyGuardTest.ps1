[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$run = Join-Path $root '.dev-runtime\diagnostics\game-maintenance\20261023-restart-synthesis'
[void][IO.Directory]::CreateDirectory($run)
$source = [IO.File]::ReadAllText((Join-Path $root 'payload\聲骸合成.ahk'))
$body = [regex]::Match($source, '(?s)\r?\nWaitEscMenuOCR\(hwnd, timeoutSec := 120\) \{.*?(?=\r?\n; 驗證是否正確進入背包面板)')
if (-not $body.Success) { throw 'Cannot isolate actual monthly-card HUD wait' }
$harness = @'
#Requires AutoHotkey v2.0
global logger := GuardLogger(), SYNTHESIS_INPUT_IDENTITY := {hwnd:11}
global guards := 0, activations := 0, unsafeActivations := 0, activeTick := 0
try {
    if !WaitEscMenuOCR(11,15)
        throw Error("actual HUD wait did not reach two samples")
    if activations < 2 || guards < 3 || unsafeActivations != 0
        throw Error("monthly-card HUD wait bypassed lease/PAUSE/identity guarded ActivateGame")
    FileAppend("PASS: actual monthly-card HUD wait gates each foreground activation and observation`n","*")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL: " err.Message "`n","**")
    ExitApp(1)
}
class GuardLogger {
    log(args*) {
    }
}
SynthesisEnsureInputAllowed() {
    global guards
    guards += 1
    return true
}
ActivateGame() {
    global activations
    activations += 1
    SynthesisEnsureInputAllowed()
    return true
}
WinActivate(args*) {
    global unsafeActivations
    unsafeActivations += 1
}
WinGetPos(&x,&y,&w,&h,args*) {
    x := 0, y := 0, w := 1280, h := 720
}
ImageSearch(&x,&y,args*) {
    x := 900, y := 650
    return true
}
FileExist(path) => "A"
Sleep(ms) {
    global activeTick
    activeTick += ms
}
SynthesisActiveTick() {
    global activeTick
    return activeTick
}
'@
$path = Join-Path $run 'SynthesisMonthlyGuardHarness.ahk'
[IO.File]::WriteAllText($path, $harness + "`r`n" + $body.Value, [Text.UTF8Encoding]::new($true))
& (Join-Path $root 'AutoHotkey64.exe') /ErrorStdOut=UTF-8 $path 2>&1 | ForEach-Object { $_ }
if ($LASTEXITCODE -ne 0) { throw 'Actual monthly-card HUD wait bypassed input guard' }
