$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot (Split-Path $PSScriptRoot -Parent) -RunName 'gm-package-test'
try {
    $packagePath = Join-Path $context.ProjectRoot '打包更新.ps1'
    $parseErrors = $null; $parseTokens = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($packagePath, [ref]$parseTokens, [ref]$parseErrors)
    Assert-GMEqual @($parseErrors).Count 0 'package script parses'
    $serverPackage = Get-Content -LiteralPath (Join-Path $context.ProjectRoot 'self-hosted-server\package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-GMTrue ($serverPackage.scripts.check -notmatch '\.\./remote-control-web') 'standalone server check must not depend on a sibling website absent from server bundle'
    foreach ($name in @('Get-GameMaintenancePayloadFiles','Get-PayloadZipExcludes','New-FilteredZip','Assert-ZipContains','Assert-ZipExcludes','Wait-HiddenProcess')) {
        $function = $ast.FindAll({param($item) $item -is [Management.Automation.Language.FunctionDefinitionAst]}, $false) | Where-Object Name -eq $name
        Assert-GMEqual @($function).Count 1 "pure package function exists: $name"
        # Only literal function definitions are evaluated, never the release body.
        . ([ScriptBlock]::Create($function.Extent.Text))
    }
    $required = @(Get-GameMaintenancePayloadFiles)
    foreach ($name in @('GameMaintenance.ahk','GameMaintenancePolicy.ahk','GameMaintenanceHost.ahk','GameUpdateAdapters.ahk','GameUpdateOcrPolicy.ahk','GameMaintenanceWorker.ps1','GameMaintenanceNotice.ps1','GameInstallDiscovery.ps1')) {
        Assert-GMTrue ($required -contains $name) "required new payload file: $name"
        Assert-GMTrue (Test-Path -LiteralPath (Join-Path $context.ProjectRoot "payload\$name")) "source exists: $name"
    }
    $source = Join-Path $context.RunRoot 'payload'
    $archive = Join-Path $context.RunRoot 'payload-test.zip'
    $forbidden = @('config/game-maintenance/state.ini','config/credential.dat','docs/plan.md','fixtures/notice.json',
        'tests/example.ahk','test/example.js','測試/fixture.ps1','.superpowers/ledger.md','.dev-runtime/private.log',
        'node_modules/module/index.js','log/old.log','.env','.env.local','temp-capture.png','temp.tmp','run.partial','staging.new')
    foreach ($name in ($required + $forbidden + @('RuntimeFilePaths.ahk','icon_main.png','plugin/license.txt'))) {
        $destination = Join-Path $source $name
        [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
        [IO.File]::WriteAllText($destination, 'test fixture only')
    }
    $excludes = @(Get-PayloadZipExcludes)
    New-FilteredZip $source $archive $excludes
    Assert-ZipContains $archive ($required + @('RuntimeFilePaths.ahk','icon_main.png','plugin/license.txt'))
    Assert-ZipExcludes $archive $forbidden
    # A nonzero native process result must never become an empty/success exit code on PS 5.1.
    $process = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') `
        -ArgumentList '-NoProfile -Command "Start-Sleep -Milliseconds 200; exit 7"' -PassThru -WindowStyle Hidden
    try { Assert-GMEqual (Wait-HiddenProcess $process 'fixture exit code' 5) 7 'hidden process exact exit code' }
    finally { $process.Dispose() }
    $ahkExit = Join-Path $context.RunRoot 'fast-exit.ahk'
    [IO.File]::WriteAllText($ahkExit,"#Requires AutoHotkey v2.0`nExitApp(7)",[Text.UTF8Encoding]::new($true))
    $process = Start-Process -FilePath (Join-Path $context.ProjectRoot 'AutoHotkey64.exe') `
        -ArgumentList ('/ErrorStdOut "' + $ahkExit + '"') -PassThru -WindowStyle Hidden
    try { Assert-GMEqual (Wait-HiddenProcess $process 'AHK exit fixture' 5) 7 'fast GUI-subsystem exact exit code' }
    finally { $process.Dispose() }
    Write-Output 'PASS: payload content/exclusion policy, release-script parsing, hidden process exit code'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
