[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$evidence = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\native-bootstrap-' + $stamp + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($evidence)
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The .NET Framework C# compiler is required' }
$native = Join-Path $project 'native-helper'
$framework = Join-Path $native 'FrameworkTarget.cs'
$source = Join-Path $native 'BootstrapAssets.cs'
$helper = Join-Path $evidence 'BootstrapAssets.exe'
$testExe = Join-Path $evidence 'BootstrapAssetsTests.exe'
$testSource = Join-Path $PSScriptRoot 'native\BootstrapAssetsTests.cs'
$references = @('/r:System.IO.Compression.dll','/r:System.IO.Compression.FileSystem.dll')

& $compiler /nologo /warnaserror /langversion:5 /optimize+ /target:exe @references `
    /main:Wuthering.Native.BootstrapAssets ('/out:' + $helper) $source $framework
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $helper -PathType Leaf)) {
    throw 'Native bootstrap helper compilation failed'
}
& $compiler /nologo /warnaserror /langversion:5 /optimize+ /target:exe @references `
    /main:BootstrapAssetsTests ('/out:' + $testExe) $source $framework $testSource
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $testExe -PathType Leaf)) {
    throw 'Native bootstrap tests compilation failed'
}

$fixtures = Join-Path $evidence 'fixtures'
[void][IO.Directory]::CreateDirectory($fixtures)
$nativeLog = Join-Path $evidence 'native-tests.txt'
& $testExe $fixtures $helper 2>&1 | Tee-Object -FilePath $nativeLog
if ($LASTEXITCODE -ne 0) { throw 'Native bootstrap C# regression failed' }

$install = Join-Path $evidence 'ahk-install'
$payload = Join-Path $install 'payload'
[void][IO.Directory]::CreateDirectory($payload)
Copy-Item -LiteralPath $helper -Destination (Join-Path $payload 'BootstrapAssets.exe')
Copy-Item -LiteralPath (Join-Path $project 'payload\NativeBootstrapAssets.ahk') -Destination (Join-Path $payload 'NativeBootstrapAssets.ahk')
[IO.File]::WriteAllBytes((Join-Path $install 'abc.bin'), [Text.Encoding]::ASCII.GetBytes('abc'))
$validPe = Join-Path $install 'valid-source.exe'
$fakeMz = Join-Path $install 'fake-mz.exe'
$targetPe = Join-Path $install 'tools\ffmpeg\bin\ffmpeg.exe'
$stalePartial = $targetPe + '.native-bootstrap-stale.partial'
Copy-Item -LiteralPath $helper -Destination $validPe
$fakeMzBytes = [byte[]]::new(512)
$fakeMzBytes[0] = [byte][char]'M'
$fakeMzBytes[1] = [byte][char]'Z'
[IO.File]::WriteAllBytes($fakeMz, $fakeMzBytes)
[void][IO.Directory]::CreateDirectory((Split-Path $targetPe -Parent))
[IO.File]::WriteAllText($stalePartial, 'corrupted stale partial', [Text.Encoding]::ASCII)
Add-Type -AssemblyName System.IO.Compression
$zipPath = Join-Path $install 'fixture.zip'
$zip = [IO.Compression.ZipFile]::Open($zipPath, [IO.Compression.ZipArchiveMode]::Create)
try {
    $entry = $zip.CreateEntry('ffmpeg-build/bin/ffmpeg.exe', [IO.Compression.CompressionLevel]::NoCompression)
    $writer = [IO.StreamWriter]::new($entry.Open(), [Text.UTF8Encoding]::new($false))
    try { $writer.Write('controlled ffmpeg fixture') } finally { $writer.Dispose() }
} finally { $zip.Dispose() }

$fixturePath = Join-Path $evidence 'bootstrap-wrapper-fixture.ahk'
$modulePath = Join-Path $payload 'NativeBootstrapAssets.ahk'
$outsideOutput = Join-Path $evidence 'outside-download.zip'
[IO.File]::WriteAllText(($outsideOutput + '.native-bootstrap.partial'), 'preserve-outside-root', [Text.UTF8Encoding]::new($false))
$mainPath = Join-Path $project ('payload\' + [char]0x5168 + [char]0x81EA + [char]0x52D5 + '.ahk')
$mainText = [IO.File]::ReadAllText($mainPath)
$findBundledMatch = [regex]::Match($mainText,
    '(?ms)^FindBundledFfmpegExe\(\) \{.*?(?=^ResolveDefaultScreenRecordingFfmpegExe\()')
$tryBootstrapMatch = [regex]::Match($mainText,
    '(?ms)^TryBootstrapBundledFfmpeg\(\) \{.*?(?=^ResolveScreenRecordingFfmpegExePath\()')
$resolveFfmpegMatch = [regex]::Match($mainText,
    '(?ms)^ResolveScreenRecordingFfmpegExePath\([^\r\n]*\) \{.*?(?=^NormalizeScreenRecordingQualityPreset\()')
if (-not $findBundledMatch.Success -or -not $tryBootstrapMatch.Success -or -not $resolveFfmpegMatch.Success) {
    throw 'Cannot extract formal FFmpeg resolve/bootstrap functions for isolated testing'
}
$formalFfmpegSource = $findBundledMatch.Value + "`r`n" + $tryBootstrapMatch.Value + "`r`n" + $resolveFfmpegMatch.Value
$fixture = @'
#Requires AutoHotkey v2.0+
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
EnvSet("PACK_APP_DIR", "__INSTALL__")
#Include __MODULE__
global SCREEN_RECORDING_FFMPEG_AUTO_DOWNLOAD := true
global SCREEN_RECORDING_FFMPEG_DOWNLOAD_URL := "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
global SCREEN_RECORDING_FFMPEG_EXE := "ffmpeg.exe"
global __SCREEN_RECORDING_FFMPEG_BOOTSTRAP_ATTEMPTED := false
global BOOTSTRAP_TEST_ROOT := "__INSTALL__"
global BOOTSTRAP_TEST_MODE := ""
global BOOTSTRAP_TEST_DOWNLOAD_CALLS := 0

ResolvePersistentToolsRoot() {
    global BOOTSTRAP_TEST_ROOT
    return BOOTSTRAP_TEST_ROOT
}

RuntimeFiles_RuntimeDir(category := "") {
    global BOOTSTRAP_TEST_ROOT
    return BOOTSTRAP_TEST_ROOT "\runtime"
}

CleanupBootstrapTempDir(path) {
}

DownloadFileWithProgress(url, path, title := "") {
    global BOOTSTRAP_TEST_DOWNLOAD_CALLS, BOOTSTRAP_TEST_MODE
    BOOTSTRAP_TEST_DOWNLOAD_CALLS += 1
    return BOOTSTRAP_TEST_MODE = "install"
}

ExtractZipByNative(zipPath, destination) {
    global BOOTSTRAP_TEST_MODE
    if (BOOTSTRAP_TEST_MODE != "install")
        return false
    output := destination "\fixture\bin\ffmpeg.exe"
    DirCreate(destination "\fixture\bin")
    FileCopy("__VALID_PE__", output, 1)
    return true
}

MonotonicTickMs() {
    return DllCall("Kernel32\GetTickCount64", "UInt64")
}

WriteLog(message, level := "INFO") {
}

NormalizePath(value) {
    return Trim(String(value), ' "`t`r`n')
}

RemoveManagedFfmpegFixtures() {
    for _, path in [
        "__INSTALL__\tools\ffmpeg\bin\ffmpeg.exe",
        "__INSTALL__\ffmpeg\bin\ffmpeg.exe",
        "__INSTALL__\ffmpeg.exe"
    ] {
        try FileDelete(path)
    }
}

AssertInvalidManagedFfmpegRejected(configuredValue, invalidPath, label) {
    global BOOTSTRAP_TEST_MODE, BOOTSTRAP_TEST_DOWNLOAD_CALLS
    global __SCREEN_RECORDING_FFMPEG_BOOTSTRAP_ATTEMPTED

    RemoveManagedFfmpegFixtures()
    SplitPath(invalidPath, , &invalidDir)
    DirCreate(invalidDir)
    FileCopy("__FAKE_MZ__", invalidPath, 1)
    BOOTSTRAP_TEST_MODE := "download-fail"
    BOOTSTRAP_TEST_DOWNLOAD_CALLS := 0
    __SCREEN_RECORDING_FFMPEG_BOOTSTRAP_ATTEMPTED := false
    if ResolveScreenRecordingFfmpegExePath(configuredValue) != ""
        throw Error("Formal resolve flow trusted an invalid managed " label " target")
    if (BOOTSTRAP_TEST_DOWNLOAD_CALLS != 1)
        throw Error("Formal resolve flow did not attempt repair for managed " label " target")
}

try {
    actualHash := NativeBootstrap_FileSha256("__INSTALL__\abc.bin")
    if actualHash != "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        throw Error("NativeBootstrap_FileSha256 mismatch: " actualHash)
    if !NativeBootstrap_Extract("__INSTALL__\fixture.zip", "__INSTALL__\extracted")
        throw Error("NativeBootstrap_Extract failed")
    if FileRead("__INSTALL__\extracted\ffmpeg-build\bin\ffmpeg.exe", "UTF-8") != "controlled ffmpeg fixture"
        throw Error("Extracted fixture mismatch")
    if !NativeBootstrap_IsValidPortableExecutable("__VALID_PE__")
        throw Error("Native PE validator rejected the real helper executable")
    if NativeBootstrap_IsValidPortableExecutable("__FAKE_MZ__")
        throw Error("Native PE validator accepted an MZ-only file")
    if !NativeBootstrap_InstallPortableExecutable("__VALID_PE__", "__TARGET_PE__")
        throw Error("Native atomic PE install failed")
    sourceHash := NativeBootstrap_FileSha256("__VALID_PE__")
    targetHash := NativeBootstrap_FileSha256("__TARGET_PE__")
    if (sourceHash = "" || targetHash != sourceHash)
        throw Error("Native atomic PE install did not preserve source bytes")
    if FileRead("__STALE_PARTIAL__", "UTF-8") != "corrupted stale partial"
        throw Error("Native atomic PE install consumed or modified an unrelated stale partial")
    if NativeBootstrap_InstallPortableExecutable("__FAKE_MZ__", "__TARGET_PE__")
        throw Error("Native atomic PE install accepted an invalid source")
    if NativeBootstrap_FileSha256("__TARGET_PE__") != targetHash
        throw Error("Rejected native PE install changed the prior target")
    BOOTSTRAP_TEST_MODE := "download-fail"
    BOOTSTRAP_TEST_DOWNLOAD_CALLS := 0
    __SCREEN_RECORDING_FFMPEG_BOOTSTRAP_ATTEMPTED := false
    if NativeBootstrap_CanonicalPath(ResolveScreenRecordingFfmpegExePath())
            != NativeBootstrap_CanonicalPath("__TARGET_PE__")
        throw Error("Formal resolve flow rejected a structurally valid internal target")
    if (BOOTSTRAP_TEST_DOWNLOAD_CALLS != 0)
        throw Error("Formal bootstrap downloaded despite a valid existing target")

    if NativeBootstrap_CanonicalPath(ResolveScreenRecordingFfmpegExePath("__TARGET_PE__"))
            != NativeBootstrap_CanonicalPath("__TARGET_PE__")
        throw Error("Formal resolve flow rejected a valid configured absolute managed target")
    if (BOOTSTRAP_TEST_DOWNLOAD_CALLS != 0)
        throw Error("Formal bootstrap downloaded for a valid configured absolute managed target")

    AssertInvalidManagedFfmpegRejected("__TARGET_PE__", "__TARGET_PE__", "absolute primary")
    AssertInvalidManagedFfmpegRejected("tools\ffmpeg\bin\ffmpeg.exe", "__TARGET_PE__", "relative primary")
    AssertInvalidManagedFfmpegRejected("__INSTALL__\ffmpeg\bin\ffmpeg.exe",
        "__INSTALL__\ffmpeg\bin\ffmpeg.exe", "absolute secondary")
    AssertInvalidManagedFfmpegRejected("ffmpeg\bin\ffmpeg.exe",
        "__INSTALL__\ffmpeg\bin\ffmpeg.exe", "relative secondary")
    AssertInvalidManagedFfmpegRejected("__INSTALL__\ffmpeg.exe",
        "__INSTALL__\ffmpeg.exe", "absolute root")

    BOOTSTRAP_TEST_MODE := "download-fail"
    BOOTSTRAP_TEST_DOWNLOAD_CALLS := 0
    __SCREEN_RECORDING_FFMPEG_BOOTSTRAP_ATTEMPTED := false
    if ResolveScreenRecordingFfmpegExePath() != ""
        throw Error("Formal resolve flow trusted an invalid preexisting internal target")
    if (BOOTSTRAP_TEST_DOWNLOAD_CALLS != 1)
        throw Error("Formal resolve flow did not attempt repair after rejecting invalid target")
    externalConfigured := "Z:\explicit\custom-ffmpeg.exe"
    if ResolveScreenRecordingFfmpegExePath(externalConfigured) != externalConfigured
        throw Error("Formal resolve flow changed policy for explicit external executable paths")
    externalUnc := "\\server\share\custom-ffmpeg.exe"
    if ResolveScreenRecordingFfmpegExePath(externalUnc) != externalUnc
        throw Error("Formal resolve flow changed policy for explicit external UNC paths")
    RemoveManagedFfmpegFixtures()
    BOOTSTRAP_TEST_MODE := "install"
    BOOTSTRAP_TEST_DOWNLOAD_CALLS := 0
    __SCREEN_RECORDING_FFMPEG_BOOTSTRAP_ATTEMPTED := false
    if NativeBootstrap_CanonicalPath(ResolveScreenRecordingFfmpegExePath())
            != NativeBootstrap_CanonicalPath("__TARGET_PE__")
        throw Error("Formal resolve flow did not publish through native atomic PE install")
    if !NativeBootstrap_IsValidPortableExecutable("__TARGET_PE__")
        throw Error("Formal bootstrap returned a non-PE target")
    if NativeBootstrap_FileSha256("__TARGET_PE__") != sourceHash
        throw Error("Formal bootstrap target bytes differ from extracted source")
    if NativeBootstrap_Download("http://127.0.0.1/not-allowed.zip", "__INSTALL__\forbidden.zip", "受控拒絕測試")
        throw Error("NativeBootstrap_Download accepted a forbidden URL")
    if FileExist("__INSTALL__\forbidden.zip")
        throw Error("Rejected download published output")
    if NativeBootstrap_Download("http://127.0.0.1/not-allowed.zip", "__OUTSIDE__", "根目錄邊界測試")
        throw Error("NativeBootstrap_Download accepted an outside output")
    if FileRead("__OUTSIDE__.native-bootstrap.partial", "UTF-8") != "preserve-outside-root"
        throw Error("Rejected outside output modified data beyond app root")
    FileAppend("PASS isolated AHK native bootstrap wrapper`n", "*")
    ExitApp(0)
} catch as bootstrapFixtureError {
    FileAppend(bootstrapFixtureError.Message " | what=" bootstrapFixtureError.What
        " | file=" bootstrapFixtureError.File " | line=" bootstrapFixtureError.Line
        "`n" bootstrapFixtureError.Stack "`n", "**")
    ExitApp(1)
}
'@
$fixture += "`r`n" + $formalFfmpegSource
$fixture = $fixture.Replace('__INSTALL__', $install).Replace('__MODULE__', $modulePath).Replace('__OUTSIDE__', $outsideOutput).Replace('__VALID_PE__', $validPe).Replace('__FAKE_MZ__', $fakeMz).Replace('__TARGET_PE__', $targetPe).Replace('__STALE_PARTIAL__', $stalePartial)
[IO.File]::WriteAllText($fixturePath, $fixture, [Text.UTF8Encoding]::new($false))
$ahk = Join-Path $project 'AutoHotkey64.exe'
$stdout = Join-Path $evidence 'ahk-wrapper.stdout.txt'
$stderr = Join-Path $evidence 'ahk-wrapper.stderr.txt'
$process = Start-Process -FilePath $ahk -ArgumentList @('/ErrorStdOut=UTF-8', ('"' + $fixturePath + '"')) `
    -WorkingDirectory $evidence -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
[void]$process.Handle
if (-not $process.WaitForExit(15000)) {
    Stop-Process -Id $process.Id -ErrorAction SilentlyContinue
    throw 'Isolated AHK bootstrap wrapper exceeded 15 seconds'
}
$process.WaitForExit()
$ahkExit = $process.ExitCode
$process.Dispose()
if ($ahkExit -ne 0) {
    throw ('Isolated AHK bootstrap wrapper failed: ' + [IO.File]::ReadAllText($stderr))
}
Get-Content -LiteralPath $stdout
Write-Output ('PASS: native bootstrap assets isolated suite; evidence=' + $evidence)
