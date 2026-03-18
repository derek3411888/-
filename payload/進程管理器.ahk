#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir

; ⚡ 設定普通優先級以減少系統負擔
ProcessSetPriority("Normal")

; DPI 感知（避免縮放改變座標/影像）
try DllCall("SetProcessDpiAwarenessContext", "ptr", -4)  ; PER_MONITOR_AWARE_V2
catch 
    try DllCall("shcore\SetProcessDpiAwareness", "int", 2)

; 引入必要的外部模組
#Include LogManager.ahk
#Include plugin\RapidOcr\RapidOcr.ahk
#Include plugin\ImagePut-1.11\ImagePut.ahk

; 鍵盤更穩
SendMode "Input"
SetKeyDelay 40, 40

; ===================== 進程管理員 =====================
; 此腳本用於解決EXE打包後重複啟動問題
; 請將此腳本放在payload目錄下，並由打包啟動器調用

; 初始化新的日誌系統
global logger := InitLogger("進程管理器")
global RUN_ID := A_Now "@" A_TickCount
global STEP_SEQ := 0

ShowTip(msg, duration := 900) {
    ToolTip "          " msg
    if (duration > 0)
        SetTimer(() => ToolTip(), -duration)
}

; 日誌函數（使用新的日誌系統）
WriteLog(msg, level := "INFO") {
    global logger, RUN_ID
    if IsSet(logger) && IsObject(logger) {
        logger.log("[" RUN_ID "] " msg, level)
    } else {
        ; 備用方案
        ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        line := ts " [" level "] [" RUN_ID "] " msg "`r`n"
        try FileAppend(line, A_ScriptDir "\process_manager_fallback.log", "UTF-8")
    }
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

WriteLog("進程管理器啟動: PID=" DllCall("GetCurrentProcessId"))
WriteStep("啟動", "AHK=" A_AhkVersion)

; 使用互斥量確保單一實例（增強版）
global uniqueID := "OKWW_EXE_ProcessManager_SingleInstance_V2"
global singletonMutex := DllCall("CreateMutex", "Ptr", 0, "Int", 1, "Str", uniqueID, "Ptr") ; 注意：第二個參數設為1，表示需要立即擁有互斥量
global lastError := DllCall("GetLastError")
WriteStep("單例鎖", "mutex=" uniqueID " lastError=" lastError)

; 檢查是否已經有實例在運行
if (lastError = 183) { ; ERROR_ALREADY_EXISTS
    WriteLog("檢測到另一個進程管理器實例正在運行，本實例將退出", "WARN")
    
    ; 查找其他進程管理器進程並顯示其PID
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%AutoHotkey%'") {
            try {
                cmdLine := proc.CommandLine
                if (InStr(cmdLine, "進程管理器.ahk")) {
                    WriteLog("已發現運行中的進程管理器: PID=" proc.ProcessId " 命令行=" cmdLine, "INFO")
                }
            } 
        }
    } catch as e {
        WriteLog("查找其他進程管理器進程失敗: " e.Message, "ERROR")
    }
    
    MsgBox("進程管理器已在運行，本實例將退出。", "單一實例檢查", 48)
    ExitApp
}

; 註冊退出時釋放互斥量
OnExit(ExitFunc)

; 退出時釋放互斥量
ExitFunc(ExitReason, ExitCode) {
    global singletonMutex
    if (singletonMutex) {
        WriteLog("釋放進程互斥量，退出原因: " ExitReason " 代碼: " ExitCode)
        DllCall("CloseHandle", "Ptr", singletonMutex)
    }
    return 0
}

; 全域變數（使用實際檢測到的程式名稱）
global OKWW_TITLE := ["OK-WW", "OKWW"]  ; 視窗標題關鍵字
global OKWW_EXE := ["ok-ww.exe", "pythonw.exe"]  ; OKWW主程式和更新檢測程式
global GAME_TITLE := ["鸣潮", "鳴潮"]   ; 遊戲視窗標題  
global GAME_EXE := ["Client-Win64-Shipping.exe"]  ; 遊戲實際程式名稱
global LRMC_EXE := ["LRMCAI.exe"]      ; LRMC程式名稱
global OKWW_ProcessID := 0
global LRMC_ProcessID := 0
global AlreadyRunningOKWW := false
global GAME_HWND := 0
global MonitorTimer := ""

; 獲取 AutoHotkey 執行檔路徑（增強版尋找方式）
global AhkExe := ""

; 嘗試尋找 AutoHotkey 執行檔的所有可能位置（按優先順序）
potentialPaths := [
    ; 1. 打包環境（新位置：自動鋤地資料夾）
    A_ScriptDir "\..\AutoHotkey64.exe",               ; 上層目錄（打包啟動器旁）
    A_ScriptDir "\AutoHotkey64.exe",                  ; 當前目錄
    A_Temp "\okww_runtime\AutoHotkey64.exe",          ; 舊的臨時目錄（向後兼容）
    
    ; 2. 標準安裝路徑
    EnvGet("ProgramFiles") "\AutoHotkey\AutoHotkey.exe",
    EnvGet("ProgramW6432") "\AutoHotkey\AutoHotkey.exe",
    EnvGet("ProgramFiles(x86)") "\AutoHotkey\AutoHotkey.exe",
    
    ; 3. 其他常見位置
    A_ProgramFiles "\AutoHotkey\AutoHotkey.exe",
    A_MyDocuments "\..\AutoHotkey\AutoHotkey.exe",
    "C:\Program Files\AutoHotkey\AutoHotkey.exe",
    "C:\AutoHotkey\AutoHotkey.exe"
]

; 遍歷所有可能路徑
WriteStep("尋找AutoHotkey", "開始檢查候選路徑")
for path in potentialPaths {
    if (path && FileExist(path)) {
        AhkExe := path
        WriteLog("找到 AutoHotkey 執行檔: " AhkExe)
        break
    }
}

; 如果直接查找失敗，嘗試搜索 PATH 環境變量
if (!AhkExe) {
    pathEnv := EnvGet("PATH")
    if (pathEnv) {
        for dir in StrSplit(pathEnv, ";") {
            ; 檢查多種可能的檔名
            possibleNames := ["AutoHotkey.exe", "AutoHotkey64.exe", "AutoHotkeyU64.exe", "AutoHotkeyU32.exe"]
            for exeName in possibleNames {
                fullPath := dir "\" exeName
                if (FileExist(fullPath)) {
                    AhkExe := fullPath
                    WriteLog("在 PATH 中找到 AutoHotkey: " AhkExe)
                    break 2  ; 跳出兩層循環
                }
            }
        }
    }
}

; 如果上述都找不到，最後嘗試環境變量
if (!AhkExe) {
    ahkPath := EnvGet("AutoHotkeyPath")
    if (ahkPath && FileExist(ahkPath)) {
        AhkExe := ahkPath
        WriteLog("從環境變量 AutoHotkeyPath 找到: " AhkExe)
    }
}

; 如果所有嘗試都失敗，顯示錯誤並退出
if !AhkExe || !FileExist(AhkExe) {
    errMsg := "找不到 AutoHotkey 執行檔。請確保以下任一條件：`n"
    errMsg .= "1. 系統已安裝 AutoHotkey v2.0+，或`n"
    errMsg .= "2. 打包時包含了 AutoHotkey64.exe，或`n"
    errMsg .= "3. 將 AutoHotkey64.exe 放置在以下位置之一：`n"
    errMsg .= "   - " A_ScriptDir "\..\AutoHotkey64.exe`n"
    errMsg .= "   - " A_ScriptDir "\AutoHotkey64.exe`n"
    errMsg .= "   - " A_Temp "\okww_runtime\AutoHotkey64.exe (舊位置)`n"
    
    ; 尋找在打包啟動器.ahk中使用FileInstall的情況
    pakFile := A_ScriptDir "\..\打包啟動器.ahk"
    if FileExist(pakFile) {
        WriteLog("正在檢查打包啟動器的FileInstall設定...")
        try {
            fileContent := FileRead(pakFile, "UTF-8")
            if InStr(fileContent, "FileInstall") && InStr(fileContent, "AutoHotkey64.exe") {
                errMsg .= "`n注意：打包啟動器中有 FileInstall 命令嘗試包含 AutoHotkey64.exe，但找不到此檔案。"
                errMsg .= "`n      請確保在編譯前，AutoHotkey64.exe 與打包啟動器.ahk 在同一目錄。"
            }
        } catch as e {
            WriteLog("檢查打包啟動器時出錯: " e.Message, "ERROR")
        }
    }
    
    MsgBox(errMsg, "AutoHotkey執行檔錯誤", 16)
    ExitApp
}

; ===================== 主流程 =====================
; 進程管理器的新角色：
; - 不再主動啟動OKWW和LRMC（由全自動.ahk負責）
; - 專注於監控已啟動的進程
; - 提供進程管理和視窗佈局功能

WriteLog("進程管理器啟動，開始監控現有進程...")

; 檢查並記錄現有的OKWW進程
CheckExistingOKWW()

; 開始持續監控
MonitorProcesses()

; ===================== 函數區 =====================

; 檢查是否已有OKWW運行
CheckExistingOKWW() {
    WriteLog("檢查是否已有OKWW運行...")
    global AlreadyRunningOKWW := false
    
    ; 通過視窗標題查找OKWW程式
    for _, title in OKWW_TITLE {
        for hwnd in WinGetList("ahk_title *" title "*") {
            try {
                pid := WinGetPID(hwnd)
                processName := WinGetProcessName(hwnd)
                windowTitle := WinGetTitle(hwnd)
                
                ; 確保是pythonw.exe且視窗標題包含OKWW
                if (processName = "pythonw.exe" && InStr(windowTitle, "OK-WW")) {
                    WriteLog("發現運行中的OKWW程式: " windowTitle " (PID: " pid ")")
                    global OKWW_ProcessID := pid
                    global AlreadyRunningOKWW := true
                    
                    ; 試著激活窗口，但不強制關閉
                    try WinActivate("ahk_id " hwnd)
                    
                    return true
                }
            } catch as e {
                WriteLog("檢查視窗進程失敗: " e.Message, "WARN")
            }
        }
    }
    
    ; 通過進程名查找
    for _, exeName in OKWW_EXE {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%" exeName "%'") {
            try {
                pid := proc.ProcessId
                WriteLog("發現運行中的OKWW進程: " exeName " (PID: " pid ")")
                global OKWW_ProcessID := pid
                global AlreadyRunningOKWW := true
                return true
            } catch as e {
                WriteLog("檢查執行檔進程失敗: " e.Message, "WARN")
            }
        }
    }
    
    WriteLog("未發現運行中的OKWW")
    return false
}

; 等待OKWW窗口出現
WaitForOKWWWindow() {
    WriteLog("等待OKWW窗口出現...")
    maxWaitTime := 120  ; 最多等待120秒
    startTime := A_TickCount
    
    while (A_TickCount - startTime < maxWaitTime * 1000) {
        ; 查找OKWW窗口
        for _, title in OKWW_TITLE {
            hwnd := WinExist("ahk_title *" title "*") 
            if (hwnd) {
                pid := WinGetPID(hwnd)
                WriteLog("找到OKWW窗口: 標題含 " title " (PID: " pid "), 耗時" Round((A_TickCount - startTime) / 1000) "秒")
                global OKWW_ProcessID := pid
                
                ; 嘗試激活窗口
                try {
                    WinActivate("ahk_id " hwnd)
                    Sleep 500
                } catch as e {
                    WriteLog("激活窗口失敗: " e.Message, "WARN")
                }
                
                return true
            }
        }
        
        ; 每1秒檢查一次
        Sleep 1000
        
        ; 每10秒輸出一條日誌
        if (Mod(Round((A_TickCount - startTime) / 1000), 10) = 0) {
            WriteLog("仍在等待OKWW窗口出現，已等待" Round((A_TickCount - startTime) / 1000) "秒")
        }
    }
    
    WriteLog("等待OKWW窗口超時", "WARN")
    return false
}

; 監控所有已啟動的進程
MonitorProcesses() {
    WriteLog("開始監控已啟動的進程...")
    SetTimer MonitorTick, 10000  ; 從5秒改為10秒，減少系統負擔
    
    ; 創建系統托盤圖標（使用默認圖標，避免找不到檔案錯誤）
    try {
        if FileExist("menu.png") {
            TraySetIcon("menu.png", , 1)
        } else {
            ; 使用系統默認圖標
            TraySetIcon("shell32.dll", 25, 1)  ; 使用系統監控圖標
        }
    } catch as e {
        WriteLog("設置托盤圖標失敗: " e.Message, "WARN")
        ; 使用默認圖標
        TraySetIcon("shell32.dll", 25, 1)
    }
    A_TrayMenu.Add()
    A_TrayMenu.Add("退出管理器", ExitHandler)
    A_TrayMenu.Default := "退出管理器"
    
    ; 啟動OKWW窗口監控
    SetTimer OKWWWindowMonitor, 8000  ; 從3秒改為8秒，減少系統負擔
    
    ; 等待用戶手動關閉
    Loop {
        Sleep 30000  ; 從10秒改為30秒，大幅減少主循環負擔
    }
}

; OKWW窗口監控
OKWWWindowMonitor() {
    static lastWindowHandle := 0
    static pidChangeCount := 0
    
    ; 檢查OKWW窗口
    okwwHwnd := 0
    for _, title in OKWW_TITLE {
        hwnd := WinExist("ahk_title *" title "*")
        if (hwnd) {
            okwwHwnd := hwnd
            break
        }
    }
    
    ; 如果找到窗口
    if (okwwHwnd) {
        ; 獲取PID
        currentPid := WinGetPID(okwwHwnd)
        
        ; 與已知的PID比較
        if (currentPid != OKWW_ProcessID && OKWW_ProcessID != 0) {
            pidChangeCount++
            WriteLog("檢測到OKWW窗口PID變化: " OKWW_ProcessID " -> " currentPid " (變化次數: " pidChangeCount ")")
            
            ; 更新PID信息，但不關閉原有進程
            global OKWW_ProcessID := currentPid
        }
        
        ; 如果窗口句柄改變
        if (okwwHwnd != lastWindowHandle) {
            WriteLog("檢測到OKWW窗口句柄變化: " lastWindowHandle " -> " okwwHwnd)
            lastWindowHandle := okwwHwnd
            
            ; 嘗試激活窗口
            try {
                WinActivate("ahk_id " okwwHwnd)
            } catch as e {
                WriteLog("激活窗口失敗: " e.Message, "WARN")
            }
        }
    } else if (OKWW_ProcessID) {
        ; 如果找不到窗口但PID還在，可能在更新過程中
        if (ProcessExist(OKWW_ProcessID)) {
            WriteLog("OKWW進程存在 (PID: " OKWW_ProcessID ") 但找不到窗口，可能在更新或啟動中")
        } else {
            WriteLog("OKWW進程已結束 (PID: " OKWW_ProcessID ") 且找不到窗口", "WARN")
            global OKWW_ProcessID := 0
        }
    }
}

; 監控計時器回調
MonitorTick() {
    static lastOKWWState := 0, lastLRMCState := 0
    static okwwCheckCount := 0
    
    ; 檢查OKWW進程
    okwwAlive := false
    if (OKWW_ProcessID && ProcessExist(OKWW_ProcessID)) {
        okwwAlive := true
    } else {
        ; 如果原始PID不存在，嘗試搜索窗口
        okwwCheckCount++
        
        ; 每30秒（6次x5秒）進行一次完整檢查，避免頻繁搜索
        if (okwwCheckCount >= 6) {
            okwwCheckCount := 0
            for _, title in OKWW_TITLE {
                hwnd := WinExist("ahk_title *" title "*")
                if (hwnd) {
                    newPid := WinGetPID(hwnd)
                    if (newPid) {
                        WriteLog("重新檢測到OKWW窗口: 標題含 " title " (新PID: " newPid ")")
                        global OKWW_ProcessID := newPid
                        okwwAlive := true
                        break
                    }
                }
            }
        }
    }
    
    if (okwwAlive != lastOKWWState) {
        if (okwwAlive)
            WriteLog("OKWW進程已恢復: " OKWW_ProcessID)
        else
            WriteLog("OKWW進程已終止: " OKWW_ProcessID, "WARN")
        lastOKWWState := okwwAlive
    }
    
    ; 檢查LRMC進程
    lrmcAlive := ProcessExist(LRMC_ProcessID) ? true : false
    if (lrmcAlive != lastLRMCState) {
        if (lrmcAlive)
            WriteLog("LRMC進程已恢復: " LRMC_ProcessID)
        else
            WriteLog("LRMC進程已終止: " LRMC_ProcessID, "WARN")
        lastLRMCState := lrmcAlive
    }
    
    ; 檢查遊戲進程狀態 - 記錄狀態但不自動退出
    gameAlive := (GAME_HWND && WinExist("ahk_id " GAME_HWND))
    
    ; 記錄進程狀態變化，但不自動退出監控程序
    if (!okwwAlive || !lrmcAlive || !gameAlive) {
        WriteLog("檢測到被監控進程狀態變化", "INFO")
        if (!okwwAlive)
            WriteLog("狀態: OKWW進程已關閉", "INFO")
        if (!lrmcAlive)
            WriteLog("狀態: LRMC進程已關閉", "INFO")
        if (!gameAlive)
            WriteLog("狀態: 遊戲窗口已關閉", "INFO")
        
        WriteLog("監控程序繼續運行，等待進程重新啟動", "INFO")
    }
}

; 關閉並退出處理程序
ExitHandler(ItemName, ItemPos, MyMenu) {
    WriteLog("用戶請求退出進程管理器")
    
    ; 停止所有計時器
    SetTimer MonitorTick, 0
    SetTimer OKWWWindowMonitor, 0
    
    ; 只關閉由本管理器啟動的LRMC進程
    if (LRMC_ProcessID && ProcessExist(LRMC_ProcessID)) {
        WriteLog("正在關閉LRMC進程 (PID: " LRMC_ProcessID ")...")
        try ProcessClose LRMC_ProcessID
    }

    ; --------------------------------------------------------------------------
    ; 重要：不再主動關閉任何 OKWW 或 鳴潮 相關進程。
    ; 讓用戶自行管理遊戲和OKWW客戶端的生命週期。
    ; --------------------------------------------------------------------------
    WriteLog("LRMC進程已清理。OKWW/鳴潮進程將保持運行。進程管理器即將退出")
    Sleep 500
    ExitApp
}

; 新增：LRMC視窗佈局函數
ArrangeLrmcWindows() {
    WriteLog("開始執行LRMC視窗佈局調整...")
    SetTitleMatchMode 2 ; 模式2：標題可以包含指定文字

    ; --- 1. 處理 LRMC 主面板 (圖像一) ---
    panelTitle := "F8暂停","F9停止","F10标记"
    WriteLog("等待 " panelTitle " 視窗出現...")
    panelHwnd := 0
    if WinWait(panelTitle,, 20) {
        panelHwnd := WinExist(panelTitle)
        WriteLog(panelTitle " 視窗已找到 (HWND: " panelHwnd ")，將其移動到左側。")
        
        try WinRestore("ahk_id " panelHwnd)
        Sleep 200
        
        WinGetPos(,, &w, &h, "ahk_id " panelHwnd)
        newW := w > 0 ? w : 400 ; 如果獲取寬度失敗，給一個預設值
        
        ; 使用工作區域信息
        workArea := GetWorkArea()
        
        ; 移動到左側，並填滿工作區域高度（貼齊工作列）
        WinMove(0, 0, newW, workArea.height, "ahk_id " panelHwnd)
        WriteLog("已將 " panelTitle " 視窗移動到左側並調整高度（貼齊工作列）。")
    } else {
        WriteLog("等待 " panelTitle " 視窗超時，跳過佈局。", "WARN")
    }
    
    Sleep 500 ; 等待一下

    ; --- 2. 處理 LRMC 日誌視窗 (圖像二) ---
    logTitle := "LRMCAI"
    WriteLog("尋找 " logTitle " 日誌視窗...")
    
    logHwnd := 0
    ; 遍歷所有標題為 "LRMCAI" 的視窗
    for hwnd in WinGetList(logTitle) {
        ; 如果這個視窗的句柄不是剛才找到的面板句柄，那它就是日誌視窗
        if (hwnd != panelHwnd) {
            logHwnd := hwnd
            break
        }
    }

    if (logHwnd) {
        WriteLog("日誌視窗已找到 (HWND: " logHwnd ")，將其移動到右下角。")
        
        try WinRestore("ahk_id " logHwnd)
        Sleep 200

        WinGetPos(,, &w, &h, "ahk_id " logHwnd)
        if (w > 0 && h > 0) {
            ; 使用工作區域信息
            workArea := GetWorkArea()
            
            newX := A_ScreenWidth - w
            newY := workArea.height - h
            WinMove(newX, newY, w, h, "ahk_id " logHwnd)
            WriteLog("已將日誌視窗移動到右下角（貼齊工作列）。")
        } else {
            WriteLog("無法獲取日誌視窗的尺寸，跳過移動。", "WARN")
        }
    } else {
        WriteLog("未找到 " logTitle " 日誌視窗，跳過佈局。", "WARN")
    }
}

; 更新偵測函數 (改為等待3.5秒檢測方式，重複多次以免沒截圖到)
DetectWutheringAndExit() {
    SetTitleMatchMode 2
    if !WinWait("鸣潮",, 60) && !WinWait("鳴潮",, 5) {
        WriteLog("找不到「鸣潮/鳴潮」視窗（逾時）")
        return false
    }

    hwnd := WinExist("鸣潮") ? WinExist("鸣潮") : WinExist("鳴潮")
    if (!hwnd) {
        WriteLog("無法獲取游戲窗口句柄")
        return false
    }

    ; 視窗貼齊右上角（確保在螢幕內）
    MoveWindowTopRight(hwnd, 0, 0)

    WriteLog("開始檢測游戲是否需要更新（3.5秒等待方式，重複5次檢測）...")
    
    ocr := RapidOcr()
    
    ; 重複檢測5次，每次等待3.5秒後截圖檢測
    Loop 5 {
        currentCheck := A_Index
        WriteLog("第 " currentCheck " 次檢測，等待3.5秒後截圖...")
        
        ; 等待3.5秒
        Sleep 3500
        
        ; 確認視窗仍然存在
        if WinExist("鸣潮")
            hwnd := WinExist("鸣潮")
        else if WinExist("鳴潮")
            hwnd := WinExist("鳴潮")
        else {
            WriteLog("第 " currentCheck " 次檢測時視窗已消失")
            break
        }

        ; 截圖並進行OCR檢測
        try {
            ImagePutFile(hwnd, "temp.png")
            res := ocr.ocr_from_file("temp.png", , true)
            
            WriteLog("第 " currentCheck " 次檢測截圖完成，進行OCR分析...")

            if IsObject(res) {
                updateFound := false
                updateCompleted := false
                confirmButton := ""
                
                for block in res {
                    clean := StrReplace(StrReplace(block.text, "`r", ""), "`n", "")
                    clean := StrReplace(clean, " ", "")
                    
                    ; 檢測更新完成相關文字
                    if (InStr(clean, "更新完成") || InStr(clean, "请重新启动游戏") || 
                        InStr(clean, "更新完畢") || InStr(clean, "請重新啟動遊戲") ||
                        InStr(clean, "遊戲即將重啟") || InStr(clean, "游戏即将重启")) {
                        WriteLog("第 " currentCheck " 次檢測發現更新完成文字: " clean)
                        updateCompleted := true
                    }
                    
                    ; 檢測進行中的更新文字
                    if (InStr(clean, "更新中") || InStr(clean, "下载中") || InStr(clean, "下載中") || 
                        InStr(clean, "正在更新") || InStr(clean, "资源包") || InStr(clean, "資源包")) {
                        WriteLog("第 " currentCheck " 次檢測發現更新進行中文字: " clean)
                        updateFound := true
                    }
                    
                    ; 尋找確認相關按鈕
                    if (InStr(clean, "確認") || InStr(clean, "确认") || 
                        InStr(clean, "確定") || InStr(clean, "确定") || 
                        InStr(clean, "OK")) {
                        if (block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3) {
                            x1 := block.boxPoint[1].x, y1 := block.boxPoint[1].y
                            x2 := block.boxPoint[3].x, y2 := block.boxPoint[3].y
                            confirmButton := [Round((x1 + x2) / 2), Round((y1 + y2) / 2)]
                            WriteLog("第 " currentCheck " 次檢測找到確認按鈕: " confirmButton[1] "," confirmButton[2])
                        }
                    }
                }
                
                ; 如果檢測到更新完成且有確認按鈕，立即點擊
                if (updateCompleted && IsObject(confirmButton)) {
                    WriteLog("檢測到更新完成，立即點擊確認按鈕")
                    MouseClick("left", confirmButton[1], confirmButton[2])
                    Sleep(2000)
                    return true
                } else if (updateCompleted) {
                    WriteLog("檢測到更新完成但找不到確認按鈕，返回更新完成狀態")
                    return true
                }
                
                ; 如果只是檢測到更新進行中，繼續等待
                if (updateFound) {
                    ; 如果發現更新相關文字，繼續等待更長時間
                    WriteLog("發現更新訊息，繼續等待更新完成...")
                    
                    ; 額外等待更新完成（最多30分鐘）
                    waitStart := A_TickCount
                    while (A_TickCount - waitStart < 1800000) {  ; 30分鐘
                        Sleep 10000  ; 每10秒檢查一次
                        
                        if WinExist("鸣潮")
                            hwnd := WinExist("鸣潮")
                        else if WinExist("鳴潮")
                            hwnd := WinExist("鳴潮")
                        else {
                            WriteLog("更新過程中視窗消失，可能已完成")
                            return true
                        }
                        
                        try {
                            ImagePutFile(hwnd, "temp.png")
                            updateRes := ocr.ocr_from_file("temp.png", , true)
                            
                            if IsObject(updateRes) {
                                updateCompleted := false
                                confirmButton := ""
                                
                                for updateBlock in updateRes {
                                    updateClean := StrReplace(StrReplace(updateBlock.text, "`r", ""), "`n", "")
                                    updateClean := StrReplace(updateClean, " ", "")
                                    
                                    ; 檢查是否更新完成
                                    if (InStr(updateClean, "更新完成") || InStr(updateClean, "请重新启动游戏") || 
                                        InStr(updateClean, "更新完畢") || InStr(updateClean, "請重新啟動遊戲") ||
                                        InStr(updateClean, "遊戲即將重啟") || InStr(updateClean, "游戏即将重启")) {
                                        WriteLog("檢測到更新完成訊息: " updateClean)
                                        updateCompleted := true
                                    }
                                    
                                    ; 尋找確認按鈕
                                    if (InStr(updateClean, "確認") || InStr(updateClean, "确认") || 
                                        InStr(updateClean, "確定") || InStr(updateClean, "确定") || 
                                        InStr(updateClean, "OK")) {
                                        if (updateBlock.HasOwnProp("boxPoint") && updateBlock.boxPoint.Length >= 3) {
                                            x1 := updateBlock.boxPoint[1].x, y1 := updateBlock.boxPoint[1].y
                                            x2 := updateBlock.boxPoint[3].x, y2 := updateBlock.boxPoint[3].y
                                            confirmButton := [Round((x1 + x2) / 2), Round((y1 + y2) / 2)]
                                            WriteLog("找到確認按鈕位置: " confirmButton[1] "," confirmButton[2])
                                        }
                                    }
                                }
                                
                                ; 如果找到更新完成且有確認按鈕，就點擊它
                                if (updateCompleted && IsObject(confirmButton)) {
                                    WriteLog("檢測到更新完成，點擊確認按鈕")
                                    MouseClick("left", confirmButton[1], confirmButton[2])
                                    Sleep(2000)
                                    return true
                                } else if (updateCompleted) {
                                    WriteLog("檢測到更新完成但找不到確認按鈕")
                                    return true
                                }
                            }
                        } catch as e {
                            WriteLog("更新等待過程中OCR失敗: " e.Message, "WARN")
                        }
                    }
                    
                    WriteLog("更新等待逾時，繼續執行...")
                    return true
                }
                
                if (!updateFound) {
                    WriteLog("第 " currentCheck " 次檢測未發現更新相關文字")
                }
            } else {
                WriteLog("第 " currentCheck " 次檢測OCR解析失敗")
            }
        } catch as e {
            WriteLog("第 " currentCheck " 次檢測截圖或OCR失敗: " e.Message, "WARN")
        }
    }
    
    WriteLog("完成5次檢測，未發現更新訊息，繼續正常流程")
    return false
}

; 獲取工作區域信息（排除工作列）
GetWorkArea() {
    rect := Buffer(16)
    DllCall("SystemParametersInfo", "UInt", 48, "UInt", 0, "Ptr", rect, "UInt", 0) ; SPI_GETWORKAREA
    return {
        left: NumGet(rect, 0, "Int"),
        top: NumGet(rect, 4, "Int"), 
        right: NumGet(rect, 8, "Int"),
        bottom: NumGet(rect, 12, "Int"),
        width: NumGet(rect, 8, "Int") - NumGet(rect, 0, "Int"),
        height: NumGet(rect, 12, "Int") - NumGet(rect, 4, "Int")
    }
}

; 將指定窗口貼齊螢幕右上角；若過大則縮到螢幕內（完全貼邊）
MoveWindowTopRight(hwnd, marginX := 0, marginY := 0) {
    if !hwnd {
        WriteLog("MoveWindowTopRight: 無效的視窗句柄", "ERROR")
        return false
    }
    
    ; 嘗試最多3次
    Loop 3 {
        attempt := A_Index
        WriteLog("嘗試移動視窗到右上角 (第 " attempt " 次)...")
        
        try {
            ; 先還原視窗（避免最大化無法移動）
            WinRestore "ahk_id " hwnd
            Sleep 200  ; 等待視窗還原完成
            
            ; 確保視窗在前台
            WinActivate "ahk_id " hwnd
            Sleep 100
        } catch as e {
            WriteLog("視窗還原失敗: " e.Message, "WARN")
        }

        try {
            WinGetPos &x, &y, &w, &h, "ahk_id " hwnd
            if (w = "" || h = "" || w <= 0 || h <= 0) {
                WriteLog("無法取得視窗尺寸: w=" w ", h=" h, "ERROR")
                if (attempt < 3) {
                    Sleep 500
                    continue
                }
                return false
            }

            sw := A_ScreenWidth, sh := A_ScreenHeight
            maxW := sw  ; 完全貼邊，不保留邊距
            maxH := sh  ; 完全貼邊，不保留邊距
            newW := (w > maxW) ? maxW : w
            newH := (h > maxH) ? maxH : h

            newX := sw - newW  ; 完全貼齊右邊
            newY := 0          ; 完全貼齊上邊
            
            WriteLog("移動視窗: 從 (" x "," y "," w "," h ") 到 (" newX "," newY "," newW "," newH ")")
            WinMove newX, newY, newW, newH, "ahk_id " hwnd
            Sleep 300  ; 等待視窗移動完成
            
            ; 驗證移動結果
            WinGetPos &actualX, &actualY, , , "ahk_id " hwnd
            if (Abs(actualX - newX) <= 10 && Abs(actualY - newY) <= 10) {
                WriteLog("✓ 視窗成功移動到右上角 (" actualX "," actualY ")")
                return true
            } else {
                WriteLog("視窗移動位置不正確: 目標(" newX "," newY ") vs 實際(" actualX "," actualY ")", "WARN")
                if (attempt < 3) {
                    Sleep 500
                    continue
                }
            }
        } catch as e {
            WriteLog("視窗移動失敗: " e.Message, "ERROR")
            if (attempt < 3) {
                Sleep 500
                continue
            }
            return false
        }
    }
    
    WriteLog("視窗移動失敗（已達最大重試次數）", "ERROR")
    return false
}

; 繁→簡（常見詞）
ToSimp(s) {
    static phrase := Map(
        "終端","终端","活動","活动","商城","商城","喚取","唤取","共鳴者","共鸣者","編隊","编队",
        "教程百科","教程百科","任務","任务","好友","好友","成就","成就","設置","设置","地圖","地图",
        "相機","相机","郵件","邮件","社交","社交","數據","数据","索拉指南","索拉指南","先約電台","先约电台"
    )
    for k, v in phrase
        s := StrReplace(s, k, v)

    static single := Map("終","终","鳴","鸣","隊","队","動","动","設","设","圖","图","編","编","術","术","學","学","裝","装","體","体","導","导","頁","页","數","数","約","约","電","电")
    for k, v in single
        s := StrReplace(s, k, v)

    return s
}

; 去抖動整窗版 ESC 菜單 OCR（檢測遊戲是否可操作）
WaitEscMenuOCR(hwnd, timeoutSec := 120) {
    if !hwnd {
        hwnd := WinExist("鸣潮") ? WinExist("鸣潮") : WinExist("鳴潮")
        if !hwnd
            return false
    }

    WriteLog("開始檢測遊戲是否可操作（ESC菜單測試）...")

    ocr := RapidOcr()
    ; 主選單常見詞（簡體）
    kws := ["终端","活动","商城","先约电台","唤取","共鸣者","编队",
            "数据坞","教程","百科","索拉指南","任务","好友","成就",
            "合成","设置","地图","相机","邮件","社交"]

    needHitsPerFrame := 4
    stableNeeded     := 2
    cooldownMs       := 900
    lastEsc := 0
    stable  := 0
    menuOpen := false

    deadline := A_TickCount + timeoutSec*1000
    while (A_TickCount < deadline) {
        try WinActivate "ahk_id " hwnd
        Sleep 120

        if (!menuOpen && (A_TickCount - lastEsc >= cooldownMs)) {
            Send "{Esc}"
            lastEsc := A_TickCount
            Sleep 650
        }

        ; 使用臨時檔案進行OCR處理，避免權限問題
        tempFile := A_Temp "\pm_menu_" A_TickCount ".png"
        try {
            ImagePutFile(hwnd, tempFile)
            res := ocr.ocr_from_file(tempFile, , true)
            ; 清理臨時檔案
            FileDelete(tempFile)
        } catch as e {
            WriteLog("OCR處理失敗: " e.Message, "WARN")
            try FileDelete(tempFile)  ; 確保清理
            return false
        }

        hits := 0
        if IsObject(res) {
            for block in res {
                t := block.text
                t := StrReplace(StrReplace(t, "`r",""), "`n","")
                t := StrReplace(t, " ", "")
                t := ToSimp(t)
                for _, kw in kws {
                    if InStr(t, kw) {
                        hits++
                        break
                    }
                }
            }
        }

        if (hits >= needHitsPerFrame) {
            menuOpen := true
            stable += 1
            WriteLog("菜單檢測進度: " stable "/" stableNeeded "（匹配關鍵詞: " hits "個）")
            Sleep 300
            if (stable >= stableNeeded) {
                Send "{Esc}"  ; 關掉選單以免擋畫面
                Sleep 2000
                WriteLog("確認遊戲可操作")
                return true
            }
        } else {
            menuOpen := false
            stable := 0
        }

        Sleep 500
    }
    
    WriteLog("遊戲可操作檢測超時", "WARN")
    return false
}
