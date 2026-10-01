[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$project=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $project -RunName 'launcher-native-integration'
try {
    # Resolve the launcher source without any ANSI-dependent source literals.
    $launcher=@(Get-ChildItem -LiteralPath $project -Filter '*.ahk' | Where-Object {
        [IO.File]::ReadAllText($_.FullName).Contains('ExtractZipNative(workDir) {')
    })
    if($launcher.Count -ne 1){throw 'Expected one launcher source'}
    $source=[IO.File]::ReadAllText($launcher[0].FullName)
    $functions=foreach($name in @('ExtractZipNative','LauncherNativeParentStamp','LauncherNativeHelperPath','LauncherNeedsPayloadRecovery')) {
        $match=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|^; \u8a2d\u7f6e\u9032\u7a0b\u512a\u5148\u7d1a|\z)')
        if(!$match.Success){throw ('Missing function '+$name)}
        $match.Value
    }
    $native=Join-Path $context.RunRoot 'native'
    & (Join-Path $project 'native-helper\Build-NativeHelpers.ps1') -OutputDirectory $native
    $install=Join-Path $context.RunRoot 'install'
    [void][IO.Directory]::CreateDirectory($install)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::Open((Join-Path $install 'payload.zip'),[IO.Compression.ZipArchiveMode]::Create)
    try {
        $name=-join @([char]0x5168,[char]0x81EA,[char]0x52D5,'.ahk')
        $writer=[IO.StreamWriter]::new($zip.CreateEntry($name).Open())
        try{$writer.Write('inert fixture only')}finally{$writer.Dispose()}
    } finally {$zip.Dispose()}
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __LOCK__
global PACK_NATIVE_HELPER_PATH := "__HELPER__"
global PACK_RUNTIME_MUTEX_HANDLE := InstallStartupLock_AcquireRuntime("__INSTALL__")
startup := InstallStartupLock_Acquire("__INSTALL__")
WriteLog(*) => 0
try {
    if startup <= 0 || PACK_RUNTIME_MUTEX_HANDLE <= 0
        throw Error("fixture reservations unavailable")
    if !ExtractZipNative("__INSTALL__")
        throw Error("actual source-mode AHK to native extraction failed")
    if PACK_RUNTIME_MUTEX_HANDLE <= 0
        throw Error("parent did not reacquire runtime ownership")
    if !FileExist("__INSTALL__\payload\" Chr(0x5168) Chr(0x81EA) Chr(0x52D5) ".ahk")
        throw Error("actual extraction not published")
    if LauncherNeedsPayloadRecovery("__INSTALL__")
        throw Error("successful publication retained pending recovery")
    fixtureUpdateDir := "__INSTALL__\" Chr(0x57F7) Chr(0x884C) Chr(0x66AB) Chr(0x5B58) "\" Chr(0x66F4) Chr(0x65B0)
    FileAppend("publishing", fixtureUpdateDir "\payload_transaction.txt")
    ; Same timestamp, healthy main, no remote update: recovery still overrides
    ; the otherwise-false unpack decision before startup can dispatch.
    needUnpack := false, WORK_DIR := "__INSTALL__"
    __RECOVERY_GATE__
    if !needUnpack
        throw Error("interrupted transaction bypassed unchanged-version gate")
    FileDelete(fixtureUpdateDir "\payload_transaction.txt")
    FileAppend("PASS actual AHK native extraction, external interpreter parent, runtime lock handoff/reacquisition`n", "*")
} catch as fixtureError {
    FileAppend(fixtureError.Message "`n", "**")
    ExitApp(1)
} finally {
    InstallStartupLock_Release(PACK_RUNTIME_MUTEX_HANDLE)
    InstallStartupLock_Release(startup)
}
ExitApp(0)
__FUNCTIONS__
'@
    $recovery=[regex]::Match($source,'(?ms)^if LauncherNeedsPayloadRecovery\(WORK_DIR\) \{.*?^\}').Value
    if(!$recovery){throw 'Missing actual pre-dispatch recovery decision'}
    $fixture=$fixture.Replace('__RECOVERY_GATE__',$recovery).Replace('__LOCK__',(Join-Path $project 'payload\InstallStartupLock.ahk')).Replace('__HELPER__',(Join-Path $native 'LauncherMaintenance.exe')).Replace('__INSTALL__',$install).Replace('__FUNCTIONS__',($functions -join "`n"))
    $path=Join-Path $context.RunRoot 'native-integration.ahk'
    [IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($false))
    $result=Invoke-GMTestProcess -ScriptPath $path -Context $context
    if($result.Stdout){Write-Output $result.Stdout.TrimEnd()}
    if($result.ExitCode -ne 0){throw $result.Stderr}
} finally {Complete-ProjectDevelopmentPaths -Context $context}
