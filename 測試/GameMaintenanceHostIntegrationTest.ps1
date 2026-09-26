$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'gm-host-integration'
try {
    . (Join-Path $root 'payload\GameMaintenanceWorker.ps1')
    $session=Join-Path $context.RunRoot 'fixture'
    [IO.Directory]::CreateDirectory($session) | Out-Null
    $snapshotPath=Join-Path $session 'snapshot.ini'
    $now=[DateTimeOffset]::FromUnixTimeMilliseconds(10000)
    $notice=[pscustomobject]@{outcome='ok';checkedAt=$now.ToString('o');errorCode='';errorDetail='';notice=[pscustomobject]@{
        eventId='fixture-global-1';revisionHash='r1';gameVersion='9.9';startsAtUtc=[DateTimeOffset]::FromUnixTimeMilliseconds(1000).ToString('o');expectedOpenAtUtc=$now.ToString('o');sourceUrl='https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/1';sourceState='verified'}}
    $install=[pscustomobject]@{provider='kuro';appId=0;gameRoot=$session;launcherPath=(Join-Path $session 'launcher.exe');fingerprint='fixture';evidence=@('installation-files-verified');checkedAtUtc=$now.ToString('o')}
    $observation=[pscustomobject]@{phase='game_running';gamePid=44;gamePath=(Join-Path $session 'Client\Binaries\Win64\Client-Win64-Shipping.exe');bytesDone='';bytesTotal='';progressPercent='';detail='';errorCode='';lastProgressAtUtc=''}
    $snapshot=ConvertTo-GMWorkerSnapshot @{requestId='integration';generation=1} 1 $notice $install $observation $now
    Write-GMSnapshot $snapshotPath $snapshot $session
    $source=[IO.File]::ReadAllText((Join-Path $root 'payload\GameMaintenanceHost.ahk'))
    $functions=@()
    foreach($name in @('GM_Init','GMHost_ReadInput','GM_MarkF11Attempt','GMHost_ScheduleKey','GM_WaitForLoginGate','GM_PrepareOkwwEntry')) {
        $match=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)')
        if(-not $match.Success){throw "Missing host function: $name"}
        $functions+=$match.Value
    }
    $extracted=$functions -join "`n"
    $testPath=Join-Path $context.RunRoot 'host-integration.ahk'
    $harness=@"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
#Include $root\payload\GameMaintenance.ahk
global GM_CONTROLLER := 0, GM_ROOT := "$session", GM_NOW := 200000000, RC_LAST_NONCE := 1
global GM_PAUSE := false, GM_CYCLE := "fixture", GM_OKWW_KEY := "44|100|12|fixture", GM_OBSERVES := 0, GM_GAME_HWND := 12
GMTest_Run(TestActualHostInput)
TestActualHostInput() {
    global GM_CONTROLLER, GM_NOW, GM_ROOT, GM_PAUSE, GM_CYCLE, GM_OKWW_KEY, GM_OBSERVES, GM_GAME_HWND
    cfg := GM_ROOT "\config.ini"
    old := GM_CopyState(GMTest_State()), old.expectedOpenAt := 10000
    GM_SaveJournal(GM_ROOT "\state.ini",old)
    c := GM_Init(cfg,"fixture.exe",{isRestart:false,isNextServerCycle:false,targetServer:"HMT"})
    GMTest_Assert(c.state.eventId = "","actual host startup supplies UTC and expires old no-action event")
    old.actionId := "durable-intent", old.actionStage := "intent"
    GM_SaveJournal(GM_ROOT "\state.ini",old)
    c := GM_Init(cfg,"fixture.exe",{isRestart:true,isNextServerCycle:false,targetServer:"HMT"})
    GMTest_Assert(c.state.actionId = "durable-intent","old action intent remains protected")
    GM_NOW := 10000
    c.snapshot := GM_ReadWorkerSnapshot("$snapshotPath","integration",0,GM_NOW,GM_ROOT)
    c.observation := {phase:"unknown",observedAt:GM_NOW,identityVerified:false}
    c.snapshot["notice"]["upcomingEventId"] := "preview-only", c.snapshot["notice"]["upcomingGameVersion"] := "3.7"
    c.snapshot["notice"]["upcomingStartsAtUtcMs"] := "1790712000000", c.snapshot["notice"]["upcomingExpectedOpenAtUtcMs"] := "1790737200000"
    c.snapshot["notice"]["upcomingSourceUrl"] := "https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5474"
    hostInput := GMHost_ReadInput(c)
    GMTest_Assert(hostInput.upcomingNotice.gameVersion = "3.7" && hostInput.notice.eventId = "fixture-global-1","actual host retains preview independently from active notice")
    GMTest_Assert(GMHost_ReadInput(c).observation.phase = "game_running","actual host: launcher unknown cannot mask verified worker game")
    c.observation := {phase:"update_ready",observedAt:GM_NOW,identityVerified:true}
    GMTest_Assert(GMHost_ReadInput(c).observation.phase = "game_running","actual host: old play button cannot mask launched game")
    c.observation := {phase:"maintenance",observedAt:GM_NOW,identityVerified:true,confirmed:true}
    GMTest_Assert(GMHost_ReadInput(c).observation.phase = "maintenance","verified in-game maintenance retains priority")
    c.observation := {phase:"game_ready",observedAt:GM_NOW,identityVerified:false,stable:true}
    GMTest_Assert(GMHost_ReadInput(c).observation.phase = "game_running","unverified local main screen cannot replace process evidence")
    c.snapshot["notice"]["checkedAtUtcMs"] := "", c.snapshot["notice"]["present"] := "0", c.snapshot["notice"]["outcome"] := "unavailable"
    GMTest_Assert(GMHost_ReadInput(c).noticeCheckedAt = 0,"source outage with no cached timestamp is valid unknown input")
    c.snapshot := GM_ReadWorkerSnapshot("$snapshotPath","integration",0,GM_NOW,GM_ROOT)
    c.state := GM_CopyState(GMTest_State()), c.state.actionId := "fixture-action", c.state.actionStage := "observed"
    c.clockUnstableAt := 0, c.lastUtcMs := GM_NOW, c.managed := true, c.loginScheduleKey := "fixture|Asia", c.observation := 0
    c.snapshot["notice"]["expectedOpenAtUtcMs"] := "20000", c.snapshot["notice"]["revision"] := "r2"
    GMTest_Assert(!GM_MarkF11Attempt(12) && c.f11GateBlocked && !c.state.f11InputAttempted,"actual final input guard blocks extension after handoff before durable key intent")
    c.snapshot := GM_ReadWorkerSnapshot("$snapshotPath","integration",0,GM_NOW,GM_ROOT)
    GM_PAUSE := true
    GMTest_Assert(!GM_MarkF11Attempt(12) && c.f11GateBlocked,"actual final input guard honors latest PAUSE")
    GM_PAUSE := false, GM_CYCLE := "next-cycle"
    GMTest_Assert(!GM_MarkF11Attempt(12) && c.f11GateBlocked,"actual final input guard requires cross-day reconciliation")
    GM_CYCLE := "fixture", c.clockUnstableAt := GM_NOW + 1
    GMTest_Assert(!GM_MarkF11Attempt(12) && c.f11GateBlocked,"actual final input guard honors clock recheck")
    c.clockUnstableAt := 0
    GM_GAME_HWND := 0
    GMTest_Assert(!GM_MarkF11Attempt(12) && c.f11GateBlocked,"actual final guard rejects vanished selected game despite cached worker process evidence")
    GM_GAME_HWND := 12
    GMTest_Assert(GM_MarkF11Attempt(12),"actual final input guard durably records permitted attempt")
    saved := GM_LoadJournal(c.journalPath)
    GMTest_Assert(saved.f11InputAttempted && saved.f11OkwwIdentity = GM_OKWW_KEY,"exact original OKWW identity survives restart")
    GMTest_Assert(!GM_MarkF11Attempt(12),"actual final input guard cannot duplicate persisted attempt")
    c.worker := {pid:1,outputPath:GM_ROOT "\missing-snapshot.ini"}, c.workerFailure := "", c.loadError := ""
    c.observation := {phase:"game_ready",stable:true,identityVerified:true,observedAt:GM_NOW}
    GMTest_Assert(GM_PrepareOkwwEntry() = "resumed" && GM_OBSERVES = 1,"actual host returns distinct resume before manager startup")
    c.state.cancelled := true
    GMTest_Assert(GM_PrepareOkwwEntry() = "stop","STOP wins over resume")
    mainSource := FileRead("$root\payload\全自動.ahk","UTF-8")
    begin := InStr(mainSource,"StartOKWWFlowWithLocalRecovery(isRestart, entryStage :=")
    GMTest_Assert(InStr(mainSource,"maintenanceEntry := GM_PrepareOkwwEntry()",false,begin) < InStr(mainSource,"firstResult := StartOKWWFlow(isRestart)",false,begin),"production manager starts only after distinct resume gate")
}
RC_UnixMs() {
    global GM_NOW
    return GM_NOW
}
MonotonicTickMs() => 100
GetCurrentServerCycleKey() {
    global GM_CYCLE
    return GM_CYCLE
}
RuntimeFiles_GameMaintenanceDir() {
    global GM_ROOT
    return GM_ROOT
}
RC_IsPaused() {
    global GM_PAUSE
    return GM_PAUSE
}
GetInteractiveDesktopState() => {ok:true}
IniReadSafe(file,section,key,fallback) => IniRead(file,section,key,fallback)
GMHost_StartWorker(args*) => 0
GMHost_WorkerAlive(args*) => true
GMHost_StopWorker(args*) => 0
GMHost_ApplyEffect(args*) => 0
GMHost_Publish(args*) => 0
GMHost_StopRecording(args*) => 0
GMHost_ReconcileSchedule(args*) => {runCycle:"fixture",targetServer:"Asia",allCompleted:false}
GMHost_RestoreScheduledTarget(args*) => true
GMHost_WriteRequest(args*) => 0
GMHost_AdapterAccepted(args*) => false
GMHost_OkwwIdentity(args*) {
    global GM_OKWW_KEY
    return GM_OKWW_KEY
}
GMHost_GetManagedGameHwnd() {
    global GM_GAME_HWND
    return GM_GAME_HWND
}
IsLoginScreenByOcr(args*) => false
TrySelectScheduledServer(args*) => false
WaitEscMenuOCR(args*) => false
GMHost_ObserveWaitingGame() {
    global GM_OBSERVES
    GM_OBSERVES += 1
}
FindBestOkwwFinalWindow(&title,a,b,d,&count) {
    count := 1
    return 12
}
WriteLog(args*) => 0
$extracted
"@
    [IO.File]::WriteAllText($testPath,$harness,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $testPath $context 20
    if($result.Stdout){Write-Output $result.Stdout}
    if($result.Stderr){Write-Output $result.Stderr}
    Assert-GMEqual $result.ExitCode 0 'actual snapshot to host, expiry and observation precedence'
} finally {Complete-ProjectDevelopmentPaths -Context $context}
