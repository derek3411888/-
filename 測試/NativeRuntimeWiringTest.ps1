[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'native-runtime-wiring'
$context.RunRoot = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\native-runtime-wiring-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($context.RunRoot)
try {
    $main = [IO.File]::ReadAllText((Join-Path $project ('payload\' + [char]0x5168 + [char]0x81EA + [char]0x52D5 + '.ahk')))
    if ($main -match '(?i)-ExecutionPolicy\s+Bypass') { throw 'The formal main entry still invokes a PowerShell policy override' }
    $functions = @(
        @('GetBootstrapFileSha256','IsPlausibleLauncherExe'),
        @('ExtractZipByNative','CleanupBootstrapTempDir'),
        @('DownloadFileWithProgress','TryBootstrapBundledFfmpeg'),
        @('TrySetWutheringProcessMute','WriteLog'),
        @('SendMailByPowerShell','ParseMailRecipients'),
        @('ParseMailRecipients','PsEsc')
    )
    $extracted = ''
    foreach ($pair in $functions) {
        $match = [regex]::Match($main,'(?ms)^' + $pair[0] + '\([^\r\n]*\) \{.*?(?=^' + $pair[1] + '\()')
        if (-not $match.Success) { throw ('Missing formal boundary: ' + $pair[0]) }
        $extracted += $match.Value + "`n"
    }
    $fixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
global calls := [], __WUTHERING_AUDIO_MUTED := false, muteResult := 0
Check(ok, label) {
    if !ok
        throw Error(label)
}
NativeBootstrap_FileSha256(path) {
    global calls
    calls.Push(["hash", path])
    return "abc123"
}
NativeBootstrap_Extract(source, destination) {
    global calls
    calls.Push(["extract", source, destination])
    return true
}
NativeBootstrap_Download(url, path, title) {
    global calls
    calls.Push(["download", url, path, title])
    return false
}
NativeRuntime_SendMail(host, port, user, pass, from, to, subject, body, ssl) {
    global calls
    calls.Push(["mail", host, port, user, pass, from, to, subject, body, ssl])
    return {ok: false, message: "fixture result"}
}
NativeRuntime_SetGameMute(pids, names, muted) {
    global calls, muteResult
    calls.Push(["mute", pids, names, muted])
    return muteResult
}
GetWutheringAudioTargets() {
    return {pids: "37,41", names: "client-win64-shipping"}
}
WriteLog(message, level := "INFO") {
}
try {
    Check(GetBootstrapFileSha256("C:\synthetic hash.bin") = "abc123", "hash result lost")
    Check(calls[-1][2] = "C:\synthetic hash.bin", "hash path corrupted")
    Check(ExtractZipByNative("archive.zip", "target folder"), "extract status lost")
    Check(calls[-1][2] = "archive.zip" && calls[-1][3] = "target folder", "extract paths changed")
    Check(!DownloadFileWithProgress("https://www.gyan.dev/asset.zip", "target.zip", "test title"), "download failure reported success")
    Check(calls[-1][4] = "test title", "download title lost")
    result := SendMailByPowerShell("smtp.invalid", 587, "synthetic-user", "synthetic-pass", "a@example.invalid", "b@example.invalid;c@example.invalid", "unicode test", "body", "1")
    Check(!result.ok && result.message = "fixture result", "SMTP result lost")
    Check(calls[-1][7] = "b@example.invalid,c@example.invalid", "multiple recipients not normalized")
    before := calls.Length
    result := SendMailByPowerShell("smtp.invalid", 587, "", "", "a@example.invalid", " " Chr(59) " `n", "subject", "body")
    Check(!result.ok && calls.Length = before, "empty recipient request reached native sender")
    Check(TrySetWutheringProcessMute(true) && __WUTHERING_AUDIO_MUTED, "successful mute state lost")
    Check(calls[-1][2] = "37,41" && calls[-1][4], "audio exact PID targets lost")
    muteResult := 2
    Check(!TrySetWutheringProcessMute(false) && __WUTHERING_AUDIO_MUTED, "failed unmute falsely updated state")
    muteResult := 0
    Check(TrySetWutheringProcessMute(false) && !__WUTHERING_AUDIO_MUTED, "successful unmute not persisted")
    FileAppend("PASS formal native boundary results, recipients, audio state, download failure`n", "*")
} catch as problem {
    FileAppend(problem.Message "`n", "**")
    ExitApp(1)
}
ExitApp(0)
'@
    $path = Join-Path $context.RunRoot 'runtime-wiring.ahk'
    [IO.File]::WriteAllText($path,($fixture + "`n" + $extracted),[Text.UTF8Encoding]::new($false))
    $result = Invoke-GMTestProcess -ScriptPath $path -Context $context
    if ($result.Stdout) { Write-Output $result.Stdout.TrimEnd() }
    if ($result.ExitCode -ne 0) { throw $result.Stderr }
} finally { Complete-ProjectDevelopmentPaths -Context $context }
