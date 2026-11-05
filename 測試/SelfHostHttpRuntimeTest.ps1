[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'selfhost-http-runtime'
$server=$null
try {
    $out=Join-Path $context.RunRoot 'server.out'
    $err=Join-Path $context.RunRoot 'server.err'
    $node=(Get-Command node -CommandType Application | Select-Object -First 1).Source
    $server=Start-Process -FilePath $node -ArgumentList ('"'+(Join-Path $PSScriptRoot 'SelfHostHttpFixture.mjs')+'"') -WindowStyle Hidden -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    $deadline=[DateTime]::UtcNow.AddSeconds(5)
    $port=0
    while([DateTime]::UtcNow -lt $deadline -and !$server.HasExited) {
        if(Test-Path -LiteralPath $out){
            $portText=Get-Content -LiteralPath $out -Raw
            if($portText){[void][int]::TryParse($portText.Trim(),[ref]$port)}
        }
        if($port -gt 0){break}
        Start-Sleep -Milliseconds 100
    }
    Assert-GMTrue ($port -gt 0 -and $port -le 65535) 'Loopback fixture listener started'
    $fixture=@'
#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Include __ROOT__\測試\GameMaintenanceFixtures.ahk
#Warn VarUnset, Off
#Include __ROOT__\payload\RemoteControlSelfHost.ahk
global RC_TIMEOUT_MS := 1500, RCSH_TRANSPORT := "selfhost_only"
RCSH_SERVER_URL := "http://127.0.0.1:__PORT__"
GMTest_Run(TestHttpRuntime)
TestHttpRuntime() {
    global RCSH_HTTP_RETRY_AFTER
    response := RCSH_HttpRequest("GET","/ok", "", false)
    GMTest_Assert(response.ok && InStr(response.body,'"fixture":"ok"'), "real WinHTTP async response parses successfully")
    start := A_TickCount
    response := RCSH_HttpRequest("GET","/slow", "", false)
    elapsed := A_TickCount-start
    GMTest_Assert(!response.ok && elapsed >= 900 && elapsed < 4500, "trickling response cannot exceed overall deadline; elapsed=" elapsed)
    GMTest_Assert(RCSH_HTTP_RETRY_AFTER > RC_UnixMs(), "timeout causes backoff")
    RCSH_HTTP_RETRY_AFTER := 0
    GMTest_Assert(RCSH_HttpRequest("GET","/ok", "", false).ok, "aborted operation releases transport ownership")
    FileAppend("WinHTTP loopback timeout elapsed_ms=" elapsed "`n","*")
}
RC_UnixMs() => A_TickCount
'@
    $path=Join-Path $context.RunRoot 'http-runtime.ahk'
    [IO.File]::WriteAllText($path,$fixture.Replace('__ROOT__',$root).Replace('__PORT__',[string]$port),[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $path $context 10
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'Real WinHTTP selfhost-only bounded response'
} finally {
    # This object is the exact child started above; no process-name cleanup.
    if($server -and !$server.HasExited){$server.Kill();[void]$server.WaitForExit(5000)}
    Complete-ProjectDevelopmentPaths -Context $context
}
