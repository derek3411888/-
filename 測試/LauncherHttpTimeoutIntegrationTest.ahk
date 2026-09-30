#Requires AutoHotkey v2.0+
#SingleInstance Force

#Include ..\LauncherHttp.ahk

AssertLauncherHttpTimeout(condition, message) {
    if !condition
        throw Error(message)
}

try {
    AssertLauncherHttpTimeout(A_Args.Length >= 2,
        "缺少測試 URL 或輸出路徑")
    url := A_Args[1]
    destination := A_Args[2]
    try FileDelete(destination)

    startedAt := A_TickCount
    failedAsExpected := false
    failureMessage := ""
    try HttpDownloadFile(url, destination, Map(), 200, 200, 200, 600)
    catch as e {
        failedAsExpected := true
        failureMessage := e.Message
    }
    elapsedMs := A_TickCount - startedAt

    AssertLauncherHttpTimeout(failedAsExpected,
        "無回應的伺服器未讓下載失敗")
    AssertLauncherHttpTimeout(InStr(failureMessage, "失敗或逾時"),
        "下載失敗沒有回報可判讀的逾時資訊")
    AssertLauncherHttpTimeout(elapsedMs < 5000,
        "無回應下載超過 5 秒仍未返回：" elapsedMs "ms")
    AssertLauncherHttpTimeout(!FileExist(destination),
        "逾時不得留下被誤認成完整更新的檔案")

    FileAppend("launcher-http-timeout-integration=ok elapsed=" elapsedMs "ms`n", "*")
} catch as e {
    FileAppend("launcher-http-timeout-integration=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)
