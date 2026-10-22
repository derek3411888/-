[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'update-outcome'
try {
    $source=[IO.File]::ReadAllText((Join-Path $project '打包啟動器.ahk'))
    $functions=foreach($name in @('TryPrepareRemotePayloadUpdate','TryPrepareRemoteLauncherUpdate','ApplyPendingLauncherUpdateV2')) {
        $match=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?^\}')
        if(!$match.Success){throw "Missing $name"}
        # Replace only OS execution-context boundaries; keep the real pending
        # version/hash/dispatch logic and intercept Run before any process starts.
        if($name -eq 'ApplyPendingLauncherUpdateV2') {
            $match.Value.Replace('if !A_IsCompiled','if false').Replace('if !A_IsAdmin','if false')
        } else { $match.Value }
    }
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __POLICY__
FileEncoding("UTF-8")
global calls := 0, oldCalls := 0, PACK_PAYLOAD_UPDATE_STATUS := "not_checked", mode := "failure"
global SKIP_PENDING_LAUNCHER_APPLY := false
global testSha := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", testVersion := "fixture-2"
global PACK_LAUNCHER_BUILD_VERSION := "5.41", PACK_PAYLOAD_BUILD_VERSION := "5.29"
global pendingDispatches := 0
WriteLog(*) => 0
LauncherDownloadProgress(*) => 0
IniReadSafe(path, section, key, fallback) => fallback
ConvertToGitHubApiUrl(url) => url
HttpGetText(*) => "fixture manifest"
JsonGetString(text, key) {
    global testSha, testVersion
    if InStr(key, "sha256")
        return testSha
    if InStr(key, "url")
        return "https://example.invalid/immutable/artifact"
    return testVersion
}
GetFileSha256(path) => InStr(path,"old.exe") ? testSha : "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
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
LauncherNativeParentStamp() => 123
Run(*) {
    global pendingDispatches
    pendingDispatches++
    throw Error("isolated replacement dispatch intercepted")
}
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
    testVersion := "5.28"
    if TryPrepareRemotePayloadUpdate(A_ScriptDir,A_ScriptDir,&version,true,"fixture manifest")
        || calls != 2 || PACK_PAYLOAD_UPDATE_STATUS != "newer_local"
        throw Error("older remote payload must not overwrite a newer embedded login fix, even in repair mode")
    testVersion := "5.40"
    if TryPrepareRemoteLauncherUpdate(A_ScriptDir,A_ScriptDir,"fixture manifest")
        || calls != 2 || !SKIP_PENDING_LAUNCHER_APPLY
        throw Error("older remote launcher must not download or apply pending downgrade over a newer compiled launcher")
    FileAppend("fixture exe",A_ScriptDir "\old.exe")
    FileAppend(A_ScriptDir "\old.exe",A_ScriptDir "\launcher_pending_update.tmp")
    FileAppend("5.40",A_ScriptDir "\launcher_pending_version.txt")
    FileAppend(testSha,A_ScriptDir "\launcher_pending_sha256.txt")
    SKIP_PENDING_LAUNCHER_APPLY := false
    ApplyPendingLauncherUpdateV2(A_ScriptDir,A_ScriptDir)
    if pendingDispatches != 0
        throw Error("stale pending launcher must be rejected even when manifest is unavailable")
    FileDelete(A_ScriptDir "\launcher_pending_version.txt")
    FileAppend("5.42",A_ScriptDir "\launcher_pending_version.txt")
    FileAppend("5.45",A_ScriptDir "\launcher_current_version.txt")
    ApplyPendingLauncherUpdateV2(A_ScriptDir,A_ScriptDir)
    if pendingDispatches != 0
        throw Error("pending launcher must also honor the installed version floor")
    FileDelete(A_ScriptDir "\launcher_current_version.txt")
    ApplyPendingLauncherUpdateV2(A_ScriptDir,A_ScriptDir)
    if pendingDispatches != 1
        throw Error("newer pending launcher must retain normal replacement routing")
    FileAppend("PASS production update branches: failure/current and SHA transport wiring`n","*")
} catch as fixtureError {
    FileAppend(fixtureError.Message "`n" fixtureError.Stack "`n","**","UTF-8")
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
