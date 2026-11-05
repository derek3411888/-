[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'selfhost-only-transport'
try {
    # Exercise the complete transport/state modules. Replace only OS/network and
    # host-application boundaries; journals, command claims and ACK routing stay real.
    $source=[IO.File]::ReadAllText((Join-Path $root 'payload\RemoteControlFirestore.ahk'))+"`n"+[IO.File]::ReadAllText((Join-Path $root 'payload\RemoteControlSelfHost.ahk'))
    $replacements=@{
        RC_Log='RC_Log(args*) => 0'
        RCSH_CleanupOrphanLivePreviews='RCSH_CleanupOrphanLivePreviews() => 0'
        RC_PatchClientState='RC_PatchClientState(state,args*) => TestHeartbeat(state)'
    }
    foreach($name in $replacements.Keys) {
        $pattern='(?ms)^'+$name+'\([^\r\n]*\) \{.*?^\}'
        $match=[regex]::Match($source,$pattern)
        Assert-GMTrue $match.Success "Boundary exists: $name"
        $source=$source.Remove($match.Index,$match.Length).Insert($match.Index,$replacements[$name]+"`n")
    }
    # No request can reach a real network, including accidentally re-enabled Firebase.
    $source=$source.Replace('ComObject("WinHttp.WinHttpRequest.5.1")','TestHttp()')
    $fixture=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'SelfHostOnlyTransportFixture.ahk'))
    $path=Join-Path $context.RunRoot 'selfhost-only.ahk'
    [IO.File]::WriteAllText($path,$fixture.Replace('__ROOT__',$root).Replace('__MODULES__',$source),[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $path $context 30
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'Selfhost-only actual init, journal, command and ACK transport'
} finally {Complete-ProjectDevelopmentPaths -Context $context}
