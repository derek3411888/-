[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$runtime = Join-Path $projectRoot 'AutoHotkey64.exe'
$testScript = Join-Path $PSScriptRoot 'LauncherHttpTimeoutIntegrationTest.ahk'
$runRoot = Join-Path $projectRoot ('.dev-runtime\diagnostics\game-maintenance\launcher-http-timeout-' + [Guid]::NewGuid().ToString('N'))
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
        '/ErrorStdOut', $testScript, "http://127.0.0.1:$port/stall", $destination
    ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    if (-not $acceptTask.Wait(3000)) {
        throw '測試 HTTP 請求沒有連到本機停滯伺服器。'
    }
    $client = $acceptTask.Result

    if (-not $process.WaitForExit(7000)) {
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch {}
        throw 'Launcher HTTP 逾時整合測試超過 7 秒，請求仍被卡住。'
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
