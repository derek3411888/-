#Requires AutoHotkey v2.0
#Include GameUpdateAdapters.ahk

MPG_CanonicalPath(path) {
    try {
        if RegExMatch(path,"i)\.lnk$")
            FileGetShortcut(path,&path)
    } catch
        return ""
    handle := DllCall("CreateFileW","str",path,"uint",0,"uint",7,"ptr",0,"uint",3,"uint",0x02000000,"ptr",0,"ptr")
    if !handle || handle = -1
        return ""
    try {
        pathBuffer := Buffer(65536)
        count := DllCall("GetFinalPathNameByHandleW","ptr",handle,"ptr",pathBuffer,"uint",32768,"uint",0,"uint")
        if !count || count >= 32768
            return ""
        value := StrGet(pathBuffer)
        if SubStr(value,1,8) = "\\?\UNC\"
            return "\\" SubStr(value,9)
        return SubStr(value,1,4) = "\\?\" ? SubStr(value,5) : value
    } finally DllCall("CloseHandle","ptr",handle)
}

MPG_ReadRecord(pid,expectedPath := "") {
    if !IsNumber(pid) || pid <= 0 || pid = DllCall("GetCurrentProcessId","uint")
        return 0
    expected := expectedPath = "" ? "" : MPG_CanonicalPath(expectedPath)
    if expectedPath != "" && expected = ""
        return 0
    handle := DllCall("OpenProcess","uint",0x1000,"int",false,"uint",pid,"ptr")
    if !handle
        return 0
    try {
        record := MPG_ReadHandleRecord(handle,pid)
        if !IsObject(record) || (expected != "" && StrLower(record.path) != StrLower(expected))
            return 0
        return record
    } finally DllCall("CloseHandle","ptr",handle)
}

MPG_ReadHandleRecord(handle,pid) {
    pathBuffer := Buffer(65536), chars := 32768
    if !DllCall("QueryFullProcessImageNameW","ptr",handle,"uint",0,"ptr",pathBuffer,"uint*",&chars)
        return 0
    created := Buffer(8), exited := Buffer(8), kernel := Buffer(8), userTime := Buffer(8)
    if !DllCall("GetProcessTimes","ptr",handle,"ptr",created,"ptr",exited,"ptr",kernel,"ptr",userTime)
        return 0
    actual := MPG_CanonicalPath(StrGet(pathBuffer,chars,"UTF-16"))
    started := NumGet(created,0,"Int64")
    if actual = "" || started <= 0
        return 0
    return {pid:pid,path:actual,started:String(started)}
}

MPG_CloseRecord(record, mayTerminate := 0) {
    if !IsObject(record) || !IsNumber(GM_Value(record,"pid","")) || GM_Value(record,"pid",0) <= 0
        || GM_Value(record,"path","") = "" || GM_Value(record,"started","") = ""
        return false
    if record.pid = DllCall("GetCurrentProcessId","uint")
        return false
    if !ProcessExist(record.pid)
        return true
    ; Query and terminate the same kernel object; never reacquire by PID after
    ; validation. Access denied is a failure, not an invitation to elevate.
    handle := DllCall("OpenProcess","uint",0x1000 | 0x0001 | 0x00100000,"int",false,"uint",record.pid,"ptr")
    if !handle
        return !ProcessExist(record.pid)
    try {
        current := MPG_ReadHandleRecord(handle,record.pid)
        if !GMU_ProcessIdentityMatches(current,record.pid,record.path,record.started)
            return false
        ; Inventory and handle identity reads stay interruptible. Only the final
        ; in-memory intent check and termination share this short atomic region.
        previousCritical := A_IsCritical
        try {
            if IsObject(mayTerminate) {
                Critical("On")
                if !mayTerminate.Call()
                    return false
            }
            if !DllCall("TerminateProcess","ptr",handle,"uint",0)
                return false
        } finally {
            if IsObject(mayTerminate)
                Critical(previousCritical)
        }
        return DllCall("WaitForSingleObject","ptr",handle,"uint",500,"uint") = 0
    } finally DllCall("CloseHandle","ptr",handle)
}


GMU_ProcessIdentityMatches(record,pid,expectedPath,started) {
    return IsObject(record) && IsNumber(pid) && pid > 0 && expectedPath != "" && started != ""
        && GM_Value(record,"pid",0) = pid
        && StrLower(GM_Value(record,"path","")) = StrLower(expectedPath)
        && String(GM_Value(record,"started","")) = String(started)
}
