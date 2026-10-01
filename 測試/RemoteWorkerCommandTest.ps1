[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$runner = Join-Path $project '.agents\skills\codex-remote-worker\scripts\Invoke-WorkerCommand.ps1'
if (!(Test-Path -LiteralPath $runner)) { throw 'FAIL: remote command result capture runner is missing' }
$testRoot = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\remote-worker\tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testRoot)
$hostName = [Net.Dns]::GetHostName()
$passed = 0
function Assert($condition, [string]$message) { if (!$condition) { throw "FAIL: $message" } }
function Run([string]$id, [string]$command, [string]$hostTarget = $hostName, [int]$timeout = 10) {
    $raw = & $runner -RequestId $id -ExpectedHost $hostTarget -WorkingDirectory $testRoot -CommandText $command -ArtifactsRoot $testRoot -TimeoutSeconds $timeout
    return ($raw | ConvertFrom-Json)
}
# Catches merged streams, text interpolation, Unicode loss and a fake zero exit code.
$command = '[Console]::Out.WriteLine(''中文 $literal''); [Console]::Error.WriteLine(''expected stderr''); exit 7'
$r = Run 'streams' $command
Assert ($r.status -eq 'completed' -and $r.exit_code -eq 7) 'nonzero command exit is preserved'
Assert ($r.stdout -ceq ('中文 $literal' + "`r`n")) 'stdout text is preserved including newline'
Assert ($r.stderr -ceq "expected stderr`r`n") 'stderr is independent including newline'
Assert ($r.command -ceq $command -and $r.hostname -ieq $hostName) 'request and actual host are correlated'
Assert ($r.cwd -ieq $testRoot -and $r.command_sha256 -ceq 'bf49a3cc47becc837739685996f8a0b6f22688314a6ac135b9bc2cea310ae338') 'cwd and independently pinned UTF-8 hash match'
Assert (!$r.output_incomplete -and $r.executed) 'complete execution evidence'
$passed++
# Catches reusing an id and executing the original side effect again.
$r = Run 'streams' '[Console]::Out.WriteLine("MUST NOT RUN")'
Assert ($r.status -eq 'duplicate_request' -and !$r.executed -and $null -eq $r.exit_code) 'duplicate id fails closed'
$passed++
# Catches executing before host validation.
$r = Run 'wrong-host' 'throw "MUST NOT RUN"' 'DEFINITELY-NOT-THIS-HOST'
Assert ($r.status -eq 'host_mismatch' -and !$r.executed -and $null -eq $r.exit_code) 'wrong host stops before command'
Assert (!(Test-Path (Join-Path $testRoot 'wrong-host.request.json'))) 'host mismatch creates no claim'
$passed++
# Catches successful completion being invented for an expired command.
$r = Run 'timeout' '[Console]::Out.WriteLine("before-timeout"); [Console]::Error.WriteLine("timeout-stderr"); Start-Sleep -Seconds 10' $hostName 1
Assert ($r.status -eq 'timed_out' -and $r.timed_out -and $null -eq $r.exit_code) 'timeout is not success'
Assert ($r.duration_ms -lt 9000) 'timeout is bounded'
Assert ($r.stdout -ceq "before-timeout`r`n" -and $r.stderr -ceq "timeout-stderr`r`n" -and !$r.output_incomplete) 'timeout retains available streams'
$passed++
# Catches the runner losing the working directory when it creates a child shell.
$r = Run 'cwd' '(Get-Location).Path'
Assert ($r.exit_code -eq 0 -and $r.stdout.TrimEnd() -ieq $testRoot) 'child executes in requested cwd'
$passed++
# Catches parser errors being swallowed by the capture wrapper.
$r = Run 'parse-error' 'Write-Output )'
Assert ($r.exit_code -ne 0 -and $r.stderr.Length -gt 0 -and $r.status -eq 'completed') 'PowerShell parser failure is surfaced'
$passed++
$record = Get-Content -LiteralPath (Join-Path $testRoot 'streams.result.json') -Raw | ConvertFrom-Json
Assert ($record.exit_code -eq 7 -and $record.command -ceq $command) 'durable receipt survives duplicate attempt'
$passed++
# Catches capture initialization breaking valid using/param syntax in the supplied body.
$r = Run 'using-directive' 'using namespace System.Text; [StringBuilder]::new("using-ok").ToString()'
Assert ($r.exit_code -eq 0 -and $r.stdout.TrimEnd() -ceq 'using-ok') 'using statement keeps first-statement semantics'
$passed++
$r = Run 'param-block' 'param([string]$Value = "param-ok") $Value'
Assert ($r.exit_code -eq 0 -and $r.stdout.TrimEnd() -ceq 'param-ok' -and $r.stderr -eq '') 'param block stays a real param block'
$passed++
# Catches losing all tool-readable evidence if receipt publication fails after execution.
[void][IO.Directory]::CreateDirectory((Join-Path $testRoot 'receipt-failure.result.json'))
$r = Run 'receipt-failure' '[Console]::Out.WriteLine("effect-observed")'
Assert ($r.status -eq 'receipt_write_failed' -and $r.executed -and $r.exit_code -eq 0 -and $r.stdout.TrimEnd() -ceq 'effect-observed') 'receipt IO failure retains execution evidence'
$passed++
# Catches PowerShell treating a Unicode smart apostrophe as a wrapper-string delimiter.
$smartBody = '[Console]::Out.WriteLine("O' + [char]0x2019 + 'Reilly")'
$r = Run 'smart-apostrophe' $smartBody
Assert ($r.exit_code -eq 0 -and $r.stdout -ceq ("O" + [char]0x2019 + "Reilly`r`n") -and $r.stderr -eq '' -and $r.command -ceq $smartBody) 'Unicode smart apostrophe does not alter command parsing'
$passed++
Write-Output "PASS: $passed remote-worker capture cases; artifacts=$testRoot"
exit 0
