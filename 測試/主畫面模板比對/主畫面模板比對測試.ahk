#Requires AutoHotkey v2.0+
#SingleInstance Force
#UseHook
SetWorkingDir A_ScriptDir
CoordMode "Pixel", "Screen"
CoordMode "Mouse", "Screen"

; 若遊戲是管理員權限，腳本也需提權才能接收到全域熱鍵
if !A_IsAdmin {
    try Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp
}

; ===== 可調參數 =====
; ROI 以遊戲視窗右下角為基準
; 下列設定代表：從右下角往左 500px、往上 140px 的矩形區域
global ROI_WIDTH := 500
global ROI_HEIGHT := 140
global ROI_RIGHT_MARGIN := 0
global ROI_BOTTOM_MARGIN := 0

global TEMPLATE_PNG := A_ScriptDir "\\icon_main.png"

global VARIATIONS := [30, 40, 50, 60, 80, 100]
global CHECK_INTERVAL_MS := 500

global gameHwnd := 0
global CONTINUOUS_MODE := false
global STAT_TOTAL := 0
global STAT_HIT := 0
global STAT_MISS := 0
global STAT_SKIP := 0
global STAT_LAST_VAR := "-"
global STAT_START_TICK := 0
global LOG_FILE := A_ScriptDir "\\test_log.txt"
global TOOLTIP_SLOT := 8
global ACTIVE_BOX := 0  ; 目前活動的邊框 GUI

#Include ..\..\payload\plugin\ImagePut-1.11\ImagePut.ahk

; ===== 熱鍵 =====
; F6：擷取目前 ROI 做為主畫面模板
; F7：同 F6（保留別名）
; F8：執行一次主畫面比對
; F9：顯示目前 ROI 範圍
; F10：切換持續判斷模式（統計準確率）

F6::{
    HandleHotkey("F6")
    CaptureTemplate()
}

F7::{
    HandleHotkey("F7")
    CaptureTemplate()
}

F8::{
    HandleHotkey("F8")
    TestMainScreenOnce()
}

F9::{
    HandleHotkey("F9")
    ShowCurrentRoi()
}

F10::{
    HandleHotkey("F10")
    ToggleContinuousMode()
}

HandleHotkey(name) {
    SoundBeep 1200, 60
    ShowTip("收到熱鍵 " name, 600)
}

ShowTip(msg, ms := 5000) {
    global TOOLTIP_SLOT
    if (ms < 5000)
        ms := 5000
    ToolTip "          " msg, , , TOOLTIP_SLOT
    if (ms > 0)
        SetTimer(() => ToolTip(, , , TOOLTIP_SLOT), -ms)
}

WriteLog(msg) {
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    FileAppend(ts " | " msg "`r`n", LOG_FILE, "UTF-8")
}

ResetStats() {
    global STAT_TOTAL, STAT_HIT, STAT_MISS, STAT_SKIP, STAT_LAST_VAR, STAT_START_TICK
    STAT_TOTAL := 0
    STAT_HIT := 0
    STAT_MISS := 0
    STAT_SKIP := 0
    STAT_LAST_VAR := "-"
    STAT_START_TICK := A_TickCount
}

ToggleContinuousMode() {
    global CONTINUOUS_MODE, CHECK_INTERVAL_MS

    if !CONTINUOUS_MODE {
        ResetStats()
        CONTINUOUS_MODE := true
        SetTimer(ContinuousCheckTick, CHECK_INTERVAL_MS)
        WriteLog("持續判斷啟動, interval=" CHECK_INTERVAL_MS "ms")
        ShowTip("▶ 持續判斷啟動", 1400)
    } else {
        CONTINUOUS_MODE := false
        SetTimer(ContinuousCheckTick, 0)
        ShowContinuousSummary(true)
    }
}

ShowContinuousSummary(showMsgBox := false) {
    global STAT_TOTAL, STAT_HIT, STAT_MISS, STAT_SKIP, STAT_LAST_VAR, STAT_START_TICK

    acc := (STAT_TOTAL > 0) ? Round((STAT_HIT * 100.0) / STAT_TOTAL, 1) : 0
    runSec := Round((A_TickCount - STAT_START_TICK) / 1000.0, 1)
    text := "樣本=" STAT_TOTAL " 命中=" STAT_HIT " 未命中=" STAT_MISS " 跳過=" STAT_SKIP " 準確率=" acc "% 最後Var=" STAT_LAST_VAR " 時長=" runSec "s"
    WriteLog("持續判斷停止, " text)
    ShowTip("■ 停止: " acc "% (" STAT_HIT "/" STAT_TOTAL ")", 2200)

    if showMsgBox
        MsgBox("持續判斷結果`n" text)
}

ContinuousCheckTick() {
    global CONTINUOUS_MODE, STAT_TOTAL, STAT_HIT, STAT_MISS, STAT_SKIP, STAT_LAST_VAR, ROI_WIDTH, ROI_HEIGHT

    if !CONTINUOUS_MODE
        return

    if !FindGameWindow() {
        STAT_SKIP += 1
        return
    }

    if !FileExist(TEMPLATE_PNG) {
        STAT_SKIP += 1
        return
    }

    ok := TryFindMainIcon(&x, &y, &tpl, &v)
    STAT_TOTAL += 1

    if ok {
        STAT_HIT += 1
        STAT_LAST_VAR := v
        
        ; 檢測到時繪製邊框
        DrawBoundingBox(x, y, ROI_WIDTH, ROI_HEIGHT, "00FF00", 2, 800)
    } else {
        STAT_MISS += 1
        STAT_LAST_VAR := "-"
    }

    ; 每 10 筆更新一次狀態顯示與日誌
    if (Mod(STAT_TOTAL, 10) = 0) {
        acc := (STAT_TOTAL > 0) ? Round((STAT_HIT * 100.0) / STAT_TOTAL, 1) : 0
        ShowTip("測試中: " acc "% (" STAT_HIT "/" STAT_TOTAL ")", 650)
        WriteLog("樣本=" STAT_TOTAL " 命中=" STAT_HIT " 未命中=" STAT_MISS " 準確率=" acc "%")
    }
}

FindGameWindow() {
    global gameHwnd
    gameHwnd := WinExist("鳴潮")
    if !gameHwnd
        gameHwnd := WinExist("鸣潮")
    return gameHwnd
}

GetRoiByWindow(&x1, &y1, &x2, &y2) {
    global gameHwnd, ROI_WIDTH, ROI_HEIGHT, ROI_RIGHT_MARGIN, ROI_BOTTOM_MARGIN
    if !FindGameWindow()
        return false

    WinGetPos &wx, &wy, &ww, &wh, "ahk_id " gameHwnd
    x2 := wx + ww - ROI_RIGHT_MARGIN
    y2 := wy + wh - ROI_BOTTOM_MARGIN
    x1 := x2 - ROI_WIDTH
    y1 := y2 - ROI_HEIGHT
    return true
}

CaptureTemplate() {
    if !GetRoiByWindow(&x1, &y1, &x2, &y2) {
        ShowTip("找不到遊戲視窗（鳴潮/鸣潮）", 2200)
        return
    }

    target := TEMPLATE_PNG

    try {
        ; ImagePutFile 支援 [x,y,w,h] 區域擷取
        ImagePutFile([x1, y1, x2 - x1, y2 - y1], target)
    } catch as e {
        ShowTip("擷取模板失敗: " e.Message, 2600)
        return
    }

    ShowTip("已擷取主畫面模板", 1800)
}

TryFindMainIcon(&hitX := 0, &hitY := 0, &usedTemplate := "", &usedVar := 0) {
    global VARIATIONS

    if !GetRoiByWindow(&x1, &y1, &x2, &y2)
        return false

    if !FileExist(TEMPLATE_PNG)
        return false

    for v in VARIATIONS {
        spec := "*" v " " TEMPLATE_PNG
        try {
            if ImageSearch(&fx, &fy, x1, y1, x2, y2, spec) {
                hitX := fx
                hitY := fy
                usedTemplate := TEMPLATE_PNG
                usedVar := v
                return true
            }
        } catch {
            ; 忽略單次搜尋失敗，繼續嘗試其他 variation
        }
    }

    return false
}

DrawBoundingBox(x, y, w, h, color := "00FF00", thickness := 3, duration := 2000) {
    global ACTIVE_BOX
    
    ; 若已有活動邊框，先關閉
    if (ACTIVE_BOX != 0) {
        try {
            ACTIVE_BOX.Destroy()
        }
    }
    
    ; 建立透明 GUI 視窗作為邊框層
    box := Gui()
    box.Opt("-Caption +AlwaysOnTop +ToolWindow -DPIScale +LastFound")
    
    ; 直接使用指定顏色作為背景
    box.BackColor := color
    
    ; 實際 RGB 顏色（綠色=00FF00）
    WinSetTransColor("000000")
    
    ; 畫邊框（上、下、左、右四條線）
    ; 上邊
    box.Add("Text", "x0 y0 w" w " h" thickness, "")
    ; 下邊
    box.Add("Text", "x0 y" (h - thickness) " w" w " h" thickness, "")
    ; 左邊
    box.Add("Text", "x0 y0 w" thickness " h" h, "")
    ; 右邊
    box.Add("Text", "x" (w - thickness) " y0 w" thickness " h" h, "")
    
    ; 背景填滿為黑色（透明）
    for ctrl in box.Controls
        ctrl.Opt("+BackgroundTrans")
    
    box.Show("x" x " y" y " w" w " h" h " NoActivate")
    
    ACTIVE_BOX := box
    
    ; 保存到全域以供定時器使用
    global PENDING_BOX := box
    global PENDING_BOX_DURATION := duration
    SetTimer(DestroyPendingBox, 100)
}

DestroyPendingBox() {
    global PENDING_BOX, PENDING_BOX_DURATION, ACTIVE_BOX
    
    if (PENDING_BOX == 0)
        return
    
    if !IsSet(PENDING_BOX_START_TIME) {
        global PENDING_BOX_START_TIME := A_TickCount
    }
    
    elapsedMs := A_TickCount - PENDING_BOX_START_TIME
    
    if (elapsedMs >= PENDING_BOX_DURATION) {
        try {
            if (ACTIVE_BOX == PENDING_BOX) {
                PENDING_BOX.Destroy()
                ACTIVE_BOX := 0
            }
        } catch {
        }
        PENDING_BOX := 0
        SetTimer(DestroyPendingBox, 0)
    }
}

TestMainScreenOnce() {
    if !FindGameWindow() {
        ShowTip("找不到遊戲視窗（鳴潮/鸣潮）", 2200)
        return
    }

    ; 若找不到模板，提示先擷取
    if !FileExist(TEMPLATE_PNG) {
        MsgBox "尚未建立模板。`n請先切到主畫面，按 F6（或 F7）擷取單一模板。"
        return
    }

    ok := TryFindMainIcon(&x, &y, &tpl, &v)
    if ok {
        ShowTip("✅ 在主畫面 (" v ")", 1800)
        
        ; 估算模板大小（可根據 ROI 調整）
        global ROI_WIDTH, ROI_HEIGHT
        templateW := ROI_WIDTH
        templateH := ROI_HEIGHT
        
        ; 繪製邊框框出檢測位置
        DrawBoundingBox(x, y, templateW, templateH, "00FF00", 3, 3000)
        
        MsgBox "判定結果：在主畫面`n位置: " x ", " y "`n模板: " tpl "`nVariation: " v
    } else {
        ; 失敗時保存 ROI 截圖，方便檢查
        if GetRoiByWindow(&x1, &y1, &x2, &y2) {
            try ImagePutFile([x1, y1, x2 - x1, y2 - y1], A_ScriptDir "\\roi_debug.png")
        }
        ShowTip("❌ 不在主畫面（或模板不吻合）", 2200)
        MsgBox "判定結果：不在主畫面。`n若你確實在主畫面，請重擷取模板後再試。"
    }
}

ShowCurrentRoi() {
    if !GetRoiByWindow(&x1, &y1, &x2, &y2) {
        ShowTip("找不到遊戲視窗（鳴潮/鸣潮）", 2200)
        return
    }

    MsgBox "目前 ROI：`n(" x1 ", " y1 ") ~ (" x2 ", " y2 ")"
}

MsgBox "主畫面模板比對測試已啟動（管理員模式）。`n`n目前截圖區域：右下角 ROI`nF6：擷取主畫面模板`nF7：同 F6`nF8：執行主畫面判定`nF9：查看 ROI`nF10：持續判斷/停止（統計準確率）"
