[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$project=Split-Path $PSScriptRoot -Parent
$run=Join-Path $project ('.dev-runtime\diagnostics\game-maintenance\download-ahk-' + [Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($run)
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$helper=Join-Path $run 'LauncherMaintenance.exe'
& $compiler /nologo /warnaserror /langversion:5 /target:exe /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll ('/out:'+$helper) (Join-Path $project 'native-helper\LauncherMaintenance.cs') (Join-Path $project 'native-helper\FrameworkTarget.cs')
if($LASTEXITCODE -ne 0){throw 'Helper compile failed'}
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
$url='http://127.0.0.1:'+([Net.IPEndPoint]$listener.LocalEndpoint).Port+'/file'
$body=[Text.Encoding]::ASCII.GetBytes('Verified real AHK to native artifact download')
$hasher=[Security.Cryptography.SHA256]::Create()
try{$sha=[BitConverter]::ToString($hasher.ComputeHash($body)).Replace('-','').ToLowerInvariant()}finally{$hasher.Dispose()}
$fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#Include __HTTP__
progressCount := 0
Report(text) {
    global progressCount
    progressCount++
}
try {
    LauncherDownloadFile("__HELPER__", "__ROOT__", "__URL__", "__ROOT__\result.bin", "__SHA__", Report, 5000, 2000)
    if FileRead("__ROOT__\result.bin") != "Verified real AHK to native artifact download"
        throw Error("artifact not published correctly")
    if !progressCount
        throw Error("no progress/outcome callback")
    ; Verified destination is reusable without a second request.
    LauncherDownloadFile("__HELPER__", "__ROOT__", "__URL__", "__ROOT__\result.bin", "__SHA__", Report, 5000, 2000)
    FileAppend("PASS actual AHK artifact caller, parent binding, output and cache reuse`n", "*")
} catch as fixtureError {
    FileAppend(fixtureError.Message "`n", "**", "UTF-8")
    ExitApp(1)
}
ExitApp(0)
'@
$fixture=$fixture.Replace('__HTTP__',(Join-Path $project 'LauncherHttp.ahk')).Replace('__HELPER__',$helper).Replace('__ROOT__',$run).Replace('__URL__',$url).Replace('__SHA__',$sha)
$path=Join-Path $run 'inert-download.ahk'
[IO.File]::WriteAllText($path,$fixture,[Text.UTF8Encoding]::new($false))
$out=Join-Path $run 'out.log';$err=Join-Path $run 'err.log'
$client=$null;$p=$null
try {
    $accept=$listener.AcceptTcpClientAsync()
    $p=Start-Process -FilePath (Join-Path $project 'AutoHotkey64.exe') -ArgumentList ('/ErrorStdOut=UTF-8 "'+$path+'"') -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    [void]$p.Handle
    if($accept.Wait(3000)) {
        $client=$accept.Result;$stream=$client.GetStream()
        $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
        while($reader.ReadLine()) {}
        $reader.Dispose()
        $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
        $stream.Write($header,0,$header.Length);$stream.Write($body,0,$body.Length);$stream.Flush();$client.Dispose();$client=$null
    }
    if(!$p.WaitForExit(12000)) { $p.Kill();throw 'Isolated AHK download exceeded deadline' }
    Get-Content -LiteralPath $out -Raw
    if($p.ExitCode -ne 0){throw ([IO.File]::ReadAllText($err))}
} finally {if($client){$client.Dispose()};$listener.Stop();if($p){$p.Dispose()}}
