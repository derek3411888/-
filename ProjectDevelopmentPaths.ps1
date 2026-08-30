[CmdletBinding()]
param()

function Test-ProjectContainedPath {
    param(
        [Parameter(Mandatory)] [string]$Path,
        [Parameter(Mandatory)] [string]$ProjectRoot
    )

    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    return $fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)
}

function Initialize-ProjectDevelopmentPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$ProjectRoot,
        [string]$RunName = 'powershell'
    )

    $resolvedProjectRoot = [IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\', '/')
    if (-not (Test-Path -LiteralPath $resolvedProjectRoot -PathType Container)) {
        throw "專案根目錄不存在：$resolvedProjectRoot"
    }

    $safeRunName = ($RunName -replace '[^A-Za-z0-9_.-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeRunName)) { $safeRunName = 'powershell' }

    $developmentRoot = Join-Path $resolvedProjectRoot '.dev-runtime'
    $tempRoot = Join-Path $developmentRoot 'temp'
    $runRoot = Join-Path $tempRoot ("{0}-{1}-{2}" -f
        $safeRunName, $PID, [Guid]::NewGuid().ToString('N'))
    $testsRoot = Join-Path $developmentRoot 'tests'
    $npmCacheRoot = Join-Path $developmentRoot 'npm-cache'
    $buildRoot = Join-Path $developmentRoot 'build'
    $cacheRoot = Join-Path $developmentRoot 'cache'
    $nodeCacheRoot = Join-Path $cacheRoot 'node-compile'
    $powershellCacheRoot = Join-Path $cacheRoot 'powershell'
    $pythonCacheRoot = Join-Path $cacheRoot 'python'
    $pipCacheRoot = Join-Path $cacheRoot 'pip'
    $nugetCacheRoot = Join-Path $cacheRoot 'nuget'
    $dotnetHomeRoot = Join-Path $cacheRoot 'dotnet-home'

    $managedPaths = @(
        $developmentRoot, $tempRoot, $runRoot, $testsRoot, $npmCacheRoot,
        $buildRoot, $cacheRoot, $nodeCacheRoot, $powershellCacheRoot,
        $pythonCacheRoot, $pipCacheRoot, $nugetCacheRoot, $dotnetHomeRoot
    )
    foreach ($path in $managedPaths) {
        if (-not (Test-ProjectContainedPath -Path $path -ProjectRoot $resolvedProjectRoot)) {
            throw "開發路徑超出專案根目錄：$path"
        }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }

    $environmentValues = [ordered]@{
        TEMP = $runRoot
        TMP = $runRoot
        TMPDIR = $runRoot
        NPM_CONFIG_CACHE = $npmCacheRoot
        npm_config_update_notifier = 'false'
        XDG_CACHE_HOME = $cacheRoot
        NODE_COMPILE_CACHE = $nodeCacheRoot
        PSModuleAnalysisCachePath = (Join-Path $powershellCacheRoot 'ModuleAnalysisCache')
        PIP_CACHE_DIR = $pipCacheRoot
        PYTHONPYCACHEPREFIX = $pythonCacheRoot
        UV_CACHE_DIR = (Join-Path $cacheRoot 'uv')
        NUGET_PACKAGES = $nugetCacheRoot
        DOTNET_CLI_HOME = $dotnetHomeRoot
    }
    $previousEnvironment = [ordered]@{}
    foreach ($name in $environmentValues.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        [Environment]::SetEnvironmentVariable($name, [string]$environmentValues[$name], 'Process')
    }

    return [pscustomobject]@{
        ProjectRoot = $resolvedProjectRoot
        Root = $developmentRoot
        TempRoot = $tempRoot
        RunRoot = $runRoot
        TestsRoot = $testsRoot
        NpmCacheRoot = $npmCacheRoot
        BuildRoot = $buildRoot
        CacheRoot = $cacheRoot
        PreviousEnvironment = $previousEnvironment
    }
}

function Complete-ProjectDevelopmentPaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [switch]$RemoveRunDirectory
    )

    foreach ($name in $Context.PreviousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable(
            [string]$name, $Context.PreviousEnvironment[$name], 'Process')
    }

    if ($RemoveRunDirectory -and
        (Test-ProjectContainedPath -Path ([string]$Context.RunRoot) -ProjectRoot ([string]$Context.ProjectRoot)) -and
        (Test-Path -LiteralPath ([string]$Context.RunRoot))) {
        Remove-Item -LiteralPath ([string]$Context.RunRoot) -Recurse -Force -ErrorAction SilentlyContinue
    }
}
