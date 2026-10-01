[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$hostText = [IO.File]::ReadAllText((Join-Path $project 'payload\GameMaintenanceHost.ahk'))
$startWorker = [regex]::Match($hostText, '(?ms)^GMHost_StartWorker\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)').Value
if ($startWorker -notmatch 'GameMaintenanceWorker\.exe' -or $startWorker -match 'powershell|ExecutionPolicy|\.ps1') {
    throw 'Formal maintenance worker must invoke the native executable, without a script fallback'
}
# Locate the Chinese-named build entry by its existing package contract, not ANSI literals.
$buildScripts = @(Get-ChildItem -LiteralPath $project -Filter '*.ps1' -File | Where-Object {
    [IO.File]::ReadAllText($_.FullName).Contains('function Get-GameMaintenancePayloadFiles')
})
if ($buildScripts.Count -ne 1) { throw 'Expected exactly one package entry' }
$packageText = [IO.File]::ReadAllText($buildScripts[0].FullName)
if ($packageText -notmatch 'Build-NativeHelpers\.ps1' -or $packageText -notmatch 'GameMaintenanceWorker\.exe') {
    throw 'Package must compile and require the native worker'
}
$build = $packageText.IndexOf("'native-helper\Build-NativeHelpers.ps1'")
$regression = $packageText.IndexOf("`nTest-GameMaintenanceReleaseSources")
if ($build -lt 0 -or $regression -lt 0 -or $build -ge $regression) { throw 'Native build must precede release regression' }
foreach ($required in @('PerformanceTelemetryWorker.exe','RuntimeUtilities.exe','BootstrapAssets.exe',
    'NativeRuntimeUtilities.ahk','NativeBootstrapAssets.ahk')) {
    if (-not $packageText.Contains("'" + $required + "'")) {
        throw ('Formal native auxiliary component is missing from package validation: ' + $required)
    }
}
$nativeBuildText = [IO.File]::ReadAllText((Join-Path $project 'native-helper\Build-NativeHelpers.ps1'))
$telemetryTestText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'NativePerformanceTelemetryTest.ps1'))
if ($telemetryTestText -notmatch 'Assert-NoLiveGameForTelemetryTest' -or
    $telemetryTestText -match '\$presentMonSource' -or
    $telemetryTestText -notmatch 'gameRunning.*false') {
    throw 'Real telemetry adapter fixture must reject live games and require no formal-install asset'
}
foreach ($helper in @('PerformanceTelemetryWorker','RuntimeUtilities','BootstrapAssets')) {
    if (-not $nativeBuildText.Contains($helper + '.exe') -or
        -not $nativeBuildText.Contains('Wuthering.Native.' + $helper)) {
        throw ('Native build does not compile the formal auxiliary helper: ' + $helper)
    }
}
foreach ($module in @('GameMaintenanceHost.ahk','PerformanceTelemetry.ahk',
    'NativeRuntimeUtilities.ahk','NativeBootstrapAssets.ahk')) {
    $moduleText = [IO.File]::ReadAllText((Join-Path $project ('payload\' + $module)))
    if ($moduleText -match '(?i)-ExecutionPolicy\s+Bypass|WindowsPowerShell\\|powershell\.exe|pwsh\.exe') {
        throw ('Formal runtime adapter must not invoke a PowerShell fallback: ' + $module)
    }
}
$releasePath = @(Get-ChildItem -LiteralPath $project -Filter '*.ps1' -File | Where-Object {
    [IO.File]::ReadAllText($_.FullName).Contains('function Set-ManifestArtifactCommit')
})
if ($releasePath.Count -ne 1) { throw 'Expected exactly one publication entry' }
$releaseText = [IO.File]::ReadAllText($releasePath[0].FullName)
$releasePaths = [regex]::Match($releaseText,'(?ms)^\$releasePaths = @\(.*?^\)').Value
if ($releasePaths -notmatch "'native-helper'") { throw 'Publication must commit native helper sources alongside their binaries' }
Write-Output 'PASS: native maintenance formal invocation and package contract (static, no AHK)'
