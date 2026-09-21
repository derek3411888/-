# Installation metadata only. Never launches executables or reads account files.
Set-StrictMode -Version 2

function Get-GMInstallField($Object,[string]$Name,$Default=$null) {
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] } }
    elseif ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Get-GMInstallHash([string]$Text) {
    $hash=[Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function Read-GMKeyValueObject([object[]]$Tokens,[ref]$Index,[bool]$NeedsClose,[int]$Depth=0) {
    if ($Depth -gt 24) { throw 'KeyValues nesting limit exceeded' }
    $result=@{}
    while ($Index.Value -lt $Tokens.Count) {
        $key=$Tokens[$Index.Value]; $Index.Value++
        if ($key.kind -eq 'close') {
            if (-not $NeedsClose) { throw 'Unexpected closing brace' }
            return $result
        }
        if ($key.kind -ne 'string' -or $Index.Value -ge $Tokens.Count) { throw 'Missing KeyValues key/value' }
        if ($result.ContainsKey($key.value)) { throw 'Duplicate KeyValues key' }
        $value=$Tokens[$Index.Value]; $Index.Value++
        if ($value.kind -eq 'open') { $result[$key.value]=Read-GMKeyValueObject $Tokens $Index $true ($Depth+1) }
        elseif ($value.kind -eq 'string') { $result[$key.value]=$value.value }
        else { throw 'Missing KeyValues value' }
    }
    if ($NeedsClose) { throw 'Unterminated KeyValues object' }
    return $result
}
function ConvertFrom-GMValveKeyValues([string]$Text) {
    if ([Text.Encoding]::UTF8.GetByteCount($Text) -gt 2097152) { throw 'KeyValues file too large' }
    $lexer=[regex]::new('\G\s*(?:"(?<q>(?:\\["\\]|[^"\\])*)"|(?<open>\{)|(?<close>\})|(?<comment>//[^\r\n]*))',[Text.RegularExpressions.RegexOptions]::None,[TimeSpan]::FromSeconds(1))
    $tokens=[Collections.Generic.List[object]]::new()
    $offset=0
    while ($offset -lt $Text.Length) {
        if ([string]::IsNullOrWhiteSpace($Text.Substring($offset))) { break }
        $match=$lexer.Match($Text,$offset)
        if (-not $match.Success) { throw 'Malformed KeyValues token' }
        $offset+=$match.Length
        if ($match.Groups['comment'].Success) { continue }
        if ($match.Groups['q'].Success) {
            $value=[regex]::Replace($match.Groups['q'].Value,'\\(["\\])','$1')
            $tokens.Add([pscustomobject]@{kind='string';value=$value})
        } else { $tokens.Add([pscustomobject]@{kind=$(if($match.Groups['open'].Success){'open'}else{'close'});value=''}) }
    }
    $index=0
    return (Read-GMKeyValueObject $tokens.ToArray() ([ref]$index) $false)
}

function Get-GMRealPath([string]$Path) {
    if (-not ('GameMaintenance.NativePathV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace GameMaintenance {
    public static class NativePathV1 {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFile(string name,uint access,uint share,IntPtr security,uint disposition,uint flags,IntPtr template);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle,StringBuilder path,uint length,uint flags);
        public static string Resolve(string path) {
            using (var handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
                if (handle.IsInvalid) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                var buffer=new StringBuilder(32768);
                uint length=GetFinalPathNameByHandle(handle,buffer,(uint)buffer.Capacity,0);
                if (length==0 || length>=buffer.Capacity) throw new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error());
                return buffer.ToString();
            }
        }
    }
}
'@ -ErrorAction Stop
    }
    $full=[GameMaintenance.NativePathV1]::Resolve([IO.Path]::GetFullPath($Path))
    if ($full.StartsWith('\\?\UNC\',[StringComparison]::OrdinalIgnoreCase)) { $full='\\'+$full.Substring(8) }
    elseif ($full.StartsWith('\\?\')) { $full=$full.Substring(4) }
    return $full.TrimEnd('\','/')
}
function Test-GMInstallWithin([string]$Path,[string]$Root) {
    if (-not $Path -or -not $Root) { return $false }
    try {
        $candidate=[IO.Path]::GetFullPath($Path).TrimEnd('\','/')
        $prefix=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
        return $candidate.Equals($prefix,[StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($prefix+'\',[StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}
function Get-GMFileIdentity([string]$Path,[bool]$Content=$false) {
    try {
        $file=Get-Item -LiteralPath $Path -ErrorAction Stop
        $identity=([string]$file.FullName)+'|'+$file.Length+'|'+$file.LastWriteTimeUtc.Ticks
        if ($Content) {
            if ($file.Length -gt 2097152) { throw 'Metadata too large' }
            $identity+='|'+(Get-GMInstallHash ([IO.File]::ReadAllText($Path)))
        }
        return $identity
    } catch { return "unavailable:$Path" }
}

function Read-GMShortcut([string]$Path) {
    $shell=New-Object -ComObject WScript.Shell
    $link=$null
    try {
        $link=$shell.CreateShortcut($Path)
        return [pscustomobject]@{TargetPath=[string]$link.TargetPath;Arguments=[string]$link.Arguments;WorkingDirectory=[string]$link.WorkingDirectory}
    } finally {
        if ($link) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}
function Resolve-GMLaunchEntry {
    param([string]$LaunchEntry,[scriptblock]$ShortcutReader={param($path) Read-GMShortcut $path})
    $result=[pscustomobject]@{kind='unknown';target='';arguments='';workingDirectory='';realPath='';fingerprint='';evidence=@()}
    $chain=@(); $seen=@{}; $target=$LaunchEntry.Trim().Trim('"')
    try {
        for ($depth=0;$depth -le 4;$depth++) {
            if ($target -match '^steam://(?:run|rungameid)/3513350/?$') {
                if ($result.arguments) { throw 'Unexpected Steam URI arguments' }
                $result.kind='steam-uri'; $result.target=$target; break
            }
            if ($target -match '^\w+://') { throw 'Unsupported launch URI' }
            $path=[IO.Path]::GetFullPath($target)
            if ($seen.ContainsKey($path)) { throw 'Shortcut cycle' }
            $seen[$path]=$true
            $chain+=Get-GMFileIdentity $path
            if (-not [IO.File]::Exists($path)) { throw 'Launch entry missing' }
            $extension=[IO.Path]::GetExtension($path).ToLowerInvariant()
            if ($extension -eq '.lnk') {
                if ($depth -eq 4) { throw 'Shortcut depth exceeded' }
                $link=& $ShortcutReader $path
                if ($result.arguments -and $link.Arguments) { throw 'Nested shortcut arguments ambiguous' }
                if ($link.Arguments) { $result.arguments=[string]$link.Arguments }
                $result.workingDirectory=[string]$link.WorkingDirectory
                $target=[string]$link.TargetPath
                continue
            }
            if ($extension -eq '.url') {
                if ($depth -eq 4 -or (Get-Item -LiteralPath $path).Length -gt 16384) { throw 'Invalid URL shortcut' }
                $content=[IO.File]::ReadAllText($path,[Text.Encoding]::UTF8)
                $urls=[regex]::Matches($content,'(?mi)^URL=(.*)$')
                if ($urls.Count -ne 1) { throw 'Ambiguous URL shortcut' }
                $target=$urls[0].Groups[1].Value.Trim()
                if ($target -notmatch '^steam://(?:run|rungameid)/3513350/?$') { throw 'Unsafe URL shortcut' }
                continue
            }
            if ($extension -ne '.exe' -or [IO.Path]::GetFileName($path) -match '^(?:cmd|powershell|pwsh|wscript|cscript|rundll32|mshta)\.exe$') { throw 'Executable wrapper not allowed' }
            $result.kind='exe'; $result.target=$path; $result.realPath=Get-GMRealPath $path
            if ($result.arguments -and $result.arguments -notmatch '^\s*-applaunch\s+3513350\s*$') { throw 'Unsupported launch arguments' }
            break
        }
        if (-not $result.target) { throw 'No launch target' }
        $result.evidence=@('entry-resolved')
    } catch {
        $result.kind='unknown'; $result.evidence=@($_.Exception.Message)
    }
    $result.fingerprint=Get-GMInstallHash ('entry-v1|'+$LaunchEntry+'|'+($chain -join '|')+'|'+$result.target+'|'+$result.arguments+'|'+$result.realPath)
    return $result
}

function Resolve-GMInstallEvidence {
    param($LaunchEntry,$Inventory)
    $matchingInstalls=@(); $kind=[string](Get-GMInstallField $LaunchEntry 'kind' '')
    $target=[string](Get-GMInstallField $LaunchEntry 'target' '')
    $real=[string](Get-GMInstallField $LaunchEntry 'realPath' '')
    $arguments=[string](Get-GMInstallField $LaunchEntry 'arguments' '')
    $preciseUri=$kind -eq 'steam-uri' -and $target -match '^steam://(?:run|rungameid)/3513350/?$' -and -not $arguments
    foreach ($provider in @('steam','kuro')) {
        foreach ($install in @(Get-GMInstallField $Inventory ($provider+'Installs') @())) {
            if (-not (Get-GMInstallField $install 'installed' $false) -or -not (Get-GMInstallField $install 'identityVerified' $false)) { continue }
            if ($provider -eq 'steam' -and (Get-GMInstallField $install 'appId' 0) -ne 3513350) { continue }
            $launcher=[string](Get-GMInstallField $install 'launcherPath' '')
            $root=[string](Get-GMInstallField $install 'realRoot' '')
            $entryMatches=$preciseUri -and $provider -eq 'steam'
            if ($kind -eq 'exe') {
                $entryMatches=(Test-GMInstallWithin $real $root) -and -not $arguments
                if ($real -and $real.Equals($launcher,[StringComparison]::OrdinalIgnoreCase)) {
                    $entryMatches=($provider -eq 'kuro' -and -not $arguments) -or ($provider -eq 'steam' -and $arguments -match '^\s*-applaunch\s+3513350\s*$')
                }
            }
            if ($entryMatches) { $matchingInstalls+= [pscustomobject]@{provider=$provider;install=$install} }
        }
    }
    $result=[pscustomobject]@{provider='unknown';appId=0;gameRoot='';launcherPath='';launchEntry=$LaunchEntry;evidence=@('insufficient-install-evidence')
        fingerprint=(Get-GMInstallHash ('install-rules-v1|'+[string](Get-GMInstallField $Inventory 'fingerprint' '')+'|'+($LaunchEntry | ConvertTo-Json -Depth 4 -Compress)))
        checkedAtUtc=[DateTimeOffset]::UtcNow.ToString('o');updateAdapterReady=$false;manifestPath='';contentLogPath=''}
    if ($matchingInstalls.Count -gt 1) { $result.provider='ambiguous'; $result.evidence=@('multiple-matching-installations'); return $result }
    if ($matchingInstalls.Count -eq 0) { return $result }
    $match=$matchingInstalls[0]; $install=$match.install
    $result.provider=$match.provider; $result.gameRoot=$install.realRoot; $result.launcherPath=$install.launcherPath
    $result.appId=if($result.provider -eq 'steam'){3513350}else{0}
    $result.evidence=@('configured-entry-matches-canonical-game-root','installation-files-verified')
    $result.updateAdapterReady=[bool](Get-GMInstallField $install 'adapterVerified' $false)
    $result.manifestPath=[string](Get-GMInstallField $install 'manifestPath' '')
    $result.contentLogPath=[string](Get-GMInstallField $install 'contentLogPath' '')
    return $result
}

function Get-GMInstallInventory {
    param([string]$LaunchEntry,[string[]]$SteamRoots=@(),[switch]$SkipRegistry)
    $entry=Resolve-GMLaunchEntry $LaunchEntry
    $roots=@($SteamRoots)
    if (-not $SkipRegistry) {
        foreach ($lookup in @(@('CurrentUser','Software\Valve\Steam','SteamPath'),@('LocalMachine','SOFTWARE\WOW6432Node\Valve\Steam','InstallPath'))) {
            $key=$null
            try {
                $hive=if($lookup[0] -eq 'CurrentUser'){[Microsoft.Win32.Registry]::CurrentUser}else{[Microsoft.Win32.Registry]::LocalMachine}
                $key=$hive.OpenSubKey($lookup[1],$false)
                if ($key) { $value=[string]$key.GetValue($lookup[2],''); if ($value) { $roots+=$value } }
            } catch { } finally { if ($key) { $key.Dispose() } }
        }
    }
    $roots=@($roots | Where-Object { $_ } | ForEach-Object { try { Get-GMRealPath $_ } catch { } } | Sort-Object -Unique)
    $steamInstalls=@(); $libraries=@(); $evidence=@($entry.fingerprint)
    foreach ($steamRoot in $roots) {
        $launcher=Join-Path $steamRoot 'steam.exe'
        if (-not [IO.File]::Exists($launcher)) { continue }
        $foldersPath=Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        $evidence+=Get-GMFileIdentity $foldersPath $true
        $libraryRoots=@($steamRoot)
        try {
            if ((Get-Item -LiteralPath $foldersPath -ErrorAction Stop).Length -gt 2097152) { throw 'Library index too large' }
            $folders=ConvertFrom-GMValveKeyValues ([IO.File]::ReadAllText($foldersPath))
            $folderMap=Get-GMInstallField $folders 'libraryfolders' @{}
            foreach ($number in @($folderMap.Keys | Where-Object { $_ -match '^\d+$' })) {
                $folder=$folderMap[$number]
                $libraryPath=if($folder -is [string]){$folder}else{Get-GMInstallField $folder 'path' ''}
                if ($libraryPath) { $libraryRoots+=Get-GMRealPath $libraryPath }
            }
        } catch { $evidence+='unreadable-library-index' }
        foreach ($library in @($libraryRoots | Sort-Object -Unique)) {
            if ($libraries -contains $library) { continue }; $libraries+=$library
            $manifestPath=Join-Path $library 'steamapps\appmanifest_3513350.acf'
            $evidence+=Get-GMFileIdentity $manifestPath $true
            try {
                if ((Get-Item -LiteralPath $manifestPath -ErrorAction Stop).Length -gt 2097152) { throw 'Manifest too large' }
                $parsed=ConvertFrom-GMValveKeyValues ([IO.File]::ReadAllText($manifestPath))
                $app=Get-GMInstallField $parsed 'AppState' @{}
                if ((Get-GMInstallField $app 'appid' '') -ne '3513350') { continue }
                $directory=[string](Get-GMInstallField $app 'installdir' '')
                if (-not $directory -or $directory -match '[\\/:]' -or $directory -in @('.','..')) { continue }
                $root=Join-Path $library ('steamapps\common\'+$directory)
                $gameExe=Join-Path $root 'Client\Binaries\Win64\Client-Win64-Shipping.exe'
                if (-not [IO.File]::Exists($gameExe)) { continue }
                $realRoot=Get-GMRealPath $root; $realExe=Get-GMRealPath $gameExe
                if (-not (Test-GMInstallWithin $realExe $realRoot)) { continue }
                $evidence+=Get-GMFileIdentity $launcher; $evidence+=Get-GMFileIdentity $gameExe
                $steamInstalls+=[pscustomobject]@{appId=3513350;installed=$true;root=$root;realRoot=$realRoot;launcherPath=(Get-GMRealPath $launcher)
                    identityVerified=$true;adapterVerified=$false;manifestPath=$manifestPath;contentLogPath=(Join-Path $steamRoot 'logs\content_log.txt')}
            } catch { $evidence+='unreadable-or-invalid-manifest' }
        }
    }
    $kuroInstalls=@(); $parent=if($entry.realPath){Split-Path $entry.realPath -Parent}else{''}
    for ($depth=0;$parent -and $depth -lt 6;$depth++) {
        $launcher=Join-Path $parent 'launcher.exe'; $root=Join-Path $parent 'Wuthering Waves Game'
        $gameExe=Join-Path $root 'Client\Binaries\Win64\Client-Win64-Shipping.exe'
        if ([IO.File]::Exists($launcher) -and [IO.File]::Exists($gameExe)) {
            try {
                $version=[Diagnostics.FileVersionInfo]::GetVersionInfo($launcher)
                if ($version.CompanyName -match '(?i)Kuro' -and $version.ProductName -eq 'Wuthering Waves') {
                    $realRoot=Get-GMRealPath $root
                    if (Test-GMInstallWithin (Get-GMRealPath $gameExe) $realRoot) {
                        $kuroInstalls+=[pscustomobject]@{installed=$true;root=$root;realRoot=$realRoot;launcherPath=(Get-GMRealPath $launcher);identityVerified=$true;adapterVerified=$false;launcherVersion=$version.FileVersion}
                        $evidence+=Get-GMFileIdentity $launcher; $evidence+=Get-GMFileIdentity $gameExe
                    }
                }
            } catch { $evidence+='unreadable-kuro-launcher-identity' }
        }
        $parent=Split-Path $parent -Parent
    }
    return [pscustomobject]@{launchEntry=$entry;steamLibraries=$libraries;steamInstalls=$steamInstalls;kuroInstalls=$kuroInstalls
        evidence=$evidence;fingerprint=(Get-GMInstallHash ('inventory-rules-v1|'+($roots -join '|')+'|'+($evidence -join '|')))}
}
