[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'launcher-startup-native'
try {
    $source=Get-Content -LiteralPath (Join-Path $project '打包啟動器.ahk') -Raw -Encoding UTF8
    $relocation=[regex]::Match($source,'(?s); 啟動新位置的exe\s*(?<body>.*?)\s*WriteLog\("啟動新位置的程式')
    if(!$relocation.Success){throw 'Missing real relocation dispatch boundary'}
    $relocationFailure=[regex]::Match($source,'(?s)WriteLog\("自我組織失敗:.*?(?=\r?\n    \}\r?\n\} else)')
    if(!$relocationFailure.Success){throw 'Missing real relocation failure boundary'}
    $functions=foreach($name in @('LauncherHashText','LauncherAcquireMainMutex')) {
        $match=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)')
        if(!$match.Success){throw ('Missing real function: '+$name)}
        $match.Value
    }
    $includes='#Include '+(Join-Path $project 'LauncherStartupGuard.ahk')+"`n"
    $lockPath=Join-Path $project 'payload\InstallStartupLock.ahk'
    if(Test-Path -LiteralPath $lockPath){$includes+='#Include '+$lockPath+"`n"}
    $shared=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
__INCLUDES__
global installation := A_Args.Length ? A_Args[1] : "__RUN_ROOT__\install"
LauncherProjectRoot() => installation
LauncherAdminForwardArgs() => relocationFixtureArgs
WriteLog(*) => 0
__FUNCTIONS__
'@
    $shared=$shared.Replace('__INCLUDES__',$includes).Replace('__RUN_ROOT__',$context.RunRoot).Replace('__FUNCTIONS__',($functions -join "`n"))
    $child=@'
guard := LauncherAcquireMainMutex()
try {
    FileAppend(String(guard > 0 ? "acquired" : guard), A_Args[2], "UTF-8")
    deadline := A_TickCount + 5000
    while !FileExist(A_Args[3]) && A_TickCount < deadline
        Sleep 20
} finally {
    if guard > 0 {
        DllCall("ReleaseMutex","ptr",guard)
        DllCall("CloseHandle","ptr",guard)
    }
}
ExitApp(0)
'@
    $childPath=Join-Path $context.RunRoot 'different-launcher-name.ahk'
    [IO.File]::WriteAllText($childPath,$shared+"`n"+$child,[Text.UTF8Encoding]::new($false))
    $parent=@'
guard := LauncherAcquireMainMutex()
try {
    if guard <= 0
        throw Error("fixture parent failed to reserve install")
    for otherInstall in [false,true] {
        resultPath := "__RUN_ROOT__\child-" otherInstall ".txt"
        stopPath := "__RUN_ROOT__\stop-" otherInstall ".txt"
        fixtureTarget := installation (otherInstall ? "-other" : "")
        runtime := "__RUNTIME__"
        fixtureCommand := '"' runtime '" /ErrorStdOut=UTF-8 "__CHILD__" "' fixtureTarget '" "' resultPath '" "' stopPath '"'
        fixtureChild := LauncherStartup_Dispatch(runtime,fixtureCommand,"__RUN_ROOT__")
        try {
            deadline := A_TickCount + 3000
            while !FileExist(resultPath) && A_TickCount < deadline
                Sleep 20
            if !FileExist(resultPath)
                throw Error("native dispatch child failed to report")
            if !LauncherStartup_ChildAlive(fixtureChild)
                throw Error("retained exact child handle should be alive")
            outcome := Trim(FileRead(resultPath,"UTF-8"))
            fixtureExpected := otherInstall ? "acquired" : "-1"
            if outcome != fixtureExpected
                throw Error("same-install/different-launcher reservation: expected " fixtureExpected " got " outcome)
        } finally {
            FileAppend("exit",stopPath)
            DllCall("WaitForSingleObject","ptr",fixtureChild.handle,"uint",6000)
            if LauncherStartup_ChildAlive(fixtureChild)
                throw Error("owned fixture did not exit")
            LauncherStartup_ReleaseChild(fixtureChild)
        }
    }
    ; Execute the real relocation dispatch while this parent remains alive.
    ; The child must acquire the same installation, not reject its own parent.
    global PACK_MAIN_MUTEX_HANDLE := guard
    guard := 0
    resultPath := "__RUN_ROOT__\relocated.txt"
    stopPath := "__RUN_ROOT__\stop-relocated.txt"
    newExePath := "__RUNTIME__"
    autoFolderPath := "__RUN_ROOT__"
    global relocationFixtureArgs := ' /ErrorStdOut=UTF-8 "__CHILD__" "' installation '" "' resultPath '" "' stopPath '"'
    try {
        __RELOCATION__
        deadline := A_TickCount + 3000
        while !FileExist(resultPath) && A_TickCount < deadline
            Sleep 20
        if !FileExist(resultPath) || Trim(FileRead(resultPath,"UTF-8")) != "acquired"
            throw Error("relocation child must acquire same-install lock before parent exit")
        if PACK_MAIN_MUTEX_HANDLE != 0
            throw Error("relocation parent must invalidate released reservation")
    } finally {
        FileAppend("exit",stopPath)
        if PACK_MAIN_MUTEX_HANDLE > 0
            InstallStartupLock_Release(PACK_MAIN_MUTEX_HANDLE)
    }
    FileAppend("PASS native exact-child dispatch/lifetime, installation reservation and relocation handoff`n","*")
} catch as e {
    FileAppend(e.Message "`n","**")
    ExitApp(1)
} finally {
    if guard > 0 {
        DllCall("ReleaseMutex","ptr",guard)
        DllCall("CloseHandle","ptr",guard)
    }
}
ExitApp(0)
'@
    $parent=$parent.Replace('__RELOCATION__',$relocation.Groups['body'].Value).Replace('__RUN_ROOT__',$context.RunRoot).Replace('__RUNTIME__',(Join-Path $project 'AutoHotkey64.exe')).Replace('__CHILD__',$childPath)
    $testPath=Join-Path $context.RunRoot 'native-parent.ahk'
    [IO.File]::WriteAllText($testPath,$shared+"`n"+$parent,[Text.UTF8Encoding]::new($false))
    $result=Invoke-GMTestProcess -ScriptPath $testPath -Context $context
    if($result.Stdout){Write-Output $result.Stdout.TrimEnd()}
    if($result.ExitCode -ne 0){throw $result.Stderr}
    # A failed relocation may not fall through and mutate/start without a lock.
    $failureSource=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
WriteLog(*) => 0
MsgBox(*) => 0
try {
    throw Error("fixture relocation dispatch failure")
} catch as e {
    __FAILURE__
}
FileAppend("unsafe continuation", "__MARKER__")
ExitApp(0)
'@
    $marker=Join-Path $context.RunRoot 'unsafe-relocation-continuation.txt'
    $failurePath=Join-Path $context.RunRoot 'relocation-failure.ahk'
    $failureSource=$failureSource.Replace('__FAILURE__',$relocationFailure.Value).Replace('__MARKER__',$marker)
    [IO.File]::WriteAllText($failurePath,$failureSource,[Text.UTF8Encoding]::new($false))
    $failureResult=Invoke-GMTestProcess -ScriptPath $failurePath -Context $context
    if($failureResult.ExitCode -ne 1 -or (Test-Path -LiteralPath $marker)){throw 'Relocation failure must exit before unreserved continuation'}
    Write-Output 'PASS real relocation failure stops before payload mutation'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
