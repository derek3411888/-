[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$module=Join-Path $PSScriptRoot '..\payload\GameInstallDiscovery.ps1'
Assert-GMTrue (Test-Path -LiteralPath $module) 'Install discovery module is missing'
. $module
$ctx=Initialize-ProjectDevelopmentPaths -ProjectRoot (Split-Path $PSScriptRoot -Parent) -RunName 'gm-install-test'
try {
    $vdf=ConvertFrom-GMValveKeyValues '// comment
    "libraryfolders" { "0" { "path" "D:\\Steam Library" "apps" { "3513350" "1234" } } "1" "E:\\遊戲" }'
    Assert-GMEqual $vdf.libraryfolders['0'].path 'D:\Steam Library' 'Nested escaped path'
    Assert-GMEqual $vdf.libraryfolders['1'] 'E:\遊戲' 'Legacy library path'
    foreach ($bad in @('"AppState" { "appid" "3513350"','"AppState" { "appid" }','"x" "a" "x" "b"','"a" { } }')) {
        $failed=$false
        try { [void](ConvertFrom-GMValveKeyValues $bad) } catch { $failed=$true }
        Assert-GMTrue $failed 'Incomplete or duplicate KeyValues rejected'
    }
    $steam=[pscustomobject]@{appId=3513350;installed=$true;root='D:\SteamLibrary\steamapps\common\Wuthering Waves';realRoot='D:\SteamLibrary\steamapps\common\Wuthering Waves';launcherPath='C:\Program Files (x86)\Steam\steam.exe';identityVerified=$true;adapterVerified=$false;fingerprint='steam1'}
    $kuro=[pscustomobject]@{installed=$true;root='D:\遊戲\Wuthering Waves Game';realRoot='D:\遊戲\Wuthering Waves Game';launcherPath='D:\遊戲\launcher.exe';identityVerified=$true;adapterVerified=$false;fingerprint='kuro1'}
    $inventory=[pscustomobject]@{steamLibraries=@('D:\SteamLibrary');steamInstalls=@($steam);kuroInstalls=@($kuro);fingerprint='inventory1'}
    $entry=[pscustomobject]@{kind='steam-uri';target='steam://run/3513350';arguments='';workingDirectory='';realPath='';fingerprint='entry1'}
    $result=Resolve-GMInstallEvidence $entry $inventory
    Assert-GMEqual $result.provider 'steam' 'Precise Steam URI identifies installation'
    Assert-GMEqual $result.updateAdapterReady $false 'Detection is not a claimed live update test'
    $entry.target='steam://rungameid/3513350'
    Assert-GMEqual (Resolve-GMInstallEvidence $entry $inventory).provider 'steam' 'Desktop Steam URI accepted'
    foreach ($target in @('steam://run/999999','steam://run/3513350?arg=evil','steam://run/3513350/extra')) {
        $entry.target=$target
        Assert-GMEqual (Resolve-GMInstallEvidence $entry $inventory).provider 'unknown' 'Wrong or decorated URI rejected'
    }
    $entry.kind='exe'; $entry.target='D:\遊戲\Wuthering Waves Game\Client\Binaries\Win64\Client-Win64-Shipping.exe'; $entry.realPath=$entry.target
    Assert-GMEqual (Resolve-GMInstallEvidence $entry $inventory).provider 'kuro' 'Selected Kuro entry wins over a separate Steam installation'
    $entry.realPath='d:\steamlibrary\steamapps\common\Wuthering Waves\Client\Binaries\Win64\Client-Win64-Shipping.exe'
    Assert-GMEqual (Resolve-GMInstallEvidence $entry $inventory).provider 'steam' 'Canonical target, not shortcut spelling, selects provider'
    $entry.realPath=$steam.realRoot+'-other\Client.exe'
    Assert-GMEqual (Resolve-GMInstallEvidence $entry $inventory).provider 'unknown' 'Sibling prefix is not game root'
    $entry.realPath=$steam.realRoot+'\Client.exe'; $kuro.realRoot=$steam.realRoot
    Assert-GMEqual (Resolve-GMInstallEvidence $entry $inventory).provider 'ambiguous' 'Conflicting provider evidence is not guessed'
    $kuro.realRoot='D:\遊戲\Wuthering Waves Game'; $steam.installed=$false
    Assert-GMEqual (Resolve-GMInstallEvidence $entry $inventory).provider 'unknown' 'Removed installation not accepted'
    $steam.installed=$true
    $before=(Resolve-GMInstallEvidence $entry $inventory).fingerprint
    $inventory.fingerprint='inventory2'
    Assert-GMTrue ((Resolve-GMInstallEvidence $entry $inventory).fingerprint -ne $before) 'Inventory changes invalidate identity fingerprint'
    $inventory.steamInstalls=@(); $inventory.kuroInstalls=@()
    Assert-GMEqual (Resolve-GMInstallEvidence $entry $inventory).provider 'unknown' 'No install evidence means unknown, not Kuro'

    $library=Join-Path $ctx.RunRoot 'Steam 中文 Library'
    $apps=Join-Path $library 'steamapps'
    $gameRoot=Join-Path $apps 'common\Wuthering Waves'
    $gameExe=Join-Path $gameRoot 'Client\Binaries\Win64\Client-Win64-Shipping.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path $gameExe -Parent))
    [IO.File]::WriteAllBytes($gameExe,[byte[]]@(1))
    [IO.File]::WriteAllBytes((Join-Path $library 'steam.exe'),[byte[]]@(1))
    $manifest=Join-Path $apps 'appmanifest_3513350.acf'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "3513350" "installdir" "Wuthering Waves" "StateFlags" "4" }')
    [IO.File]::WriteAllText((Join-Path $apps 'libraryfolders.vdf'),('"libraryfolders" { "0" { "path" "'+$library.Replace('\','\\')+'" } }'))
    $inventory=Get-GMInstallInventory -LaunchEntry $gameExe -SteamRoots @($library) -SkipRegistry
    Assert-GMEqual (Resolve-GMInstallEvidence $inventory.launchEntry $inventory).provider 'steam' 'Real file inventory with non-default library'
    $oldFingerprint=$inventory.fingerprint
    [IO.File]::AppendAllText($manifest,' // metadata changed')
    $changed=Get-GMInstallInventory -LaunchEntry $gameExe -SteamRoots @($library) -SkipRegistry
    Assert-GMTrue ($changed.fingerprint -ne $oldFingerprint) 'Manifest bytes are part of cache identity'
    $urlPath=Join-Path $ctx.RunRoot '鳴潮.url'
    [IO.File]::WriteAllText($urlPath,"[InternetShortcut]`r`nURL=steam://rungameid/3513350`r`n",[Text.UTF8Encoding]::new($true))
    $urlInventory=Get-GMInstallInventory -LaunchEntry $urlPath -SteamRoots @($library) -SkipRegistry
    Assert-GMEqual (Resolve-GMInstallEvidence $urlInventory.launchEntry $urlInventory).provider 'steam' 'Steam .url resolved without opening it'
    $junctionPath=Join-Path $ctx.RunRoot 'game-alias'
    Assert-GMTrue (Test-ProjectContainedPath $junctionPath $ctx.RunRoot) 'Junction stays in test root'
    Assert-GMTrue (Test-ProjectContainedPath $gameRoot $ctx.RunRoot) 'Junction target stays in test root'
    [void](New-Item -ItemType Junction -Path $junctionPath -Target $gameRoot -ErrorAction Stop)
    $aliased=Get-GMInstallInventory -LaunchEntry (Join-Path $junctionPath 'Client\Binaries\Win64\Client-Win64-Shipping.exe') -SteamRoots @($library) -SkipRegistry
    Assert-GMEqual (Resolve-GMInstallEvidence $aliased.launchEntry $aliased).provider 'steam' 'Actual junction resolves to matching Steam installation'
    $linkPath=Join-Path $ctx.RunRoot 'game.lnk'
    $shell=New-Object -ComObject WScript.Shell
    $link=$shell.CreateShortcut($linkPath); $link.TargetPath=$gameExe; $link.Save()
    $shortcut=Get-GMInstallInventory -LaunchEntry $linkPath -SteamRoots @($library) -SkipRegistry
    Assert-GMEqual (Resolve-GMInstallEvidence $shortcut.launchEntry $shortcut).provider 'steam' 'LNK target resolved without running it'
    # Windows Shell refuses to create self-links; inject only the metadata read.
    $loopEntry=Resolve-GMLaunchEntry -LaunchEntry $linkPath -ShortcutReader { param($path) [pscustomobject]@{TargetPath=$path;Arguments='';WorkingDirectory=''} }
    Assert-GMEqual (Resolve-GMInstallEvidence $loopEntry $inventory).provider 'unknown' 'Shortcut loop rejected'
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "3513350"')
    $partial=Get-GMInstallInventory -LaunchEntry $gameExe -SteamRoots @($library) -SkipRegistry
    Assert-GMEqual (Resolve-GMInstallEvidence $partial.launchEntry $partial).provider 'unknown' 'Half-written manifest never counts as installed'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "999999" "installdir" "Wuthering Waves" }')
    $wrong=Get-GMInstallInventory -LaunchEntry $gameExe -SteamRoots @($library) -SkipRegistry
    Assert-GMEqual (Resolve-GMInstallEvidence $wrong.launchEntry $wrong).provider 'unknown' 'Wrong manifest app ID rejected'
    Write-Output 'PASS: KeyValues parsing, provider evidence, canonical paths, shortcuts, manifests and fingerprint invalidation'
} finally { Complete-ProjectDevelopmentPaths -Context $ctx }
