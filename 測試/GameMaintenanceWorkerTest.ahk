#Requires AutoHotkey v2.0
#Include GameMaintenanceFixtures.ahk
#Include ..\payload\GameMaintenance.ahk

GMTest_Run(TestWorkerProtocol)
TestWorkerProtocol() {
    root := TestRuntime_NewCaseDir("maintenance-worker")
    path := root "\snapshot.ini"
    text := "[meta]`nschemaVersion=1`nmarker=WUTHERING_GAME_MAINTENANCE_WORKER_V1`nrequestId=fixture-1`nsequence=2`ngeneration=3`nobservedAtUtcMs=100000`n"
        . "[notice]`noutcome=ok`npresent=0`n[install]`nprovider=unknown`n[observation]`nphase=unknown`ndetail=等待官方公告；不啟動遊戲`n"
    FileAppend(text, path, "UTF-8")
    got := GM_ReadWorkerSnapshot(path, "fixture-1", 1, 100001, root)
    GMTest_Assert(got["meta"]["sequence"] = 2, "valid sequence")
    GMTest_Assert(got["observation"]["detail"] = "等待官方公告；不啟動遊戲", "UTF8 Chinese preserved")
    GMTest_Assert(got["observation"]["progressPercent"] = "", "unknown progress not zero")
    for args in [["old", 1, 100001, root], ["fixture-1", 2, 100001, root], ["fixture-1", 1, 160001, root], ["fixture-1", 1, 94999, root], ["fixture-1", 1, 100001, root "\outside"]] {
        rejected := false
        try GM_ReadWorkerSnapshot(path, args[1], args[2], args[3], args[4])
        catch
            rejected := true
        GMTest_Assert(rejected, "forged/stale snapshot rejected")
    }
    for extra in ["[meta]`nsequence=3", "[injected]`nphase=READY", "[install]`nprovider=kuro", "phase=game_ready", "garbage", "errorCode=" Chr(1)] {
        FileDelete(path)
        FileAppend(text extra "`n", path, "UTF-8")
        rejected := false
        try GM_ReadWorkerSnapshot(path, "fixture-1", 1, 100001, root)
        catch
            rejected := true
        GMTest_Assert(rejected, "malformed snapshot rejected: " extra)
    }
    FileDelete(path)
    FileAppend(StrReplace(text, "present=0", "present=1"), path, "UTF-8")
    rejected := false
    try GM_ReadWorkerSnapshot(path, "fixture-1", 1, 100001, root)
    catch
        rejected := true
    GMTest_Assert(rejected, "partial known notice must not release gate")
}
