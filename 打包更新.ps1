[CmdletBinding()]
param(
    [string]$PayloadVersion = '4.81',
    [string]$LauncherVersion = '4.92',
    [string]$ServerVersion = '1.0.41'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $projectRoot
. (Join-Path $projectRoot 'ProjectDevelopmentPaths.ps1')
$developmentPaths = Initialize-ProjectDevelopmentPaths -ProjectRoot $projectRoot -RunName 'package'
$developmentSucceeded = $false

function Assert-ExitCode([string]$Task) {
    if ($LASTEXITCODE -ne 0) { throw "$Task 失敗，exit=$LASTEXITCODE" }
}

function Wait-HiddenProcess([Diagnostics.Process]$Process, [string]$Task,
    [int]$TimeoutSeconds) {
    if ($null -eq $Process) { throw "$Task 未能啟動程序。" }
    if (-not $Process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)) {
        # 只終止這次驗證建立的精確 PID，不用名稱掃描，
        # 避免影響正式運行中的 AutoHotkey 或其他測試。
        try { Stop-Process -Id $Process.Id -Force -ErrorAction Stop } catch {}
        try { $Process.WaitForExit() } catch {}
        throw "$Task 超過 $TimeoutSeconds 秒，已關閉該無視窗測試程序。"
    }
    # 等待 stdout/stderr 非同步重定向完全排空。
    $Process.WaitForExit()
    return $Process.ExitCode
}

function Invoke-AhkValidate([string]$RuntimePath, [string]$ScriptPath, [string]$Task) {
    # AutoHotkey 是 GUI 子系統程式；直接用 & 執行時 Windows PowerShell 不一定
    # 會可靠等待或填入 LASTEXITCODE。Start-Process -Wait 才能取得真正驗證結果。
    $captureRoot = Join-Path $script:developmentPaths.RunRoot ("ahk-validate-" + [Guid]::NewGuid().ToString('N'))
    $stdoutPath = "$captureRoot.out.txt"
    $stderrPath = "$captureRoot.err.txt"
    try {
        $process = Start-Process -FilePath $RuntimePath -ArgumentList @(
            '/ErrorStdOut', '/Validate', $ScriptPath
        ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $exitCode = Wait-HiddenProcess $process $Task 45
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }
        if ($exitCode -ne 0) {
            $details = [string]::Concat($stderr, $stdout).Trim()
            throw "$Task 失敗，exit=$exitCode：$details"
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-AhkCompile([string]$CompilerPath, [string]$SourcePath,
    [string]$OutputPath, [string]$BasePath, [string]$Task) {
    $process = Start-Process -FilePath $CompilerPath -ArgumentList @(
        '/in', $SourcePath, '/out', $OutputPath, '/base', $BasePath, '/silent', 'verbose'
    ) -WindowStyle Hidden -PassThru
    $exitCode = Wait-HiddenProcess $process $Task 180
    if ($exitCode -ne 0) { throw "$Task 失敗，exit=$exitCode" }
    if (-not (Test-Path -LiteralPath $OutputPath)) { throw "$Task 未產生輸出檔：$OutputPath" }
    if ((Get-Item -LiteralPath $OutputPath).Length -le 0) { throw "$Task 產生空白輸出檔：$OutputPath" }
}

function Invoke-AhkTest([string]$RuntimePath, [string]$ScriptPath, [string]$Task) {
    # AHK 是 GUI 子系統，沒有重導向時 FileAppend("*"/"**") 可能取得無效控制碼
    # 而跳出錯誤視窗。每次測試提供獨立檔案控制碼，並把結果讀回發布紀錄。
    $captureRoot = Join-Path $script:developmentPaths.RunRoot ("ahk-test-" + [Guid]::NewGuid().ToString('N'))
    $stdoutPath = "$captureRoot.out.txt"
    $stderrPath = "$captureRoot.err.txt"
    try {
        $process = Start-Process -FilePath $RuntimePath -ArgumentList @(
            '/ErrorStdOut', $ScriptPath
        ) -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath
        $exitCode = Wait-HiddenProcess $process $Task 120
        $stdout = if (Test-Path -LiteralPath $stdoutPath) { Get-Content -LiteralPath $stdoutPath -Raw -Encoding UTF8 } else { '' }
        $stderr = if (Test-Path -LiteralPath $stderrPath) { Get-Content -LiteralPath $stderrPath -Raw -Encoding UTF8 } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($stdout)) { Write-Host $stdout.Trim() }
        if ($exitCode -ne 0) {
            $details = [string]::Concat($stderr, $stdout).Trim()
            throw "$Task 失敗，exit=$exitCode：$details"
        }
    } finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Find-AhkCompiler {
    $candidates = @(
        (Join-Path $env:ProgramFiles 'AutoHotkey\Compiler\Ahk2Exe.exe'),
        'C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe',
        (Join-Path $projectRoot 'Ahk2Exe.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    throw '找不到 AutoHotkey v2 Ahk2Exe.exe。'
}

function New-FilteredZip([string]$SourceRoot, [string]$TargetPath, [string[]]$ExcludedParts) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $source = [IO.Path]::GetFullPath($SourceRoot)
    $target = [IO.Path]::GetFullPath($TargetPath)
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
    $archive = [IO.Compression.ZipFile]::Open($target, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File | Sort-Object FullName) {
            $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/').Replace('\', '/')
            $excluded = $false
            foreach ($part in $ExcludedParts) {
                if ($relative -like $part) { $excluded = $true; break }
            }
            if ($excluded) { continue }
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $file.FullName, $relative, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
}

function Assert-ZipContains([string]$ArchivePath, [string[]]$RequiredEntries) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead((Resolve-Path -LiteralPath $ArchivePath))
    try {
        $names = @($archive.Entries | ForEach-Object { $_.FullName.Replace('\', '/') })
        foreach ($required in $RequiredEntries) {
            if ($required -notin $names) { throw "$ArchivePath 缺少必要檔案：$required" }
        }
    } finally {
        $archive.Dispose()
    }
}

function Get-WebAssetHash([string]$Root) {
    $lines = foreach ($name in @('app.js', 'index.html', 'styles.css') | Sort-Object) {
        $path = Join-Path $Root "public\$name"
        if (-not (Test-Path -LiteralPath $path)) { throw "缺少網站檔案：$path" }
        "${name}:$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)"
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '') } finally { $sha.Dispose() }
}

try {
$compiler = Find-AhkCompiler
$runtime = Join-Path $projectRoot 'AutoHotkey64.exe'
$payloadRuntime = Join-Path $projectRoot 'payload\AutoHotkey64.exe'
if (-not (Test-Path -LiteralPath $runtime) -or -not (Test-Path -LiteralPath $payloadRuntime)) {
    throw '找不到 AutoHotkey64.exe。'
}

$launcherSource = Get-Content -LiteralPath '打包啟動器.ahk' -Raw -Encoding UTF8
$payloadSource = Get-Content -LiteralPath 'payload\全自動.ahk' -Raw -Encoding UTF8
$runtimeSources = @(
    '打包啟動器.ahk', 'LauncherProcessCleanupPolicy.ahk',
    'payload\全自動.ahk', 'payload\開啟LRMC.ahk',
    'payload\自動開啟OKWW.ahk', 'payload\聲骸合成.ahk',
    'payload\RecordingFinalizeWorker.ahk', 'payload\RemoteControlFirestore.ahk'
)
foreach ($runtimeSourcePath in $runtimeSources) {
    $runtimeText = Get-Content -LiteralPath $runtimeSourcePath -Raw -Encoding UTF8
    if ($runtimeText -match 'A_Temp\s+"\\') {
        throw "執行路徑政策失敗：$runtimeSourcePath 仍會直接在 Windows Temp 產生檔案。"
    }
    if ($runtimeSourcePath -ne '打包啟動器.ahk' -and
        $runtimeText -match 'A_ScriptDir\s*"[^"\r\n]*_fallback\.log') {
        throw "執行路徑政策失敗：$runtimeSourcePath 仍會把 fallback Log 寫在 payload。"
    }
}
if ($launcherSource -notmatch ('PACK_LAUNCHER_BUILD_VERSION\s*:=\s*"' + [regex]::Escape($LauncherVersion) + '"')) {
    throw "打包啟動器.ahk 版本不是 $LauncherVersion"
}
if ($payloadSource -notmatch ('PAYLOAD_BOOTSTRAP_LAUNCHER_VERSION\s*:=\s*"' + [regex]::Escape($LauncherVersion) + '"')) {
    throw "payload 啟動器相容版本不是 $LauncherVersion"
}
$package = Get-Content -LiteralPath 'self-hosted-server\package.json' -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$package.version -ne $ServerVersion) { throw "server package 版本不是 $ServerVersion" }

Write-Host '執行語法與單元測試…'
& (Join-Path $projectRoot '測試\PowerShellDevelopmentPathPolicyTest.ps1')
Invoke-AhkValidate $payloadRuntime '測試\AhkGeneratedPathPolicyTest.ahk' 'AHK 產生檔案路徑政策測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\AhkGeneratedPathPolicyTest.ahk' 'AHK 產生檔案路徑政策回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\PerformanceTelemetryWatchdogTest.ahk' '效能採集 watchdog 語法 validate'
Invoke-AhkTest $payloadRuntime '測試\PerformanceTelemetryWatchdogTest.ahk' '效能採集 watchdog 回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\LauncherProcessCleanupPolicyTest.ahk' 'Launcher 程序清理安全策略語法 validate'
Invoke-AhkTest $payloadRuntime '測試\LauncherProcessCleanupPolicyTest.ahk' 'Launcher 程序清理安全策略回歸測試'
Invoke-AhkValidate $payloadRuntime 'payload\全自動.ahk' 'Payload AHK validate'
Invoke-AhkValidate $payloadRuntime '測試\RuntimeFilePaths測試.ahk' '程式根目錄輸出路徑測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\RuntimeFilePaths測試.ahk' '程式根目錄輸出路徑回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\ScreenRecordingEncoderPolicyTest.ahk' '顯卡錄影編碼策略測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\ScreenRecordingEncoderPolicyTest.ahk' '顯卡錄影編碼策略回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\InteractiveDesktopGuardTest.ahk' '鎖定畫面守門測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\InteractiveDesktopGuardTest.ahk' '鎖定畫面守門回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\SelfHealingPolicyTest.ahk' '自動修復策略測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\SelfHealingPolicyTest.ahk' '自動修復策略回歸測試'
Invoke-AhkValidate $payloadRuntime 'payload\自動開啟OKWW.ahk' 'OKWW manager AHK validate'
Invoke-AhkValidate $payloadRuntime '測試\OKWW自動戰鬥OCR判斷測試.ahk' 'OKWW OCR 回歸測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\OKWW自動戰鬥OCR判斷測試.ahk' 'OKWW OCR 回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\伺服器名稱與切服判斷測試.ahk' '伺服器名稱回歸測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\伺服器名稱與切服判斷測試.ahk' '伺服器名稱與切服回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\伺服器登入標籤OCR影像測試.ahk' '伺服器登入標籤 OCR 實機影像測試語法 validate'
Invoke-AhkValidate $payloadRuntime '測試\實機伺服器切換壓力測試.ahk' '伺服器切換實機壓力測試語法 validate'
Invoke-AhkValidate $payloadRuntime 'payload\RecordingFinalizeWorker.ahk' '錄影 worker AHK validate'
Invoke-AhkValidate $payloadRuntime '測試\SelfHostLiveLoopbackTest.ahk' '直播 loopback 測試語法 validate'
Invoke-AhkValidate $payloadRuntime '測試\SelfHostLiveAutomaticFallbackTest.ahk' '直播自動回退測試語法 validate'
Invoke-AhkValidate $payloadRuntime '測試\SelfHostLiveCandidatesTest.ahk' '直播路由候選測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\SelfHostLiveCandidatesTest.ahk' '直播路由候選回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\SelfHostFreshDeviceDefaultTest.ahk' '外網新裝置預設連線測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\SelfHostFreshDeviceDefaultTest.ahk' '外網新裝置預設連線回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\SelfHostCredentialReuseTest.ahk' '自架既有裝置憑證測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\SelfHostCredentialReuseTest.ahk' '自架既有裝置憑證回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\SelfHostBufferRegressionTest.ahk' '自架 Buffer 測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\SelfHostBufferRegressionTest.ahk' '自架 Buffer 回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\SupportLogContextTest.ahk' '裝置 Log 摘要測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\SupportLogContextTest.ahk' '裝置 Log 摘要與敏感字串遮蔽測試'
Invoke-AhkValidate $runtime '打包啟動器.ahk' 'Launcher AHK validate'
foreach ($payloadUtilityScript in @(
    'payload\SelfHostMediaUpload.ps1',
    'payload\PerformanceTelemetryWorker.ps1'
)) {
    $utilityTokens = $null
    $utilityParseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $projectRoot $payloadUtilityScript),
        [ref]$utilityTokens, [ref]$utilityParseErrors)
    if ($utilityParseErrors.Count -gt 0) {
        throw "Payload PowerShell 語法錯誤 ($payloadUtilityScript)：$($utilityParseErrors[0].Message)"
    }
}
$telemetryRegressionRoot = Join-Path $developmentPaths.RunRoot 'performance-telemetry-collection-test'
$telemetryRegressionOutput = @(& (Join-Path $projectRoot 'payload\PerformanceTelemetryWorker.ps1') `
    -OutputRoot $telemetryRegressionRoot -ParentPid $PID -CollectionRegressionTest)
$telemetryRegression = ($telemetryRegressionOutput -join "`n") | ConvertFrom-Json
if (-not [bool]$telemetryRegression.Ok -or
    [int]$telemetryRegression.EmptyCount -ne 0 -or
    [int]$telemetryRegression.SingletonDoubleCount -ne 1 -or
    [int]$telemetryRegression.SingletonHistoryCount -ne 1 -or
    -not [bool]$telemetryRegression.SingletonMessageJoined) {
    throw '效能採集集合回歸測試失敗。'
}
foreach ($bridgeScript in @(
    'self-hosted-server\Install-Server.ps1',
    'self-hosted-server\Update-Server.ps1',
    'self-hosted-server\windows\CodexSupportBridge.ps1',
    'self-hosted-server\windows\CodexSupportBootstrap.ps1',
    'self-hosted-server\windows\CodexSupportWatchdog.ps1',
    'self-hosted-server\windows\Install-CodexSupportBridge.ps1',
    'self-hosted-server\windows\Uninstall-CodexSupportBridge.ps1'
)) {
    $bridgeTokens = $null
    $bridgeParseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $projectRoot $bridgeScript),
        [ref]$bridgeTokens, [ref]$bridgeParseErrors)
    if ($bridgeParseErrors.Count -gt 0) {
        throw "Codex 橋接 PowerShell 語法錯誤 ($bridgeScript)：$($bridgeParseErrors[0].Message)"
    }
}
Add-Type -AssemblyName System.Security
if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
    throw '目前 PowerShell 無法載入 DPAPI ProtectedData 型別。'
}
Push-Location -LiteralPath (Join-Path $projectRoot 'self-hosted-server')
try {
    & npm.cmd run check
    Assert-ExitCode 'Server 靜態檢查'
    & npm.cmd test
    Assert-ExitCode 'Server 單元測試'
} finally {
    Pop-Location
}
& node.exe --check 'remote-control-web\app.js'
Assert-ExitCode '舊控制台靜態檢查'

Write-Host '編譯 Payload EXE…'
$payloadTemp = Join-Path $projectRoot 'payload\全自動鋤地.new.exe'
if (Test-Path -LiteralPath $payloadTemp) { Remove-Item -LiteralPath $payloadTemp -Force }
Invoke-AhkCompile $compiler 'payload\全自動.ahk' $payloadTemp $payloadRuntime 'Payload 編譯'
Move-Item -LiteralPath $payloadTemp -Destination 'payload\全自動鋤地.exe' -Force

Write-Host '建立 payload.zip…'
New-FilteredZip 'payload' 'payload.zip' @(
    '*.log', 'temp*.png', 'ue4crash*.png', 'menu*.png', '*.new', '*.partial'
)
Assert-ZipContains 'payload.zip' @(
    '全自動.ahk', '全自動鋤地.exe', 'RemoteControlFirestore.ahk',
    'RemoteControlSelfHost.ahk', 'InteractiveDesktopGuard.ahk',
    'ScreenRecordingEncoderPolicy.ahk', 'PerformanceTelemetry.ahk', 'SupportLogContext.ahk',
    'PerformanceTelemetryWorker.ps1', 'tools/PresentMon/LICENSE.txt',
    'SelfHealingPolicy.ahk', 'SelfHostMediaUpload.ps1'
)

Write-Host '編譯內嵌最新版 Payload 的 Launcher EXE…'
$launcherTemp = Join-Path $projectRoot '全自動鋤地.new.exe'
if (Test-Path -LiteralPath $launcherTemp) { Remove-Item -LiteralPath $launcherTemp -Force }
Invoke-AhkCompile $compiler '打包啟動器.ahk' $launcherTemp $runtime 'Launcher 編譯'
Move-Item -LiteralPath $launcherTemp -Destination '全自動鋤地.exe' -Force

Write-Host '建立同版 self-hosted-server.zip…'
New-FilteredZip 'self-hosted-server' 'self-hosted-server.zip' @(
    'node_modules/*', '.update-work/*', '.env', '*.log', '*.partial'
)
Assert-ZipContains 'self-hosted-server.zip' @(
    '.npmrc', 'package.json', 'compose.yml', 'src/app.js', 'src/media.js',
    'public/index.html', 'public/app.js', 'public/styles.css',
    'migrations/004_media_auto_repair.sql', 'migrations/005_performance_telemetry.sql',
    'migrations/006_codex_support_queue.sql', 'migrations/007_effective_settings_revision.sql',
    'src/performance.js', 'src/settings.js',
    'src/codex-support.js', 'src/codex-support-queue.js', 'Update-Server.ps1',
    'test/dev-runtime.js', 'test/development-paths.test.js', 'test/run-tests.mjs',
    'test/integration-smoke.mjs', 'test/media-stream.test.js',
    'test/company-performance-web.test.js',
    'windows/CodexSupportBridge.ps1', 'windows/CodexSupportWatchdog.ps1', 'windows/CodexSupportBootstrap.ps1', 'windows/Install-CodexSupportBridge.ps1',
    'windows/Uninstall-CodexSupportBridge.ps1'
)

$payloadHash = (Get-FileHash -LiteralPath 'payload.zip' -Algorithm SHA256).Hash
$launcherHash = (Get-FileHash -LiteralPath '全自動鋤地.exe' -Algorithm SHA256).Hash
$serverHash = (Get-FileHash -LiteralPath 'self-hosted-server.zip' -Algorithm SHA256).Hash
$webHash = Get-WebAssetHash 'self-hosted-server'
$releaseId = "p$PayloadVersion-l$LauncherVersion-s$ServerVersion-$($payloadHash.Substring(0,8))-$($launcherHash.Substring(0,8))-$($serverHash.Substring(0,8))-$($webHash.Substring(0,8))"
$manifest = [ordered]@{
    release_id = $releaseId
    version = $PayloadVersion
    payload_url = "https://raw.githubusercontent.com/derek3411888/-/main/payload.zip?release=$releaseId"
    payload_sha256 = $payloadHash
    launcher_version = $LauncherVersion
    launcher_url = "https://raw.githubusercontent.com/derek3411888/-/main/%E5%85%A8%E8%87%AA%E5%8B%95%E9%8B%A4%E5%9C%B0.exe?release=$releaseId"
    launcher_sha256 = $launcherHash
    server_version = $ServerVersion
    server_bundle_url = "https://raw.githubusercontent.com/derek3411888/-/main/self-hosted-server.zip?release=$releaseId"
    server_sha256 = $serverHash
    web_sha256 = $webHash
}
$manifestJson = $manifest | ConvertTo-Json
[IO.File]::WriteAllText((Join-Path $projectRoot 'update_manifest.example.json'), $manifestJson + "`n", [Text.UTF8Encoding]::new($false))

& git diff --check
Assert-ExitCode 'git diff --check'

Write-Host "完成：Payload $PayloadVersion / Launcher $LauncherVersion / Server $ServerVersion"
Write-Host "payload.zip SHA256=$payloadHash"
Write-Host "launcher SHA256=$launcherHash"
Write-Host "server bundle SHA256=$serverHash"
Write-Host "web SHA256=$webHash"
$developmentSucceeded = $true
} finally {
    Complete-ProjectDevelopmentPaths -Context $developmentPaths -RemoveRunDirectory:$developmentSucceeded
}
