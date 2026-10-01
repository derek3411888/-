[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'main-instance-ownership'
$owned=[Collections.Generic.List[Diagnostics.Process]]::new()
function Start-Fixture([string]$Path,[string]$Runtime) {
    $p=Start-Process -FilePath $Runtime -ArgumentList ('/ErrorStdOut=UTF-8 "'+$Path+'"') -WindowStyle Hidden -PassThru
    [void]$p.Handle
    $owned.Add($p)
    return $p
}
function Wait-Marker([string]$Path) {
    $end=[DateTime]::UtcNow.AddSeconds(8)
    while (!(Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $end) { Start-Sleep -Milliseconds 30 }
    if (!(Test-Path -LiteralPath $Path)) { throw "Fixture did not report: $Path" }
}
try {
    $source=Get-Content -LiteralPath (Join-Path $project 'payload\全自動.ahk') -Raw -Encoding UTF8
    $directive=[regex]::Match($source,'(?m)^#SingleInstance[^\r\n]*').Value
    $gate=[regex]::Match($source,'(?s); BEGIN MAIN INSTANCE OWNERSHIP.*?; END MAIN INSTANCE OWNERSHIP').Value
    $gate=$gate.Replace('#Include InstallStartupLock.ahk','#Include '+(Join-Path $project 'payload\InstallStartupLock.ahk'))
    $runtime=Join-Path $project 'AutoHotkey64.exe'
    $template=@'
#Requires AutoHotkey v2.0
__DIRECTIVE__
#NoTrayIcon
#Warn All, StdOut
__GATE__
FileAppend(DllCall("GetCurrentProcessId") "`n", A_ScriptDir "\starts.txt", "UTF-8")
OnExit(FixtureCleanup)
SetTimer(() => FileExist(A_ScriptDir "\stop.txt") ? ExitApp(0) : 0, 20)
SetTimer(() => ExitApp(2), -12000)
Persistent
FixtureCleanup(*) {
    FileAppend("cleanup", A_ScriptDir "\cleanup.txt")
    Sleep 700
}
'@
    $fixture=$template.Replace('__DIRECTIVE__',$directive).Replace('__GATE__',$gate)
    $dir=Join-Path $context.RunRoot 'install\payload'
    [void](New-Item -ItemType Directory -Path $dir -Force)
    $path=Join-Path $dir 'main-fixture.ahk'
    [IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($false))
    $first=Start-Fixture $path $runtime
    Wait-Marker (Join-Path $dir 'starts.txt')
    $second=Start-Fixture $path $runtime
    Start-Sleep -Milliseconds 1600
    if($first.HasExited -or @(Get-Content (Join-Path $dir 'starts.txt')).Count -ne 1) {
        throw 'Duplicate main replaced the owner or performed initialization'
    }
    if(!$second.WaitForExit(3000)) { throw 'Duplicate main did not exit nonblocking' }
    if($directive -ne '#SingleInstance Off' -or !$gate) { throw 'Production main must use explicit early ownership, not interpreter replacement' }
    if($source.IndexOf('; END MAIN INSTANCE OWNERSHIP') -gt $source.IndexOf('ProcessSetPriority(')) { throw 'Ownership gate must precede effectful initialization' }
    Write-Output 'PASS actual main directive/prologue: duplicate exits, original owner untouched'
    [IO.File]::WriteAllText((Join-Path $dir 'stop.txt'),'stop')
    Wait-Marker (Join-Path $dir 'cleanup.txt')
    $duringExit=Start-Fixture $path $runtime
    if(!$duringExit.WaitForExit(2500)) { throw 'Slow OnExit contender did not exit' }
    if(@(Get-Content (Join-Path $dir 'starts.txt')).Count -ne 1) { throw 'Lifetime reservation released before cleanup finished' }
    if(!$first.WaitForExit(4000)) { throw 'Fixture cleanup did not finish' }
    Write-Output 'PASS main lifetime owns entire slow OnExit'
    # Independent installation and racing first starts, including another runtime.
    $raceDir=Join-Path $context.RunRoot 'race\payload'
    [void](New-Item -ItemType Directory -Path $raceDir -Force)
    $racePath=Join-Path $raceDir 'main-fixture.ahk'
    [IO.File]::WriteAllText($racePath,$fixture,[Text.UTF8Encoding]::new($false))
    $otherRuntime=Join-Path $context.RunRoot 'AutoHotkey-other.exe'
    Copy-Item -LiteralPath $runtime -Destination $otherRuntime
    $a=Start-Fixture $racePath $runtime
    $b=Start-Fixture $racePath $otherRuntime
    Wait-Marker (Join-Path $raceDir 'starts.txt')
    Start-Sleep -Milliseconds 700
    if(@(Get-Content (Join-Path $raceDir 'starts.txt')).Count -ne 1 -or ($a.HasExited -eq $b.HasExited)) { throw 'Simultaneous cross-runtime starts must have exactly one owner' }
    Write-Output 'PASS simultaneous starts across runtimes: exactly one owner'
    [IO.File]::WriteAllText((Join-Path $raceDir 'stop.txt'),'stop')
    foreach($p in @($a,$b)) { if(!$p.WaitForExit(4000)){throw 'Race fixture did not finish'} }
    # Windows closes ownership on termination, so a new PID can safely take over.
    $next=Start-Fixture $racePath $runtime
    if(!$next.WaitForExit(4000) -or @(Get-Content (Join-Path $raceDir 'starts.txt')).Count -ne 2) { throw 'Exited owner left a stale reservation' }
    Write-Output 'PASS terminated owner cannot leave a stale PID lock'
    $launcher=Get-Content (Join-Path $project '打包啟動器.ahk') -Raw -Encoding UTF8
    $reserve=[regex]::Match($launcher,'(?s); BEGIN LAUNCHER RUNTIME RESERVATION.*?; END LAUNCHER RUNTIME RESERVATION').Value
    $release=[regex]::Match($launcher,'(?s); BEGIN MAIN DISPATCH RESERVATION RELEASE.*?; END MAIN DISPATCH RESERVATION RELEASE').Value
    if(!$reserve -or !$release){throw 'Missing actual launcher runtime reservation boundaries'}
    $transferDir=Join-Path $context.RunRoot 'transfer\payload'
    [void](New-Item -ItemType Directory -Path $transferDir -Force)
    $transferPath=Join-Path $transferDir 'main-fixture.ahk'
    # Prove the main can enter and ACK while a worker/launcher STILL owns startup.
    $transferFixture=$fixture.Replace('FileAppend(DllCall',@'
SplitPath(A_ScriptDir, , &fixtureInstall)
startupCheck := InstallStartupLock_Acquire(fixtureInstall)
if startupCheck != -1
    ExitApp(3)
FileAppend(DllCall
'@)
    [IO.File]::WriteAllText($transferPath,$transferFixture,[Text.UTF8Encoding]::new($false))
    $transfer=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __LOCK__
#Include __STARTUP__
LauncherProjectRoot() => "__INSTALL__"
WriteLog(*) => 0
global PACK_RUNTIME_MUTEX_HANDLE := 0
startupHandle := InstallStartupLock_Acquire(LauncherProjectRoot())
if startupHandle <= 0
    ExitApp(1)
try {
    __RESERVE__
    transferChild := LauncherStartup_Dispatch("__RUNTIME__", '"__RUNTIME__" /ErrorStdOut=UTF-8 "__CHILD__"', "__DIR__")
    try {
        if DllCall("WaitForSingleObject", "ptr", transferChild.handle, "uint", 3000, "uint") != 0
            throw Error("main did not reject active installer reservation")
        if FileExist("__DIR__\starts.txt")
            throw Error("main initialized during installation writes")
    } finally LauncherStartup_ReleaseChild(transferChild)
    __RELEASE__
    transferChild := LauncherStartup_Dispatch("__RUNTIME__", '"__RUNTIME__" /ErrorStdOut=UTF-8 "__CHILD__"', "__DIR__")
    try {
        transferDeadline := A_TickCount + 6000
        while !FileExist("__DIR__\starts.txt") && A_TickCount < transferDeadline
            Sleep 20
        if !FileExist("__DIR__\starts.txt") || !LauncherStartup_ChildAlive(transferChild)
            throw Error("installer/worker ACK wait deadlocked with main ownership")
    } finally {
        FileAppend("stop", "__DIR__\stop.txt")
        if DllCall("WaitForSingleObject", "ptr", transferChild.handle, "uint", 4000, "uint") != 0
            DllCall("TerminateProcess", "ptr", transferChild.handle, "uint", 1)
        LauncherStartup_ReleaseChild(transferChild)
    }
    FileAppend("PASS actual installer reservation blocks main; releases before child; startup lock held through ACK without deadlock`n", "*")
} catch as e {
    FileAppend(e.Message "`n", "**")
    ExitApp(1)
} finally {
    InstallStartupLock_Release(PACK_RUNTIME_MUTEX_HANDLE)
    InstallStartupLock_Release(startupHandle)
}
ExitApp(0)
'@
    $transfer=$transfer.Replace('__RESERVE__',$reserve).Replace('__RELEASE__',$release).Replace('__LOCK__',(Join-Path $project 'payload\InstallStartupLock.ahk')).Replace('__STARTUP__',(Join-Path $project 'LauncherStartupGuard.ahk')).Replace('__INSTALL__',(Split-Path $transferDir -Parent)).Replace('__DIR__',$transferDir).Replace('__RUNTIME__',$runtime).Replace('__CHILD__',$transferPath)
    $transferScript=Join-Path $context.RunRoot 'transfer-parent.ahk'
    [IO.File]::WriteAllText($transferScript,$transfer,[Text.UTF8Encoding]::new($false))
    $result=Invoke-GMTestProcess -ScriptPath $transferScript -Context $context
    if($result.Stdout){Write-Output $result.Stdout.TrimEnd()}
    if($result.ExitCode -ne 0){throw $result.Stderr}
} finally {
    foreach($p in $owned) {
        if(!$p.HasExited) { $p.Kill(); [void]$p.WaitForExit(3000) }
        $p.Dispose()
    }
    Complete-ProjectDevelopmentPaths -Context $context
}
