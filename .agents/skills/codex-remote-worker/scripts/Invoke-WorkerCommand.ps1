#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$')][string]$RequestId,
    [Parameter(Mandatory)][string]$ExpectedHost,
    [Parameter(Mandatory)][string]$WorkingDirectory,
    [Parameter(Mandatory)][AllowEmptyString()][string]$CommandText,
    [Parameter(Mandatory)][string]$ArtifactsRoot,
    [ValidateRange(1,600)][int]$TimeoutSeconds = 30
)
$ErrorActionPreference = 'Stop'
$started = [DateTimeOffset]::Now
$timer = [Diagnostics.Stopwatch]::StartNew()
$sha = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($CommandText))
$receipt = [ordered]@{
    schema_version = 1; request_id = $RequestId; mode = 'command'
    command = $CommandText; command_sha256 = [Convert]::ToHexString($sha).ToLowerInvariant()
    hostname = [Net.Dns]::GetHostName(); cwd = $null; shell = $null
    started_at = $started.ToString('o'); finished_at = $null; duration_ms = 0
    status = 'not_started'; executed = $false; exit_code = $null
    stdout = ''; stderr = ''; capture_mode = 'separate'; capture_encoding = 'utf-8'; output_incomplete = $false
    timed_out = $false; child_pid = $null; artifact_path = $null; error = $null
}
$claimOwned = $false
$child = $null
$resultPath = $null
try {
    if ($receipt.hostname -ine $ExpectedHost) {
        $receipt.status = 'host_mismatch'
        $receipt.error = "Expected host $ExpectedHost; observed $($receipt.hostname)"
    } else {
        if (!(Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { throw 'Working directory is unavailable' }
        $receipt.cwd = (Resolve-Path -LiteralPath $WorkingDirectory).ProviderPath
        # Callers supply their project diagnostics folder, never a system Temp directory.
        $artifactDir = [IO.Path]::GetFullPath($ArtifactsRoot)
        [void][IO.Directory]::CreateDirectory($artifactDir)
        $claimPath = Join-Path $artifactDir ($RequestId + '.request.json')
        $resultPath = Join-Path $artifactDir ($RequestId + '.result.json')
        try {
            $claim = [IO.File]::Open($claimPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $claimOwned = $true
        } catch [IO.IOException] {
            if (!(Test-Path -LiteralPath $claimPath)) { throw }
            $receipt.status = 'duplicate_request'
            $receipt.error = 'Request id was already claimed; inspect its original receipt. Do not re-execute.'
        }
        if ($claimOwned) {
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes(($receipt | ConvertTo-Json -Depth 5))
                $claim.Write($bytes, 0, $bytes.Length)
                $claim.Flush($true)
            } finally { $claim.Dispose() }
            $receipt.shell = Join-Path $PSHOME 'pwsh.exe'
            if (!(Test-Path -LiteralPath $receipt.shell -PathType Leaf)) { throw 'Windows PowerShell 7 executable is unavailable' }
            $info = [Diagnostics.ProcessStartInfo]::new()
            $info.FileName = $receipt.shell
            $info.WorkingDirectory = $receipt.cwd
            $info.UseShellExecute = $false
            $info.CreateNoWindow = $true
            $info.RedirectStandardOutput = $true
            $info.RedirectStandardError = $true
            $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
            $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
            # Parse the unchanged body separately so leading using/param remain valid.
            # Transport the body as data; smart quotes must never become harness syntax.
            $bodyData = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($CommandText))
            $captureCommand = '[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false); & ([scriptblock]::Create([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $bodyData + '''))))'
            foreach ($argument in @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $captureCommand)) {
                [void]$info.ArgumentList.Add($argument)
            }
            $child = [Diagnostics.Process]::new()
            $child.StartInfo = $info
            if (!$child.Start()) { throw 'Child PowerShell did not start' }
            $receipt.executed = $true
            $receipt.child_pid = $child.Id
            $outTask = $child.StandardOutput.ReadToEndAsync()
            $errTask = $child.StandardError.ReadToEndAsync()
            if (!$child.WaitForExit($TimeoutSeconds * 1000)) {
                $receipt.status = 'timed_out'
                $receipt.timed_out = $true
                # Only this retained command-process handle and its children are owned here.
                $child.Kill($true)
                [void]$child.WaitForExit(2000)
            } else {
                $receipt.status = 'completed'
                $receipt.exit_code = $child.ExitCode
            }
            $outDone = $outTask.Wait(1000)
            $errDone = $errTask.Wait(1000)
            $receipt.output_incomplete = !($outDone -and $errDone)
            if ($outDone) { $receipt.stdout = $outTask.Result }
            if ($errDone) { $receipt.stderr = $errTask.Result }
        }
    }
} catch {
    $receipt.status = 'capture_error'
    $receipt.error = $_.Exception.Message
    $receipt.output_incomplete = $receipt.executed
    # A wrapper failure after execution is not proof the requested side effects did not happen.
} finally {
    if ($child) { $child.Dispose() }
    $timer.Stop()
    $receipt.finished_at = [DateTimeOffset]::Now.ToString('o')
    $receipt.duration_ms = $timer.ElapsedMilliseconds
}
if ($claimOwned) {
    $receipt.artifact_path = $resultPath
    $json = $receipt | ConvertTo-Json -Depth 5
    $staged = $resultPath + '.pending'
    try {
        [IO.File]::WriteAllText($staged, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($staged, $resultPath)
    } catch {
        $receipt.status = 'receipt_write_failed'
        $receipt.error = $_.Exception.Message
        $receipt.artifact_path = $null
    }
}
$receipt | ConvertTo-Json -Depth 5
