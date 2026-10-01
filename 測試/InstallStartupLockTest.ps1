[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'install-startup-policy'
try {
    $source=Get-Content -LiteralPath (Join-Path $project 'payload\InstallStartupLock.ahk') -Raw -Encoding UTF8
    $source=[regex]::Replace($source,'(?ms)^InstallStartupLock_QueryProcesses\(\) \{.*?^\}',@'
InstallStartupLock_QueryProcesses() {
    if inventoryFails
        throw Error("unavailable process inventory")
    return fixtureRecords
}
'@)
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
global fixtureRecords := [], inventoryFails := false
global fixtureMain := "E:\fixture\payload\全自動.ahk"
Check(expected,label) {
    if InstallStartupLock_MainAbsent(fixtureMain) != expected
        throw Error(label)
}
try {
    if InstallStartupLock_Normalize('\\?\E:\fixture') != InstallStartupLock_Normalize('E:\fixture')
        throw Error("extended DOS root must share the mutex identity")
    if InstallStartupLock_Normalize('\\?\UNC\host\share\fixture') != InstallStartupLock_Normalize('\\host\share\fixture')
        throw Error("extended UNC root must share the mutex identity")
    Check(true,"empty inventory")
    fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe" "E:\fixture\payload\全自動.ahk"'}]
    Check(false,"matching main blocks")
    fixtureRecords := [{CommandLine:'"D:\other\AutoHotkey64.exe" /restart "E:\fixture\payload\全自動.ahk"'}]
    Check(false,"matching main in another interpreter blocks")
    fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe" "E:\fixture\payload\ScriptRestartWorker.ahk"'}]
    Check(true,"known worker is unrelated")
    fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe" "E:\other\payload\全自動.ahk"'}]
    Check(true,"different installation is unrelated")
    for relative in ['payload\全自動.ahk', '全自動.ahk', 'E:全自動.ahk'] {
        fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe" "' relative '"'}]
        Check(false,"relative target CWD is unknown")
    }
    fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe" /include "E:\bootstrap.ahk" "E:\fixture\payload\全自動.ahk"'}]
    Check(false,"include argument must not hide the legacy main")
    fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe" "\\?\E:\fixture\payload\全自動.ahk"'}]
    Check(false,"extended path cannot hide legacy main")
    fixtureRecords := [{ProcessId:123, CommandLine:'"E:\fixture\AutoHotkey64.exe" "E:\fixture\payload\全自動.ahk"'}]
    if !InstallStartupLock_MainAbsent(fixtureMain,123)
        throw Error("main excludes only its own current PID")
    if InstallStartupLock_MainAbsent(fixtureMain,124)
        throw Error("different PID must not be ignored")
    fixtureRecords := [{CommandLine:""}]
    Check(false,"unreadable processes fail closed in production")
    fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe"'}]
    Check(false,"missing script argument is uninspectable")
    fixtureRecords := []
    inventoryFails := true
    Check(false,"inventory errors fail closed")
    FileAppend("PASS install startup guard: 15 inventory cases and 2 extended-path identities`n","*")
} catch as e {
    FileAppend(e.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
__SOURCE__
'@
    $testPath=Join-Path $context.RunRoot 'install-policy.ahk'
    [IO.File]::WriteAllText($testPath,$fixture.Replace('__SOURCE__',$source),[Text.UTF8Encoding]::new($false))
    $result=Invoke-GMTestProcess -ScriptPath $testPath -Context $context
    if($result.Stdout){Write-Output $result.Stdout.TrimEnd()}
    if($result.ExitCode -ne 0){throw $result.Stderr}
} finally { Complete-ProjectDevelopmentPaths -Context $context }
