[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$ahk = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%' OR Name = 'AutoHotkey.exe'")
if ($ahk.Count) { throw 'Native-only acceptance requires zero AHK baseline' }
$run = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\native-suite-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
[void][IO.Directory]::CreateDirectory($run)
& (Join-Path $project 'native-helper\Build-NativeHelpers.ps1') -OutputDirectory $run
& (Join-Path $project 'native-helper\Build-NativeHelpers.ps1') -OutputDirectory $run
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$native = Join-Path $project 'native-helper'
$testCases = @(
    @{ Name='MaintenanceNoticeTests'; Sources=@('MaintenanceNotice.cs') },
    @{ Name='InstallDiscoveryTests'; Sources=@('InstallDiscovery.cs') },
    @{ Name='LauncherMaintenanceTests'; Sources=@('LauncherMaintenance.cs') },
    @{ Name='MaintenanceWorkerTests'; Sources=@('MaintenanceWorker.cs','MaintenanceNotice.cs','InstallDiscovery.cs') }
)
foreach ($case in $testCases) {
    $sources = @($case.Sources | ForEach-Object { Join-Path $native $_ }) + @(Join-Path $native 'FrameworkTarget.cs') + @(Join-Path $PSScriptRoot ('native\' + $case.Name + '.cs'))
    $exe = Join-Path $run ($case.Name + '.exe')
    & $compiler /nologo /warnaserror /langversion:5 /r:System.Web.Extensions.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll ('/main:' + $case.Name) ('/out:' + $exe) @sources
    if ($LASTEXITCODE -ne 0) { throw ('Native test compilation failed: ' + $case.Name) }
    $arguments = @()
    if ($case.Name -eq 'MaintenanceWorkerTests') { $arguments = @((Join-Path $run 'worker-fixtures'),(Join-Path $run 'GameMaintenanceWorker.exe')) }
    if ($case.Name -eq 'LauncherMaintenanceTests') { $arguments = @((Join-Path $run 'launcher-fixtures'),(Join-Path $run 'LauncherMaintenance.exe')) }
    & $exe @arguments 2>&1 | Tee-Object -FilePath (Join-Path $run ($case.Name + '.txt'))
    if ($LASTEXITCODE -ne 0) { throw ('Native regression failed: ' + $case.Name) }
}
& (Join-Path $PSScriptRoot 'NativeMaintenanceIntegrationTest.ps1')
$ahk = @(Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'")
if ($ahk.Count) { throw 'Zero-AHK postcondition failed' }
Write-Output ('PASS: native-only suite; AHK=0; evidence=' + $run)
