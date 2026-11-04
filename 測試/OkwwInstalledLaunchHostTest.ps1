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
} finally { Complete-ProjectDevelopmentPaths -Context $context }
