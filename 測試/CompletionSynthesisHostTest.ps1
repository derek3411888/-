[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root = Split-Path $PSScriptRoot -Parent
$run = Join-Path $root ('.dev-runtime\diagnostics\game-maintenance\20261023-restart-synthesis\host-durable-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($run)
$context = [pscustomobject]@{ProjectRoot=$root; Root=(Join-Path $root '.dev-runtime'); RunRoot=$run}
$source = [IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
$extracted = ''
foreach ($name in @('RewardMonitorFinishWithSynthesis','RewardMonitorPendingMatchesDisk','CommitRewardMonitorCompleted',
    'ClearCompletedRewardPendingOnFreshStart','CanReplaceCompletedRewardMonitorState','LoadRewardMonitorRuntimeState',
    'SaveRewardMonitorRuntimeState','ClearRewardMonitorRuntimeState','ReadRewardMonitorStateInteger',
    'ReadRewardMonitorStateBool','MarkServerCompletedInCurrentCycle','HandleCycleFinishAndShutdown','IniReadSafe')) {
    $extracted += "`n" + [regex]::Match($source, '(?ms)^'+$name+'\([^\r\n]*\) \{.*?^\}').Value
}
# Replace filesystem write only, retaining real state, load, readback and commit.
$extracted = $extracted -replace '\bIniWrite\b','HostIniWrite'
$hold = [regex]::Match($source,'(?ms)^\s*holdCompletion := .*?REWARD_TASK_ABANDON_WINDOW_SEC\)').Value
Assert-GMTrue ([bool]$hold) 'Missing actual task-abandon completion admission branch'
$extracted += "`nHostHoldCompletion(state) {`n    global REWARD_TASK_ABANDON_NEED_COUNT, REWARD_TASK_ABANDON_WINDOW_SEC`n$hold`n    return holdCompletion`n}`n"
$path = Join-Path $run 'host.ahk'
$header = "#Requires AutoHotkey v2.0`n#Include $root\測試\CompletionSynthesisHostFixtures.ahk`n"
[IO.File]::WriteAllText($path,$header+$extracted,[Text.UTF8Encoding]::new($true))
$result = Invoke-GMTestProcess -ScriptPath $path -Context $context -TimeoutSeconds 25
Write-Output $result.Stdout
Write-Output $result.Stderr
Assert-GMEqual $result.ExitCode 0 'Actual durable completion commit, crash replay and write-failure barriers'
