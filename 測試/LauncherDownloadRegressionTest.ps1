[CmdletBinding()]
param([switch]$LongTransfer)
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$run = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\download-regression-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($run)
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$helper = Join-Path $run 'LauncherMaintenance.exe'
$test = Join-Path $run 'LauncherDownloadTests.exe'
& $compiler /nologo /warnaserror /langversion:5 /target:exe /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll ('/out:' + $helper) (Join-Path $project 'native-helper\LauncherMaintenance.cs') (Join-Path $project 'native-helper\FrameworkTarget.cs')
if ($LASTEXITCODE -ne 0) { throw 'Download helper compilation failed' }
& $compiler /nologo /warnaserror /langversion:5 /target:exe ('/r:' + $helper) ('/out:' + $test) (Join-Path $PSScriptRoot 'native\LauncherDownloadTests.cs')
if ($LASTEXITCODE -ne 0) { throw 'Download regression compilation failed' }
if ($LongTransfer) { & $test $run $helper long }
else { & $test $run $helper }
if ($LASTEXITCODE -ne 0) { throw 'Native download regressions failed' }
