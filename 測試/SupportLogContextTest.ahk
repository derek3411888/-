#Requires AutoHotkey v2.0+
#SingleInstance Force
global logger := ""
#Include ..\payload\SupportLogContext.ahk

AssertTrue(condition, message) {
    if !condition
        throw Error(message)
}

tempPath := A_Temp "\WutheringSupportLogContextTest_" A_TickCount ".log"
try {
    Loop 140
        FileAppend("line " A_Index "`n", tempPath, "UTF-8")
    FileAppend("Authorization: Bearer abcdefghijklmnopqrstuvwxyz`n", tempPath, "UTF-8")
    FileAppend("password=do-not-copy`n", tempPath, "UTF-8")
    FileAppend("final diagnostic line`n", tempPath, "UTF-8")

    result := SupportLog_ReadRecentFile(tempPath, 4000, 65536, 120)
    AssertTrue(result.available, "應讀到最近 Log")
    AssertTrue(result.truncated, "超過 120 行應標記截斷")
    AssertTrue(InStr(result.excerpt, "final diagnostic line") > 0, "應保留檔案尾端")
    AssertTrue(InStr(result.excerpt, "do-not-copy") = 0, "不得保留密碼")
    AssertTrue(InStr(result.excerpt, "abcdefghijklmnopqrstuvwxyz") = 0, "不得保留 Bearer token")
    AssertTrue(InStr(result.excerpt, "[REDACTED]") > 0, "應顯示已遮蔽標記")
} finally {
    try FileDelete(tempPath)
}

ExitApp(0)
