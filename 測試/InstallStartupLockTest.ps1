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
    Check(true,"empty inventory")
    fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe" "E:\fixture\payload\全自動.ahk"'}]
    Check(false,"matching main blocks")
    fixtureRecords := [{CommandLine:'"D:\other\AutoHotkey64.exe" /restart "E:\fixture\payload\全自動.ahk"'}]
    Check(false,"matching main in another interpreter blocks")
    fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe" "E:\fixture\payload\ScriptRestartWorker.ahk"'}]
    Check(true,"known worker is unrelated")
    fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe" "E:\other\payload\全自動.ahk"'}]
    Check(true,"different installation is unrelated")
    fixtureRecords := [{CommandLine:""}]
    Check(false,"unreadable processes fail closed in production")
    fixtureRecords := [{CommandLine:'"E:\fixture\AutoHotkey64.exe"'}]
    Check(false,"missing script argument is uninspectable")
    fixtureRecords := []
    inventoryFails := true
    Check(false,"inventory errors fail closed")
    FileAppend("PASS install startup guard: 8 inventory cases`n","*")
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
