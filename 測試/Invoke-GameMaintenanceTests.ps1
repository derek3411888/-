[CmdletBinding()]
param([ValidateSet('Foundation','Native','Notice','Install','Worker','Policy','Adapters','Ocr','Startup','Transport','Ui','Release','All')][string]$Suite = 'All')
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$suiteTests = [ordered]@{
    Foundation=@('TestScriptEncodingTest.ps1','GameMaintenanceRunnerTest.ps1')
    Native=@('NativeMaintenanceTest.ps1','LauncherNativeIntegrationTest.ps1','LauncherNativeEmbeddingTest.ps1',
        'NativePerformanceTelemetryTest.ps1','NativeRuntimeUtilitiesTest.ps1',
        'NativeBootstrapAssetsTest.ps1','NativeRuntimeWiringTest.ps1','NativeMaintenanceIntegrationTest.ps1','LegacyBootstrapSourceTest.ps1','ImagePutLifetimeTest.ps1')
    Notice=@('GameMaintenanceNoticeTest.ps1')
    Install=@('GameInstallDiscoveryTest.ps1')
    Worker=@('GameMaintenanceWorkerTest.ps1','GameMaintenanceWorkerTest.ahk')
    Policy=@('GameMaintenancePolicyTest.ahk','GameMaintenancePersistenceTest.ahk')
    Adapters=@('GameUpdateAdaptersTest.ahk','ManagedProcessGuardTest.ps1')
    Ocr=@('GameUpdateOcrPolicyTest.ahk')
    Startup=@('GameMaintenanceStartupTest.ahk','GameMaintenanceHostTest.ps1','GameMaintenanceHostIntegrationTest.ps1','GameLauncherOnlyHostTest.ps1','LrmcRestartBudgetTest.ps1','LauncherStartupGuardTest.ps1','LauncherStartupNativeTest.ps1','InstallStartupLockTest.ps1','MainInstanceOwnershipTest.ps1','LauncherInstallationRootTest.ps1','LauncherCleanupIdentityTest.ps1','RestartWorkerOwnershipTest.ps1','LauncherNativeHelperDrainTest.ps1')
    Transport=@('GameMaintenanceTransportTest.ahk','GameMaintenancePreviewRefreshTest.ps1','RemoteControlStartupHookTest.ps1','RuntimeSnapshotThrottleTest.ps1')
    Ui=@('GameMaintenanceLocalUiTest.ps1')
    Release=@('GameMaintenancePackageTest.ps1')
}
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot (Split-Path $PSScriptRoot -Parent) -RunName "gm-$Suite"
try {
    $selected = if ($Suite -eq 'All') { @($suiteTests.Keys) } else { @($Suite) }
    $testPaths = @($selected | ForEach-Object { $suiteTests[$_] } | ForEach-Object { Join-Path $PSScriptRoot $_ })
    foreach ($testPath in $testPaths) {
        if (-not (Test-Path -LiteralPath $testPath)) { throw "Suite $Suite is incomplete; missing $testPath" }
    }
    foreach ($testPath in $testPaths) {
        $result = Invoke-GMTestProcess -ScriptPath $testPath -Context $context
        if ($result.Stdout) { Write-Output $result.Stdout.TrimEnd() }
        if ($result.Stderr) { Write-Output $result.Stderr.TrimEnd() }
        if ($result.ExitCode -ne 0) { throw "Test failed ($($result.ExitCode)): $testPath" }
    }
    Write-Output "PASS: $Suite ($($testPaths.Count) test files)"
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
} finally { Complete-ProjectDevelopmentPaths -Context $context }
