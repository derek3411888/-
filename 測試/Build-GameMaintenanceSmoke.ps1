[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot (Split-Path $PSScriptRoot -Parent) -RunName 'gm-compile'
$script:developmentPaths = $context
try {
    $errors = $null; $tokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $context.ProjectRoot '打包更新.ps1'), [ref]$tokens, [ref]$errors)
    Assert-GMEqual @($errors).Count 0 'release source parser'
    foreach ($name in @('Wait-HiddenProcess','Invoke-AhkValidate','Invoke-AhkCompile','Get-GameMaintenancePayloadFiles','Get-PayloadZipExcludes','New-FilteredZip','Assert-ZipContains','Assert-ZipExcludes')) {
        $function = $ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst]},$false) | Where-Object Name -eq $name
        Assert-GMEqual @($function).Count 1 "release function: $name"
        . ([ScriptBlock]::Create($function.Extent.Text))
    }
    $buildRoot = Join-Path $context.ProjectRoot ('.dev-runtime\build\game-maintenance-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($buildRoot) | Out-Null
    $compiler = 'C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe'
    $runtime = Join-Path $context.ProjectRoot 'AutoHotkey64.exe'
    $payloadRuntime = Join-Path $context.ProjectRoot 'payload\AutoHotkey64.exe'
    $payloadSource = Join-Path $context.ProjectRoot 'payload\全自動.ahk'
    $payloadExe = Join-Path $buildRoot 'payload-smoke.exe'
    $launcherSource = Join-Path $buildRoot '打包啟動器.ahk'
    $launcherExe = Join-Path $buildRoot 'launcher-smoke.exe'
    Invoke-AhkValidate $payloadRuntime $payloadSource 'Payload source validate only'
    Invoke-AhkCompile $compiler $payloadSource $payloadExe $payloadRuntime 'Payload isolated compile'
    $payloadZip = Join-Path $buildRoot 'payload.zip'
    New-FilteredZip (Join-Path $context.ProjectRoot 'payload') $payloadZip (@(Get-PayloadZipExcludes) + @('全自動鋤地.exe'))
    $archive = [IO.Compression.ZipFile]::Open($payloadZip,[IO.Compression.ZipArchiveMode]::Update)
    try {
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$payloadExe,'全自動鋤地.exe',[IO.Compression.CompressionLevel]::Optimal) | Out-Null
    } finally { $archive.Dispose() }
    Assert-ZipContains $payloadZip (@(Get-GameMaintenancePayloadFiles) + @('全自動鋤地.exe','AutoHotkey64.exe'))
    Assert-ZipExcludes $payloadZip (Get-PayloadZipExcludes)
    Copy-Item -LiteralPath (Join-Path $context.ProjectRoot '打包啟動器.ahk') -Destination $launcherSource
    Copy-Item -LiteralPath (Join-Path $context.ProjectRoot 'LauncherProcessCleanupPolicy.ahk') -Destination $buildRoot
    Copy-Item -LiteralPath $runtime -Destination $buildRoot
    Invoke-AhkValidate $runtime $launcherSource 'Launcher source validate only'
    Invoke-AhkCompile $compiler $launcherSource $launcherExe $runtime 'Launcher isolated compile'
    $result = [ordered]@{ verifiedAtUtc=[DateTime]::UtcNow.ToString('o'); sourceCommit=(& git rev-parse HEAD)
        sourceMayIncludeUncommittedChanges=$true; status='ISOLATED_COMPILE_ONLY_NOT_RELEASED'
        executedCompiledBinaries=$false; actualProviderUpdateAccepted=$false; outputs=@() }
    foreach ($file in @($payloadExe,$payloadZip,$launcherExe)) {
        $item=Get-Item -LiteralPath $file
        $result.outputs += @{path=$item.FullName;length=$item.Length;sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}
    }
    [IO.File]::WriteAllText((Join-Path $buildRoot 'compile-result.json'),($result | ConvertTo-Json -Depth 5),[Text.UTF8Encoding]::new($false))
    Write-Output "PASS: isolated Payload + Launcher validate/compile and payload ZIP checks; compiled EXEs never executed. $buildRoot"
} finally { Complete-ProjectDevelopmentPaths -Context $context }
