[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'caps-lock-integration'
try {
    $main = [IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $synthesis = [IO.File]::ReadAllText((Join-Path $root 'payload\聲骸合成.ahk'))
    $tick = [regex]::Match($main,'(?ms)^CapsLockGuardTick\(\) \{.*?^\}').Value
    $permission = [regex]::Match($main,'(?ms)^CapsLockGuardMayCheck\(\) \{.*?^\}').Value
    $gate = [regex]::Match($synthesis,'(?ms)^SynthesisEnsureInputAllowed\(\) \{.*?^\}').Value
    Assert-GMTrue ([bool]$tick) 'Missing RUN-only Caps Lock periodic guard'
    Assert-GMTrue ([bool]$gate) 'Missing synthesis input boundary'
    Assert-GMTrue ([bool]$permission) 'Missing live Caps Lock main admission gate'
    # Replace OS/guard side effects only; execute the real production admission gates.
    $functions = ($tick + "`n" + $gate + "`n" + $permission) -replace '\bCapsLockGuard_EnsureOff\b','HostCapsClear' -replace '\bGetKeyState\b','HostKeyState'
    $fixture = @'
#Requires AutoHotkey v2.0
global REMOTE_STOP_IN_PROGRESS := false, EXITING_FROM_TRAY := false
global __RESTART_IN_PROGRESS := false, __NEXTSERVER_RESTART := false
global __CLEAN_FINAL_EXIT_REQUESTED := false, REMOTE_CONTROL_ACTIVE := true
global paused := false, stopped := false, desktopOk := true, capsOn := true, clears := 0
global pauseDuringDesktopCheck := false
global SYNTHESIS_INPUT_IDENTITY := {Alive: (*) => true}
global COMPLETION_CONTEXT := {EnsureRun: CheckChildRun}
try {
    CapsLockGuardTick()
    Check(clears = 1, "RUN must check Caps Lock")
    for blocked in ["pause","stop","exit","restart","nextserver","finished","maintenance","desktop","off"] {
        paused := blocked = "pause", REMOTE_STOP_IN_PROGRESS := blocked = "stop"
        EXITING_FROM_TRAY := blocked = "exit", __RESTART_IN_PROGRESS := blocked = "restart"
        __NEXTSERVER_RESTART := blocked = "nextserver", __CLEAN_FINAL_EXIT_REQUESTED := blocked = "finished"
        stopped := blocked = "maintenance", desktopOk := blocked != "desktop", capsOn := blocked != "off"
        CapsLockGuardTick()
        Check(clears = 1, "periodic guard must suppress input during " blocked)
    }
    paused := false, REMOTE_STOP_IN_PROGRESS := false, EXITING_FROM_TRAY := false
    __RESTART_IN_PROGRESS := false, __NEXTSERVER_RESTART := false, __CLEAN_FINAL_EXIT_REQUESTED := false
    stopped := false, desktopOk := true, capsOn := true
    pauseDuringDesktopCheck := true
    CapsLockGuardTick()
    Check(clears = 1, "main must supply a live gate so a newer PAUSE suppresses correction")
    pauseDuringDesktopCheck := false, paused := false
    SynthesisEnsureInputAllowed()
    Check(clears = 2, "synthesis input boundary must clear Caps Lock")
    for blocked in ["pause","desktop","identity"] {
        paused := blocked = "pause", desktopOk := blocked != "desktop"
        SYNTHESIS_INPUT_IDENTITY := {Alive: (*) => blocked != "identity"}
        denied := false
        try SynthesisEnsureInputAllowed()
        catch
            denied := true
        Check(denied && clears = 2, "synthesis existing barrier must precede Caps Lock during " blocked)
    }
    FileAppend("PASS: real main RUN/pause/stop/desktop gates and synthesis input boundary`n", "*")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL: " err.Message "`n", "**")
    ExitApp(1)
}
Check(ok, detail) {
    if !ok
        throw Error(detail)
}
RC_IsPaused() => paused
GM_IsMaintenanceStopped() => stopped
GetInteractiveDesktopState() {
    global paused
    if pauseDuringDesktopCheck
        paused := true
    return {ok:desktopOk}
}
HostKeyState(args*) => capsOn
SynthesisDesktopAllowsInput() => desktopOk
CheckChildRun(args*) {
    if paused
        throw Error("child paused")
}
HostCapsClear(logFn := 0, allowed := true) {
    global clears
    if IsObject(allowed) && !allowed.Call()
        return "disabled"
    clears += 1
}
WriteLog(args*) => 0
'@
    $path = Join-Path $context.RunRoot 'caps-lock-host.ahk'
    [IO.File]::WriteAllText($path,$fixture + "`n" + $functions,[Text.UTF8Encoding]::new($true))
    $result = Invoke-GMTestProcess -ScriptPath $path -Context $context
    Write-Output $result.Stdout
    Write-Output $result.Stderr
    Assert-GMEqual $result.ExitCode 0 'Caps Lock host admission gates'
    foreach ($name in @('全自動','聲骸合成','開啟LRMC','自動開啟OKWW')) {
        $source = Join-Path $root ('payload\' + $name + '.ahk')
        $stdout = Join-Path $context.RunRoot ($name + '.stdout.log')
        $stderr = Join-Path $context.RunRoot ($name + '.stderr.log')
        $proc = Start-Process -FilePath (Join-Path $root 'AutoHotkey64.exe') -ArgumentList ('/ErrorStdOut=UTF-8 /Validate "' + $source + '"') -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        [void]$proc.Handle
        try {
            if (-not $proc.WaitForExit(15000)) { $proc.Kill(); throw "$name syntax validation timed out" }
            $proc.WaitForExit()
            $output = (Read-GMTestOutput $stdout) + (Read-GMTestOutput $stderr)
            Assert-GMTrue ($proc.ExitCode -eq 0 -and $output -notmatch '(?i)warning:|error:') "$name validation failed: $output"
        } finally { $proc.Dispose() }
    }
    'PASS: four production entrypoints validate without running game flow'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
