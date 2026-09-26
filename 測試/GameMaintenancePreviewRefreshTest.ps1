$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root=Split-Path $PSScriptRoot -Parent
$context=Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'gm-preview-refresh'
try {
    $source=[IO.File]::ReadAllText((Join-Path $root 'payload\GameMaintenanceHost.ahk'))
    $functions=@()
    foreach($name in @('GMHost_RefreshPublicNotice','GMHost_PollNoticePreview','GMHost_StopNoticePreview','GMHost_OwnsNoticePreview')) {
        $match=[regex]::Match($source,'(?ms)^'+$name+'\([^\r\n]*\) \{.*?(?=^\w+\([^\r\n]*\) \{|\z)')
        Assert-GMTrue $match.Success ('Missing read-only notice refresh: '+$name)
        $functions+=$match.Value
    }
    . (Join-Path $root 'payload\GameMaintenanceWorker.ps1')
    $session=Join-Path $context.RunRoot 'fixture'
    [void][IO.Directory]::CreateDirectory($session)
    $snapshotPath=Join-Path $session 'snapshot.ini'
    $now=[DateTimeOffset]'2026-09-26T00:00:00Z'
    $notice=[pscustomobject]@{outcome='ok';notice=$null;checkedAt=$now.ToString('o');upcomingNotice=[pscustomobject]@{
        eventId='wuthering-global-3.7-1790712000';gameVersion='3.7';startsAtUtc='2026-09-29T20:00:00Z';expectedOpenAtUtc='2026-09-30T03:00:00Z';
        sourceUrl='https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5474'}}
    $snapshot=ConvertTo-GMWorkerSnapshot @{requestId='preview';generation=1} 1 $notice $null $null $now
    Write-GMSnapshot $snapshotPath $snapshot $session
    $notice.notice=[pscustomobject]@{eventId='wuthering-global-3.6-today';gameVersion='3.6';revisionHash=('a'*64);sourceState='official';startsAtUtc='2026-09-25T20:00:00Z';expectedOpenAtUtc='2026-09-26T03:00:00Z';sourceUrl='https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/5474'}
    $todayPath=Join-Path $session 'today-and-future.ini'
    Write-GMSnapshot $todayPath (ConvertTo-GMWorkerSnapshot @{requestId='preview';generation=1} 1 $notice $null $null $now) $session
    $unavailablePath=Join-Path $session 'unavailable.ini'
    Write-GMSnapshot $unavailablePath (ConvertTo-GMWorkerSnapshot @{requestId='preview';generation=1} 1 ([pscustomobject]@{outcome='unavailable';errorCode='SOURCE_UNAVAILABLE'}) $null $null $now) $session
    $testPath=Join-Path $session 'preview-host.ahk'
    $extracted=($functions -join "`n").Replace('GM_ReadWorkerSnapshot(probe.worker.outputPath,probe.worker.requestId,0,RC_UnixMs(),probe.worker.session)','TEST_ReadSnapshot(probe)')
    [IO.File]::WriteAllText($testPath,@"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
#Include $root\payload\GameMaintenance.ahk
global TEST_STARTS := 0, TEST_STOPS := 0, TEST_TICK := 100000, TEST_PATH := "$snapshotPath"
global GM_CONTROLLER := 0, TEST_CANCEL_START := false, TEST_CANCEL_READ := false, TEST_LAST_PROBE := 0
GMTest_Run(TestRefresh)
TestRefresh() {
    global TEST_STARTS, TEST_STOPS, TEST_TICK, TEST_PATH, GM_CONTROLLER, TEST_CANCEL_START, TEST_CANCEL_READ, TEST_LAST_PROBE
    cfg := "$session\config.ini"
    c := {state:GM_DefaultState(),active:false,cfgPath:cfg,launchEntry:"fixture.exe",lastSettingsRefresh:"old",lastInput:{noticeState:"valid",noticeCheckedAt:1}}
    c.state.phase := "NORMAL"
    GM_CONTROLLER := c
    IniWrite("new",cfg,"game_maintenance","refresh_request_id")
    try {
        GMHost_RefreshPublicNotice(c)
        GMTest_Assert(TEST_STARTS = 1 && c.noticePreview.workerMode = "notice", "explicit request starts one display-only helper")
        GMTest_Assert(c.lastInput.noticeState = "pending", "query is not marked successful before snapshot")
        GMHost_RefreshPublicNotice(c)
        GMTest_Assert(TEST_STARTS = 1, "same request cannot start duplicate helper")
        GMHost_PollNoticePreview(c,c.noticePreview)
        GMTest_Assert(c.lastInput.upcomingNotice.gameVersion = "3.7" && c.lastInput.noticeCheckedAt = 1790380800000, "completed query refreshes retained public information")
        GMTest_Assert(TEST_STOPS = 1 && !IsObject(c.noticePreview), "completed helper is stopped, no permanent polling")
        GMTest_Assert(c.state.phase = "NORMAL" && c.state.eventId = "" && c.state.actionId = "", "refresh never pins event or changes farming policy")
        GMHost_RefreshPublicNotice(c)
        GMTest_Assert(TEST_STARTS = 1, "applied refresh identity remains consumed")
        IniWrite("timeout",cfg,"game_maintenance","refresh_request_id")
        TEST_TICK += 60001, TEST_PATH := "$session\missing.ini"
        GMHost_RefreshPublicNotice(c)
        TEST_TICK += 30001
        GMHost_PollNoticePreview(c,c.noticePreview)
        GMTest_Assert(c.lastInput.noticeState = "unavailable" && c.lastInput.upcomingNotice.gameVersion = "3.7", "timeout retains prior announcement with failed state")
        GMTest_Assert(c.lastInput.noticeCheckedAt = 1790380800000 && TEST_STOPS = 2, "timeout cannot refresh timestamp and closes only owned helper")
        IniWrite("today",cfg,"game_maintenance","refresh_request_id")
        TEST_TICK += 60001, TEST_PATH := "$todayPath"
        GMHost_RefreshPublicNotice(c)
        GMHost_PollNoticePreview(c,c.noticePreview)
        GMTest_Assert(c.lastInput.upcomingNotice.gameVersion = "3.6", "today notice has display priority over another future announcement")
        GMTest_Assert(c.state.eventId = "" && c.state.phase = "NORMAL", "current-day passive display does not take over farming")
        IniWrite("cancel-start",cfg,"game_maintenance","refresh_request_id")
        TEST_TICK += 60001, TEST_CANCEL_START := true
        GMHost_RefreshPublicNotice(c)
        GMTest_Assert(!IsObject(c.noticePreview) && !IsObject(GM_Value(TEST_LAST_PROBE,"timer",0)), "cancellation during startup cannot arm a permanent orphan timer")
        GMTest_Assert(TEST_STOPS = 4, "cancelled helper receives only one stop signal")
        stale := TEST_LAST_PROBE
        IniWrite("cancel-read",cfg,"game_maintenance","refresh_request_id")
        TEST_TICK += 60001, TEST_CANCEL_START := false, TEST_PATH := "$snapshotPath"
        GMHost_RefreshPublicNotice(c)
        current := c.noticePreview
        GMHost_PollNoticePreview(c,stale)
        GMTest_Assert(c.noticePreview = current && TEST_STOPS = 4, "stale callback cannot dispose a newer owned probe")
        TEST_CANCEL_READ := true
        GMHost_PollNoticePreview(c,current)
        GMTest_Assert(c.lastInput.upcomingNotice.gameVersion = "3.6" && !IsObject(c.noticePreview), "cancellation during snapshot IO prevents late status commit")
        IniWrite("no-cache",cfg,"game_maintenance","refresh_request_id")
        TEST_TICK += 60001, TEST_CANCEL_READ := false, TEST_PATH := "$unavailablePath"
        GMHost_RefreshPublicNotice(c)
        GMHost_PollNoticePreview(c,c.noticePreview)
        GMTest_Assert(c.lastInput.noticeState = "unavailable" && c.lastInput.upcomingNotice.gameVersion = "3.6" && c.lastInput.noticeCheckedAt = 1790380800000, "failed response without disk cache retains last known evidence")
        c.state.cancelled := true
        IniWrite("after-stop",cfg,"game_maintenance","refresh_request_id")
        TEST_TICK += 60001
        GMHost_RefreshPublicNotice(c)
        GMTest_Assert(TEST_STARTS = 6, "STOP cannot launch a background refresh")
        c.state.cancelled := false, GM_CONTROLLER := {state:GM_DefaultState(),active:false}
        GMHost_RefreshPublicNotice(c)
        GMTest_Assert(TEST_STARTS = 6, "replaced controller cannot launch a stale preview")
    } finally GMHost_StopNoticePreview(c)
}
GMHost_StartWorker(probe) {
    global TEST_STARTS, TEST_PATH, TEST_CANCEL_START, TEST_LAST_PROBE, GM_CONTROLLER
    TEST_STARTS += 1
    probe.worker := {outputPath:TEST_PATH,requestId:"preview",session:"$session",pid:1}
    worker := probe.worker, TEST_LAST_PROBE := probe
    if TEST_CANCEL_START
        GMHost_StopNoticePreview(GM_CONTROLLER)
    return worker
}
TEST_ReadSnapshot(probe) {
    global TEST_CANCEL_READ, GM_CONTROLLER
    snapshot := GM_ReadWorkerSnapshot(probe.worker.outputPath,probe.worker.requestId,0,RC_UnixMs(),probe.worker.session)
    if TEST_CANCEL_READ
        GMHost_StopNoticePreview(GM_CONTROLLER)
    return snapshot
}
GMHost_StopWorker(worker) {
    global TEST_STOPS
    TEST_STOPS += 1
}
GMHost_WorkerAlive(worker) => true
MonotonicTickMs() {
    global TEST_TICK
    return TEST_TICK
}
RC_UnixMs() => 1790380800000
IniReadSafe(file,section,key,fallback) => IniRead(file,section,key,fallback)
WriteLog(args*) => 0
$extracted
"@,[Text.UTF8Encoding]::new($true))
    $result=Invoke-GMTestProcess $testPath $context 20
    Assert-GMEqual $result.ExitCode 0 ('read-only refresh lifecycle: '+$result.Stdout+$result.Stderr)
    Write-Output $result.Stdout.TrimEnd()
} finally {Complete-ProjectDevelopmentPaths -Context $context}
