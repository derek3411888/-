[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'launcher-installation-root'
try {
    $source=Get-Content (Join-Path $project '打包啟動器.ahk') -Raw -Encoding UTF8
    $function=[regex]::Match($source,'(?ms)^LauncherProjectRoot\(\) \{.*?^\}').Value.Replace('A_ScriptDir','fixtureDir')
    $condition=[regex]::Match($source,'(?m)^if (?<condition>[^\r\n]+) \{\r?\n    WriteLog\("開始自我組織').Groups['condition'].Value
    $workDecision=[regex]::Match($source,'(?ms)^; 確保在.*?^APP_DIR\s*:=').Value
    $workDecision=[regex]::Replace($workDecision,'(?m)^APP_DIR\s*:=.*$','').Replace('A_ScriptDir','fixtureDir')
    if(!$function -or !$condition -or !$workDecision){throw 'Missing production root/relocation/work-directory decision'}
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __LOCK__
global fixtureDir := "", fixtureDev := false
LauncherIsDevelopmentCheckout() => fixtureDev
__FUNCTION__
try {
    for row in [["download", "", false, true], ["自動鋤地", "", false, false],
        ["custom-payload", "payload", false, false], ["custom-config", "config", false, false],
        ["repo", "", true, false], ["parent自動鋤地\download", "", false, true]] {
        fixtureDir := "__ROOT__\" row[1]
        DirCreate(fixtureDir (row[2] ? "\" row[2] : ""))
        fixtureDev := row[3]
        currentDir := fixtureDir, autoFolderName := "自動鋤地"
        shouldRelocate := __CONDITION__
        wantedRoot := fixtureDir (fixtureDev ? "\.dev-runtime\launcher-app" : row[4] ? "\自動鋤地" : "")
        if LauncherProjectRoot() != wantedRoot || !!shouldRelocate != row[4]
            throw Error("inconsistent installation/relocation identity: " row[1])
        ; Relocated parents exit before this block; exercise each surviving
        ; existing installation and development-root decision exactly as shipped.
        if !shouldRelocate {
            __WORK_DECISION__
            if InstallStartupLock_Normalize(WORK_DIR) != InstallStartupLock_Normalize(wantedRoot)
                throw Error("working directory differs from reserved installation: " row[1])
        }
    }
    FileAppend("PASS production installation identity: 6 root/relocation cases`n", "*")
} catch as e {
    FileAppend(e.Message "`n", "**")
    ExitApp(1)
}
ExitApp(0)
'@
    $fixture=$fixture.Replace('__FUNCTION__',$function).Replace('__CONDITION__',$condition).Replace('__WORK_DECISION__',$workDecision).Replace('__ROOT__',$context.RunRoot).Replace('__LOCK__',(Join-Path $project 'payload\InstallStartupLock.ahk'))
    $path=Join-Path $context.RunRoot 'roots.ahk'
    [IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($false))
    $result=Invoke-GMTestProcess -ScriptPath $path -Context $context
    if($result.Stdout){Write-Output $result.Stdout.TrimEnd()}
    if($result.ExitCode -ne 0){throw $result.Stderr}
} finally { Complete-ProjectDevelopmentPaths -Context $context }
