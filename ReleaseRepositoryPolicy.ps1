function Test-ReleaseLocalOnlyPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $normalized = $Path.Replace('\', '/')
    $exactPaths = @(
        '開發日記.md', 'AGENTS.md', 'PROJECT_AI_HANDOFF.md', 'DEVELOPMENT_ARTIFACTS.md',
        'docs/game-maintenance-acceptance.md', 'docs/game-maintenance-final-review.md',
        '測試/實機伺服器切換50次驗證報告.md', '測試/RemoteWorkerCommandTest.ps1',
        '測試/主畫面模板比對/roi_debug.png', '測試/主畫面模板比對/test_log.txt'
    )
    if ($normalized -in $exactPaths) { return $true }
    return $normalized -match '^(?:\.agents|\.vscode|\.superpowers|\.dev-runtime|docs/superpowers|docs/archive)/'
}

function Assert-ReleaseRepositoryPrivacy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ProjectRoot,
        [string]$Revision = ''
    )

    # Read the real index/tree, not just changed paths: ignored files already
    # tracked (or added with -f) must not silently survive a release.
    $root = @(& git -C $ProjectRoot rev-parse --show-toplevel 2>&1)
    if ($LASTEXITCODE -ne 0 -or $root.Count -ne 1) { throw 'Cannot resolve release repository root.' }
    $arguments = @('-C', [string]$root[0], '-c', 'core.quotepath=false')
    if ([string]::IsNullOrWhiteSpace($Revision)) {
        $arguments += @('ls-files', '--cached', '-z')
    } else {
        $arguments += @('ls-tree', '-r', '--name-only', '-z', $Revision, '--')
    }
    $output = @(& git @arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect release index/tree; publication is blocked.' }
    $paths = @(($output -join "`n") -split "`0" | Where-Object { $_.Length -gt 0 })
    $privatePaths = @($paths | Where-Object { Test-ReleaseLocalOnlyPath -Path $_ })
    if ($privatePaths.Count -gt 0) {
        throw ("Release contains local-only files. Keep local copies and remove Git tracking:`n - " + ($privatePaths -join "`n - "))
    }
}
