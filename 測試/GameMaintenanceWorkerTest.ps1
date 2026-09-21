$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'gm-worker'
try {
    . (Join-Path $root 'payload\GameMaintenanceWorker.ps1')
    $program=Join-Path $context.RunRoot 'program'
    $state=Join-Path $program 'config\game-maintenance'
    $session=Join-Path $program '執行暫存\遊戲更新\test-session'
    [void][IO.Directory]::CreateDirectory($state); [void][IO.Directory]::CreateDirectory($session)
    $paths=@{RequestPath=(Join-Path $session 'request.json');OutputPath=(Join-Path $session 'snapshot.ini');StopPath=(Join-Path $session 'stop');StateDirectory=$state}
    $validated=Test-GMWorkerPaths @paths
    Assert-GMEqual $validated $session 'session containment validated'
    Assert-GMTrue (Test-GMWorkerNoticeDue 300001 0 0 '0' '0' $false) 'five-minute periodic notice read'
    Assert-GMTrue (Test-GMWorkerNoticeDue 60001 50000 0 '2' '1' $false) 'explicit recheck after min interval'
    Assert-GMTrue (-not (Test-GMWorkerNoticeDue 59999 50000 0 '2' '1' $true)) 'rapid manual/deadline rechecks bounded to 60 seconds'
    $bad=$paths.Clone();$bad.OutputPath=Join-Path $context.RunRoot 'escape.ini'
    $rejected=$false;try { Test-GMWorkerPaths @bad } catch { $rejected=$true };Assert-GMTrue $rejected 'output escape rejected'
    $snapshot=[ordered]@{meta=[ordered]@{schemaVersion=1;marker='WUTHERING_GAME_MAINTENANCE_WORKER_V1';requestId='roundtrip';sequence=1;generation=2;observedAtUtcMs=100000}
        notice=@{outcome='ok';present=0};install=@{provider='unknown'};observation=@{phase='unknown';detail='等待官方公告';progressPercent=$null}}
    Write-GMSnapshot -Path $paths.OutputPath -Snapshot $snapshot -AllowedRoot $session
    Write-GMSnapshot -Path $paths.OutputPath -Snapshot $snapshot -AllowedRoot $session
    $ahk=Join-Path $context.RunRoot 'roundtrip.ahk'
    $ahkText=@"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
#Include $root\payload\GameMaintenance.ahk
GMTest_Run(RoundTrip)
RoundTrip() {
    result := GM_ReadWorkerSnapshot("$($paths.OutputPath)", "roundtrip", 0, 100001, "$session")
    GMTest_Assert(result["observation"]["detail"] = "等待官方公告", "actual PS writer to AHK UTF8 reader")
}
"@
    [IO.File]::WriteAllText($ahk,$ahkText,[Text.UTF8Encoding]::new($true))
    $readback=Invoke-GMTestProcess $ahk $context
    Assert-GMEqual $readback.ExitCode 0 ('real reader roundtrip '+$readback.Stdout+$readback.Stderr)
    $before=[IO.File]::ReadAllText($paths.OutputPath)
    $snapshot.observation.detail="bad`n[meta]"
    $rejected=$false;try { Write-GMSnapshot -Path $paths.OutputPath -Snapshot $snapshot -AllowedRoot $session } catch { $rejected=$true }
    Assert-GMTrue $rejected 'section injection rejected'
    Assert-GMEqual ([IO.File]::ReadAllText($paths.OutputPath)) $before 'invalid write preserves prior snapshot'
    Assert-GMEqual @(Get-ChildItem -LiteralPath $session -Filter '*.tmp').Count 0 'no atomic temp leaks'
    $manifest=Join-Path $session 'appmanifest_3513350.acf'; $log=Join-Path $session 'content_log.txt'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "3513350" "StateFlags" "4" "BytesDownloaded" "100" "BytesToDownload" "100" }')
    [IO.File]::WriteAllText($log,'[2026-08-20 11:09:59] AppID 3513350 state changed : Fully Installed,'+[Environment]::NewLine)
    $install=[pscustomobject]@{provider='steam';appId=3513350;manifestPath=$manifest;contentLogPath=$log;gameRoot=$session}
    $now=[DateTimeOffset]'2026-08-20T03:10:00Z'
    $first=Get-GMSteamObservation -Install $install -Now $now
    Assert-GMEqual $first.phase 'unknown' 'historical fully installed is not current ready'
    Assert-GMEqual $first.progressPercent $null 'old complete bytes are not current progress'
    $priorTime=$first.lastProgressAtUtc
    [IO.File]::AppendAllText($log,'[2026-08-20 11:10:00] AppID 123456 update changed : Running,'+[Environment]::NewLine)
    $other=Get-GMSteamObservation -Install $install -Previous $first -Now $now.AddSeconds(1)
    Assert-GMEqual $other.lastProgressAtUtc $priorTime 'other App cannot refresh progress'
    [IO.File]::AppendAllText($log,'[2026-08-20 11:10:01] AppID 3513350 update changed : Running,Downloading,'+[Environment]::NewLine)
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "3513350" "BytesDownloaded" "50" "BytesToDownload" "200" }')
    $down=Get-GMSteamObservation -Install $install -Previous $other -Now $now.AddSeconds(2)
    Assert-GMEqual $down.phase 'downloading' 'fresh target progress'
    Assert-GMEqual $down.progressPercent 25 'stage percent from verified current activity'
    [IO.File]::AppendAllText($log,'[2026-08-20 11:10:03] AppID 3513350 update changed : Staging,'+[Environment]::NewLine)
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "3513350" "BytesStaged" "20" "BytesToStage" "100" }')
    $staging=Get-GMSteamObservation -Install $install -Previous $down -Now $now.AddSeconds(4)
    Assert-GMEqual $staging.phase 'installing' 'separate install stage'
    Assert-GMEqual $staging.progressPercent 20 'install stage has its own denominator'
    [IO.File]::AppendAllText($log,'[2026-08-20 11:10:04] AppID 3513350 state changed : Fully Installed,'+[Environment]::NewLine)
    $ready=Get-GMSteamObservation -Install $install -Previous $staging -Now $now.AddSeconds(5)
    Assert-GMEqual $ready.phase 'update_ready' 'updater ready is not game ready'
    [IO.File]::AppendAllText($log,'[2026-08-20 11:10:05] AppID 3513350 update changed : Paused,'+[Environment]::NewLine)
    $paused=Get-GMSteamObservation -Install $install -Previous $ready -Now $now.AddSeconds(6)
    Assert-GMEqual $paused.phase 'paused_download' 'Steam download pause distinct from client pause'
    [IO.File]::WriteAllText($log,'[2026-08-20 09:00:00] AppID 3513350 update changed : Running,Downloading,'+[Environment]::NewLine)
    $rotated=Get-GMSteamObservation -Install $install -Previous $paused -Now $now.AddSeconds(7)
    Assert-GMEqual $rotated.lastProgressAtUtc $paused.lastProgressAtUtc 'rotation old timestamps not progress'
    [IO.File]::WriteAllText($manifest,'"AppState" { "appid" "123" }')
    $invalid=Get-GMSteamObservation -Install $install -Previous $rotated -Now $now.AddSeconds(7)
    Assert-GMEqual $invalid.errorCode 'STEAM_MANIFEST_INVALID' 'wrong App ID rejected'
    $identity=Get-GMObservedGame -Install $install -Candidates @([pscustomobject]@{Id=91;Path=(Join-Path $session 'unrelated\Client-Win64-Shipping.exe')})
    Assert-GMEqual $identity $null 'same process name outside root not adopted'
    $gameFile=Join-Path $session 'Client\Binaries\Win64\Client-Win64-Shipping.exe'
    [void][IO.Directory]::CreateDirectory((Split-Path $gameFile -Parent));[IO.File]::WriteAllText($gameFile,'fixture')
    $identity=Get-GMObservedGame -Install $install -Candidates @([pscustomobject]@{Id=92;Path=$gameFile})
    Assert-GMEqual $identity.gamePid 92 'exact canonical game adopted only as running'
    Assert-GMEqual $identity.phase 'game_running' 'process alone not ready'
    $request=@{schemaVersion=1;requestId='lifecycle';generation=1;launchEntry=(Join-Path $session 'missing.exe');mode='install';createdAtUtc=[DateTimeOffset]::UtcNow.ToString('o')}
    [IO.File]::WriteAllText($paths.RequestPath,($request|ConvertTo-Json),[Text.UTF8Encoding]::new($false))
    $parent=Get-Process -Id $PID
    Assert-GMTrue (Test-GMWorkerParent $PID $parent.StartTime.ToUniversalTime().ToString('o')) 'exact parent accepted'
    Assert-GMTrue (-not (Test-GMWorkerParent $PID $parent.StartTime.AddSeconds(-1).ToUniversalTime().ToString('o'))) 'PID reuse identity rejected'
    $exe=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args='-NoProfile -ExecutionPolicy Bypass -File "'+(Join-Path $root 'payload\GameMaintenanceWorker.ps1')+'"'
    foreach($key in $paths.Keys){$args+=' -'+$key+' "'+$paths[$key]+'"'}
    $args+=' -ParentPid '+$PID+' -ParentStartUtc "'+$parent.StartTime.ToUniversalTime().ToString('o')+'"'
    $worker=Start-Process $exe -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $session 'worker.err')
    [void]$worker.Handle
    try {
        $timer=[Diagnostics.Stopwatch]::StartNew()
        while($timer.ElapsedMilliseconds -lt 10000 -and -not $worker.HasExited){
            if([IO.File]::ReadAllText($paths.OutputPath) -match 'requestId=lifecycle'){break};Start-Sleep -Milliseconds 100
        }
        Assert-GMTrue ([IO.File]::ReadAllText($paths.OutputPath) -match 'requestId=lifecycle') 'worker publishes without game launch'
        $duplicate=Start-Process $exe -ArgumentList $args -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $session 'duplicate.err')
        [void]$duplicate.Handle
        Assert-GMTrue $duplicate.WaitForExit(5000) 'second helper exits rather than duplicate loop'
        Assert-GMEqual $duplicate.ExitCode 2 'exclusive state lock rejects second helper'
        $duplicate.Dispose()
        [IO.File]::WriteAllText($paths.StopPath,'stop')
        Assert-GMTrue $worker.WaitForExit(2000) 'stop exits within two seconds'
        Assert-GMEqual $worker.ExitCode 0 'normal stop exit'
    } finally { if(-not $worker.HasExited){Stop-Process -InputObject $worker};$worker.Dispose() }
    Write-Output 'PASS: worker protocol, containment, observation and lifecycle'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
