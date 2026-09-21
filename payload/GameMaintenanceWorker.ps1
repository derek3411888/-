param([string]$RequestPath,[string]$OutputPath,[string]$StopPath,[string]$StateDirectory,
    [int]$ParentPid,[string]$ParentStartUtc)
Set-StrictMode -Version 2
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceNotice.ps1')
. (Join-Path $PSScriptRoot 'GameInstallDiscovery.ps1')

function Test-GMPathContained {
    param([string]$Path,[string]$Root)
    $full=[IO.Path]::GetFullPath($Path);$base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if(-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Maintenance path outside allowed root'}
    $scan=$full
    while($scan){
        if(Test-Path -LiteralPath $scan){if((Get-Item -LiteralPath $scan -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse paths forbidden'}}
        $parent=Split-Path $scan -Parent;if($parent -eq $scan){break};$scan=$parent
    }
    return $full
}
function Test-GMWorkerPaths {
    param([string]$RequestPath,[string]$OutputPath,[string]$StopPath,[string]$StateDirectory)
    $state=[IO.Path]::GetFullPath($StateDirectory).TrimEnd('\')
    if((Split-Path $state -Leaf) -ne 'game-maintenance' -or (Split-Path (Split-Path $state -Parent) -Leaf) -ne 'config'){throw 'Invalid maintenance state directory'}
    $program=Split-Path (Split-Path $state -Parent) -Parent
    [void](Test-GMPathContained $state $program)
    $session=Split-Path ([IO.Path]::GetFullPath($RequestPath)) -Parent
    $runtime=Join-Path $program '執行暫存\遊戲更新'
    if((Split-Path $session -Parent) -ne $runtime){throw 'Invalid worker session directory'}
    foreach($item in @($RequestPath,$OutputPath,$StopPath)){
        $safe=Test-GMPathContained $item $session
        if((Split-Path $safe -Parent) -ne $session){throw 'Worker files must share session'}
    }
    if(@($RequestPath,$OutputPath,$StopPath | Sort-Object -Unique).Count -ne 3){throw 'Worker paths must be distinct'}
    return $session
}
function Get-GMSnapshotSchema {
    return [ordered]@{
        meta='schemaVersion,marker,requestId,sequence,generation,observedAtUtcMs'
        notice='outcome,present,eventId,revision,gameVersion,startsAtUtcMs,expectedOpenAtUtcMs,checkedAtUtcMs,sourceUrl,sourceState,freshForRelease,errorCode,detail'
        install='provider,appId,gameRoot,launcherPath,fingerprint,updateAdapterReady,evidence,checkedAtUtcMs'
        observation='phase,bytesDone,bytesTotal,progressPercent,lastProgressAtUtcMs,detail,errorCode,gamePid,gamePath'
    }
}
function Write-GMSnapshot {
    param([string]$Path,[Collections.IDictionary]$Snapshot,[string]$AllowedRoot)
    $safe=Test-GMPathContained $Path $AllowedRoot;$schema=Get-GMSnapshotSchema
    $lines=[Collections.Generic.List[string]]::new()
    foreach($section in $Snapshot.Keys){if(-not $schema.Contains($section)){throw 'Unknown snapshot section'}}
    foreach($section in $schema.Keys){
        if(-not $Snapshot.Contains($section)){throw 'Missing snapshot section'}
        $allowed=$schema[$section].Split(',');$lines.Add('['+$section+']')
        foreach($key in $Snapshot[$section].Keys){if($allowed -cnotcontains $key){throw 'Unknown snapshot field'}}
        foreach($key in $allowed){
            $value=$Snapshot[$section][$key]
            if($value -is [IFormattable]){$value=$value.ToString($null,[Globalization.CultureInfo]::InvariantCulture)}else{$value=[string]$value}
            if($value.Length -gt 2048 -or $value -match '[\x00-\x1F]'){throw 'Unsafe snapshot field'}
            $lines.Add($key+'='+$value)
        }
    }
    $text=($lines -join "`n")+"`n";if([Text.Encoding]::UTF8.GetByteCount($text) -gt 65536){throw 'Snapshot too large'}
    $temporary=$safe+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try {
        $bytes=[Text.UTF8Encoding]::new($false).GetBytes($text)
        $stream=[IO.File]::Open($temporary,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try {$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
        if([IO.File]::Exists($safe)){[IO.File]::Replace($temporary,$safe,[NullString]::Value)}else{[IO.File]::Move($temporary,$safe)}
    }finally{if([IO.File]::Exists($temporary)){[IO.File]::Delete($temporary)}}
}
function Test-GMWorkerParent {
    param([int]$ProcessId,[string]$StartedUtc)
    try {
        $process=Get-Process -Id $ProcessId -ErrorAction Stop
        $actual=[DateTimeOffset]$process.StartTime.ToUniversalTime()
        if($StartedUtc -match '^\d{13}$'){return [Math]::Abs($actual.ToUnixTimeMilliseconds()-[long]$StartedUtc) -le 1}
        return $actual.UtcTicks -eq ([DateTimeOffset]$StartedUtc).UtcTicks
    }catch{return $false}
}
function Read-GMWorkerRequest {
    param([string]$Path,[string]$ExpectedId='')
    if((Get-Item -LiteralPath $Path).Length -gt 16384){throw 'Request too large'}
    $request=ConvertFrom-GMNoticeJson ([IO.File]::ReadAllText($Path))
    if($request.schemaVersion -ne 1 -or $request.requestId -cnotmatch '^[A-Za-z0-9_-]{1,128}$' -or
        ($ExpectedId -and $ExpectedId -cne $request.requestId) -or [string]$request.generation -notmatch '^\d{1,12}$' -or
        $request.mode -cnotin @('notice','install','observe') -or [string]$request.launchEntry -match '[\x00-\x1F]' -or
        ([string]$request.launchEntry).Length -gt 2048){throw 'Invalid maintenance request'}
    [void][DateTimeOffset]::Parse($request.createdAtUtc)
    return $request
}
function Get-GMSteamObservation {
    param($Install,$Previous=$null,[DateTimeOffset]$Now=[DateTimeOffset]::UtcNow)
    $result=[pscustomobject]@{phase='unknown';progressPercent=$null;bytesDone=$null;bytesTotal=$null
        lastProgressAtUtc=(Get-GMInstallField $Previous 'lastProgressAtUtc' '');cursor=0;logIdentity='';partial=''
        errorCode='';detail='';gamePid=0;gamePath=''}
    try {
        if($Install.appId -ne 3513350 -or (Get-Item -LiteralPath $Install.manifestPath).Length -gt 2097152){throw 'Invalid manifest'}
        $parsed=ConvertFrom-GMValveKeyValues ([IO.File]::ReadAllText($Install.manifestPath));$app=Get-GMInstallField $parsed 'AppState' @{}
        if((Get-GMInstallField $app 'appid' '') -ne '3513350'){throw 'Wrong App ID'}
    } catch {$result.errorCode='STEAM_MANIFEST_INVALID';$result.detail='Steam manifest 不完整或不屬於鳴潮';return $result}
    $result.phase=Get-GMInstallField $Previous 'phase' 'unknown'
    try {
        $info=Get-Item -LiteralPath $Install.contentLogPath -ErrorAction Stop
        $result.logIdentity=$info.CreationTimeUtc.Ticks.ToString()
        $cursor=[long](Get-GMInstallField $Previous 'cursor' 0)
        if($null -eq $Previous){$cursor=$info.Length}
        elseif($cursor -gt $info.Length -or $result.logIdentity -ne (Get-GMInstallField $Previous 'logIdentity' '')){$cursor=0}
        $remaining=$info.Length-$cursor
        # Bound each sample. If far behind, skip to the recent tail, never replay a huge old Log.
        $skipFirst=$false
        if($remaining -gt 65536){$cursor=$info.Length-65536;$remaining=65536;$skipFirst=$true}
        $partial=if($cursor -eq (Get-GMInstallField $Previous 'cursor' -1) -and -not $skipFirst){[string](Get-GMInstallField $Previous 'partial' '')}else{''}
        $stream=[IO.File]::Open($info.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try{[void]$stream.Seek($cursor,[IO.SeekOrigin]::Begin);$data=[byte[]]::new([int]$remaining);$count=$stream.Read($data,0,$data.Length);$result.cursor=$cursor+$count}finally{$stream.Dispose()}
        $chunk=$partial+[Text.Encoding]::UTF8.GetString($data,0,$count)
        $lines=$chunk.Split("`n");$result.partial=$lines[$lines.Length-1]
        if($result.partial.Length -gt 4096){$result.partial=''}
        for($i=0;$i -lt $lines.Length-1;$i++){
            if($skipFirst -and $i -eq 0){continue};$line=$lines[$i]
            if($line -notmatch '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\].*\bAppID\s+3513350\b'){continue}
            $timestamp=[DateTimeOffset]([DateTime]::SpecifyKind([DateTime]::ParseExact($Matches[1],'yyyy-MM-dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture),[DateTimeKind]::Local))
            if(($Now-$timestamp).TotalSeconds -gt 60 -or ($timestamp-$Now).TotalSeconds -gt 5){continue}
            $phase=if($line -match '(?i)disk write|not enough disk|disk full|failed|error'){'error'}
                elseif($line -match '(?i)Fully Installed'){'update_ready'}
                elseif($line -match '(?i)Downloading'){'downloading'}
                elseif($line -match '(?i)Staging|Committing|Installing'){'installing'}
                elseif($line -match '(?i)Verifying|Validating'){'verifying'}
                elseif($line -match '(?i)Paused'){'paused_download'}
                elseif($line -match '(?i)Queued'){'queued'}else{''}
            if($phase){$result.phase=$phase;$result.lastProgressAtUtc=$Now.ToString('o')}
            if($phase -eq 'error'){$result.errorCode='STEAM_UPDATE_ERROR';$result.detail='Steam 記錄到目標遊戲更新錯誤'}
        }
    }catch{$result.detail='Steam 更新 Log 暫時不可讀；未以缺失 Log 宣告成功'}
    $keys=@(switch($result.phase){'downloading'{@('BytesDownloaded','BytesToDownload')};'installing'{@('BytesStaged','BytesToStage')};default{@()}})
    if($keys.Count -eq 2){
        $done=Get-GMInstallField $app $keys[0] '';$total=Get-GMInstallField $app $keys[1] ''
        if([string]$done -match '^\d{1,15}$' -and [string]$total -match '^\d{1,15}$' -and [long]$total -gt 0 -and [long]$done -le [long]$total){
            $result.bytesDone=[long]$done;$result.bytesTotal=[long]$total;$result.progressPercent=[Math]::Round(100.0*[long]$done/[long]$total,2)
            if($null -ne $Previous -and $result.bytesDone -ne (Get-GMInstallField $Previous 'bytesDone' $null)){$result.lastProgressAtUtc=$Now.ToString('o')}
        }
    }
    return $result
}
function Invoke-GMWorkerHttp {
    param([string]$Url,[int]$TimeoutMilliseconds=10000)
    if(-not (Test-GMNoticeUrl $Url)){throw 'Untrusted official URL'}
    $request=[Net.HttpWebRequest]::Create($Url);$request.AllowAutoRedirect=$false;$request.Timeout=$TimeoutMilliseconds
    $response=$null;$stream=$null;$memory=[IO.MemoryStream]::new();$timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        $task=$request.GetResponseAsync()
        while(-not $task.IsCompleted){
            if($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds -or -not (& $script:GMWorkerAlive)){throw 'Worker HTTP cancelled or timed out'}
            Start-Sleep -Milliseconds 100
        }
        $response=$task.GetAwaiter().GetResult()
        if([int]$response.StatusCode -ne 200 -or $response.ContentLength -gt 2097152){throw 'Invalid official response'}
        $stream=$response.GetResponseStream();$buffer=[byte[]]::new(16384)
        while($true){
            $read=$stream.ReadAsync($buffer,0,$buffer.Length)
            while(-not $read.IsCompleted){
                if($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds -or -not (& $script:GMWorkerAlive)){throw 'Worker HTTP cancelled or timed out'}
                Start-Sleep -Milliseconds 100
            }
            $count=$read.GetAwaiter().GetResult();if(-not $count){break}
            if($timer.ElapsedMilliseconds -ge $TimeoutMilliseconds -or $memory.Length+$count -gt 2097152){throw 'Official response exceeded budget'}
            $memory.Write($buffer,0,$count)
        }
        return [Text.Encoding]::UTF8.GetString($memory.ToArray())
    }finally{$request.Abort();if($stream){$stream.Dispose()};if($response){$response.Dispose()};$memory.Dispose()}
}
function Get-GMObservedGame {
    param($Install,[object[]]$Candidates)
    if(-not $Install -or -not $Install.gameRoot){return $null}
    try{$expected=Get-GMRealPath (Join-Path $Install.gameRoot 'Client\Binaries\Win64\Client-Win64-Shipping.exe')}catch{return $null}
    if(-not $PSBoundParameters.ContainsKey('Candidates')){$Candidates=@(Get-Process -Name 'Client-Win64-Shipping' -ErrorAction SilentlyContinue)}
    $found=@()
    foreach($process in $Candidates){
        try{if($expected -ieq (Get-GMRealPath $process.Path)){$found+=$process}}catch{}
    }
    if($found.Count -ne 1){return $null}
    return [pscustomobject]@{phase='game_running';gamePid=$found[0].Id;gamePath=$expected}
}
function ConvertTo-GMWorkerSnapshot {
    param($Request,[long]$Sequence,$Notice,$Install,$Observation,[DateTimeOffset]$Now)
    $record=Get-GMInstallField $Notice 'notice' $null
    $noticeFields=[ordered]@{outcome=(Get-GMInstallField $Notice 'outcome' 'pending');present=[int]($null -ne $record)
        checkedAtUtcMs='';errorCode=(Get-GMInstallField $Notice 'errorCode' '');detail=(Get-GMInstallField $Notice 'errorDetail' '')}
    $checked=Get-GMInstallField $Notice 'checkedAt' ''
    if($checked){$noticeFields.checkedAtUtcMs=([DateTimeOffset]$checked).ToUnixTimeMilliseconds()}
    if($record){
        $noticeFields.eventId=$record.eventId;$noticeFields.revision=$record.revisionHash;$noticeFields.gameVersion=$record.gameVersion
        $noticeFields.startsAtUtcMs=([DateTimeOffset]$record.startsAtUtc).ToUnixTimeMilliseconds()
        $noticeFields.expectedOpenAtUtcMs=([DateTimeOffset]$record.expectedOpenAtUtc).ToUnixTimeMilliseconds()
        $noticeFields.sourceUrl=$record.sourceUrl;$noticeFields.sourceState=$record.sourceState
        # Fresh source evidence and the ordinary post-deadline recheck are
        # separate: only the explicit event-scoped skip may relax the latter.
        $ageMs=if($checked){($Now-[DateTimeOffset]$checked).TotalMilliseconds}else{[double]::PositiveInfinity}
        $noticeFields.freshForRelease=[int]($Notice.outcome -eq 'ok' -and $checked -and $ageMs -ge -5000 -and $ageMs -le 900000)
    }
    $installation=[ordered]@{provider='unknown';updateAdapterReady=0}
    if($Install){foreach($key in @('provider','appId','gameRoot','launcherPath','fingerprint')){$installation[$key]=$Install.$key};$installation.evidence=$Install.evidence -join ';';$installation.checkedAtUtcMs=([DateTimeOffset]$Install.checkedAtUtc).ToUnixTimeMilliseconds()}
    $observationFields=[ordered]@{phase='unknown'}
    if($Observation){foreach($key in @('phase','bytesDone','bytesTotal','progressPercent','detail','errorCode','gamePid','gamePath')){$observationFields[$key]=$Observation.$key}
        if($Observation.lastProgressAtUtc){$observationFields.lastProgressAtUtcMs=([DateTimeOffset]$Observation.lastProgressAtUtc).ToUnixTimeMilliseconds()}}
    return [ordered]@{meta=[ordered]@{schemaVersion=1;marker='WUTHERING_GAME_MAINTENANCE_WORKER_V1';requestId=$Request.requestId;sequence=$Sequence;generation=$Request.generation;observedAtUtcMs=$Now.ToUnixTimeMilliseconds()}
        notice=$noticeFields;install=$installation;observation=$observationFields}
}
function Invoke-GMWorker {
    param([string]$RequestPath,[string]$OutputPath,[string]$StopPath,[string]$StateDirectory,[int]$ParentPid,[string]$ParentStartUtc)
    $session=Test-GMWorkerPaths $RequestPath $OutputPath $StopPath $StateDirectory
    # Override only this helper's environment, after canonical containment checks.
    # Do not read or fall back to the user's Windows temporary directory.
    foreach ($variableName in @('TEMP','TMP','TMPDIR')) {
        [Environment]::SetEnvironmentVariable($variableName, $session, 'Process')
    }
    [void][IO.Directory]::CreateDirectory($StateDirectory)
    $lock=$null
    # A just-exiting parent may need a short moment to release its one helper.
    # Still one exclusive lock; this never opens a second concurrent loop.
    for($attempt=0;$attempt -lt 8 -and -not $lock;$attempt++){
        if([IO.File]::Exists($StopPath) -or -not (Test-GMWorkerParent $ParentPid $ParentStartUtc)){return 0}
        try{$lock=[IO.File]::Open((Join-Path $StateDirectory 'worker.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
        catch{Start-Sleep -Milliseconds 250}
    }
    if(-not $lock){return 2}
    try {
        try{(Get-Process -Id $PID).PriorityClass='BelowNormal'}catch{}
        $script:GMWorkerAlive={-not [IO.File]::Exists($StopPath) -and (Test-GMWorkerParent $ParentPid $ParentStartUtc)}.GetNewClosure()
        $request=Read-GMWorkerRequest $RequestPath;$requestId=$request.requestId
        $timer=[Diagnostics.Stopwatch]::StartNew();$lastObserve=-5000;$lastNotice=-300000;$lastWrite=-30000;$lastForce=-60000
        $notice=$null;$install=$null;$observation=$null;$game=$null;$previousPayload='';$sequence=0;$entry='';$generation=-1;$lastForceId='0'
        while(& $script:GMWorkerAlive){
            try{$next=Read-GMWorkerRequest $RequestPath $requestId;if([long]$next.generation -ge [long]$request.generation){$request=$next}}catch{}
            if($entry -cne $request.launchEntry -or $generation -ne $request.generation){
                $entry=$request.launchEntry;$generation=$request.generation
                try{$inventory=Get-GMInstallInventory $entry;$install=Resolve-GMInstallEvidence $inventory.launchEntry $inventory}catch{$install=$null}
            }
            $now=[DateTimeOffset]::UtcNow
            $deadline=if($notice -and $notice.notice){([DateTimeOffset]$notice.notice.expectedOpenAtUtc).ToUnixTimeMilliseconds()}else{0}
            $forceId=[string](Get-GMInstallField $request 'refreshRequestId' '0')
            $checkedMs=if($notice -and $notice.checkedAt){([DateTimeOffset]$notice.checkedAt).ToUnixTimeMilliseconds()}else{0}
            $force=($deadline -gt 0 -and $now.ToUnixTimeMilliseconds() -ge $deadline -and $checkedMs -lt $deadline) -or $forceId -ne $lastForceId
            if($request.mode -ne 'install' -and (Test-GMWorkerNoticeDue $timer.ElapsedMilliseconds $lastNotice $lastForce $forceId $lastForceId $force)){
                $lastNotice=$timer.ElapsedMilliseconds;if($force){$lastForce=$lastNotice}
                $lastForceId=$forceId
                $previous=if($notice){$notice.notice}else{$null}
                if(-not $previous){
                    $pinned=[string](Get-GMInstallField $request 'pinnedEventId' '')
                    if($pinned){$cached=Read-GMNoticeCache $StateDirectory;if($cached){$previous=@($cached.notices | Where-Object {$_.eventId -ceq $pinned}) | Select-Object -First 1}}
                }
                $notice=Get-GMOfficialNotice -CacheDirectory $StateDirectory -Now $now -Force $force -Previous $previous -HttpGetter ${function:Invoke-GMWorkerHttp}
                if(-not (& $script:GMWorkerAlive)){break}
            }
            if($timer.ElapsedMilliseconds-$lastObserve -ge 5000){
                $lastObserve=$timer.ElapsedMilliseconds
                if($install -and $install.provider -eq 'steam'){$observation=Get-GMSteamObservation $install $observation $now}
                $game=if($request.mode -eq 'observe'){Get-GMObservedGame $install}else{$null}
            }
            $snapshot=ConvertTo-GMWorkerSnapshot $request ($sequence+1) $notice $install $observation ([DateTimeOffset]::UtcNow)
            if($request.mode -eq 'observe'){
                if($game){$snapshot.observation.phase=$game.phase;$snapshot.observation.gamePid=$game.gamePid;$snapshot.observation.gamePath=$game.gamePath}
            }
            $payload=@($snapshot.notice,$snapshot.install,$snapshot.observation,$request.generation)|ConvertTo-Json -Depth 5 -Compress
            if($payload -cne $previousPayload -or $timer.ElapsedMilliseconds-$lastWrite -ge 30000){
                Write-GMSnapshot $OutputPath $snapshot $session;$sequence++;$previousPayload=$payload;$lastWrite=$timer.ElapsedMilliseconds
            }
            Start-Sleep -Milliseconds 250
        }
        return 0
    }finally{$lock.Dispose()}
}
function Test-GMWorkerNoticeDue {
    param([long]$Elapsed,[long]$LastNotice,[long]$LastForce,[string]$ForceId,[string]$LastForceId,[bool]$DeadlineDue)
    if($Elapsed-$LastNotice -ge 300000){return $true}
    return ($DeadlineDue -or $ForceId -cne $LastForceId) -and $Elapsed-$LastForce -ge 60000
}
if($MyInvocation.InvocationName -ne '.') {
    try{exit (Invoke-GMWorker -RequestPath $RequestPath -OutputPath $OutputPath -StopPath $StopPath -StateDirectory $StateDirectory -ParentPid $ParentPid -ParentStartUtc $ParentStartUtc)}
    catch{[Console]::Error.WriteLine('Maintenance worker failed: '+$_.Exception.Message);exit 1}
}
