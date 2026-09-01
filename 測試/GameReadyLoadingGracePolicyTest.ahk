#Requires AutoHotkey v2.0
#SingleInstance Force

sourcePath := A_ScriptDir "\..\payload\全自動.ahk"
source := FileRead(sourcePath, "UTF-8")

AssertTrue(condition, message) {
    if !condition
        throw Error(message)
}

startAt := InStr(source, "`nWaitGameReadyAfterOkwwF11(")
endAt := InStr(source, "`nClickWutheringClientCenter(", false, startAt + 1)
AssertTrue(startAt > 0 && endAt > startAt, "找不到 OKWW F11 後遊戲就緒函式")
block := SubStr(source, startAt, endAt - startAt)

AssertTrue(InStr(block, "loadingGraceSec := 150"),
    "MyTUF 載入寬限未設定為 150 秒")
AssertTrue(InStr(block, "if !hwnd") && InStr(block, "game_window_missing_before_grace"),
    "載入寬限前未區分遊戲視窗已消失")
AssertTrue(InStr(block, "IsLoginScreenByOcr(hwnd)"),
    "載入寬限缺少登入頁／載入中診斷")
AssertTrue(InStr(block, "if WaitEscMenuOCR(hwnd, loadingGraceSec)"),
    "遊戲仍存活時沒有追加主畫面驗證")
AssertTrue(InStr(block, "loading_grace_ready") && InStr(block, "loading_grace_timeout"),
    "載入寬限成功與逾時結果未細分")
AssertTrue(!InStr(block, "第二階段逾時；中心左鍵="),
    "仍保留第二階段一逾時就直接失敗的舊路徑")

FileAppend("Game-ready loading grace policy tests passed`n", "*")
ExitApp 0
