; 聲骸合成.ahk - 自動聲骸合成腳本
; 遊戲解析度：1280×720
; 功能：自動執行聲骸批量融合流程

#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir

; 自動提權
if !A_IsAdmin {
    try Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp
}

; 設定普通優先級
ProcessSetPriority("Normal")

; DPI 感知
try DllCall("SetProcessDpiAwarenessContext", "ptr", -4)
catch 
    try DllCall("shcore\SetProcessDpiAwareness", "int", 2)

; 引入依賴
#Include LogManager.ahk
#Include plugin\ImagePut-1.11\ImagePut.ahk
#Include plugin\RapidOcr\RapidOcr.ahk

; 初始化日誌
global logger := InitLogger("聲骸合成")
RegisterLifecycleLogging("聲骸合成")
global RUN_ID := A_Now "@" A_TickCount
global STEP_SEQ := 0
logger.log("========== 聲骸合成腳本啟動 ==========")

WriteLog(msg, level := "INFO") {
    global logger, RUN_ID
    logger.log("[" RUN_ID "] " msg, level)
}

WriteStep(stepName, detail := "", level := "INFO") {
    global STEP_SEQ
    STEP_SEQ += 1
    msg := "[STEP " Format("{:03}", STEP_SEQ) "] " stepName
    if (detail != "")
        msg .= " | " detail
    WriteLog(msg, level)
    ShowTip("📌 " stepName, 700)
}

WriteStep("啟動", "PID=" DllCall("GetCurrentProcessId") " AHK=" A_AhkVersion)

; 顯示提示時避免被游標遮住（開頭加5個空白）
ShowTip(msg, duration := 1200) {
    ToolTip "          " msg
    if (duration > 0)
        SetTimer(() => ToolTip(), -duration)
}

; 全域變數
global gameWindow := ""
global ocrEngine := ""
global firstTime := true  ; 標記是否首次執行（用於圖9）

; 主程式入口
Main()

Main() {
    try {
        ; 初始化 OCR
        global ocrEngine := RapidOcr()
        WriteStep("OCR初始化", "成功")
        
        ; 尋找遊戲視窗
        if !FindGameWindow() {
            WriteStep("尋找遊戲視窗", "失敗", "ERROR")
            ShowTip("找不到遊戲視窗（鳴潮/鸣潮），請先啟動遊戲。", 3000)
            Sleep 3000
            return
        }
        
        WriteStep("尋找遊戲視窗", "成功 hwnd=" gameWindow)
        
        ; 由全自動主流程先完成可操作驗證，這裡不再重複驗證
        WriteStep("可操作驗證", "略過（由全自動前置驗證）")
        
        ; 開始聲骸合成流程
        WriteStep("聲骸合成流程", "開始執行")
        RunSynthesisLoop()
        
        logger.log("========== 聲骸合成完成 ==========")
        ShowTip("✅ 聲骸合成流程已完成！", 3000)
        Sleep 3000
        
    } catch as e {
        logger.log("執行錯誤: " e.Message, "ERROR")
        ShowTip("⚠️ 執行過程中發生錯誤：" e.Message, 3000)
        Sleep 3000
    }
    
    ; 完成後正確結束腳本
    ExitApp
}

; ==================== 主流程 ====================

RunSynthesisLoop() {
    global logger, firstTime
    ; 步驟1：按 Esc 打開主選單（圖2）
    if !OpenMainMenu() {
        logger.log("無法打開主選單", "ERROR")
        return
    }
    
    ; 步驟2：點擊數據屋（圖2 → 圖3）
    if !ClickDataWarehouse() {
        logger.log("無法點擊數據屋", "ERROR")
        return
    }
    
    ; 步驟3：點擊圖3紅框（圖3 → 圖4）
    if !ClickStep3Icon() {
        logger.log("無法點擊圖3目標", "ERROR")
        return
    }
    
    ; 驗證是否正確進入背包面板
    if !VerifyBackpackPanel() {
        logger.log("未正確進入背包面板，流程終止", "ERROR")
        ShowTip("⚠️ 未能正確進入背包面板，請檢查遊戲狀態。", 3000)
        Sleep 3000
        return
    }
    
    ; 進入主迴圈（第16步開始，圖4開始循環）
    loopCount := 0
    firstLoop := true  ; 標記是否首次迴圈
    while true {
        loopCount++
        logger.log("========== 第 " loopCount " 輪融合 ==========")
        
        ; 步驟16~19：僅在第一次執行，後續迴圈從「全選」開始
        if firstLoop {
            ; 步驟16：點擊批量融合（圖4 → 圖5）
            if !ClickBatchMerge() {
                logger.log("無法點擊批量融合", "ERROR")
                break
            }

            ; 步驟17：點擊最靠下的標準融合（Y軸最大）
            if !ClickBottomStandardMerge() {
                logger.log("無法點擊最靠下的標準融合", "ERROR")
                break
            }

            ; 步驟18：點擊圖5紅框（圖5 → 圖6）
            if !ClickStep5Icon() {
                logger.log("無法點擊圖5目標", "ERROR")
                break
            }
            
            ; 步驟19：選擇已棄置並返回（圖6 → 圖7）
            if !SelectDiscardedAndConfirm() {
                logger.log("無法選擇已棄置", "ERROR")
                break
            }
        } else {
            logger.log("非首次迴圈，跳過標準融合與篩選步驟（圖5/圖6），直接從全選開始")
            Sleep 1000
        }
        
        ; 步驟20：點擊全選（圖7 → 圖8）
        if !ClickSelectAll() {
            logger.log("無法點擊全選", "ERROR")
            break
        }
        
        ; 步驟21：檢查次數並點擊批量融合（圖8）
        mergeCount := CheckMergeCount()
        logger.log("批量融合次數: " mergeCount)
        
        if (mergeCount <= 0) {
            logger.log("融合次數為 0，先點擊返回再點擊回到主畫面後結束流程")

            ; 步驟22：先點擊右上角返回（座標：1213,56）
            ClickRelative(1213, 56)
            Sleep 1000

            ; 步驟23：再點擊回到主畫面（座標：1139,56）
            ClickRelative(1139, 56)
            Sleep 2000  ; 等待遊戲作動
            
            ; 打開 ESC 背包畫面
            logger.log("打開 ESC 背包畫面")
            ActivateGame()
            Sleep 500
            Send "{Esc}"
            Sleep 1500
            logger.log("已停留在 ESC 背包畫面")
            
            break
        }
        
        ; 點擊批量融合按鈕（圖8 → 圖9或圖10）
        if !ClickMergeBatchButton() {
            logger.log("無法點擊批量融合按鈕", "ERROR")
            break
        }
        
        ; 步驟24：首次處理提示框（圖9 → 圖10）
        if (firstTime) {
            if !HandleFirstTimePrompt() {
                logger.log("無法處理首次提示", "WARN")
            }
            firstTime := false
        }
        
        ; 等待融合完成（圖10）
        Sleep 1000
        
        ; 步驟25：按 Esc 返回圖4
        if !ReturnToStep4() {
            logger.log("無法返回圖4", "ERROR")
            break
        }
        
        ; 標記首次迴圈已完成
        if firstLoop {
            firstLoop := false
            logger.log("首次迴圈完成，後續將跳過圖5和圖6")
        }
        
        Sleep 1000
    }
    
    logger.log("批量融合迴圈結束")
}

; ==================== 各步驟函數 ====================

FindGameWindow() {
    global gameWindow
    
    ; 嘗試找繁體視窗
    gameWindow := WinExist("鳴潮")
    if gameWindow
        return true
    
    ; 嘗試找簡體視窗
    gameWindow := WinExist("鸣潮")
    if gameWindow
        return true
    
    return false
}

OpenMainMenu() {
    global logger
    logger.log("按 Esc 打開主選單")
    ActivateGame()
    
    ; 按 Esc
    Send "{Esc}"
    Sleep 1500
    
    ; 驗證是否打開（OCR 檢測「數據屋」等關鍵字）
    result := OCRWindow()
    if !result
        return false
    
    keywords := ["数据坞", "數據屋", "终端", "終端", "设置", "設置"]
    for block in result {
        text := CleanText(block.text)
        for kw in keywords {
            if InStr(text, kw) {
                logger.log("主選單已打開")
                return true
            }
        }
    }
    
    logger.log("未檢測到主選單", "WARN")
    return false
}

ClickDataWarehouse() {
    global logger, gameWindow
    logger.log("點擊數據屋")
    
    ; 先嘗試用OCR尋找「數據屋」
    try {
        result := OCRWindow()
        if IsObject(result) {
            for block in result {
                text := CleanText(block.text)
                if InStr(text, "数据坞") || InStr(text, "數據屋") {
                    if block.HasOwnProp("boxPoint") && IsObject(block.boxPoint) && block.boxPoint.Length >= 3 {
                        cx := (block.boxPoint[1].x + block.boxPoint[3].x) / 2
                        cy := (block.boxPoint[1].y + block.boxPoint[3].y) / 2
                        logger.log("用OCR找到數據屋，座標: " cx ", " cy)
                        ClickRelative(cx, cy)
                        Sleep 1000
                        return true
                    }
                }
            }
        }
    } catch as e {
        logger.log("OCR查找數據屋失敗: " e.Message, "WARN")
    }
    
    ; OCR找不到，使用備選座標
    logger.log("使用備選座標點擊數據屋")
    cx := (905 + 1012) / 2
    cy := (273 + 418) / 2
    
    ClickRelative(cx, cy)
    Sleep 1000
    
    return true
}

ClickStep3Icon() {
    global logger
    logger.log("點擊圖3目標")
    
    ; 座標：9,356,92,437
    cx := (9 + 92) / 2
    cy := (356 + 437) / 2
    
    ClickRelative(cx, cy)
    Sleep 1000
    
    return true
}

ClickBatchMerge() {
    global logger
    logger.log("點擊標準融合")
    
    ; 先嘗試用OCR尋找「標準融合」
    try {
        result := OCRWindow()
        if IsObject(result) {
            for block in result {
                text := CleanText(block.text)
                if InStr(text, "标准融合") || InStr(text, "標準融合") {
                    if block.HasOwnProp("boxPoint") && IsObject(block.boxPoint) && block.boxPoint.Length >= 3 {
                        cx := (block.boxPoint[1].x + block.boxPoint[3].x) / 2
                        cy := (block.boxPoint[1].y + block.boxPoint[3].y) / 2
                        logger.log("用OCR找到標準融合，座標: " cx ", " cy)
                        ClickRelative(cx, cy)
                        Sleep 1000
                        return true
                    }
                }
            }
        }
    } catch as e {
        logger.log("OCR查找標準融合失敗: " e.Message, "WARN")
    }
    
    ; OCR找不到，使用備選座標
    logger.log("使用備選座標點擊標準融合")
    ClickRelative(368, 98)
    Sleep 1000
    
    return true
}

ClickBottomStandardMerge() {
    global logger
    logger.log("點擊最靠下的標準融合（Y軸最大）")
    
    ; 先嘗試用OCR尋找Y軸最大的「標準融合」
    try {
        result := OCRWindow()
        if IsObject(result) {
            bottomMerge := ""
            maxY := 0
            
            for block in result {
                text := CleanText(block.text)
                if InStr(text, "标准融合") || InStr(text, "標準融合") {
                    if block.HasOwnProp("boxPoint") && IsObject(block.boxPoint) && block.boxPoint.Length >= 3 {
                        cy := (block.boxPoint[1].y + block.boxPoint[3].y) / 2
                        if (cy > maxY) {
                            maxY := cy
                            bottomMerge := block
                        }
                    }
                }
            }
            
            if (bottomMerge != "") {
                cx := (bottomMerge.boxPoint[1].x + bottomMerge.boxPoint[3].x) / 2
                cy := (bottomMerge.boxPoint[1].y + bottomMerge.boxPoint[3].y) / 2
                logger.log("用OCR找到最靠下的標準融合，座標: " cx ", " cy)
                ClickRelative(cx, cy)
                Sleep 1000
                return true
            }
        }
    } catch as e {
        logger.log("OCR查找最靠下標準融合失敗: " e.Message, "WARN")
    }
    
    ; OCR找不到，使用備選座標
    logger.log("使用備選座標點擊最靠下的標準融合")
    ClickRelative(685, 658)
    Sleep 1000
    
    return true
}

ClickStep5Icon() {
    global logger
    logger.log("點擊圖5目標")
    
    ; 座標：25,636,74,683
    cx := (25 + 74) / 2
    cy := (636 + 683) / 2
    
    ClickRelative(cx, cy)
    Sleep 1000
    
    return true
}

SelectDiscardedAndConfirm() {
    global logger
    logger.log("選擇已棄置並返回")

    foundDiscarded := false

    ; 先嘗試用OCR尋找「已棄置」
    try {
        result := OCRWindow()
        if IsObject(result) {
            for block in result {
                text := CleanText(block.text)
                if InStr(text, "已弃置") || InStr(text, "已棄置") {
                    if block.HasOwnProp("boxPoint") && IsObject(block.boxPoint) && block.boxPoint.Length >= 3 {
                        cx1 := (block.boxPoint[1].x + block.boxPoint[3].x) / 2
                        cy1 := (block.boxPoint[1].y + block.boxPoint[3].y) / 2
                        logger.log("用OCR找到已棄置，座標: " cx1 ", " cy1)
                        ClickRelative(cx1, cy1)
                        foundDiscarded := true
                        break
                    }
                }
            }
        }
    } catch as e {
        logger.log("OCR查找已棄置失敗: " e.Message, "WARN")
    }

    ; OCR找不到，使用備選座標
    if !foundDiscarded {
        cx1 := 890
        cy1 := 185
        logger.log("使用備選座標點擊已棄置: " cx1 ", " cy1)
        ClickRelative(cx1, cy1)
    }

    Sleep 800

    ; 點擊右上角關閉/返回圖示
    cx2 := 1213
    cy2 := 56
    logger.log("點擊右上角關閉/返回: " cx2 ", " cy2)
    ClickRelative(cx2, cy2)
    Sleep 2000

    return true
}

ClickSelectAll() {
    global logger
    logger.log("點擊全選")
    
    ; 座標：310,637,391,684
    cx := (310 + 391) / 2
    cy := (637 + 684) / 2
    
    ClickRelative(cx, cy)
    Sleep 1000
    
    return true
}

CheckMergeCount() {
    global logger
    logger.log("檢查融合次數")
    
    ; 綠框座標：936,603,1075,633
    x1 := 936, y1 := 603, x2 := 1075, y2 := 633
    
    ; 截圖並 OCR 該區域
    result := OCRWindow()
    if !result
        return -1
    
    ; 搜尋包含「次數」或數字的文字
    for block in result {
        text := CleanText(block.text)
        
        ; 檢查是否在綠框範圍內
        if !block.HasOwnProp("boxPoint") || block.boxPoint.Length < 3
            continue
        
        bx := (block.boxPoint[1].x + block.boxPoint[3].x) / 2
        by := (block.boxPoint[1].y + block.boxPoint[3].y) / 2
        
        if (bx >= x1 && bx <= x2 && by >= y1 && by <= y2) {
            ; 提取數字
            if RegExMatch(text, "\d+", &match) {
                count := Integer(match[0])
                logger.log("找到融合次數: " count " (原文: " text ")")
                return count
            }
        }
    }
    
    logger.log("未找到融合次數，返回 0", "WARN")
    return 0
}

ClickMergeBatchButton() {
    global logger
    logger.log("點擊批量融合按鈕")
    
    ; 座標：857,631,1155,686
    cx := (857 + 1155) / 2
    cy := (631 + 686) / 2
    
    ClickRelative(cx, cy)
    Sleep 2000
    
    return true
}

HandleFirstTimePrompt() {
    global logger
    logger.log("檢查是否有首次提示框")
    
    Sleep 1000  ; 等待可能的彈窗出現
    
    ; OCR 檢測是否有提示框
    result := OCRWindow()
    if !result {
        logger.log("無法 OCR，跳過提示框處理")
        return true
    }
    
    foundPrompt := false
    keywords := ["本次登", "不再提示", "本次登录", "本次登陆"]
    
    for block in result {
        text := CleanText(block.text)
        for kw in keywords {
            if InStr(text, kw) {
                foundPrompt := true
                logger.log("檢測到首次提示框，準備處理")
                break 2
            }
        }
    }
    
    if !foundPrompt {
        logger.log("未檢測到首次提示框，直接繼續")
        return true
    }
    
    ; 有提示框，執行點擊
    logger.log("處理首次提示框")
    
    ; 勾選「本次登陸不再提示」：543,380,729,416
    cx1 := (543 + 729) / 2
    cy1 := (380 + 416) / 2
    
    ClickRelative(cx1, cy1)
    Sleep 500
    
    ; 點擊確認：753,400,968,482
    cx2 := (753 + 968) / 2
    cy2 := (400 + 482) / 2
    
    ClickRelative(cx2, cy2)
    Sleep 2000
    
    return true
}

ReturnToStep4() {
    global logger
    logger.log("按 Esc 返回圖4")
    ActivateGame()
    
    Send "{Esc}"
    Sleep 1000
    
    return true
}

; 去抖動主畫面模板比對（驗證遊戲是否正常運行）
WaitEscMenuOCR(hwnd, timeoutSec := 120) {
    global logger
    oldPixelMode := A_CoordModePixel
    CoordMode "Pixel", "Screen"

    if !hwnd {
        logger.log("WaitEscMenuOCR: 無效的視窗句柄", "ERROR")
        CoordMode "Pixel", oldPixelMode
        return false
    }

    templateFile := A_ScriptDir "\icon_main.png"
    if !FileExist(templateFile) {
        logger.log("模板驗證失敗：找不到模板檔 " templateFile, "WARN")
        CoordMode "Pixel", oldPixelMode
        return false
    }

    variations := [30, 40, 50, 60, 80, 100]
    stableNeeded := 2
    stable := 0
    checkIntervalMs := 500

    roiWidth := 500
    roiHeight := 140
    roiRightMargin := 0
    roiBottomMargin := 0

    logger.log("開始模板驗證: template=" templateFile " roi=" roiWidth "x" roiHeight " timeout=" timeoutSec "s")

    deadline := A_TickCount + timeoutSec*1000
    lastProgressLog := A_TickCount
    sampleCount := 0
    bestVar := 0
    while (A_TickCount < deadline) {
        try WinActivate "ahk_id " hwnd
        Sleep 120
        sampleCount += 1

        try {
            WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " hwnd)
        } catch as e {
            logger.log("模板驗證取視窗座標失敗: " e.Message, "WARN")
            Sleep checkIntervalMs
            continue
        }

        x2 := wx + ww - roiRightMargin
        y2 := wy + wh - roiBottomMargin
        x1 := x2 - roiWidth
        y1 := y2 - roiHeight
        if (x1 < 0 || y1 < 0 || x2 <= x1 || y2 <= y1) {
            Sleep checkIntervalMs
            continue
        }

        found := false
        matchedVar := 0
        for _, v in variations {
            spec := "*" v " " templateFile
            try {
                if ImageSearch(&fx, &fy, x1, y1, x2, y2, spec) {
                    found := true
                    matchedVar := v
                    bestVar := v
                    break
                }
            } catch {
            }
        }

        if found {
            stable += 1
            logger.log("模板偵測 " stable "/" stableNeeded "（Var=" matchedVar "）")
            if (stable >= stableNeeded) {
                logger.log("遊戲驗證成功")
                CoordMode "Pixel", oldPixelMode
                return true
            }
        } else {
            stable := 0
        }

        if (A_TickCount - lastProgressLog >= 5000) {
            remainSec := Round((deadline - A_TickCount) / 1000.0, 1)
            logger.log("模板驗證進行中: 樣本=" sampleCount " 連續命中=" stable "/" stableNeeded " 最後Var=" (bestVar ? bestVar : "-") " 剩餘=" remainSec "s")
            lastProgressLog := A_TickCount
        }

        Sleep checkIntervalMs
    }
    logger.log("遊戲驗證超時", "WARN")
    CoordMode "Pixel", oldPixelMode
    return false
}

; 驗證是否正確進入背包面板
VerifyBackpackPanel() {
    global logger
    logger.log("驗證背包面板是否正確開啟")
    
    Sleep 1000  ; 等待界面穩定
    
    ; OCR 檢測特定關鍵字
    result := OCRWindow()
    if !result {
        logger.log("無法 OCR 檢測面板", "ERROR")
        return false
    }
    
    ; 檢測關鍵字：批量融合、合成、聲骸等
    keywords := ["批量融合", "批量合成", "聲骸", "声骸", "融合", "合成"]
    foundCount := 0
    
    for block in result {
        text := CleanText(block.text)
        for kw in keywords {
            if InStr(text, kw) {
                foundCount++
                logger.log("檢測到關鍵字: " kw " (原文: " block.text ")")
                break
            }
        }
    }
    
    ; 至少找到1個關鍵字才算成功
    if (foundCount >= 1) {
        logger.log("背包面板驗證成功 (找到 " foundCount " 個關鍵字)")
        return true
    } else {
        logger.log("背包面板驗證失敗，未找到關鍵字", "ERROR")
        return false
    }
}

; ==================== 輔助函數 ====================

ActivateGame() {
    global gameWindow
    if gameWindow {
        WinActivate "ahk_id " gameWindow
        Sleep 200
    }
}

ClickRelative(x, y) {
    global gameWindow, logger
    
    ActivateGame()

    ; 使用前景實體滑鼠點擊客戶區座標
    CoordMode "Mouse", "Client"
    WinActivate "ahk_id " gameWindow
    Sleep 100

    MouseMove x, y
    Sleep 50
    Click
    Sleep 100

    CoordMode "Mouse", "Screen"

    logger.log("點擊客戶區座標: (" Round(x) ", " Round(y) ")")
    return true
}

OCRWindow() {
    global gameWindow, ocrEngine, logger
    
    ; 避免把無效 hwnd 傳給 ImagePut 導致崩潰
    if !IsValidHwnd(gameWindow) {
        logger.log("OCRWindow: gameWindow 無效，嘗試重新尋找視窗", "WARN")
        if !FindGameWindow() || !IsValidHwnd(gameWindow) {
            logger.log("OCRWindow: 無法取得有效遊戲視窗", "ERROR")
            return false
        }
    }
    
    ; 截圖並 OCR
    tempFile := A_ScriptDir "\temp_synthesis_" A_TickCount ".png"
    
    try {
        if !IsValidHwnd(gameWindow) {
            logger.log("OCRWindow: 截圖前視窗已失效", "WARN")
            return false
        }
        ImagePutFile(gameWindow, tempFile)
        result := ocrEngine.ocr_from_file(tempFile, , true)
        
        ; 清理暫存檔
        if FileExist(tempFile)
            FileDelete(tempFile)
        
        return result
        
    } catch as e {
        logger.log("OCR 失敗: " e.Message, "ERROR")
        if FileExist(tempFile)
            FileDelete(tempFile)
        return false
    }
}

IsValidHwnd(hwnd) {
    try {
        return !!(hwnd && DllCall("IsWindow", "ptr", hwnd, "int"))
    } catch {
        return false
    }
}

CleanText(text) {
    ; 移除換行與空白
    text := StrReplace(StrReplace(text, "`r", ""), "`n", "")
    text := StrReplace(text, " ", "")
    return ToSimp(text)
}

ToSimp(s) {
    ; 繁體轉簡體（常用詞）
    static phrase := Map(
        "數據屋", "数据坞",
        "終端", "终端",
        "設置", "设置",
        "確認", "确认",
        "確定", "确定",
        "已棄置", "已弃置",
        "批量融合", "批量融合",
        "全選", "全选"
    )
    
    for trad, simp in phrase {
        s := StrReplace(s, trad, simp)
    }
    
    return s
}
