#Requires AutoHotkey v2.0+
#SingleInstance Off
#NoTrayIcon
#Include ..\payload\FreshMaintenanceState.ahk

Check(value,message) {
    if !value
        throw Error(message)
}
root := A_ScriptDir "\..\.dev-runtime\diagnostics\game-maintenance\20261025-fresh-start-takeover\maintenance-" A_Now "-" DllCall("GetCurrentProcessId")
try {
    nowMs := DateDiff(A_NowUTC,"19700101000000","Seconds") * 1000
    for index,phase in ["UPDATING","NEEDS_ATTENTION","WAIT_SERVER","STOPPED"] {
        install := root "\case-" index, path := install "\config\game-maintenance\state.ini"
        prior := GM_DefaultState(), prior.phase := phase, prior.provider := "kuro"
        prior.actionId := "old-attempt", prior.actionStage := "observed", prior.f11InputAttempted := true
        prior.desiredState := "PAUSE", prior.targetServer := "Asia", prior.runCycle := "old-day"
        prior.notificationKeys := "mail-dedupe", prior.eventId := "official-current", prior.gameVersion := "3.8"
        prior.expectedOpenAt := nowMs + 60000
        GM_SaveJournal(path,prior), GM_SaveJournal(path,prior)
        before := FileRead(path,"UTF-8")
        Check(FMS_ArchiveAndReset(install),"fresh archive/reset succeeds for " phase)
        after := GM_LoadJournal(path)
        Check(!GM_HasActiveContinuation(after,nowMs),"old phase cannot force fresh into continuation")
        Check(after.actionId = "" && !after.f11InputAttempted && after.runCycle = "","old action attempts are not inherited")
        Check(after.notificationKeys = "mail-dedupe" && after.eventId = "official-current" && after.expectedOpenAt = prior.expectedOpenAt,"current official notice and mail history survive reset")
        Check(FileRead(path,"UTF-8") = FileRead(path ".bak","UTF-8"),"backup cannot resurrect old active action")
        archives := 0
        Loop Files, install "\執行暫存\fresh-start-history\state.ini", "FR" {
            Check(FileRead(A_LoopFileFullPath,"UTF-8") = before,"exact old maintenance evidence remains in history")
            archives += 1
        }
        Check(archives = 1,"exactly one old maintenance snapshot")
    }
    install := root "\past", path := install "\config\game-maintenance\state.ini"
    prior := GM_DefaultState(), prior.eventId := "outdated-version", prior.expectedOpenAt := nowMs - 172800000
    GM_SaveJournal(path,prior)
    Check(FMS_ArchiveAndReset(install) && GM_LoadJournal(path).eventId = "","past version does not pin the new run")
    install := root "\write-failure", path := install "\config\game-maintenance\state.ini"
    GM_SaveJournal(path,prior), before := FileRead(path,"UTF-8")
    DirCreate(install "\執行暫存")
    FileAppend("block",install "\執行暫存\fresh-start-history")
    denied := false
    try FMS_ArchiveAndReset(install)
    catch
        denied := true
    Check(denied && FileRead(path,"UTF-8") = before,"archive failure never erases the only old state")
    install := root "\corrupt", path := install "\config\game-maintenance\state.ini"
    DirCreate(install "\config\game-maintenance")
    FileAppend("broken",path,"UTF-8-RAW"), denied := false
    try FMS_ArchiveAndReset(install)
    catch
        denied := true
    Check(denied && FileRead(path,"UTF-8") = "broken","invalid journal remains fail-closed, not silently discarded")
    FileAppend("PASS real fresh maintenance state, official notice preservation, recovery copy, archive failure and corrupt journal gates`n","*")
} catch as err {
    FileAppend(err.Message "`n" err.Stack,"**")
    ExitApp(1)
}
ExitApp(0)
