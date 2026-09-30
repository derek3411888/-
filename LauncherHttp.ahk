#Requires AutoHotkey v2.0+

; Launcher 的同步 HTTP 請求必須有明確逾時。Msxml2.XMLHTTP.6.0 沒有可用的
; 同步逾時設定，網路層卡住時會連帶凍結 launcher，讓 payload 更新與主流程都
; 無法繼續。ServerXMLHTTP 提供四階段逾時，並保留同步完成後才使用回應的語意。
LauncherHttp_CreateRequest(url, extraHeaders := Map(), resolveTimeoutMs := 10000,
    connectTimeoutMs := 15000, sendTimeoutMs := 15000, receiveTimeoutMs := 60000) {
    http := ComObject("Msxml2.ServerXMLHTTP.6.0")
    http.setTimeouts(resolveTimeoutMs, connectTimeoutMs, sendTimeoutMs, receiveTimeoutMs)
    http.open("GET", url, false)
    http.setRequestHeader("Cache-Control", "no-cache, no-store, must-revalidate")
    http.setRequestHeader("Pragma", "no-cache")
    http.setRequestHeader("User-Agent", "AHK-Launcher/2.0")
    for k, v in extraHeaders
        http.setRequestHeader(k, v)
    return http
}

HttpGetText(url, extraHeaders := Map(), resolveTimeoutMs := 10000,
    connectTimeoutMs := 15000, sendTimeoutMs := 15000, receiveTimeoutMs := 60000) {
    http := LauncherHttp_CreateRequest(url, extraHeaders, resolveTimeoutMs,
        connectTimeoutMs, sendTimeoutMs, receiveTimeoutMs)
    try http.send()
    catch as e
        throw Error("HTTP GET 失敗或逾時: " e.Message)
    if (http.status != 200)
        throw Error("HTTP " http.status " for: " url)
    return http.responseText
}

HttpDownloadFile(url, destPath, extraHeaders := Map(), resolveTimeoutMs := 10000,
    connectTimeoutMs := 15000, sendTimeoutMs := 15000, receiveTimeoutMs := 60000) {
    http := LauncherHttp_CreateRequest(url, extraHeaders, resolveTimeoutMs,
        connectTimeoutMs, sendTimeoutMs, receiveTimeoutMs)
    try http.send()
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
