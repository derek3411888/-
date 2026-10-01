[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'restart-worker-ownership'
try {
    $source=Get-Content (Join-Path $project 'payload\ScriptRestartHandoff.ahk') -Raw -Encoding UTF8
    $prepare=[regex]::Match($source,'(?ms)^RestartHandoff_Prepare\([^\r\n]*\) \{.*?^\}').Value
    if($prepare -match 'OpenProcess|ProcessExist\(workerPid\)' -or $prepare -notmatch 'RestartHandoff_DispatchWorker') {
        throw 'Restart preparation must retain an atomically dispatched process handle, never reopen a returned PID'
    }
    $dispatch=[regex]::Match($source,'(?ms)^RestartHandoff_DispatchWorker\([^\r\n]*\) \{.*?^\}').Value
    $cancel=[regex]::Match($source,'(?ms)^RestartHandoff_Cancel\([^\r\n]*\) \{.*?^\}').Value
    if(!$dispatch -or !$cancel){throw 'Missing actual ownership functions'}
    $runtime=Join-Path $project 'AutoHotkey64.exe'
    $child=Join-Path $context.RunRoot 'inert-child.ahk'
    [IO.File]::WriteAllText($child,"#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`nSleep 8000`nExitApp 0",[Text.UTF8Encoding]::new($false))
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
global RestartHandoff_ActiveRequest := "__ROOT__\request.ini", RestartHandoff_WorkerHandle := 0
RestartHandoff_WriteIni(*) => ThrowFixtureWriteError()
ThrowFixtureWriteError() {
    throw Error("fixture cancellation file unavailable")
}
__DISPATCH__
__CANCEL__
other := RestartHandoff_DispatchWorker("__RUNTIME__", '"__RUNTIME__" /ErrorStdOut=UTF-8 "__CHILD__"', "__ROOT__")
try {
    for alreadyExited in [false, true] {
        owned := RestartHandoff_DispatchWorker("__RUNTIME__", '"__RUNTIME__" /ErrorStdOut=UTF-8 "__CHILD__"', "__ROOT__")
        RestartHandoff_WorkerHandle := owned.handle
        try {
            if alreadyExited {
                DllCall("TerminateProcess", "ptr", owned.handle, "uint", 0)
                DllCall("WaitForSingleObject", "ptr", owned.handle, "uint", 3000)
            }
            ; A stale/reused PID must be irrelevant to cancellation ownership.
            owned.pid := other.pid
            if !RestartHandoff_Cancel("fixture cancel")
                throw Error("exact-handle cancellation failed")
            if DllCall("WaitForSingleObject", "ptr", owned.handle, "uint", 0, "uint") != 0
                throw Error("owned worker not terminated")
            if DllCall("WaitForSingleObject", "ptr", other.handle, "uint", 0, "uint") != 258
                throw Error("unrelated process was affected")
        } finally DllCall("CloseHandle", "ptr", owned.handle)
    }
    FileAppend("PASS atomic worker handle: live/fast-exited helper, simulated reused PID, failed cancellation write, unrelated process retained`n", "*")
} catch as e {
    FileAppend(e.Message "`n", "**")
    ExitApp(1)
} finally {
    DllCall("TerminateProcess", "ptr", other.handle, "uint", 0)
    DllCall("WaitForSingleObject", "ptr", other.handle, "uint", 3000)
    DllCall("CloseHandle", "ptr", other.handle)
}
ExitApp(0)
'@
    $fixture=$fixture.Replace('__DISPATCH__',$dispatch).Replace('__CANCEL__',$cancel).Replace('__RUNTIME__',$runtime).Replace('__CHILD__',$child).Replace('__ROOT__',$context.RunRoot)
    $path=Join-Path $context.RunRoot 'ownership.ahk'
    [IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($false))
    $result=Invoke-GMTestProcess -ScriptPath $path -Context $context
    if($result.Stdout){Write-Output $result.Stdout.TrimEnd()}
    if($result.ExitCode -ne 0){throw $result.Stderr}
} finally { Complete-ProjectDevelopmentPaths -Context $context }
