[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'legacy-bootstrap-source'
$context.RunRoot = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\legacy-source-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($context.RunRoot)
try {
    $mainPath = Join-Path $project ('payload\' + [char]0x5168 + [char]0x81EA + [char]0x52D5 + '.ahk')
    $main = [IO.File]::ReadAllText($mainPath)
    $required = [regex]::Match($main, '(?ms)^GetPendingLauncherSourceSha256\([^\r\n]*\) \{.*?(?=^ResolvePendingLauncherSource\()')
    if (-not $required.Success) { throw 'Legacy external source hashing is missing its safe staging boundary' }
    if ($main -notmatch 'sourceSha := GetPendingLauncherSourceSha256\(sourcePath, dataDir\)') { throw 'Legacy repair does not use guarded external source hash' }
    $app = Join-Path $context.RunRoot 'app'
    $module = Join-Path $app 'payload'
    $external = Join-Path $context.RunRoot 'external-config'
    [void][IO.Directory]::CreateDirectory($module)
    [void][IO.Directory]::CreateDirectory($external)
    [IO.File]::Copy((Join-Path $project 'payload\BootstrapAssets.exe'),(Join-Path $module 'BootstrapAssets.exe'))
    [IO.File]::Copy((Join-Path $project 'payload\NativeBootstrapAssets.ahk'),(Join-Path $module 'NativeBootstrapAssets.ahk'))
    $valid = Join-Path $external 'launcher_update_legacy.exe'
    $bytes = New-Object byte[] 1048576
    $bytes[0]=0x4d; $bytes[1]=0x5a; $bytes[65536]=19
    [IO.File]::WriteAllBytes($valid,$bytes)
    [IO.File]::WriteAllBytes((Join-Path $external 'not-approved.exe'),$bytes)
    [IO.File]::WriteAllBytes((Join-Path $external 'launcher_update_partial.exe'),[byte[]](0x4d,0x5a))
    $hash=(Get-FileHash -LiteralPath $valid -Algorithm SHA256).Hash.ToLowerInvariant()
    $functions = ''
    foreach ($pair in @(@('NormalizePath','CanonicalLocalPath'),@('CanonicalLocalPath','WriteBootstrapTextFile'),@('GetBootstrapFileSha256','IsPlausibleLauncherExe'),@('IsSafePendingLauncherSource','GetPendingLauncherSourceSha256'))) {
        $m=[regex]::Match($main,'(?ms)^'+$pair[0]+'\([^\r\n]*\) \{.*?(?=^'+$pair[1]+'\()')
        if (-not $m.Success) { throw ('Missing boundary: '+$pair[0]) }
        $functions += $m.Value + "`n"
    }
    $fixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include payload\NativeBootstrapAssets.ahk
EnvSet("PACK_APP_DIR", A_ScriptDir)
try {
    legacySourceDir := A_ScriptDir "\..\external-config"
    legacySource := legacySourceDir "\launcher_update_legacy.exe"
    if NativeBootstrap_FileSha256(legacySource) != ""
        throw Error("Ordinary hash unexpectedly accepted outside-root input")
    if GetPendingLauncherSourceSha256(legacySource, legacySourceDir) != "EXPECTED_HASH"
        throw Error("Guarded external legacy source hash failed")
    if GetPendingLauncherSourceSha256(legacySourceDir "\not-approved.exe", legacySourceDir) != ""
        throw Error("Unapproved filename accepted")
    if GetPendingLauncherSourceSha256(legacySourceDir "\launcher_update_partial.exe", legacySourceDir) != ""
        throw Error("Partial launcher accepted")
    if GetPendingLauncherSourceSha256(legacySource, A_ScriptDir "\config") != ""
        throw Error("Unapproved external directory accepted")
    Loop Files, A_ScriptDir "\*", "FR" {
        if InStr(A_LoopFileName, "legacy_source_")
            throw Error("Legacy hash left a staged executable")
    }
    if !FileExist(legacySource)
        throw Error("Read-only hash removed its original source")
    FileAppend("PASS guarded legacy external hash, partial/name/root rejection and staging cleanup`n", "*")
} catch as legacyFailure {
    FileAppend(legacyFailure.Message "`n", "**")
    ExitApp 1
}
ExitApp 0
'@
    $fixture=$fixture.Replace('EXPECTED_HASH',$hash)
    $path=Join-Path $app 'legacy-source-test.ahk'
    [IO.File]::WriteAllText($path,($fixture+"`n"+$functions+"`n"+$required.Value),[Text.UTF8Encoding]::new($false))
    $result=Invoke-GMTestProcess -ScriptPath $path -Context $context
    if ($result.Stdout) { Write-Output $result.Stdout.TrimEnd() }
    if ($result.ExitCode -ne 0) { throw ('Legacy source isolated test failed: '+$result.Stderr) }
} finally { Complete-ProjectDevelopmentPaths -Context $context }
