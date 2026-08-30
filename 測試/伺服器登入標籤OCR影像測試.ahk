#Requires AutoHotkey v2.0+
#SingleInstance Off

#Include TestRuntimePaths.ahk
#Include ..\payload\plugin\RapidOcr\RapidOcr.ahk
#Include ..\payload\plugin\ImagePut-1.11\ImagePut.ahk
#Include ..\payload\WutheringServerNames.ahk

if (A_Args.Length < 2)
    ExitApp(2)

imagePath := A_Args[1]
expected := CanonicalizeWutheringServerName(A_Args[2])
if (!FileExist(imagePath) || expected = "")
    ExitApp(2)

windowHwnd := 0
tempFile := TestRuntime_NewFile("server-login-ocr", "server_login_label", ".png")
try {
    ; 用實際 Window 擷取路徑驗證正式程式採用的裁切與放大參數，避免只測
    ; 已預先裁好的圖片，卻漏掉 PrintWindow 客戶區座標差異。
    windowHwnd := ImagePutWindow(imagePath, "ServerLabelOcrImageTest")
    Sleep 300
    WinGetClientPos(, , &clientW, &clientH, "ahk_id " windowHwnd)
    roiX := Max(0, Floor(clientW * 0.25))
    roiY := Max(0, Floor(clientH * 0.68))
    roiW := Min(clientW - roiX, Max(1, Ceil(clientW * 0.50)))
    roiH := Min(clientH - roiY, Max(1, Ceil(clientH * 0.16)))
    ImagePutFile({Window: windowHwnd, crop: [roiX, roiY, roiW, roiH],
        scale: [roiW * 2, roiH * 2]}, tempFile)

    blocks := RapidOcr().ocr_from_file(tempFile, , true)
    detected := ""
    raw := ""
    for block in blocks {
        text := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
        if (text = "")
            continue
        raw .= (raw = "" ? "" : " | ") text
        canonical := DetectWutheringServerFromOcrText(text)
        if (canonical != "")
            detected := canonical
    }
    if (detected != expected)
        throw Error("expected=" expected " detected=" (detected != "" ? detected : "unknown")
            " raw=" (raw != "" ? raw : "(empty)"))

    FileAppend("server-login-label-image-regression=ok | detected=" detected
        " | raw=" raw "`n", "*")
} catch as e {
    FileAppend("server-login-label-image-regression=failed: " e.Message "`n", "**")
    ExitApp(1)
} finally {
    try FileDelete(tempFile)
    if windowHwnd
        try WinClose("ahk_id " windowHwnd)
}
ExitApp(0)
