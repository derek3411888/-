[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'launcher-startup-guard'
try {
    $source=Get-Content -LiteralPath (Join-Path $project '打包啟動器.ahk') -Raw -Encoding UTF8
    $start=$source.IndexOf('mainLaunchSucceeded := false')
    $end=$source.IndexOf('if (mainLaunchSucceeded && !SKIP_PENDING_LAUNCHER_APPLY)', $start)
    if($start -lt 0 -or $end -le $start){throw 'Cannot locate real launcher startup block'}
    $block=$source.Substring($start,$end-$start)
    $earlyStart=$source.IndexOf('existingMainGate := LauncherStartup_Inspect(')
    $earlyEnd=$source.IndexOf('autoFolderName :=', $earlyStart)
    if($earlyStart -lt 0 -or $earlyEnd -le $earlyStart -or
        $earlyEnd -ge $source.IndexOf('FileInstall')) { throw 'Existing-main guard must run before embedded writes' }
    $earlyBlock=$source.Substring($earlyStart,$earlyEnd-$earlyStart)
    $includes='#Include '+(Join-Path $project 'LauncherProcessCleanupPolicy.ahk')+"`n"
    $startupPolicy=Join-Path $project 'LauncherStartupGuard.ahk'
    if(Test-Path -LiteralPath $startupPolicy){
        $policy=Get-Content -LiteralPath $startupPolicy -Raw -Encoding UTF8
        $policy=$policy.Replace('#Include LauncherProcessCleanupPolicy.ahk','')
        foreach($boundary in @('LauncherStartup_Dispatch','LauncherStartup_ChildAlive','LauncherStartup_ReleaseChild')) {
            $policy=[regex]::Replace($policy,'(?ms)^'+$boundary+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)','')
        }
        $includes+=$policy+"`n"
    }
    $fixture=@'
#Requires AutoHotkey v2.0+
#SingleInstance Off
__INCLUDES__
global ahkPath := "E:\fixture\AutoHotkey64.exe"
global MAIN_PATH := "E:\fixture\payload\全自動.ahk"
global APP_DIR := "E:\fixture\payload"
global scenario := A_Args.Length ? A_Args[1] : "existing"
global runCount := 0
global queryCount := 0
global logLines := []
global oldProc := {Name:"AutoHotkey64.exe", ProcessId:111, ExecutablePath:ahkPath,
    CommandLine:'"' ahkPath '" "' MAIN_PATH '"', CreationDate:"20261001095023.000000+480"}
global newProc := {Name:"AutoHotkey64.exe", ProcessId:222, ExecutablePath:ahkPath,
    CommandLine:'"' ahkPath '" "' MAIN_PATH '"', CreationDate:"20261001102023.000000+480"}
class FixtureWmi {
    ExecQuery(query) {
        global scenario,runCount,oldProc,newProc,queryCount,MAIN_PATH
        queryCount += 1
        if scenario="unreadable"
            throw Error("fixture query denied")
        if scenario="existing"
            return [oldProc]
        if scenario="same-script-other-runtime" {
            return [{Name:"AutoHotkey64.exe",ProcessId:111,ExecutablePath:"D:\other\AutoHotkey64.exe",
                CommandLine:'"D:\other\AutoHotkey64.exe" "' MAIN_PATH '"',CreationDate:oldProc.CreationDate}]
        }
        if scenario="fresh"
            return runCount ? [newProc] : []
        if scenario="exited-before-first-poll" || scenario="exited-during-query"
            return runCount ? [newProc] : []
        if scenario="old-pid-same-script"
            return runCount ? [oldProc] : []
        if scenario="child-query-failed" {
            if runCount
                throw Error("fixture child inspection unavailable")
            return []
        }
        if scenario="pid-reused" {
            if !runCount
                return []
            replacement := {Name:"AutoHotkey64.exe", ProcessId:222, ExecutablePath:ahkPath,
                CommandLine:newProc.CommandLine, CreationDate:"20261001102024.000000+480"}
            return [queryCount = 2 ? newProc : replacement]
        }
        if scenario="wrong-child" {
            unrelated := {Name:"AutoHotkey64.exe",ProcessId:111,ExecutablePath:"D:\other\AutoHotkey64.exe",
                CommandLine:'"D:\other\AutoHotkey64.exe" "D:\other\全自動.ahk"',CreationDate:"20261001095023.000000+480"}
            return [unrelated]
        }
        if scenario="inaccessible" {
            return [{Name:"AutoHotkey64.exe",ProcessId:111,ExecutablePath:"",CommandLine:"",CreationDate:""}]
        }
        if scenario="wrong-script" {
            other := {Name:"AutoHotkey64.exe",ProcessId:222,ExecutablePath:ahkPath,
                CommandLine:'"' ahkPath '" "E:\fixture\payload\別的.ahk"',CreationDate:newProc.CreationDate}
            return runCount ? [other] : []
        }
        throw Error("unknown fixture scenario")
    }
}
ComObjGet(*) => FixtureWmi()
LauncherProjectRoot(*) => "E:\fixture"
LauncherHasArg(*) => false
LauncherStartup_Dispatch(runtime,command,workingDir) {
    global runCount,ahkPath,MAIN_PATH,APP_DIR
    if runtime != ahkPath || command != '"' ahkPath '" "' MAIN_PATH '"' || workingDir != APP_DIR
        throw Error("wrong launcher dispatch arguments")
    runCount += 1
    return {pid:222,handle:42}
}
LauncherStartup_ChildAlive(child) => scenario != "exited-before-first-poll" && !(scenario="exited-during-query" && queryCount >= 2)
LauncherStartup_ReleaseChild(*) => 0
Sleep(*) => 0
MsgBox(*) => 0
WriteStep(*) => 0
WriteLog(message,level:="INFO") {
    global logLines
    logLines.Push(message)
}
__START_BLOCK__
try {
    if scenario="existing" || scenario="unreadable" || scenario="inaccessible" || scenario="same-script-other-runtime" {
        if runCount != 0
            throw Error("Existing or uninspectable runtime must not be replaced by a second Run")
        if mainLaunchSucceeded
            throw Error("Skipped duplicate is not a newly verified startup")
    } else if scenario="fresh" {
        if runCount != 1 || !mainLaunchSucceeded
            throw Error("Fresh exact child should be dispatched once and recognized")
    } else {
        if runCount != 1 || mainLaunchSucceeded
            throw Error("Old or wrong-script process must not confirm the new child")
    }
    FileAppend("PASS " scenario "`n", "*")
} catch as e {
    FileAppend(e.Message "`n", "**")
    ExitApp(1)
}
ExitApp(0)
'@
    $fixture=$fixture.Replace('__INCLUDES__',$includes).Replace('__START_BLOCK__',$block)
    foreach($scenario in @('existing','fresh','wrong-child','unreadable','inaccessible','wrong-script','old-pid-same-script','child-query-failed','pid-reused','same-script-other-runtime','exited-before-first-poll','exited-during-query')){
        $testPath=Join-Path $context.RunRoot ('startup-'+$scenario+'.ahk')
        # Set scenario directly so the normal contained test runner needs no extra interface.
        $case=$fixture.Replace('global scenario := A_Args.Length ? A_Args[1] : "existing"', ('global scenario := "'+$scenario+'"'))
        [IO.File]::WriteAllText($testPath,$case,[Text.UTF8Encoding]::new($false))
        $result=Invoke-GMTestProcess -ScriptPath $testPath -Context $context
        if($result.Stdout){Write-Output $result.Stdout.TrimEnd()}
        if($result.ExitCode -ne 0){throw ($scenario+': '+$result.Stderr)}
    }
    # Exercise the actual early guard with the real ExitApp boundary. A blocked
    # invocation must exit before reaching the next phase, not merely skip Run.
    $earlyFixture=$fixture.Substring(0,$fixture.IndexOf($block)).Replace('global scenario := A_Args.Length ? A_Args[1] : "existing"','global scenario := "__CASE__"')+
        $earlyBlock+"`nFileAppend(`"NEXT_PHASE`", `"*`")`nExitApp(0)`n"
    foreach($scenario in @('existing','inaccessible','unreadable','fresh')){
        $testPath=Join-Path $context.RunRoot ('early-'+$scenario+'.ahk')
        [IO.File]::WriteAllText($testPath,$earlyFixture.Replace('__CASE__',$scenario),[Text.UTF8Encoding]::new($false))
        $result=Invoke-GMTestProcess -ScriptPath $testPath -Context $context
        if($result.ExitCode -ne 0){throw ('early '+$scenario+': '+$result.Stderr)}
        if($result.Stdout.Contains('NEXT_PHASE') -ne ($scenario -eq 'fresh')){throw ('Early guard did not stop embedded-write phase: '+$scenario)}
        Write-Output ('PASS early-'+$scenario)
    }
} finally { Complete-ProjectDevelopmentPaths -Context $context }
