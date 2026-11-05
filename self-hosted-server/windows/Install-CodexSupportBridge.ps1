[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9a-fA-F-]{36}$')]
    [string]$ThreadId,
    [string]$Workspace = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
    [string]$ProjectId = 'ww-control-a3988',
    [string]$ApiKey = 'AIzaSyDqWHdBixVQPt4OiTi50hseInFxPtk0hf0',
    [string]$Collection = 'ahk_clients',
    [string]$SelfHostedBaseUrl = 'http://127.0.0.1:3000',
    [string]$SelfHostedBridgeToken = '',
    [bool]$FirestoreSupportEnabled = $false,
    [ValidateRange(10, 300)]
    [int]$PollSeconds = 15,
    [ValidateRange(30, 3600)]
    [int]$MinimumRequestIntervalSeconds = 300
)

#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
$sourceScript = Join-Path $PSScriptRoot 'CodexSupportBridge.ps1'
$sourceWatchdog = Join-Path $PSScriptRoot 'CodexSupportWatchdog.ps1'
$sourceBootstrap = Join-Path $PSScriptRoot 'CodexSupportBootstrap.ps1'
if (-not (Test-Path -LiteralPath $sourceScript -PathType Leaf)) { throw "缺少橋接主程式：$sourceScript" }
if (-not (Test-Path -LiteralPath $sourceWatchdog -PathType Leaf)) { throw "缺少橋接 watchdog：$sourceWatchdog" }
if (-not (Test-Path -LiteralPath $sourceBootstrap -PathType Leaf)) { throw "缺少橋接 bootstrap：$sourceBootstrap" }
$workspaceFull = [IO.Path]::GetFullPath($Workspace)
if (-not (Test-Path -LiteralPath $workspaceFull -PathType Container)) { throw "工作區不存在：$workspaceFull" }

function Read-EnvValue([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        if ($line -match ('^\s*' + [Regex]::Escape($Name) + '\s*=\s*(.*)$')) {
            $value = $matches[1].Trim()
            if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return $value
        }
    }
    return ''
}

function Resolve-CodexBridgeRuntime([string]$ExistingConfigPath) {
    $runtimePath = ''
    if (Test-Path -LiteralPath $ExistingConfigPath -PathType Leaf) {
        $existingConfig = Get-Content -LiteralPath $ExistingConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $property = $existingConfig.PSObject.Properties['BridgePowerShellPath']
        if ($null -ne $property) { $runtimePath = [string]$property.Value }
    }
    if ([string]::IsNullOrWhiteSpace($runtimePath)) {
        $runtimePath = [string](Get-Command pwsh.exe -CommandType Application -ErrorAction Stop).Source
    }
    if (-not [IO.Path]::IsPathFullyQualified($runtimePath) -or
        [IO.Path]::GetFileName($runtimePath) -ine 'pwsh.exe' -or
        -not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
        throw 'BridgePowerShellPath must point to an existing PowerShell 7 pwsh.exe; no PS5.1 fallback is permitted.'
    }
    $major = @(& $runtimePath -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.Major')
    if ($LASTEXITCODE -ne 0 -or $major.Count -ne 1 -or
        [string]$major[0] -notmatch '^\d+$' -or [int]$major[0] -lt 7) {
        throw 'Codex bridge requires PowerShell 7 or newer.'
    }
    return [IO.Path]::GetFullPath($runtimePath)
}

function Get-ScriptProcesses([string]$ScriptPath, [string]$AlternateScriptPath = '', [switch]$IncludeQueueWorkers) {
    $filePattern = '(?i)(?:^|\s)' + [Regex]::Escape('-File ' + $ScriptPath) + '(?:\s|$)'
    $alternatePattern = if ($AlternateScriptPath) {
        '(?i)(?:^|\s)' + [Regex]::Escape('-File ' + $AlternateScriptPath) + '(?:\s|$)'
    } else { '' }
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            if ($_.Name -notin @('powershell.exe', 'pwsh.exe')) { return $false }
            # WMI 有時保留 -File 路徑的引號，有時會正規化掉。先去除引號再比對完整參數，
            # 避免 watchdog 因誤判「未執行」而不斷啟動短命的重複 bridge。
            $normalized = ([string]$_.CommandLine).Replace('"', '').Replace("'", '')
            if (-not $IncludeQueueWorkers -and $normalized -match '(?i)(?:^|\s)-QueueWorker(?:\s|$)') { return $false }
            return $normalized -match $filePattern -or ($alternatePattern -and $normalized -match $alternatePattern)
        })
}

function Assert-NoCodexQueueWorkers([string[]]$ScriptPaths) {
    foreach ($path in $ScriptPaths) {
        foreach ($process in @(Get-ScriptProcesses $path -IncludeQueueWorkers)) {
            if (([string]$process.CommandLine) -match '(?i)(?:^|\s)-QueueWorker(?:\s|$)') {
                throw 'Codex worker is active; defer bridge installation until the turn finishes.'
            }
        }
    }
}

function Enter-CodexBridgeMaintenance([string[]]$ScriptPaths) {
    $mutex = [Threading.Mutex]::new($false, 'Local\WutheringCodexSupportQueueWorker')
    $owns = $false
    try {
        try { $owns = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owns = $true }
        if (-not $owns) { throw 'Codex worker owns the queue; defer bridge installation.' }
        Assert-NoCodexQueueWorkers $ScriptPaths
        return $mutex
    } catch {
        if ($owns) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
        throw
    }
}

$serverRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($SelfHostedBridgeToken)) {
    $SelfHostedBridgeToken = Read-EnvValue (Join-Path $serverRoot '.env') 'CODEX_BRIDGE_TOKEN'
}
if ([string]::IsNullOrWhiteSpace($SelfHostedBridgeToken)) {
    if (-not $FirestoreSupportEnabled) { throw 'Firestore Codex 已停用；必須先提供中央 CODEX_BRIDGE_TOKEN。' }
    Write-Warning '找不到 CODEX_BRIDGE_TOKEN；本次只啟用公司 Firestore 來源。執行 Install-Server.ps1 後重新安裝即可啟用中央 loopback。'
    $SelfHostedBaseUrl = ''
}

$codexCommand = Get-Command codex.exe -ErrorAction SilentlyContinue
if (-not $codexCommand) {
    $codexCommand = Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin') `
        -Filter codex.exe -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}
if (-not $codexCommand) { throw '找不到 Codex CLI；請先安裝或啟動 Codex 桌面版。' }
$codexPath = if ($codexCommand.PSObject.Properties['Source']) { $codexCommand.Source } else { $codexCommand.FullName }

$installRoot = Join-Path $env:ProgramData 'WutheringAutomation\CodexSupportBridge'
$installedScript = Join-Path $installRoot 'CodexSupportBridge.ps1'
$installedWatchdog = Join-Path $installRoot 'CodexSupportWatchdog.ps1'
$installedBootstrap = Join-Path $installRoot 'CodexSupportBootstrap.ps1'
$configPath = Join-Path $installRoot 'config.json'
$bridgePowerShellPath = Resolve-CodexBridgeRuntime $configPath
$legacyInstallRoot = Join-Path $env:LOCALAPPDATA 'WutheringAutomation\CodexSupportBridge'
$maintenanceMutex = Enter-CodexBridgeMaintenance @($installedScript, (Join-Path $legacyInstallRoot 'CodexSupportBridge.ps1'))
try {
New-Item -ItemType Directory -Path $installRoot -Force | Out-Null
# Codex Desktop runs tools in an AppContainer. LocalAppData can therefore be
# virtualized and invisible to Task Scheduler. ProgramData is shared with the
# scheduled process, but the bridge token must remain private to this user.
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
# PowerShell 7 Set-Acl attempts to write the SACL as well and therefore asks
# for SeSecurityPrivilege even when only the DACL changes. icacls updates only
# the DACL and works for the directory owned by the current interactive user.
$icaclsPath = Join-Path $env:SystemRoot 'System32\icacls.exe'
$userGrant = "*$($currentIdentity.User.Value):(OI)(CI)F"
$systemGrant = '*S-1-5-18:(OI)(CI)F'
& $icaclsPath $installRoot '/inheritance:r' '/grant:r' $userGrant $systemGrant | Out-Null
if ($LASTEXITCODE -ne 0) { throw '無法限制 Codex 橋接目錄 ACL。' }
$existingWatchdogProcesses = @(Get-ScriptProcesses $installedWatchdog $installedBootstrap)
$existingBridgeProcesses = @(Get-ScriptProcesses $installedScript)
$legacyInstallRoot = Join-Path $env:LOCALAPPDATA 'WutheringAutomation\CodexSupportBridge'
if (-not [IO.Path]::GetFullPath($legacyInstallRoot).Equals(
    [IO.Path]::GetFullPath($installRoot),
    [StringComparison]::OrdinalIgnoreCase
)) {
    $existingWatchdogProcesses += @(Get-ScriptProcesses `
        (Join-Path $legacyInstallRoot 'CodexSupportWatchdog.ps1') `
        (Join-Path $legacyInstallRoot 'CodexSupportBootstrap.ps1'))
    $existingBridgeProcesses += @(Get-ScriptProcesses (Join-Path $legacyInstallRoot 'CodexSupportBridge.ps1'))
}
$existingWatchdogProcesses = @($existingWatchdogProcesses | Sort-Object ProcessId -Unique)
$existingBridgeProcesses = @($existingBridgeProcesses | Sort-Object ProcessId -Unique)
foreach ($process in @($existingWatchdogProcesses) + @($existingBridgeProcesses)) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
}
if ($existingWatchdogProcesses.Count + $existingBridgeProcesses.Count -gt 0) { Start-Sleep -Milliseconds 700 }
# 整條啟動鏈使用已驗證的 PS7；保留既有 UTF-8 BOM 檔案格式。
$scriptText = [IO.File]::ReadAllText($sourceScript, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($installedScript, $scriptText, [Text.UTF8Encoding]::new($true))
$watchdogText = [IO.File]::ReadAllText($sourceWatchdog, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($installedWatchdog, $watchdogText, [Text.UTF8Encoding]::new($true))
$bootstrapText = [IO.File]::ReadAllText($sourceBootstrap, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($installedBootstrap, $bootstrapText, [Text.Encoding]::ASCII)

# Preserve idempotency and truthful in-flight status while migrating the old
# LocalAppData runtime. It is deleted only after both new processes are alive.
if (Test-Path -LiteralPath $legacyInstallRoot -PathType Container) {
    foreach ($name in @(
        'state.json', 'state.firestore.json', 'state.selfhost.json',
        'inflight.firestore.json', 'inflight.selfhost.json'
    )) {
        $sourcePath = Join-Path $legacyInstallRoot $name
        $destinationPath = Join-Path $installRoot $name
        if ((Test-Path -LiteralPath $sourcePath -PathType Leaf) -and
            -not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            Copy-Item -LiteralPath $sourcePath -Destination $destinationPath
        }
    }
    foreach ($legacyLog in @(Get-ChildItem -LiteralPath $legacyInstallRoot -Filter '*.log*' -File -ErrorAction SilentlyContinue)) {
        $destinationPath = Join-Path $installRoot $legacyLog.Name
        if (-not (Test-Path -LiteralPath $destinationPath -PathType Leaf)) {
            Copy-Item -LiteralPath $legacyLog.FullName -Destination $destinationPath
        }
    }
}

$dispatcherId = ''
foreach ($candidateConfig in @($configPath, (Join-Path $legacyInstallRoot 'config.json'))) {
    if (-not (Test-Path -LiteralPath $candidateConfig -PathType Leaf)) { continue }
    try {
        $candidate = Get-Content -LiteralPath $candidateConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $candidateIdProperty = $candidate.PSObject.Properties['DispatcherId']
        if ($null -ne $candidateIdProperty -and
            [string]$candidateIdProperty.Value -match '^[A-Za-z0-9._:@-]{8,160}$') {
            $dispatcherId = [string]$candidateIdProperty.Value
            break
        }
    } catch {}
}
if ([string]::IsNullOrWhiteSpace($dispatcherId)) {
    $dispatcherId = 'dispatcher-' + [Guid]::NewGuid().ToString('N')
}

$config = [ordered]@{
    ProjectId = $ProjectId
    ApiKey = $ApiKey
    Collection = $Collection
    DocumentId = '__codex_support'
    ThreadId = $ThreadId.ToLowerInvariant()
    Workspace = $workspaceFull
    CodexPath = [string]$codexPath
    BridgePowerShellPath = $bridgePowerShellPath
    DispatcherId = $dispatcherId
    SelfHostedBaseUrl = $SelfHostedBaseUrl.TrimEnd('/')
    SelfHostedBridgeToken = $SelfHostedBridgeToken
    FirestoreSupportEnabled = $FirestoreSupportEnabled
    PollSeconds = $PollSeconds
    MinimumRequestIntervalSeconds = $MinimumRequestIntervalSeconds
}
[IO.File]::WriteAllText(
    $configPath,
    ($config | ConvertTo-Json -Depth 4),
    [Text.UTF8Encoding]::new($false)
)

Write-Host '正在驗證已啟用的來源與本機 Codex…'
& $bridgePowerShellPath -NoProfile -NonInteractive -File $installedScript -ConfigPath $configPath -ValidateOnly
if ($LASTEXITCODE -ne 0) { throw 'Codex 橋接驗證失敗。' }
& $bridgePowerShellPath -NoProfile -NonInteractive -File $installedBootstrap -ValidateOnly | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Codex bootstrap/watchdog 驗證失敗。' }

$taskName = 'Wuthering Codex Support Bridge'
$oldTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($oldTask) {
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

# 以任務排程器啟動 watchdog，進程由 Task Scheduler 服務建立，不會繼承
# Codex 桌面版的 AppX job。Codex 自動更新強制結束舊版進程時，watchdog 仍可存活並重啟 bridge。
$powershellPath = $bridgePowerShellPath
$currentUser = $currentIdentity.Name
$taskArguments = "-NoProfile -NoLogo -NonInteractive -WindowStyle Hidden -File `"$installedBootstrap`""
$action = New-ScheduledTaskAction -Execute $powershellPath -Argument $taskArguments
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)
$task = New-ScheduledTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
    -Description '常駐監督公司 Firestore 與中央主機 Codex 訊息傳送器'
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

# 舊版使用 Startup 捷徑；不再同時保留，避免登入時啟動兩個 watchdog。
$startupDirectory = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDirectory 'Wuthering Codex Support Bridge.lnk'
if (Test-Path -LiteralPath $shortcutPath -PathType Leaf) { Remove-Item -LiteralPath $shortcutPath -Force }

Start-ScheduledTask -TaskName $taskName
$deadline = [DateTime]::UtcNow.AddSeconds(20)
do {
    Start-Sleep -Milliseconds 500
    $runningWatchdog = @(Get-ScriptProcesses $installedWatchdog $installedBootstrap)
    $runningBridge = @(Get-ScriptProcesses $installedScript)
} while (($runningWatchdog.Count -ne 1 -or $runningBridge.Count -ne 1) -and [DateTime]::UtcNow -lt $deadline)
if ($runningWatchdog.Count -ne 1) { throw "Codex watchdog 常駐程序數量不正確：$($runningWatchdog.Count)" }
if ($runningBridge.Count -ne 1) { throw "Codex 橋接常駐程序數量不正確：$($runningBridge.Count)" }
if (Test-Path -LiteralPath $legacyInstallRoot -PathType Container) {
    Remove-Item -LiteralPath $legacyInstallRoot -Recurse -Force
}

Write-Host ''
Write-Host 'Codex 橋接已安裝。'
Write-Host "狀態：watchdog PID $($runningWatchdog[0].ProcessId)／bridge PID $($runningBridge[0].ProcessId)"
Write-Host "目前 Codex 任務：$ThreadId"
Write-Host "輪詢間隔：$PollSeconds 秒（每天最多約 $([Math]::Ceiling(86400 / $PollSeconds)) 次單文件讀取）"
Write-Host "來源：Firestore=$FirestoreSupportEnabled；中央 loopback=$([bool]$SelfHostedBaseUrl)"
Write-Host "設定與 Log：$installRoot"
Write-Host "開機啟動項目：工作排程器\$taskName"
} finally {
    $maintenanceMutex.ReleaseMutex()
    $maintenanceMutex.Dispose()
}
