#Requires AutoHotkey v2.0+

; Launcher 的 HTTP 請求必須同時有四階段逾時與硬性總逾時。只有
; ServerXMLHTTP.setTimeouts 仍可能被持續少量傳輸刷新 receive timeout，導致
; launcher 永遠卡在更新下載。改用 async request 輪詢 readyState，超過整體
; 截止時間就 abort；呼叫端仍只會在完整回應後使用資料。
LauncherHttp_CreateRequest(url, extraHeaders := Map(), resolveTimeoutMs := 10000,
    connectTimeoutMs := 15000, sendTimeoutMs := 15000, receiveTimeoutMs := 60000) {
    http := ComObject("Msxml2.ServerXMLHTTP.6.0")
    http.setTimeouts(resolveTimeoutMs, connectTimeoutMs, sendTimeoutMs, receiveTimeoutMs)
    http.open("GET", url, true)
    http.setRequestHeader("Cache-Control", "no-cache, no-store, must-revalidate")
    http.setRequestHeader("Pragma", "no-cache")
    http.setRequestHeader("User-Agent", "AHK-Launcher/2.0")
    for k, v in extraHeaders
        http.setRequestHeader(k, v)
    return http
}

LauncherHttp_SendAndWait(http, totalTimeoutMs) {
    if !(totalTimeoutMs is Integer) || totalTimeoutMs < 1
        throw ValueError("HTTP 總逾時必須是正整數毫秒", -1, totalTimeoutMs)

    http.send()
    startedAt := A_TickCount
    loop {
        if (http.readyState = 4)
            return

        elapsedMs := A_TickCount - startedAt
        if (elapsedMs >= totalTimeoutMs) {
            try http.abort()
            throw Error("HTTP 總逾時（" totalTimeoutMs "ms）")
        }
        Sleep(Min(50, totalTimeoutMs - elapsedMs))
    }
}

LauncherHttp_ResolveTotalTimeout(totalTimeoutMs, resolveTimeoutMs,
    connectTimeoutMs, sendTimeoutMs, receiveTimeoutMs) {
    if (totalTimeoutMs = 0)
        totalTimeoutMs := resolveTimeoutMs + connectTimeoutMs + sendTimeoutMs + receiveTimeoutMs
    if !(totalTimeoutMs is Integer) || totalTimeoutMs < 1
        throw ValueError("HTTP 總逾時必須是正整數毫秒", -1, totalTimeoutMs)
    return totalTimeoutMs
}

HttpGetText(url, extraHeaders := Map(), resolveTimeoutMs := 10000,
    connectTimeoutMs := 15000, sendTimeoutMs := 15000, receiveTimeoutMs := 60000,
    totalTimeoutMs := 0) {
    totalTimeoutMs := LauncherHttp_ResolveTotalTimeout(totalTimeoutMs,
        resolveTimeoutMs, connectTimeoutMs, sendTimeoutMs, receiveTimeoutMs)
    http := LauncherHttp_CreateRequest(url, extraHeaders, resolveTimeoutMs,
        connectTimeoutMs, sendTimeoutMs, receiveTimeoutMs)
    try LauncherHttp_SendAndWait(http, totalTimeoutMs)
    catch as e
        throw Error("HTTP GET 失敗或逾時: " e.Message)
    if (http.status != 200)
        throw Error("HTTP " http.status " for: " url)
    return http.responseText
}

HttpDownloadFile(url, destPath, extraHeaders := Map(), resolveTimeoutMs := 10000,
    connectTimeoutMs := 15000, sendTimeoutMs := 15000, receiveTimeoutMs := 60000,
    totalTimeoutMs := 0) {
    totalTimeoutMs := LauncherHttp_ResolveTotalTimeout(totalTimeoutMs,
        resolveTimeoutMs, connectTimeoutMs, sendTimeoutMs, receiveTimeoutMs)
    http := LauncherHttp_CreateRequest(url, extraHeaders, resolveTimeoutMs,
        connectTimeoutMs, sendTimeoutMs, receiveTimeoutMs)
    try LauncherHttp_SendAndWait(http, totalTimeoutMs)
    catch as e
        throw Error("HTTP 下載失敗或逾時: " e.Message)
    if (http.status != 200)
        throw Error("HTTP " http.status " for: " url)

    stream := ComObject("ADODB.Stream")
    stream.Type := 1  ; adTypeBinary
    stream.Open()
    try {
        stream.Write(http.responseBody)
        stream.SaveToFile(destPath, 2)  ; adSaveCreateOverWrite
    } finally {
        stream.Close()
    }
}

; Large release artifacts must not inherit the manifest's 100-second budget.
; Native streaming keeps bounded disk/memory usage and SHA-addressed partials.
; Returns only after verified atomic publication; the formal launcher is never
; restarted here and no startup/runtime ownership lock is acquired by the child.
LauncherDownloadFile(helper, root, url, destPath, expectedSha, progress := 0,
    totalTimeoutMs := 1200000, idleTimeoutMs := 60000) {
    if !(expectedSha ~= "^[0-9a-fA-F]{64}$")
        throw Error("更新檔缺少有效 SHA256，拒絕下載")
    for value in [helper, root, url, destPath]
        if InStr(value, '"') || InStr(value, "`r") || InStr(value, "`n")
            throw Error("更新下載參數含不合法字元")
    if !(totalTimeoutMs is Integer) || totalTimeoutMs < 1 || totalTimeoutMs > 1800000
        || !(idleTimeoutMs is Integer) || idleTimeoutMs < 1 || idleTimeoutMs > 120000
        throw Error("更新下載逾時設定不合法")
    created := Buffer(8), exited := Buffer(8), kernel := Buffer(8), userTime := Buffer(8)
    if !DllCall("GetProcessTimes", "ptr", DllCall("GetCurrentProcess", "ptr"),
        "ptr", created, "ptr", exited, "ptr", kernel, "ptr", userTime)
        throw OSError(A_LastError, "GetProcessTimes(download parent)")
    parentImage := A_IsCompiled ? A_ScriptFullPath : A_AhkPath
    command := '"' helper '" download "' root '" "' parentImage '" '
        . DllCall("GetCurrentProcessId", "uint") ' ' NumGet(created, 0, "Int64")
        . ' "' url '" "' destPath '" ' StrLower(expectedSha) ' ' totalTimeoutMs ' ' idleTimeoutMs ' 3'
    startupInfo := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
    processInfo := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
    commandBuffer := Buffer((StrLen(command) + 1) * 2, 0)
    StrPut(command, commandBuffer, "UTF-16")
    NumPut("UInt", startupInfo.Size, startupInfo)
    if !DllCall("CreateProcessW", "str", helper, "ptr", commandBuffer, "ptr", 0,
        "ptr", 0, "int", false, "uint", 0x08000000, "ptr", 0, "str", root,
        "ptr", startupInfo, "ptr", processInfo, "int")
        throw OSError(A_LastError, "CreateProcessW(download)")
    childHandle := NumGet(processInfo, 0, "ptr")
    DllCall("CloseHandle", "ptr", NumGet(processInfo, A_PtrSize, "ptr"))
    statusPath := destPath ".download.status", lastStatus := "", started := A_TickCount
    try {
        loop {
            done := DllCall("WaitForSingleObject", "ptr", childHandle, "uint", 0, "uint") = 0
            currentStatus := ""
            try currentStatus := Trim(FileRead(statusPath, "UTF-8"))
            if currentStatus != "" && currentStatus != lastStatus {
                lastStatus := currentStatus
                if IsObject(progress)
                    try progress.Call(currentStatus)
            }
            if done
                break
            if A_TickCount - started > totalTimeoutMs + 5000 {
                ; Exact handle returned by CreateProcess, never a reused PID.
                DllCall("TerminateProcess", "ptr", childHandle, "uint", 124)
                DllCall("WaitForSingleObject", "ptr", childHandle, "uint", 2000)
                throw Error("原生下載工具未在期限內退出；保留舊版及續傳暫存")
            }
            Sleep 200
        }
        exitCode := 1
        if !DllCall("GetExitCodeProcess", "ptr", childHandle, "uint*", &exitCode)
            throw OSError(A_LastError, "GetExitCodeProcess(download)")
        if exitCode != 0 || !FileExist(destPath)
            throw Error("更新下載失敗（exit=" exitCode "）：" lastStatus)
        return true
    } finally {
        DllCall("CloseHandle", "ptr", childHandle)
    }
}
