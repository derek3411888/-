[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:Checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw $Message
    }
    $script:Checks++
}

function ConvertTo-AhkLiteral {
    param([string]$Value)
    return '"' + $Value.Replace('"', '""') + '"'
}

function Invoke-IsolatedAhk {
    param(
        [string]$AutoHotkey,
        [string]$ScriptPath,
        [string]$WorkingDirectory,
        [int]$TimeoutMilliseconds = 15000
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $AutoHotkey
    $psi.Arguments = '/ErrorStdOut=UTF-8 "' + $ScriptPath + '"'
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) {
        throw 'Failed to start isolated ImagePut fixture.'
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        $process.Kill()
        [void]$process.WaitForExit(5000)
        throw 'Isolated ImagePut fixture exceeded its bounded timeout.'
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    [IO.File]::WriteAllText(($ScriptPath + '.stdout.txt'), $stdout, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText(($ScriptPath + '.stderr.txt'), $stderr, [Text.UTF8Encoding]::new($false))
    if ($process.ExitCode -ne 0) {
        throw ('Isolated ImagePut fixture failed: ' + $stderr.Trim())
    }
    return $stdout.Trim()
}

$project = Split-Path $PSScriptRoot -Parent
$stamp = [DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')
$evidenceRoot = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\imageput-lifetime-' + $stamp + '-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
$resultPath = Join-Path $evidenceRoot 'result.txt'

try {
    $mainCandidates = @(Get-ChildItem -LiteralPath (Join-Path $project 'payload') -Filter '*.ahk' -File | Where-Object {
        $text = [IO.File]::ReadAllText($_.FullName)
        $text.Contains('#Include plugin\ImagePut-1.11\ImagePut.ahk') -and $text.Contains('global PAYLOAD_BUILD_VERSION')
    })
    Assert-True ($mainCandidates.Count -eq 1) 'Expected one payload main source containing the ImagePut include.'
    $mainSource = [IO.File]::ReadAllText($mainCandidates[0].FullName)
    $includeNeedle = '#Include plugin\ImagePut-1.11\ImagePut.ahk'
    $pinNeedle = 'global IMAGEPUT_GDIPLUS_PROCESS_PIN := ImagePut.gdiplusStartup()'
    $includeIndex = $mainSource.IndexOf($includeNeedle, [StringComparison]::Ordinal)
    $pinIndex = $mainSource.IndexOf($pinNeedle, [StringComparison]::Ordinal)
    $loggerIndex = $mainSource.IndexOf('global logger := InitLogger(', [StringComparison]::Ordinal)
    Assert-True ($includeIndex -ge 0 -and $pinIndex -gt $includeIndex) 'Main must pin GDI+ immediately after loading ImagePut.'
    Assert-True ($loggerIndex -gt $pinIndex) 'The ImagePut process-lifetime pin must precede logger and timer startup.'
    $between = $mainSource.Substring($includeIndex + $includeNeedle.Length, $pinIndex - ($includeIndex + $includeNeedle.Length))
    $meaningfulBetween = (($between -split "`r?`n") | Where-Object {
        $trimmed = $_.Trim()
        $trimmed -ne '' -and -not $trimmed.StartsWith(';')
    })
    Assert-True (@($meaningfulBetween).Count -eq 0) 'The GDI+ lifetime pin must be the next executable line after the ImagePut include.'
    Assert-True (-not $mainSource.Contains('ImagePut.gdiplusShutdown()')) 'Main must not release the process-lifetime GDI+ pin during runtime or OnExit.'

    $vendorPath = Join-Path $project 'payload\plugin\ImagePut-1.11\ImagePut.ahk'
    $vendorSource = [IO.File]::ReadAllText($vendorPath)
    $startupIndex = $vendorSource.IndexOf('this.gdiplusStartup()', [StringComparison]::Ordinal)
    $convertIndex = $vendorSource.IndexOf('coimage := this.convert(', [StringComparison]::Ordinal)
    $shutdownIndex = $vendorSource.IndexOf('this.gdiplusShutdown(cotype)', [StringComparison]::Ordinal)
    $unloadIndex = $vendorSource.IndexOf('DllCall("gdiplus\GdiplusShutdown"', [StringComparison]::Ordinal)
    $decrementIndex = $vendorSource.IndexOf('instances += vary', [StringComparison]::Ordinal)
    Assert-True ($startupIndex -ge 0 -and $convertIndex -gt $startupIndex -and $shutdownIndex -gt $convertIndex) 'Fixture requires the observed ImagePut call lifecycle.'
    Assert-True ($unloadIndex -ge 0 -and $decrementIndex -gt $unloadIndex) 'Fixture requires the observed unload-before-counter-update gap.'

    $patchedVendorPath = Join-Path $evidenceRoot 'ImagePut.ForcedYield.ahk'
    $unloadNeedle = '         DllCall("FreeLibrary", "ptr", DllCall("GetModuleHandle", "str", "gdiplus", "ptr"))'
    $unloadReplacement = $unloadNeedle + "`r`n         ImagePutLifetimeTestForceYield()"
    $patchedVendor = $vendorSource.Replace($unloadNeedle, $unloadReplacement)
    Assert-True ($patchedVendor -ne $vendorSource) 'Failed to inject the test-only forced-yield hook.'
    Assert-True (([regex]::Matches($patchedVendor, [regex]::Escape('ImagePutLifetimeTestForceYield()'))).Count -eq 1) 'Forced-yield hook must be injected exactly once.'
    [IO.File]::WriteAllText($patchedVendorPath, $patchedVendor, [Text.UTF8Encoding]::new($false))

    $pngPath = Join-Path $evidenceRoot 'synthetic.png'
    $pngBytes = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9WlS8AAAAASUVORK5CYII=')
    [IO.File]::WriteAllBytes($pngPath, $pngBytes)
    Assert-True ((Get-Item -LiteralPath $pngPath).Length -gt 50) 'Synthetic PNG fixture was not created.'

    $autoHotkey = Join-Path $project 'AutoHotkey64.exe'
    Assert-True (Test-Path -LiteralPath $autoHotkey -PathType Leaf) 'AutoHotkey64.exe is required for isolated ImagePut fixtures.'
    Assert-True (@(Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue).Count -eq 0) 'Serialized ImagePut test requires an AutoHotkey baseline of zero.'

    $unpinnedFixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include __VENDOR__

global ipltPng := __PNG__
global ipltHookArmed := true, ipltHookEntered := 0, ipltReentryDone := false, ipltReentryError := ""

Check(ok,message) {
    if !ok
        throw Error(message)
}

ImagePutLifetimeTestForceYield() {
    global ipltHookArmed, ipltHookEntered, ipltReentryDone
    if !ipltHookArmed
        return
    ipltHookArmed := false
    ipltHookEntered += 1
    Critical "Off"
    Thread "Interrupt", 0
    SetTimer(ImagePutLifetimeTestReenter,1)
    deadline := A_TickCount + 250
    while !ipltReentryDone && A_TickCount < deadline
        Sleep(1)
    SetTimer(ImagePutLifetimeTestReenter,0)
}

ImagePutLifetimeTestReenter() {
    global ipltPng, ipltReentryDone, ipltReentryError
    try {
        nested := ImagePutBuffer(ipltPng)
        nested := ""
        ipltReentryError := "unexpected-success"
    } catch as e {
        ipltReentryError := e.Message
    }
    ipltReentryDone := true
}

try {
    ; Leave AutoHotkey's initial uninterruptible launch interval before forcing
    ; the one-shot timer into the instrumented unload gap.
    Sleep(20)
    output := A_ScriptDir "\unpinned.jpg"
    ImagePutFile(ipltPng,output,80)
    Check(FileExist(output),"outer synthetic conversion did not complete")
    Check(ipltReentryDone,"forced timer reentry did not execute in unload gap; hook=" ipltHookEntered)
    Check(InStr(ipltReentryError,"pBitmap cannot be zero"),"unpinned unload gap did not reproduce zero bitmap: " ipltReentryError)
    FileAppend("PASS unpinned forced timer reentry reproduces disposed GDI+`n","*")
} catch as fixtureError {
    FileAppend(fixtureError.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
'@
    $unpinnedFixture = $unpinnedFixture.Replace('__VENDOR__', $patchedVendorPath).Replace('__PNG__', (ConvertTo-AhkLiteral $pngPath))
    $unpinnedPath = Join-Path $evidenceRoot 'unpinned-reentry.ahk'
    [IO.File]::WriteAllText($unpinnedPath, $unpinnedFixture, [Text.UTF8Encoding]::new($false))
    $unpinnedOutput = Invoke-IsolatedAhk -AutoHotkey $autoHotkey -ScriptPath $unpinnedPath -WorkingDirectory $evidenceRoot
    Assert-True ($unpinnedOutput.Contains('PASS unpinned forced timer reentry')) 'Unpinned root-cause fixture did not report success.'

    $pinnedFixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include __VENDOR__

global IPLT_PROCESS_PIN := ImagePut.gdiplusStartup()
global ipltPng := __PNG__
global ipltHookCount := 0, ipltTimerCount := 0, ipltFailure := ""

Check(ok,message) {
    if !ok
        throw Error(message)
}

ImagePutLifetimeTestForceYield() {
    global ipltHookCount
    ipltHookCount += 1
}

ImagePutLifetimeConvertOnce() {
    global ipltPng
    image := ImagePutBuffer(ipltPng)
    if (image.width != 1 || image.height != 1)
        throw Error("synthetic PNG dimensions changed")
    image := ""
}

ImagePutLifetimeTimer() {
    global ipltTimerCount, ipltFailure
    try {
        ImagePutLifetimeConvertOnce()
        ipltTimerCount += 1
    } catch as e {
        ipltFailure := e.Message
        SetTimer(ImagePutLifetimeTimer,0)
    }
}

try {
    Sleep(20)
    Check(IPLT_PROCESS_PIN >= 1,"process lifetime pin was not established")
    SetTimer(ImagePutLifetimeTimer,1)
    Loop 40 {
        ImagePutLifetimeConvertOnce()
        Sleep(2)
    }
    deadline := A_TickCount + 3000
    while (ipltTimerCount < 8 && ipltFailure = "" && A_TickCount < deadline)
        Sleep(5)
    SetTimer(ImagePutLifetimeTimer,0)
    output := A_ScriptDir "\pinned.jpg"
    ImagePutFile(ipltPng,output,80)
    Check(ipltFailure = "","timer conversion failed: " ipltFailure)
    Check(ipltTimerCount >= 8,"timer conversion stress did not run")
    Check(ipltHookCount = 0,"pinned lifetime unexpectedly entered GDI+ unload gap")
    Check(FileExist(output),"pinned synthetic conversion did not create output")
    FileAppend("PASS pinned synthetic PNG timer stress count=" ipltTimerCount "`n","*")
} catch as fixtureError {
    try SetTimer(ImagePutLifetimeTimer,0)
    FileAppend(fixtureError.Message "`n","**")
    ExitApp(1)
}
ExitApp(0)
'@
    $pinnedFixture = $pinnedFixture.Replace('__VENDOR__', $patchedVendorPath).Replace('__PNG__', (ConvertTo-AhkLiteral $pngPath))
    $pinnedPath = Join-Path $evidenceRoot 'pinned-timer-stress.ahk'
    [IO.File]::WriteAllText($pinnedPath, $pinnedFixture, [Text.UTF8Encoding]::new($false))
    $pinnedOutput = Invoke-IsolatedAhk -AutoHotkey $autoHotkey -ScriptPath $pinnedPath -WorkingDirectory $evidenceRoot
    Assert-True ($pinnedOutput.Contains('PASS pinned synthetic PNG timer stress')) 'Pinned timer stress fixture did not report success.'

    Assert-True (@(Get-Process -Name 'AutoHotkey*' -ErrorAction SilentlyContinue).Count -eq 0) 'ImagePut fixtures left AutoHotkey processes behind.'
    $summary = 'PASS ImagePut process lifetime: ' + $script:Checks + ' checks; evidence=' + $evidenceRoot
    [IO.File]::WriteAllText($resultPath, $summary + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Output $summary
} catch {
    [IO.File]::WriteAllText($resultPath, ('FAIL: ' + $_.Exception.Message + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    throw
}
