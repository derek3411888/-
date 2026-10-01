[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$project = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent)).TrimEnd('\')
$target = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
if (-not $target.StartsWith($project + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Native build output must remain inside the project'
}
for ($scan = $target; $scan; $scan = [IO.Path]::GetDirectoryName($scan)) {
    if ((Test-Path -LiteralPath $scan) -and ((Get-Item -LiteralPath $scan -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Native build output cannot use reparse points'
    }
    if ([IO.Path]::GetPathRoot($scan) -eq $scan) { break }
}
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler is required' }
[void][IO.Directory]::CreateDirectory($target)
$destination = Join-Path $target 'GameMaintenanceWorker.exe'
$temporary = Join-Path $target ('GameMaintenanceWorker.' + [guid]::NewGuid().ToString('N') + '.exe')
$sources = @('FrameworkTarget.cs','MaintenanceWorker.cs','MaintenanceNotice.cs','InstallDiscovery.cs') | ForEach-Object { Join-Path $PSScriptRoot $_ }
try {
    & $compiler /nologo /warnaserror /langversion:5 /optimize+ /target:exe /r:System.Web.Extensions.dll /main:Wuthering.Native.MaintenanceWorker ('/out:' + $temporary) @sources
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary)) { throw 'Native maintenance worker compilation failed' }
    if (Test-Path -LiteralPath $destination) { [IO.File]::Replace($temporary,$destination,[NullString]::Value) }
    else { [IO.File]::Move($temporary,$destination) }
    Write-Output ('Built native maintenance worker: ' + $destination)
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}

$destination = Join-Path $target 'LauncherMaintenance.exe'
$temporary = Join-Path $target ('LauncherMaintenance.' + [guid]::NewGuid().ToString('N') + '.exe')
try {
    & $compiler /nologo /warnaserror /langversion:5 /optimize+ /target:exe /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /main:Wuthering.Native.LauncherMaintenance ('/out:' + $temporary) (Join-Path $PSScriptRoot 'LauncherMaintenance.cs') (Join-Path $PSScriptRoot 'FrameworkTarget.cs')
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary)) { throw 'Native launcher helper compilation failed' }
    if (Test-Path -LiteralPath $destination) { [IO.File]::Replace($temporary,$destination,[NullString]::Value) }
    else { [IO.File]::Move($temporary,$destination) }
    Write-Output ('Built native launcher helper: ' + $destination)
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
}

$auxiliaryHelpers = @(
    @{
        File = 'PerformanceTelemetryWorker.exe'
        Main = 'Wuthering.Native.PerformanceTelemetryWorker'
        References = @('System.Web.Extensions.dll','System.Management.dll')
        Sources = @('PerformanceTelemetryModel.cs','PerformanceTelemetryCollectors.cs','PerformanceTelemetryWorker.cs')
    },
    @{
        File = 'RuntimeUtilities.exe'
        Main = 'Wuthering.Native.RuntimeUtilities'
        References = @('System.Web.Extensions.dll')
        Sources = @('RuntimeUtilities.cs')
    },
    @{
        File = 'BootstrapAssets.exe'
        Main = 'Wuthering.Native.BootstrapAssets'
        References = @('System.IO.Compression.dll','System.IO.Compression.FileSystem.dll')
        Sources = @('BootstrapAssets.cs')
    }
)
foreach ($helper in $auxiliaryHelpers) {
    $destination = Join-Path $target $helper.File
    $temporary = Join-Path $target ([IO.Path]::GetFileNameWithoutExtension($helper.File) + '.' + [guid]::NewGuid().ToString('N') + '.exe')
    $sources = @('FrameworkTarget.cs') + $helper.Sources | ForEach-Object { Join-Path $PSScriptRoot $_ }
    foreach ($source in $sources) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw ('Missing native source: ' + $source) }
    }
    $references = @($helper.References | ForEach-Object { '/r:' + $_ })
    try {
        & $compiler /nologo /warnaserror /langversion:5 /optimize+ /target:exe @references ('/main:' + $helper.Main) ('/out:' + $temporary) @sources
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $temporary)) { throw ('Native helper compilation failed: ' + $helper.File) }
        if (Test-Path -LiteralPath $destination) { [IO.File]::Replace($temporary,$destination,[NullString]::Value) }
        else { [IO.File]::Move($temporary,$destination) }
        Write-Output ('Built native auxiliary helper: ' + $destination)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}
