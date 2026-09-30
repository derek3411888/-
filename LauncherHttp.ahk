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
