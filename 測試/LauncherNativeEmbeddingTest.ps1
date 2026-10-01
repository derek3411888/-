[CmdletBinding()]
param([string]$CompiledLauncherPath = '')
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
if ($CompiledLauncherPath) {
    # Data-file-only PE resource inspection. No production code is executed.
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
public static class EmbeddedLauncherResource {
    private delegate bool EnumName(IntPtr module, IntPtr type, IntPtr name, IntPtr param);
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32", CharSet=CharSet.Unicode, SetLastError=true)] private static extern bool EnumResourceNames(IntPtr module, IntPtr type, EnumName callback, IntPtr param);
    [DllImport("kernel32", CharSet=CharSet.Unicode)] private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32")] private static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32")] private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32")] private static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32")] private static extern bool FreeLibrary(IntPtr module);
    public static string Hash(string path) {
        IntPtr module=LoadLibraryEx(path,IntPtr.Zero,0x22);
        if(module==IntPtr.Zero) throw new Exception("Cannot inspect compiled PE resources");
        var matches=new List<string>();
        string failure=null;
        try {
            EnumName callback=delegate(IntPtr m,IntPtr type,IntPtr name,IntPtr param) {
                try {
                if(name.ToInt64()<=65535) return true;
                string text=Marshal.PtrToStringUni(name);
                if(!text.EndsWith("LAUNCHERMAINTENANCE.EXE",StringComparison.OrdinalIgnoreCase)) return true;
                IntPtr resource=FindResource(m,name,type);
                uint size=SizeofResource(m,resource);
                if(size==0 || size>10485760) throw new Exception("Unexpected helper resource size");
                byte[] bytes=new byte[size];
                Marshal.Copy(LockResource(LoadResource(m,resource)),bytes,0,bytes.Length);
                using(var sha=SHA256.Create()) matches.Add(BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-",""));
                return true;
                } catch(Exception error) {failure=error.Message;return false;}
            };
            EnumResourceNames(module,new IntPtr(10),callback,IntPtr.Zero);
            GC.KeepAlive(callback);
            if(failure!=null) throw new Exception(failure);
            if(matches.Count!=1) throw new Exception("Expected exactly one embedded native launcher helper, actual="+matches.Count);
            return matches[0];
        } finally {FreeLibrary(module);}
    }
}
'@
    $actual=[EmbeddedLauncherResource]::Hash((Resolve-Path -LiteralPath $CompiledLauncherPath).ProviderPath)
    $expected=(Get-FileHash -LiteralPath (Join-Path $project 'payload\LauncherMaintenance.exe') -Algorithm SHA256).Hash
    if($actual -cne $expected){throw 'Final compiled launcher native helper resource SHA mismatch'}
    Write-Output 'PASS final production PE resource exists and SHA matches; executable was not launched'
    return
}
$launcher = @(Get-ChildItem -LiteralPath $project -File -Filter '*.ahk' | Where-Object { [IO.File]::ReadAllText($_.FullName).Contains('ExtractZipNative(workDir) {') })
if ($launcher.Count -ne 1) { throw 'Cannot identify exact launcher source' }
$source = [IO.File]::ReadAllText($launcher[0].FullName)
$start = $source.IndexOf('PACK_NATIVE_HELPER_PATH := LauncherNewTempPath(')
$end = $source.IndexOf('payloadPath := WORK_DIR', $start)
if ($start -lt 0 -or $end -le $start) { throw 'Cannot isolate production native FileInstall block' }
$block = $source.Substring($start, $end-$start)
$evidence = Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\launcher-native-embedding-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory((Join-Path $evidence 'payload'))
$helper = Join-Path $project 'payload\LauncherMaintenance.exe'
Copy-Item -LiteralPath $helper -Destination (Join-Path $evidence 'payload\LauncherMaintenance.exe')
$fixture = @'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
SetWorkingDir A_ScriptDir
DirCreate A_ScriptDir "\out"
WriteLog(message,*) => FileAppend(message "`n", A_ScriptDir "\trace.log", "UTF-8")
LauncherNewTempPath(*) => A_ScriptDir "\out\LauncherMaintenance.exe"
'@ + "`n" + $block + "`nExitApp 0`n"
$scriptPath = Join-Path $evidence 'embedding-fixture.ahk'
$exePath = Join-Path $evidence 'embedding-fixture.exe'
[IO.File]::WriteAllText($scriptPath,$fixture,[Text.UTF8Encoding]::new($true))
$compiler = 'C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe'
$runtime = Join-Path $project 'AutoHotkey64.exe'
$compile = Start-Process -FilePath $compiler -ArgumentList @('/in',('"'+$scriptPath+'"'),'/out',('"'+$exePath+'"'),'/base',('"'+$runtime+'"'),'/silent','verbose') -WorkingDirectory $evidence -WindowStyle Hidden -PassThru
try {
    [void]$compile.Handle
    if (!$compile.WaitForExit(25000)) { $compile.Kill(); throw 'Owned fixture compilation timed out' }
    if ($compile.ExitCode -ne 0 -or !(Test-Path -LiteralPath $exePath)) { throw 'Fixture compilation failed' }
} finally { $compile.Dispose() }
# Execute only the small isolated fixture, never the production launcher.
$child = Start-Process -FilePath $exePath -WorkingDirectory $evidence -WindowStyle Hidden -PassThru
try {
    [void]$child.Handle
    if (!$child.WaitForExit(10000)) { $child.Kill(); throw 'Owned embedding fixture timed out' }
    if ($child.ExitCode -ne 0) { throw ('Compiled production FileInstall block failed, exit=' + $child.ExitCode + '; evidence=' + $evidence) }
} finally { $child.Dispose() }
$extracted = Join-Path $evidence 'out\LauncherMaintenance.exe'
if (!(Test-Path -LiteralPath $extracted)) { throw 'Compiled FileInstall did not extract helper' }
if ((Get-FileHash -LiteralPath $extracted -Algorithm SHA256).Hash -cne (Get-FileHash -LiteralPath $helper -Algorithm SHA256).Hash) { throw 'Embedded helper SHA mismatch' }
Write-Output ('PASS actual compiled production FileInstall extraction and SHA; evidence=' + $evidence)
