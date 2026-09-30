[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $projectRoot 'AutoHotkey64.exe'
$testScript = Join-Path $PSScriptRoot 'LauncherHttpTotalTimeoutIntegrationTest.ahk'
$runRoot = Join-Path $projectRoot ('.dev-runtime\diagnostics\game-maintenance\launcher-http-total-timeout-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $runRoot | Out-Null
$stdoutPath = Join-Path $runRoot 'stdout.txt'
$stderrPath = Join-Path $runRoot 'stderr.txt'
$destination = Join-Path $runRoot 'must-not-exist.bin'

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$client = $null
$process = $null
try {
    $listener.Start()
    $port = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $acceptTask = $listener.AcceptTcpClientAsync()
    $process = Start-Process -FilePath $runtime -ArgumentList @(
        '/ErrorStdOut', $testScript, "http://127.0.0.1:$port/trickle", $destination
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
    [void]$process.Handle

    if (-not $acceptTask.Wait(3000)) {
        throw 'Test HTTP request did not reach the local trickle server.'
    }
    $client = $acceptTask.Result
    $stream = $client.GetStream()
    $header = [Text.Encoding]::ASCII.GetBytes(
        "HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: 1048576`r`nConnection: close`r`n`r`n")
    $stream.Write($header, 0, $header.Length)
    $stream.Flush()

    # 每 100ms 送一個 byte；沒有 hard total deadline 的同步請求會一直等，
    # 因為每次 activity 都早於 600ms receive timeout。
    $oneByte = [byte[]](65)
    for ($i = 0; $i -lt 50 -and -not $process.HasExited; $i++) {
        try {
            $stream.Write($oneByte, 0, 1)
            $stream.Flush()
        } catch { break }
        Start-Sleep -Milliseconds 100
    }

    if (-not $process.WaitForExit(5000)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch {}
        throw 'Launcher HTTP hard total-timeout test exceeded 5 seconds.'
    }
    $process.WaitForExit()
    $stdout = if (Test-Path -LiteralPath $stdoutPath) {
        Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8
    } else { '' }
    $stderr = if (Test-Path -LiteralPath $stderrPath) {
        Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8
    } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Host $stdout.Trim() }
    if ($process.ExitCode -ne 0) {
        throw ([string]::Concat($stderr, $stdout).Trim())
    }
} finally {
    if ($null -ne $client) { $client.Dispose() }
    $listener.Stop()
}
