[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'hotfix-host'
try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $start = $source.IndexOf('        if (foundUpdate && IsObject(btnCenter)) {')
    $end = $source.IndexOf('        ; ✅', $start)
    if ($start -lt 0 -or $end -lt 0) { throw 'Missing production update-dialog branch' }
    $branch = $source.Substring($start, $end-$start)
    $gate = [regex]::Match($source,'(?m)^\s*if InStr\(clean, kwUpdate1\).*').Value.Trim()
    $keywords = [regex]::Match($source,'(?ms)^    kwUpdate1 :=.*?(?=^    kwBtn)').Value
    if (-not $gate) { $gate = [regex]::Match($source,'(?m)^\s*if GH_IsCompletionText\(clean\).*').Value.Trim() }
    if (-not $gate) { throw 'Missing actual update text gate' }
    $startup = [regex]::Match($source,'(?m)^LoadServerScheduleContext\([^\r\n]+\)').Value
    $schedule = foreach ($name in @('LoadServerScheduleContext','ResolveNextPendingServerIndexInCurrentCycle')) {
        $match = [regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)')
        if (-not $match.Success) { throw "Missing schedule function $name" }
        $match.Value
    }
    $scheduleSource = $schedule -join "`n"
    $fixture = @"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
#Include $root\payload\GameHotfixRecovery.ahk
global hotfixCalls := 0
global CFG_FILE := "$($context.RunRoot)\isolated-schedule.ini", SERVER_SCHEDULE_ENABLED := false, SERVER_SCHEDULE_LIST := [], SERVER_SCHEDULE_INDEX := 1, CURRENT_SERVER_TARGET := "", SERVER_SWITCH_POINT_X := 0, SERVER_SWITCH_POINT_Y := 0
GMTest_Run(TestActualHotfixBranch)
TestActualHotfixBranch() {
    global hotfixCalls, CFG_FILE, SERVER_SCHEDULE_INDEX, CURRENT_SERVER_TARGET
    for text in ["更新完成，游戏即将重启。","請重新啟動遊戲"]
        GMTest_Assert(ActualBranch(text) = "update", "actual OCR gate must route both locales to verified exit")
    GMTest_Assert(hotfixCalls = 2, "actual production branch must enter hotfix recovery once per prompt")
    IniWrite("1",CFG_FILE,"server_schedule","enabled")
    IniWrite("HMT|Asia",CFG_FILE,"server_schedule","list")
    IniWrite("2",CFG_FILE,"server_schedule","current_index")
    ActualStartup(true,false,false)
    GMTest_Assert(SERVER_SCHEDULE_INDEX = 2 && CURRENT_SERVER_TARGET = "Asia", "internal hotfix restart retains Asia even when earlier HMT is unfinished and no maintenance event exists")
    ActualStartup(false,false,false)
    GMTest_Assert(SERVER_SCHEDULE_INDEX = 1 && CURRENT_SERVER_TARGET = "HMT", "fresh user start still begins with first pending server")
    IniWrite("2",CFG_FILE,"server_schedule","current_index")
    ActualStartup(false,true,false)
    GMTest_Assert(CURRENT_SERVER_TARGET = "Asia", "nextserver retains selected server")
}
ActualBranch(clean) {
    foundUpdate := false, btnCenter := [840,454], hwnd := 123
$keywords
    $gate
        foundUpdate := true
    loop 1 {
$branch
    }
    return "not-handled"
}
HandleWutheringHotfix(hwnd) {
    global hotfixCalls
    hotfixCalls++
    return "exited"
}
GM_StopForManualUpdate(args*) => GMTest_Assert(false,"regression: ordinary completed patch is incorrectly classified as manual version update")
WriteStep(args*) => 0
Sleep(args*) => 0
ActualStartup(isRestart,isNextServerCycle,isRemoteServerSwitchCycle) {
    $startup
}
IniReadSafe(path,section,key,fallback) => IniRead(path,section,key,fallback)
ParseBool01(value,args*) => value = "1"
ParseServerScheduleList(value) => StrSplit(value,"|")
IsServerCompletedInCurrentCycle(server) => false
SyncRemoteControlRuntimeState() => 0
WriteLog(args*) => 0
$scheduleSource
"@
    $path = Join-Path $context.RunRoot 'actual-hotfix-branch.ahk'
    [IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($true))
    $result = Invoke-GMTestProcess $path $context 20
    if ($result.Stdout) { $result.Stdout }
    if ($result.Stderr) { $result.Stderr }
    Assert-GMEqual $result.ExitCode 0 'weekday hotfix production branch'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
