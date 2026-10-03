[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'update-outcome'
try {
    $source=[IO.File]::ReadAllText((Join-Path $project '打包啟動器.ahk'))
    $functions=foreach($name in @('TryPrepareRemotePayloadUpdate','TryPrepareRemoteLauncherUpdate')) {
        $match=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?^\}')
        if(!$match.Success){throw "Missing $name"};$match.Value
    }
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __POLICY__
global calls := 0, oldCalls := 0, PACK_PAYLOAD_UPDATE_STATUS := "not_checked", mode := "failure"
global SKIP_PENDING_LAUNCHER_APPLY := false
global testSha := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
WriteLog(*) => 0
LauncherDownloadProgress(*) => 0
IniReadSafe(path, section, key, fallback) => fallback
ConvertToGitHubApiUrl(url) => url
HttpGetText(*) => "fixture manifest"
JsonGetString(text, key) {
    global testSha
    if InStr(key, "sha256")
        return testSha
    if InStr(key, "url")
        return "https://example.invalid/immutable/artifact"
    return "fixture-2"
}
GetFileSha256(*) => ""
LauncherNewTempPath(*) => A_ScriptDir "\artifact.tmp"
LauncherNativeHelperPath() => "fixture-helper"
HttpDownloadFile(*) {
    global oldCalls
    oldCalls++
    throw Error("isolated legacy transport failure")
}
LauncherDownloadFile(helper, root, url, dest, sha, callback) {
    global calls, testSha
    if sha != testSha
        throw Error("manifest SHA not forwarded")
    calls++
    throw Error("isolated native transport failure")
}
WriteTextFileReplace(*) => true
ClearPendingLauncherState(*) => true
try {
    version := ""
    if TryPrepareRemotePayloadUpdate(A_ScriptDir,A_ScriptDir,&version)
        throw Error("failed payload download reported prepared")
    if calls != 1 || oldCalls != 0
        throw Error("payload did not use one resumable SHA-verified transport call")
    if PACK_PAYLOAD_UPDATE_STATUS != "failed" || version != ""
        throw Error("failed payload download did not preserve failure outcome")
    if TryPrepareRemoteLauncherUpdate(A_ScriptDir,A_ScriptDir,"fixture manifest")
        throw Error("failed launcher download reported prepared")
    if calls != 2 || oldCalls != 0
        throw Error("launcher did not use resumable SHA-verified transport")
    FileAppend("fixture-2",A_ScriptDir "\payload_remote_version.txt")
    TryPrepareRemotePayloadUpdate(A_ScriptDir,A_ScriptDir,&version)
    if PACK_PAYLOAD_UPDATE_STATUS != "current" || calls != 2
        throw Error("confirmed current version not distinguished from download failure")
    FileAppend("PASS production update branches: failure/current and SHA transport wiring`n","*")
} catch as fixtureError {
    FileAppend(fixtureError.Message "`n","**","UTF-8")
    ExitApp(1)
}
ExitApp(0)
__FUNCTIONS__
'@
    $fixture=$fixture.Replace('__POLICY__',(Join-Path $project 'LauncherPayloadUpdatePolicy.ahk')).Replace('__FUNCTIONS__',($functions -join "`n"))
    $path=Join-Path $context.RunRoot 'outcome.ahk'
    [IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($false))
    $result=Invoke-GMTestProcess -ScriptPath $path -Context $context
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.ExitCode -ne 0){throw $result.Stderr}
} finally {Complete-ProjectDevelopmentPaths -Context $context}
