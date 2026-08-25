[CmdletBinding()]
param(
    [ValidateSet('Status','OpenLogs','ImportFirestore','RestoreTest','Shadow','Primary','Fallback','Stop','Start')]
    [string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
$serverRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$envPath = Join-Path $serverRoot '.env'
if (-not (Test-Path -LiteralPath $envPath)) { throw '尚未執行 Install-Server.ps1。' }
Set-Location -LiteralPath $serverRoot
$compose = @('compose', '--env-file', $envPath, '-f', 'compose.yml')

switch ($Action) {
    'Status' { & docker @compose ps; & docker @compose exec -T api node src/cli.js status }
    'OpenLogs' { & docker @compose logs --tail 300 }
    'ImportFirestore' { & docker @compose exec -T api node src/cli.js import-firestore }
    'RestoreTest' { & docker @compose exec -T backup /usr/local/bin/restore-test.sh }
    'Shadow' { & docker @compose exec -T api node src/cli.js force-mode shadow }
    'Primary' { & docker @compose exec -T api node src/cli.js force-mode primary }
    'Fallback' { & docker @compose exec -T api node src/cli.js force-mode fallback }
    'Stop' { & docker @compose stop }
    'Start' { & docker @compose up -d }
}
if ($LASTEXITCODE -ne 0) { throw "伺服器管理操作失敗：$Action" }
