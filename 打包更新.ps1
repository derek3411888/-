[CmdletBinding()]
param(
    [string]$PayloadVersion = '4.62',
    [string]$LauncherVersion = '4.73',
    [string]$ServerVersion = '1.0.19'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location -LiteralPath $projectRoot

function Assert-ExitCode([string]$Task) {
    if ($LASTEXITCODE -ne 0) { throw "$Task 失敗，exit=$LASTEXITCODE" }
}

function Invoke-AhkValidate([string]$RuntimePath, [string]$ScriptPath, [string]$Task) {
    # AutoHotkey 是 GUI 子系統程式；直接用 & 執行時 Windows PowerShell 不一定
    # 會可靠等待或填入 LASTEXITCODE。Start-Process -Wait 才能取得真正驗證結果。
    $process = Start-Process -FilePath $RuntimePath -ArgumentList @(
        '/ErrorStdOut', '/Validate', $ScriptPath
    ) -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "$Task 失敗，exit=$($process.ExitCode)" }
}

function Invoke-AhkCompile([string]$CompilerPath, [string]$SourcePath,
    [string]$OutputPath, [string]$BasePath, [string]$Task) {
    $process = Start-Process -FilePath $CompilerPath -ArgumentList @(
        '/in', $SourcePath, '/out', $OutputPath, '/base', $BasePath, '/silent', 'verbose'
    ) -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "$Task 失敗，exit=$($process.ExitCode)" }
    if (-not (Test-Path -LiteralPath $OutputPath)) { throw "$Task 未產生輸出檔：$OutputPath" }
    if ((Get-Item -LiteralPath $OutputPath).Length -le 0) { throw "$Task 產生空白輸出檔：$OutputPath" }
}

function Invoke-AhkTest([string]$RuntimePath, [string]$ScriptPath, [string]$Task) {
    $process = Start-Process -FilePath $RuntimePath -ArgumentList @(
        '/ErrorStdOut', $ScriptPath
    ) -NoNewWindow -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "$Task 失敗，exit=$($process.ExitCode)" }
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

$compiler = Find-AhkCompiler
$runtime = Join-Path $projectRoot 'AutoHotkey64.exe'
$payloadRuntime = Join-Path $projectRoot 'payload\AutoHotkey64.exe'
if (-not (Test-Path -LiteralPath $runtime) -or -not (Test-Path -LiteralPath $payloadRuntime)) {
    throw '找不到 AutoHotkey64.exe。'
}

$launcherSource = Get-Content -LiteralPath '打包啟動器.ahk' -Raw -Encoding UTF8
$payloadSource = Get-Content -LiteralPath 'payload\全自動.ahk' -Raw -Encoding UTF8
if ($launcherSource -notmatch ('PACK_LAUNCHER_BUILD_VERSION\s*:=\s*"' + [regex]::Escape($LauncherVersion) + '"')) {
    throw "打包啟動器.ahk 版本不是 $LauncherVersion"
}
if ($payloadSource -notmatch ('PAYLOAD_BOOTSTRAP_LAUNCHER_VERSION\s*:=\s*"' + [regex]::Escape($LauncherVersion) + '"')) {
    throw "payload 啟動器相容版本不是 $LauncherVersion"
}
$package = Get-Content -LiteralPath 'self-hosted-server\package.json' -Raw -Encoding UTF8 | ConvertFrom-Json
if ([string]$package.version -ne $ServerVersion) { throw "server package 版本不是 $ServerVersion" }

Write-Host '執行語法與單元測試…'
Invoke-AhkValidate $payloadRuntime 'payload\全自動.ahk' 'Payload AHK validate'
Invoke-AhkValidate $payloadRuntime '測試\SelfHealingPolicyTest.ahk' '自動修復策略測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\SelfHealingPolicyTest.ahk' '自動修復策略回歸測試'
Invoke-AhkValidate $payloadRuntime 'payload\自動開啟OKWW.ahk' 'OKWW manager AHK validate'
Invoke-AhkValidate $payloadRuntime '測試\OKWW自動戰鬥OCR判斷測試.ahk' 'OKWW OCR 回歸測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\OKWW自動戰鬥OCR判斷測試.ahk' 'OKWW OCR 回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\伺服器名稱與切服判斷測試.ahk' '伺服器名稱回歸測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\伺服器名稱與切服判斷測試.ahk' '伺服器名稱與切服回歸測試'
Invoke-AhkValidate $payloadRuntime 'payload\RecordingFinalizeWorker.ahk' '錄影 worker AHK validate'
Invoke-AhkValidate $payloadRuntime '測試\SelfHostLiveLoopbackTest.ahk' '直播 loopback 測試語法 validate'
Invoke-AhkValidate $payloadRuntime '測試\SelfHostLiveAutomaticFallbackTest.ahk' '直播自動回退測試語法 validate'
Invoke-AhkValidate $payloadRuntime '測試\SelfHostLiveCandidatesTest.ahk' '直播路由候選測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\SelfHostLiveCandidatesTest.ahk' '直播路由候選回歸測試'
Invoke-AhkValidate $payloadRuntime '測試\SelfHostFreshDeviceDefaultTest.ahk' '外網新裝置預設連線測試語法 validate'
Invoke-AhkTest $payloadRuntime '測試\SelfHostFreshDeviceDefaultTest.ahk' '外網新裝置預設連線回歸測試'
Invoke-AhkValidate $runtime '打包啟動器.ahk' 'Launcher AHK validate'
$uploaderTokens = $null
$uploaderParseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $projectRoot 'payload\SelfHostMediaUpload.ps1'),
    [ref]$uploaderTokens, [ref]$uploaderParseErrors)
if ($uploaderParseErrors.Count -gt 0) {
    throw "中央影片上傳 PowerShell 語法錯誤：$($uploaderParseErrors[0].Message)"
}
Add-Type -AssemblyName System.Security
if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
    throw '目前 PowerShell 無法載入 DPAPI ProtectedData 型別。'
}
& npm.cmd --prefix self-hosted-server run check
Assert-ExitCode 'Server 靜態檢查'
& npm.cmd --prefix self-hosted-server test
Assert-ExitCode 'Server 單元測試'
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
    'RemoteControlSelfHost.ahk', 'SelfHealingPolicy.ahk', 'SelfHostMediaUpload.ps1'
)

Write-Host '編譯內嵌最新版 Payload 的 Launcher EXE…'
$launcherTemp = Join-Path $projectRoot '全自動鋤地.new.exe'
if (Test-Path -LiteralPath $launcherTemp) { Remove-Item -LiteralPath $launcherTemp -Force }
Invoke-AhkCompile $compiler '打包啟動器.ahk' $launcherTemp $runtime 'Launcher 編譯'
Move-Item -LiteralPath $launcherTemp -Destination '全自動鋤地.exe' -Force

Write-Host '建立同版 self-hosted-server.zip…'
New-FilteredZip 'self-hosted-server' 'self-hosted-server.zip' @(
    'node_modules/*', '.env', '*.log', '*.partial'
)
Assert-ZipContains 'self-hosted-server.zip' @(
    'package.json', 'compose.yml', 'src/app.js', 'src/media.js',
    'public/index.html', 'public/app.js', 'public/styles.css',
    'migrations/004_media_auto_repair.sql', 'Update-Server.ps1',
    'test/integration-smoke.mjs', 'test/media-stream.test.js'
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
