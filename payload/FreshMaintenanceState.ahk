#Requires AutoHotkey v2.0+
#Include GameMaintenance.ahk

FMS_ArchiveAndReset(root) {
    ; Caller owns both installation reservations and has verified that the old
    ; main, gameplay children, and native worker have all exited.
    path := root "\config\game-maintenance\state.ini"
    if !FileExist(path) && !FileExist(path ".bak")
        return true
    prior := GM_LoadJournal(path), saved := Map()
    for candidate in [path,path ".bak"]
        if FileExist(candidate)
            saved[candidate] := FileRead(candidate,"UTF-8")
    archive := root "\執行暫存\fresh-start-history\maintenance-" A_Now "-" DllCall("GetCurrentProcessId") "-" Random(1,2147483647)
    for candidate,content in saved {
        SplitPath(candidate,&name)
        GM_AtomicText(archive "\" name,content)
        if FileRead(archive "\" name,"UTF-8") != content
            throw Error("舊維護狀態歸檔回讀失敗")
    }
    next := GM_DefaultState(), next.phase := "NORMAL"
    next.notificationKeys := prior.notificationKeys
    nowMs := DateDiff(A_NowUTC,"19700101000000","Seconds") * 1000
    ; Keep current official notice evidence and mail deduplication; only the
    ; abandoned action/PAUSE/attempt is historical, not today's maintenance.
    if prior.expectedOpenAt > 0 && Floor((prior.expectedOpenAt+28800000-1)/86400000) >= Floor((nowMs+28800000)/86400000)
        for field in ["eventId","revision","gameVersion","sourceUrl","startsAt","expectedOpenAt","notifiedOpenAt"]
            next.%field% := prior.%field%
    GM_SaveJournal(archive "\fresh-state.ini",next)
    fresh := FileRead(archive "\fresh-state.ini","UTF-8")
    for candidate in [path,path ".bak"] {
        if !!FileExist(candidate) != saved.Has(candidate)
            throw Error("重設前維護狀態已變更")
        if saved.Has(candidate) && FileRead(candidate,"UTF-8") != saved[candidate]
            throw Error("重設前維護狀態內容已變更")
    }
    ; Both recovery copies now describe the new cycle, never the old action.
    GM_AtomicText(path ".bak",fresh)
    GM_AtomicText(path,fresh)
    if FileRead(path,"UTF-8") != fresh || FileRead(path ".bak","UTF-8") != fresh
        throw Error("全新維護狀態回讀未確認")
    GM_AtomicText(archive "\reset-complete.txt","fresh-launch | " A_Now)
    return true
}
