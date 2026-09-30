#Requires AutoHotkey v2.0+
#SingleInstance Force

#Include ..\LauncherHttp.ahk

AssertLauncherHttpTotalTimeout(condition, message) {
    if !condition
        throw Error(message)
}

try {
    AssertLauncherHttpTotalTimeout(A_Args.Length >= 2,
        "缺少測試 URL 或輸出路徑")
    url := A_Args[1]
    destination := A_Args[2]
    try FileDelete(destination)

    startedAt := A_TickCount
    failedAsExpected := false
    failureMessage := ""
    ; 測試伺服器會持續少量送資料，讓 receive timeout 一直被刷新。
    ; 第八個參數必須提供不受單次網路活動影響的整體截止時間。
    try HttpDownloadFile(url, destination, Map(), 200, 200, 200, 600, 900)
    catch as e {
        failedAsExpected := true
        failureMessage := e.Message
    }
    elapsedMs := A_TickCount - startedAt

    AssertLauncherHttpTotalTimeout(failedAsExpected,
        "持續滴流的下載未在總截止時間失敗")
    AssertLauncherHttpTotalTimeout(InStr(failureMessage, "總逾時"),
        "下載失敗不是由硬性總逾時中止：" failureMessage)
    AssertLauncherHttpTotalTimeout(elapsedMs >= 700 && elapsedMs < 3500,
        "硬性總逾時沒有在預期範圍返回：" elapsedMs "ms")
    AssertLauncherHttpTotalTimeout(!FileExist(destination),
        "總逾時不得留下被誤認成完整更新的檔案")

    FileAppend("launcher-http-total-timeout-integration=ok elapsed=" elapsedMs "ms`n", "*")
} catch as e {
    FileAppend("launcher-http-total-timeout-integration=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)
