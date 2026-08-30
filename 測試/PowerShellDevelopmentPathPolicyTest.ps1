[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$pathHelper = Join-Path $projectRoot 'ProjectDevelopmentPaths.ps1'
$policyTestPath = [IO.Path]::GetFullPath($MyInvocation.MyCommand.Path)
. $pathHelper

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Get-ProjectPowerShellSourceFiles([string]$Root) {
    $excludedDirectoryNames = @('.git', '.dev-runtime', '.codex_tmp', '.venv', 'node_modules')
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue([IO.Path]::GetFullPath($Root))
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        foreach ($file in Get-ChildItem -LiteralPath $directory -File -ErrorAction Stop) {
            if ($file.Extension -in @('.ps1', '.psm1', '.psd1')) { Write-Output $file }
        }
        foreach ($child in Get-ChildItem -LiteralPath $directory -Directory -ErrorAction Stop) {
            if ($child.Name -notin $excludedDirectoryNames) { $pending.Enqueue($child.FullName) }
        }
    }
}

$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $projectRoot -RunName 'path-policy-test'
$succeeded = $false
try {
    foreach ($path in @(
        $context.Root, $context.TempRoot, $context.RunRoot, $context.TestsRoot,
        $context.NpmCacheRoot, $context.BuildRoot, $context.CacheRoot
    )) {
        Assert-True (Test-ProjectContainedPath -Path $path -ProjectRoot $projectRoot) `
            "開發路徑不在專案內：$path"
        Assert-True (Test-Path -LiteralPath $path -PathType Container) `
            "開發路徑未建立：$path"
    }

    foreach ($name in @('TEMP', 'TMP', 'TMPDIR', 'NPM_CONFIG_CACHE',
        'XDG_CACHE_HOME', 'NODE_COMPILE_CACHE', 'PSModuleAnalysisCachePath',
        'PIP_CACHE_DIR', 'PYTHONPYCACHEPREFIX', 'UV_CACHE_DIR', 'NUGET_PACKAGES',
        'DOTNET_CLI_HOME')) {
        $value = [Environment]::GetEnvironmentVariable($name, 'Process')
        Assert-True (-not [string]::IsNullOrWhiteSpace($value)) "開發環境變數未設定：$name"
        Assert-True (Test-ProjectContainedPath -Path $value -ProjectRoot $projectRoot) `
            "開發環境變數超出專案：$name=$value"
    }

    $sourceFiles = @(Get-ProjectPowerShellSourceFiles $projectRoot)
    $prohibitedPatterns = [ordered]@{
        'Windows Temp API' = '(?i)(?:\[IO\.Path\]|\[System\.IO\.Path\])::GetTempPath\s*\('
        '隨機外部暫存檔 API' = '(?i)\bNew-TemporaryFile\b|(?:\[IO\.Path\]|\[System\.IO\.Path\])::GetRandomFileName\s*\('
        '直接使用 TEMP/TMP' = '(?i)\$env:(?:TEMP|TMP)(?![A-Za-z0-9_])'
        '舊 Codex 開發暫存' = '(?i)\.codex_tmp'
    }
    $violations = [Collections.Generic.List[string]]::new()
    foreach ($file in $sourceFiles) {
        if ($file.FullName -eq $pathHelper -or $file.FullName -eq $policyTestPath) { continue }
        $relative = $file.FullName.Substring($projectRoot.Length).TrimStart('\', '/')
        $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
        foreach ($entry in $prohibitedPatterns.GetEnumerator()) {
            if ($text -match $entry.Value) { $violations.Add("$relative：$($entry.Key)") }
        }
    }
    Assert-True ($violations.Count -eq 0) `
        ("PowerShell 開發路徑政策失敗：`n - " + ($violations -join "`n - "))

    foreach ($scriptName in @('打包更新.ps1', '完整發布更新.ps1')) {
        $text = Get-Content -LiteralPath (Join-Path $projectRoot $scriptName) -Raw -Encoding UTF8
        Assert-True ($text -match "ProjectDevelopmentPaths\.ps1") "$scriptName 未載入專案開發路徑政策。"
        Assert-True ($text -match "Initialize-ProjectDevelopmentPaths") "$scriptName 未初始化專案開發路徑。"
        Assert-True ($text -match "Complete-ProjectDevelopmentPaths") "$scriptName 未還原開發環境。"
    }

    $telemetryWorkerText = Get-Content -LiteralPath `
        (Join-Path $projectRoot 'payload\PerformanceTelemetryWorker.ps1') -Raw -Encoding UTF8
    Assert-True ($telemetryWorkerText -notmatch '\.ToArray\s*\(') `
        'PerformanceTelemetryWorker 不得再直接呼叫 ToArray。'
    Assert-True ($telemetryWorkerText -match 'CollectionRegressionTest') `
        'PerformanceTelemetryWorker 缺少 singleton 集合回歸入口。'

    $batchText = Get-Content -LiteralPath (Join-Path $projectRoot '編譯打包.bat') -Raw -Encoding UTF8
    Assert-True ($batchText -match '(?i)set\s+"TEMP=%DEV_RUN_ROOT%"') '批次入口未將 TEMP 指向專案。'
    Assert-True ($batchText -match '(?i)set\s+"TMP=%DEV_RUN_ROOT%"') '批次入口未將 TMP 指向專案。'
    Assert-True ($batchText -match '(?i)set\s+"NPM_CONFIG_CACHE=%DEV_RUNTIME_ROOT%\\npm-cache"') `
        '批次入口未將 npm cache 指向專案。'

    $gitignoreText = Get-Content -LiteralPath (Join-Path $projectRoot '.gitignore') -Raw -Encoding UTF8
    Assert-True ($gitignoreText -match '(?m)^\.dev-runtime/$') '.gitignore 未排除 .dev-runtime。'

    Write-Host 'PowerShell 開發路徑政策測試通過：所有暫存、測試、build 與工具快取均限制在 .dev-runtime。'
    $succeeded = $true
} finally {
    Complete-ProjectDevelopmentPaths -Context $context -RemoveRunDirectory:$succeeded
}
