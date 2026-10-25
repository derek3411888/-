[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$run=Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\20261025-fresh-start-takeover\state-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($run)
$context=[pscustomobject]@{ProjectRoot=$project;Root=(Join-Path $project '.dev-runtime');RunRoot=$run}
$source=[IO.File]::ReadAllText((Join-Path $project 'payload\全自動.ahk'))
$functions=''
foreach($name in @('ClearCompletedRewardPendingOnFreshStart','CanReplaceCompletedRewardMonitorState','ClearRewardMonitorRuntimeState','IniReadSafe')){
    $match=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?^\}')
    Assert-GMTrue $match.Success ('Missing actual host function '+$name)
    $functions+="`n"+$match.Value
}
$fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include *i __PROJECT__\payload\FreshRunState.ahk
global CFG_FILE := "", REWARD_MONITOR_STATE_SECTION := "reward_monitor_runtime"
global __REWARD_MONITOR_COMPLETION_PENDING := true, drained := true, fixtureRoot := "", caseNo := 0
WriteLog(*) => 0
CS_RewardAlreadySucceeded(*) => false
class CompletionSynthesisIo {
    Drained() => drained
}
RuntimeFiles_RuntimeDir(category) {
    path := fixtureRoot "\" category
    if !DirExist(path)
        DirCreate(path)
    return path
}
Seed(stage := "failed") {
    global CFG_FILE, fixtureRoot, caseNo, drained, __REWARD_MONITOR_COMPLETION_PENDING
    caseNo += 1, fixtureRoot := A_ScriptDir "\case-" caseNo, drained := true
    DirCreate(fixtureRoot)
    CFG_FILE := fixtureRoot "\config.ini", __REWARD_MONITOR_COMPLETION_PENDING := true
    IniWrite("20261024|Asia|fixture.log",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"state_key")
    IniWrite("old reward",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_reason")
    IniWrite("2026-10-24 22:00:00",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_at")
    IniWrite("1",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"seen_daily_reward_success")
    IniWrite("0",CFG_FILE,REWARD_MONITOR_STATE_SECTION,"completion_recorded")
    IniWrite("2026-10-25 03:00:00",CFG_FILE,"server_completed","HMT")
    IniWrite("keep-me",CFG_FILE,"unrelated","setting")
    FileAppend("20261024|Asia|fixture.log|2026-10-24 22:00:00`ntoken-123`n" stage,RuntimeFiles_RuntimeDir("completion-synthesis") "\state.txt","UTF-8-RAW")
}
Check(value,message) {
    if !value
        throw Error(message)
}
try {
    for stage in ["failed","uncertain","running","success"] {
        Seed(stage)
        Check(ClearCompletedRewardPendingOnFreshStart(false,false),"Explicit fresh launch must archive stale " stage " transaction after child drain")
        Check(!__REWARD_MONITOR_COMPLETION_PENDING,"fresh in-memory pending cleared")
        Check(IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"pending_reason","") = "","prior-day pending cannot enter new run")
        Check(IniRead(CFG_FILE,REWARD_MONITOR_STATE_SECTION,"seen_daily_reward_success","") = "","old reward evidence cannot terminate new run")
        Check(!FileExist(RuntimeFiles_RuntimeDir("completion-synthesis") "\state.txt"),"old transaction no longer active")
        Check(IniRead(CFG_FILE,"server_completed","HMT","") = "2026-10-25 03:00:00","completed server history preserved")
        Check(IniRead(CFG_FILE,"unrelated","setting","") = "keep-me","other config preserved")
        archives := 0
        Loop Files, fixtureRoot "\fresh-start-history\completion-state.txt", "FR" {
            Check(InStr(FileRead(A_LoopFileFullPath,"UTF-8"),stage),"original failure evidence archived")
            archives += 1
        }
        Check(archives = 1,"exactly one archival receipt")
    }
    for continuation in [[true,false],[false,true]] {
        Seed(), before := FileRead(CFG_FILE)
        Check(!ClearCompletedRewardPendingOnFreshStart(continuation[1],continuation[2]),"continuations must not reset")
        Check(FileRead(CFG_FILE) = before && FileExist(RuntimeFiles_RuntimeDir("completion-synthesis") "\state.txt"),"restart and nextserver retain exact old state")
    }
    Seed(), drained := false, before := FileRead(CFG_FILE)
    Check(!ClearCompletedRewardPendingOnFreshStart(false,false) && FileRead(CFG_FILE) = before,"live or unknown child prevents reset")
    Seed(), before := FileRead(CFG_FILE)
    FileAppend("block archive directory",fixtureRoot "\fresh-start-history")
    Check(!ClearCompletedRewardPendingOnFreshStart(false,false) && FileRead(CFG_FILE) = before,"archive failure preserves active evidence")
    FileAppend("PASS real fresh reward-state archive/reset, continuity, live-child and write-failure gates`n","*")
} catch as err {
    FileAppend(err.Message "`n" err.Stack,"**")
    ExitApp(1)
}
ExitApp(0)
__FUNCTIONS__
'@
$path=Join-Path $run 'state.ahk'
[IO.File]::WriteAllText($path,$fixture.Replace('__PROJECT__',$project).Replace('__FUNCTIONS__',$functions),[Text.UTF8Encoding]::new($true))
$result=Invoke-GMTestProcess -ScriptPath $path -Context $context
Write-Output $result.Stdout
Assert-GMEqual $result.ExitCode 0 $result.Stderr
