#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir

#Include plugin\RapidOcr\RapidOcr.ahk
#Include plugin\ImagePut-1.11\ImagePut.ahk
#Include LogManager.ahk

; 初始化新的日誌系統
global logger := InitLogger("開啟LRMC")
RegisterLifecycleLogging("開啟LRMC")
global RUN_ID := A_Now "@" A_TickCount
global STEP_SEQ := 0
global TOOLTIP_SLOT := 4
global TOOLTIP_UNTIL_TICK := 0
global TOOLTIP_CONTENT := ""
global HOTKEY_MODE := false
global BUNDLED_AHK_EXE := ResolveBundledAhkExe()

if A_Args.Length > 0 && A_Args[1] = "hotkey" {
    HOTKEY_MODE := true
    Log("檢測到 hotkey 模式，將略過 OCR『副本』搜尋")
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
        try FileAppend(line, A_ScriptDir "\lrmc_fallback.log", "UTF-8")
    }
}

WriteStep(stepName, detail := "", level := "INFO") {
    global STEP_SEQ
    STEP_SEQ += 1
    stepId := Format("{:03}", STEP_SEQ)
    msg := "[STEP " stepId "] " stepName
    if (detail != "")
        msg .= " | " detail
    WriteLog(msg, level)
    tip := "📌 STEP " stepId "｜" stepName
    if (detail != "")
        tip .= "`nℹ " detail
    ShowTip(tip)
}

Log("LRMC 啟動腳本開始: " A_ScriptFullPath)
WriteStep("啟動", "PID=" DllCall("GetCurrentProcessId") " AHK=" A_AhkVersion)

; 設置進程優先級為普通，避免佔用過多系統資源
try {
    ProcessSetPriority("Normal", DllCall("GetCurrentProcessId"))
    Log("已設置進程優先級為 Normal")
} catch as e {
    Log("設置進程優先級失敗: " e.Message, "WARN")
}

; 管理員提權
if !A_IsAdmin {
    Log("需要管理員權限，嘗試提權...")
    if FileExist(BUNDLED_AHK_EXE) {
        try {
            Run('*RunAs "' BUNDLED_AHK_EXE '" "' A_ScriptFullPath '"')
        }
    } else {
        MsgBox "找不到 AutoHotkey64.exe，請先執行「打包啟動器」完成解壓。"
    }
    ExitApp
}

; ===== 路徑處理（優先使用打包啟動器設定的環境變數）=====
dataDir := EnvGet("PACK_DATA_DIR")
if (dataDir = "") {
    ; 如果沒有環境變數，嘗試使用新的位置
    dataDir := A_ScriptDir "\..\config"
    if !DirExist(dataDir) {
        ; 向後兼容舊位置
        dataDir := A_Temp "\okww_runtime\config"
    }
}
DirCreate dataDir
global CFG_FILE := dataDir "\config.ini"

; 顯示提示時避免被游標遮住（開頭加5個空白）
ShowTip(msg, duration := 5000) {
    global TOOLTIP_SLOT, TOOLTIP_UNTIL_TICK, TOOLTIP_CONTENT
    if (duration < 3000)
        duration := 3000
    msg := StrReplace(msg, "`r", "")

    if (A_TickCount < TOOLTIP_UNTIL_TICK && TOOLTIP_CONTENT != "")
        TOOLTIP_CONTENT := TOOLTIP_CONTENT "`n" msg
    else
        TOOLTIP_CONTENT := msg

    display := "          " StrReplace(TOOLTIP_CONTENT, "`n", "`n          ")
    TOOLTIP_UNTIL_TICK := A_TickCount + duration
    expireTick := TOOLTIP_UNTIL_TICK

    ToolTip display, , , TOOLTIP_SLOT
    if (duration > 0)
        SetTimer(() => ClearTipIfMatched(expireTick), -duration)
}

ClearTipIfMatched(expireTick) {
    global TOOLTIP_SLOT, TOOLTIP_UNTIL_TICK, TOOLTIP_CONTENT
    if (TOOLTIP_UNTIL_TICK = expireTick) {
        ToolTip(, , , TOOLTIP_SLOT)
        TOOLTIP_UNTIL_TICK := 0
        TOOLTIP_CONTENT := ""
    }
}

; 去除路徑前後的引號和空白
NormalizePath(p) {
    return Trim(p, ' "')
}

ResolveBundledAhkExe() {
    candidates := []
    candidates.Push(A_ScriptDir "\..\AutoHotkey64.exe")
    candidates.Push(A_ScriptDir "\AutoHotkey64.exe")

    packAppDir := EnvGet("PACK_APP_DIR")
    if (packAppDir != "") {
        candidates.Push(StrReplace(packAppDir, "\payload", "") "\AutoHotkey64.exe")
        candidates.Push(packAppDir "\AutoHotkey64.exe")
    }

    for _, candidate in candidates {
        path := Trim(candidate, ' "')
        if (path != "" && FileExist(path))
            return path
    }
    return ""
}

CaptureWindowVisibleRegionForOcr(hwnd, outFile) {
    WinGetPos &winX, &winY, &winW, &winH, "ahk_id " hwnd
    if (winW <= 0 || winH <= 0)
        throw Error("目標視窗尺寸異常: " winW "x" winH)

    ; 優先擷取螢幕上可見的視窗區域，避免透明/分層視窗直接抓 hwnd 時拿到空圖。
    try {
        ImagePutFile([winX, winY, winW, winH], outFile)
        if FileExist(outFile) && (FileGetSize(outFile) > 0)
            return { method: "screen-region", x: winX, y: winY, w: winW, h: winH }
    } catch as e {
        Log("螢幕區域截圖失敗，改用 hwnd 擷取: " e.Message, "WARN")
    }

    ImagePutFile("ahk_id " hwnd, outFile)
    return { method: "window-hwnd", x: winX, y: winY, w: winW, h: winH }
}

; ===== 重啟計數器和安全機制 =====
global RESTART_COUNT_KEY := "LRMC_restart_count"
global MAX_RESTART_ATTEMPTS := 3  ; 最多重啟3次
global RESTART_RESET_TIME := 1800  ; 30分鐘後重置計數器（秒）
global SCRIPT_START_TIME := A_Now  ; 記錄腳本啟動時間

; 重置重啟計數器（每次腳本啟動時調用）
ResetRestartCounter() {
    global CFG_FILE, RESTART_COUNT_KEY, SCRIPT_START_TIME
    
    Log("腳本啟動，重置 LRMCAI 重啟計數器")
    IniWrite "0", CFG_FILE, "restart_tracking", RESTART_COUNT_KEY
    IniWrite SCRIPT_START_TIME, CFG_FILE, "restart_tracking", RESTART_COUNT_KEY "_time"
    Log("重啟計數器已歸零")
}

; 檢查重啟計數器
CheckRestartCounter() {
    global CFG_FILE, RESTART_COUNT_KEY, MAX_RESTART_ATTEMPTS, SCRIPT_START_TIME
    
    ; 讀取當前計數
    restartCount := IniReadSafe(CFG_FILE, "restart_tracking", RESTART_COUNT_KEY, "0")
    restartCount := Integer(restartCount)
    
    Log("當前重啟計數: " restartCount "/" MAX_RESTART_ATTEMPTS)
    
    ; 檢查是否超過最大重啟次數
    if (restartCount >= MAX_RESTART_ATTEMPTS) {
        Log("已達到最大重啟次數限制 (" MAX_RESTART_ATTEMPTS " 次)，停止自動重啟", "ERROR")
        MsgBox "❌ LRMCAI 重啟次數已達上限 (" MAX_RESTART_ATTEMPTS " 次)`n`n請檢查 LRMCAI 程式是否正常，或稍後手動重新執行。`n`n重新啟動全自動腳本將重置計數器。", "重啟限制", "T10"
        ExitApp
    }
    
    return restartCount
}

; 更新重啟計數器
IncrementRestartCounter() {
    global CFG_FILE, RESTART_COUNT_KEY, SCRIPT_START_TIME
    
    restartCount := IniReadSafe(CFG_FILE, "restart_tracking", RESTART_COUNT_KEY, "0")
    restartCount := Integer(restartCount) + 1
    
    IniWrite restartCount, CFG_FILE, "restart_tracking", RESTART_COUNT_KEY
    IniWrite SCRIPT_START_TIME, CFG_FILE, "restart_tracking", RESTART_COUNT_KEY "_time"
    
    Log("重啟計數器已更新: " restartCount)
    return restartCount
}

Hotkey("^F2", (*) => ForceAskAndSave_LRMC())

LaunchLRMC() {
    return GetPathWithAsk_LRMC("LRMC", "請選擇 LRMCAI 執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
}

GetPathWithAsk_LRMC(key, prompt, filter) {
    global CFG_FILE
    path     := NormalizePath(IniReadSafe(CFG_FILE, "paths", key, ""))
    remember := IniReadSafe(CFG_FILE, "flags", key "_remember", "0")
    if (remember != "1" || !FileExist(path)) {
        sel := AskPathGui(prompt, path, filter)
        if (!sel.path)
            return ""
        path := NormalizePath(sel.path)
        IniWrite path,     CFG_FILE, "paths", key
        IniWrite sel.keep, CFG_FILE, "flags", key "_remember"
    }
    return path
}

ForceAskAndSave_LRMC() {
    global CFG_FILE
    cur := NormalizePath(IniReadSafe(CFG_FILE, "paths", "LRMC", ""))
    sel := AskPathGui("請選擇 LRMCAI 執行檔或捷徑", cur, "可執行檔或捷徑 (*.exe;*.lnk)")
    if (!sel.path)
        return
    IniWrite sel.path, CFG_FILE, "paths", "LRMC"
    IniWrite 1,        CFG_FILE, "flags", "LRMC_remember"
    TrayTip "已更新 LRMCAI 路徑", sel.path, 2
}

AskPathGui(prompt, defaultPath := "", filter := "All Files (*.*)") {
    sel := { path: "", keep: 0 }  ; 預設不記住
    g := Gui("+AlwaysOnTop -MinimizeBox", prompt)
    g.SetFont("s10")

    g.Add("Text", "xm ym", "執行檔路徑：")
    e := g.AddEdit("xm w520 vPATH", defaultPath)

    b := g.AddButton("x+m w90", "瀏覽...")
    b.OnEvent("Click", AskPathGui_Browse.Bind(e, prompt, filter))

    cb := g.AddCheckbox("xm vKEEP", "下次不再詢問")

    ok := g.AddButton("xm w120 Default", "確定")
    cancel := g.AddButton("x+m w90", "取消")

    ok.OnEvent("Click", AskPathGui_Ok.Bind(g, e, cb, sel))
    cancel.OnEvent("Click", AskPathGui_Cancel.Bind(g, sel))

    g.Show("AutoSize Center")
    WinWaitClose g.Hwnd
    return sel
}
AskPathGui_Browse(e, prompt, filter, *) {
    p := FileSelect(, "", prompt, filter)
    if (p)
        e.Value := p
}
AskPathGui_Ok(g, e, cb, sel, *) {
    sel.path := Trim(e.Value)
    sel.keep := cb.Value ? 1 : 0
    g.Hide()
}
AskPathGui_Cancel(g, sel, *) {
    sel.path := ""
    g.Hide()
}

IniReadSafe(file, section, key, default) {
    try return IniRead(file, section, key, default)
    catch 
        return default
}

; ===== 原流程（僅將寫死路徑改為動態）=====

; 每次腳本啟動時重置重啟計數器
WriteStep("重啟計數器", "重置並檢查上限")
ResetRestartCounter()

; 檢查重啟計數器，防止無限循環
currentRestartCount := CheckRestartCounter()

; 啟動 LRMCAI
Log("開始啟動 LRMCAI... (重啟計數: " currentRestartCount ")")
WriteStep("啟動LRMCAI", "準備讀取路徑並啟動進程")
lnkPath := LaunchLRMC()
if (!lnkPath) {
    WriteStep("讀取LRMCAI路徑", "未設定路徑", "ERROR")
    Log("未設定 LRMCAI 路徑", "ERROR")
    MsgBox "未設定 LRMCAI 路徑。按 Ctrl+F2 重新指定。"
    ExitApp
}
WriteStep("讀取LRMCAI路徑", "成功 | " lnkPath)

Log("執行 LRMCAI: " lnkPath)
Run lnkPath,,, &pid
ProcessWait(pid)
Sleep 3000  ; 從3秒減少到2秒
WriteStep("進程已啟動", "PID=" pid)

; 優化：增加錯誤處理和資源監控
Log("LRMCAI 進程已啟動，PID: " pid)

; 搜尋啟動視窗（優化版：減少資源占用）
findWindow() {
    ; 限制搜尋次數，避免無限循環占用 CPU
    maxAttempts := 10
    attempt := 0
    
    while (attempt < maxAttempts) {
        attempt++
        
        ; 只搜尋指定 PID 的視窗，減少遍歷範圍
        try {
            for hwnd in WinGetList("ahk_pid " pid) {
                if WinGetPID(hwnd) == pid
                    return hwnd
            }
        } catch {
            ; 如果出錯，等待一下再試
        }

        ; 每次嘗試後等待，減少 CPU 占用
        Sleep 300
    }
    return 0
}

; 更健壯的視窗尋找：若依 PID 找不到，嘗試依 exe 名稱或標題關鍵字回退
findWindowWithFallback() {
    maxAttempts := 12
    attempt := 0

    while (attempt < maxAttempts) {
        attempt++
        try {
            ; 優先：同 PID 的視窗
            for hwnd in WinGetList("ahk_pid " pid) {
                if (WinGetPID(hwnd) == pid)
                    return hwnd
            }
        } catch {
        }

        try {
            ; 回退一：以 exe 名稱搜尋（常見情況：.lnk 會啟動另一個 exe）
            for hwnd in WinGetList("ahk_exe LRMCAI.exe") {
                return hwnd
            }
        } catch {
        }

        try {
            ; 回退二：以標題內含 LRMCAI 的視窗
            for hwnd in WinGetList() {
                title := WinGetTitle(hwnd)
                if InStr(title, "LRMCAI")
                    return hwnd
            }
        } catch {
        }

        Sleep 500
    }
    return 0
}

WriteStep("主窗口搜尋", "開始 PID/fallback 搜尋")
targetHwnd := findWindowWithFallback()
if !targetHwnd {
    ; 額外給 UI 緩衝時間，避免剛啟動就誤判失敗
    WriteStep("主窗口搜尋", "首輪未命中，進入延長等待", "WARN")
    Log("首輪未找到 LRMC 視窗，進入延長等待重試...", "WARN")
    Loop 8 {
        Sleep 1000
        targetHwnd := findWindowWithFallback()
        if (targetHwnd)
            break
    }
}

if !targetHwnd {
    ; 補充進程狀態，方便辨識是視窗慢啟動還是程式秒退
    hasProc := ProcessExist("LRMCAI.exe")
    WriteStep("主窗口搜尋", hasProc ? "失敗 | 進程存在但 UI 未就緒" : "失敗 | 進程可能秒退", "ERROR")
    if (hasProc)
        MsgBox "❌ 找不到應用程式視窗（LRMCAI 進程存在，但 UI 尚未就緒）"
    else
        MsgBox "❌ 找不到應用程式視窗（LRMCAI 可能啟動失敗或秒退）"
    ExitApp
}
WriteStep("主窗口定位", "hwnd=" targetHwnd)

; 避免搶焦點導致全螢幕遊戲被最小化。
try WinRestore targetHwnd
Sleep 200

; 點擊視窗左上角位置啟動處理
WriteStep("切換LRMCAI前景", "準備點擊啟動入口")
if (!EnsureWindowForegroundForClick(targetHwnd, pid)) {
    WriteStep("切換LRMCAI前景", "失敗，停止後續操作", "WARN")
    ExitApp
}
pt := Buffer(8)
NumPut("int", 30, pt, 0), NumPut("int", 30, pt, 4)
DllCall("ClientToScreen", "ptr", targetHwnd, "ptr", pt)
CoordMode "Mouse", "Screen"
MouseClick "left", NumGet(pt, 0, "int"), NumGet(pt, 4, "int")
Sleep 300

; 送出 Enter 鍵
if !WinExist("ahk_id " targetHwnd) {
    WriteStep("送出Enter前檢查", "視窗失效，重新定位", "WARN")
    Log("送 Enter 前視窗已失效，重新定位視窗...", "WARN")
    targetHwnd := findWindowWithFallback()
}

if !targetHwnd || !WinExist("ahk_id " targetHwnd) {
    WriteStep("送出Enter前檢查", "失敗，目標視窗不存在", "ERROR")
    MsgBox "❌ 目標視窗失效，請重試啟動 LRMCAI"
    ExitApp
}

WriteStep("送出Enter", "啟動 LRMCAI 互動介面")
PostMessage 0x100, 0x0D, 0, , targetHwnd
Sleep 200
PostMessage 0x101, 0x0D, 0, , targetHwnd
ShowTip("LRMCAI 啟動中...", 1500)

; 等待新視窗出現
; 取代你原本的等待視窗迴圈
Log("等待 LRMCAI 主視窗出現（包含版本號的UI窗口）...")
WriteStep("等待UI窗口", "條件: 標題包含 LRMCAI 且有版本數字")

; 先嘗試找到包含版本號的主窗口（優先）
targetHwnd := 0
maxAttempts := 60
attempt := 0

while (attempt < maxAttempts && !targetHwnd) {
    attempt++
    
    try {
        for hwnd in WinGetList("ahk_pid " pid) {
            title := WinGetTitle(hwnd)
            Log("檢查窗口: [" title "]")
            
            ; 檢查 LRMCAI 後面是否有數字
            ; 匹配任何格式的版本號（3.03、v3.03、v303、3 等）
            if (title ~= "i)LRMCAI.*\d") {
                Log("找到UI窗口（含數字）: [" title "]", "INFO")
                targetHwnd := hwnd
                break
            }
        }
    } catch as e {
        Log("搜索窗口出錯: " e.Message, "WARN")
    }
    
    if (!targetHwnd) {
        if (Mod(attempt, 10) = 0)
            WriteStep("等待UI窗口", "仍在等待 | attempt=" attempt "/" maxAttempts)
        Log("第 " attempt " 次搜索未找到UI窗口，3秒後重試...")
        Sleep 3000
    }
}

if !targetHwnd {
    WriteStep("等待UI窗口", "超時（180秒）", "ERROR")
    Log("等待 LRMCAI UI 窗口超時（180秒），無法找到包含版本號的窗口", "ERROR")
    
    ; 列出所有找到的窗口供調試
    Log("所有找到的窗口:", "WARN")
    try {
        for hwnd in WinGetList("ahk_pid " pid) {
            title := WinGetTitle(hwnd)
            Log("  - [" title "]")
        }
    }
    
    Log("準備重啟", "WARN")
    WriteStep("重啟流程", "UI 超時，準備重啟", "WARN")
    
    ; 更新重啟計數器
    newRestartCount := IncrementRestartCounter()
    Log("準備執行第 " newRestartCount " 次重啟")
    WriteStep("重啟流程", "第 " newRestartCount " 次")
    
    ; 關閉 LRMCAI 進程
    try {
        ProcessClose(pid)
        Log("已關閉超時的 LRMCAI 進程 PID: " pid)
    } catch as e {
        Log("關閉 LRMCAI 進程失敗: " e.Message, "ERROR")
    }
    
    ; 強制關閉所有 LRMCAI 相關進程
    try {
        Run("taskkill /F /IM LRMCAI.exe", , "Hide")
        Log("執行強制關閉 LRMCAI.exe")
    } catch as e {
        Log("強制關閉 LRMCAI 失敗: " e.Message, "WARN")
    }
    
    Sleep 2000  ; 等待進程完全關閉
    
    ; 重新啟動開啟LRMC.ahk腳本
    Log("重新啟動開啟LRMC.ahk腳本... (第 " newRestartCount " 次重啟)")
    WriteStep("重啟腳本", "重新啟動開啟LRMC.ahk")
    try {
        ahkExe := BUNDLED_AHK_EXE
        
        if FileExist(ahkExe) {
            restartCmd := '"' ahkExe '" "' A_ScriptFullPath '"'
            if (HOTKEY_MODE)
                restartCmd .= ' hotkey'
            Run(restartCmd)
            Log("已重新啟動開啟LRMC.ahk腳本 (第 " newRestartCount " 次)")
        } else {
            Log("找不到 AutoHotkey 執行檔，無法重啟", "ERROR")
            MsgBox "❌ 找不到 AutoHotkey 執行檔，無法重啟 LRMCAI"
        }
    } catch as e {
        Log("重啟腳本失敗: " e.Message, "ERROR")
        MsgBox "❌ 重啟 LRMCAI 腳本失敗: " e.Message
    }
    
    ExitApp
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

WindowReady:
; 避免再次切換前景視窗，減少讓遊戲失焦的機率。
try WinRestore targetHwnd
Sleep 200

; 🎯 分別移動兩個LRMCAI視窗到正確位置
Log("調整LRMCAI視窗位置...")
WriteStep("視窗佈局", "調整控制窗與執行窗")
try {
    ; 獲取螢幕尺寸
    screenWidth := A_ScreenWidth
    screenHeight := A_ScreenHeight
    
    ; 尋找所有相關的LRMCAI視窗
    controlWindowHwnd := 0
    consoleWindowHwnd := 0
    ocrTargetHwnd := targetHwnd
    
    for hwnd in WinGetList() {
        try {
            if (WinGetPID(hwnd) = pid) {
                title := WinGetTitle(hwnd)
                Log("發現PID " pid " 的視窗: " title)
                
                ; 控制視窗：包含F8暂停、F9停止、F10标记等字樣
                if (InStr(title, "F8") || InStr(title, "F9") || InStr(title, "F10") || 
                    InStr(title, "暂停") || InStr(title, "停止") || InStr(title, "标记")) {
                    controlWindowHwnd := hwnd
                    Log("識別為控制視窗: " title)
                }
                ; 執行視窗：包含LRMCAI字樣的黑色控制台
                else if (InStr(title, "LRMCAI")) {
                    consoleWindowHwnd := hwnd
                    Log("識別為執行視窗: " title)
                }
            }
        } catch {
            continue
        }
    }
    
    ; 1. 移動控制視窗到螢幕左上角（完全貼邊）
    if (controlWindowHwnd) {
        WinMove 0, 0, , , "ahk_id " controlWindowHwnd
        Log("控制視窗已移動到螢幕左上角 (0,0)")
        WriteStep("視窗佈局", "控制視窗定位完成")
    } else {
        Log("未找到控制視窗，使用預設目標視窗", "WARN")
        WinMove 0, 0, , , "ahk_id " targetHwnd
        Log("預設視窗已移動到螢幕左上角 (0,0)")
        WriteStep("視窗佈局", "未找到控制窗，使用預設視窗", "WARN")
    }
    
    ; 2. 移動執行視窗到螢幕右下角（貼齊工作列）
    if (consoleWindowHwnd) {
        WinGetPos ,, &consoleWidth, &consoleHeight, "ahk_id " consoleWindowHwnd
        
        ; 使用工作區域信息
        workArea := GetWorkArea()
        
        newX := screenWidth - consoleWidth
        newY := workArea.height - consoleHeight
        WinMove newX, newY, , , "ahk_id " consoleWindowHwnd
        Log("LRMCAI執行視窗已移動到右下角（貼齊工作列）: X=" newX " Y=" newY)
        WriteStep("視窗佈局", "執行視窗定位完成 | X=" newX " Y=" newY)
    } else {
        Log("未找到LRMCAI執行視窗", "WARN")
        WriteStep("視窗佈局", "未找到執行視窗", "WARN")
    }

    ; OCR 視窗固定使用控制視窗
    if (controlWindowHwnd) {
        ocrTargetHwnd := controlWindowHwnd
        Log("OCR 將使用控制視窗")
        WriteStep("OCR目標視窗", "使用控制視窗 | hwnd=" ocrTargetHwnd)
    } else {
        ocrTargetHwnd := targetHwnd
        Log("未找到控制視窗，OCR 沿用預設 target", "WARN")
        WriteStep("OCR目標視窗", "未找到控制視窗，沿用預設", "WARN")
    }
    
} catch as e {
    Log("移動視窗時出錯: " e.Message, "WARN")
    WriteStep("視窗佈局", "例外 | " e.Message, "WARN")
    ocrTargetHwnd := targetHwnd
}

Sleep 2000

if (HOTKEY_MODE) {
    WriteStep("Hotkey模式", "直接送出 Ctrl+F1")
    ocrHwnd := (IsSet(ocrTargetHwnd) && ocrTargetHwnd) ? ocrTargetHwnd : targetHwnd
    if (!EnsureWindowForegroundForClick(ocrHwnd, pid)) {
        WriteStep("切換LRMCAI前景", "hotkey 模式送鍵前切換失敗", "WARN")
        ExitApp
    }
    WriteStep("送出快捷鍵", "Ctrl+F1")
    SendCtrlF1(pid, ocrHwnd)
    Log("已發送 Ctrl+F1")
    Log("LRMC 啟動流程完成")
    ExitApp
}

Log("開始 OCR 識別...")
WriteStep("OCR", "搜尋『副本』按鈕")
; OCR 偵測「副本」（優化版：減少內存占用）
ocr := RapidOcr()

; 使用臨時檔案名避免衝突，執行後清理
tempFile := A_ScriptDir "\temp_lrmc_" A_TickCount ".png"
debugCapturePath := ""
try {
    WriteStep("OCR截圖", "開始擷取")
    captureInfo := CaptureWindowVisibleRegionForOcr(ocrTargetHwnd, tempFile)
    Log("OCR 目標視窗: 標題=[" WinGetTitle("ahk_id " ocrTargetHwnd) "] 尺寸=" captureInfo.w "x" captureInfo.h " 位置=" captureInfo.x "," captureInfo.y " 擷取方式=" captureInfo.method)
    WriteStep("OCR截圖", "成功 | " captureInfo.method " | " captureInfo.w "x" captureInfo.h)
    if FileExist(tempFile)
        Log("OCR 截圖已保存: " tempFile " (" FileGetSize(tempFile) " bytes)")
    res := ocr.ocr_from_file(tempFile, , true)
} catch as e {
    WriteStep("OCR截圖", "失敗 | " e.Message, "ERROR")
    Log("OCR 處理失敗: " e.Message, "ERROR")
    if FileExist(tempFile)
        FileDelete(tempFile)
    ExitApp
}

if (res is Array) && (res.Length = 0) {
    WriteStep("OCR辨識", "未返回任何文字區塊", "WARN")
    Log("OCR 未返回任何文字區塊，將略過「副本」點擊流程", "WARN")
}

; 顯示 OCR 識別結果（簡化輸出，減少字串處理）
foundCopy := false
ocrTexts := []
for block in res {
    clean := StrReplace(StrReplace(block.text, "`r", ""), "`n", " ")
    if (clean != "")
        ocrTexts.Push(clean)
    if InStr(clean, "副本") {
        foundCopy := true
        Log("找到「副本」文字: " clean)
        break
    }
}

if (!foundCopy) {
    WriteStep("OCR辨識", "未找到『副本』文字", "WARN")
    Log("未找到「副本」文字，繼續處理...", "WARN")
    if (ocrTexts.Length > 0)
        Log("OCR 辨識內容: " StrJoin(ocrTexts, " | "), "WARN")
} else {
    WriteStep("OCR辨識", "找到『副本』文字")
}

; 尋找最左上角「副本」並點擊（優化版：減少計算量）
best := ""
bestScore := 99999999
copyFound := false

for block in res {
    clean := StrReplace(block.text, " ", "")
    if InStr(clean, "副本") && block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3 {
        copyFound := true
        x1 := block.boxPoint[1].x, y1 := block.boxPoint[1].y
        x2 := block.boxPoint[3].x, y2 := block.boxPoint[3].y
        cx := Round((x1 + x2) / 2), cy := Round((y1 + y2) / 2)
        score := cx + cy  ; 左上角優先（數值越小越好）
        
        if (score < bestScore) {
            best := [cx, cy]
            bestScore := score
            Log("找到更佳的「副本」位置: " cx "," cy " (得分: " score ")")
        }
    }
}

if (best is Array) {
    ; OCR 座標通常是截圖內相對座標，需轉為螢幕座標避免誤點。
    clickX := best[1]
    clickY := best[2]
    if (IsSet(captureInfo) && IsObject(captureInfo)
        && captureInfo.HasOwnProp("w") && captureInfo.HasOwnProp("h")
        && captureInfo.HasOwnProp("x") && captureInfo.HasOwnProp("y")) {
        ; 只有在座標看起來落在截圖尺寸內時才做偏移，避免重複加位移。
        if (clickX <= captureInfo.w + 5 && clickY <= captureInfo.h + 5) {
            clickX += captureInfo.x
            clickY += captureInfo.y
        }
    }

    ; 避免誤點工作列右下角「顯示桌面」熱區，防止全視窗最小化。
    if (clickX >= A_ScreenWidth - 8 && clickY >= A_ScreenHeight - 8) {
        WriteStep("點擊副本", "座標過於接近右下角，已取消", "WARN")
        Log("點擊座標過於接近右下角，已中止點擊以避免誤觸顯示桌面: raw=" best[1] "," best[2] " screen=" clickX "," clickY, "WARN")
    } else {
        ocrHwnd := (IsSet(ocrTargetHwnd) && ocrTargetHwnd) ? ocrTargetHwnd : targetHwnd
        WriteStep("切換LRMCAI前景", "副本點擊前切換")
        if (!EnsureWindowForegroundForClick(ocrHwnd, pid)) {
            Log("點擊前切換 LRMC 前景失敗，已中止本次點擊以避免誤點", "WARN")
            WriteStep("切換LRMCAI前景", "失敗，已中止點擊", "WARN")
            if FileExist(tempFile)
                FileDelete(tempFile)
            ExitApp
        }
        CoordMode "Mouse", "Screen"
        WriteStep("點擊副本", "screen=" clickX "," clickY)
        Log("點擊「副本」位置: raw=" best[1] "," best[2] " -> screen=" clickX "," clickY)
        MouseClick "left", clickX, clickY
        Sleep 500
        WriteStep("送出快捷鍵", "Ctrl+F1")
        SendCtrlF1(pid, ocrHwnd)   ; 送 Ctrl+F1（對同 PID 多視窗嘗試）
        Log("已發送 Ctrl+F1")
    }
} else if (copyFound) {
    WriteStep("點擊副本", "找到文字但缺少可點擊座標", "WARN")
    Log("找到「副本」文字但無法獲取座標", "WARN")
} else {
    debugCapturePath := A_ScriptDir "\debug_lrmc_ocr_nomatch_" FormatTime(, "yyyyMMdd_HHmmss") ".png"
    try {
        if FileExist(debugCapturePath)
            FileDelete(debugCapturePath)
        if FileExist(tempFile)
            FileCopy(tempFile, debugCapturePath, 1)
        Log("未找到「副本」文字，已保留除錯截圖: " debugCapturePath, "WARN")
    } catch as e {
        Log("保存 OCR 除錯截圖失敗: " e.Message, "WARN")
    }
    WriteStep("點擊副本", "未找到『副本』，跳過點擊", "WARN")
    Log("未找到「副本」文字，跳過點擊", "WARN")
}

if FileExist(tempFile)
    FileDelete(tempFile)

Log("LRMC 啟動流程完成")
WriteStep("流程完成", "LRMC 啟動流程完成")
ExitApp

; 點擊前先切到 LRMC 前景，避免遊戲鎖滑鼠導致座標正確但點擊無效。
EnsureWindowForegroundForClick(hwnd, pid := 0) {
    if (!hwnd || !WinExist("ahk_id " hwnd))
        return false

    try WinRestore("ahk_id " hwnd)
    Sleep 120
    try WinActivate("ahk_id " hwnd)
    if WinWaitActive("ahk_id " hwnd, , 1) {
        Log("點擊前已切到 LRMC 前景視窗: hwnd=" hwnd)
        return true
    }

    ; 模擬人為切窗（Alt+Tab）後再次指定 LRMC，處理遊戲剛鎖滑鼠視角的情況。
    try Send("!{Tab}")
    Sleep 220
    try WinActivate("ahk_id " hwnd)
    if WinWaitActive("ahk_id " hwnd, , 1) {
        Log("Alt+Tab 後切換 LRMC 前景成功: hwnd=" hwnd)
        return true
    }

    ; 後備：同 PID 其他視窗嘗試取得前景。
    if (pid) {
        try {
            for altHwnd in WinGetList("ahk_pid " pid) {
                if !WinExist("ahk_id " altHwnd)
                    continue
                try WinRestore("ahk_id " altHwnd)
                Sleep 100
                try WinActivate("ahk_id " altHwnd)
                if WinWaitActive("ahk_id " altHwnd, , 1) {
                    Log("後備切換成功（同 PID 視窗）: hwnd=" altHwnd)
                    return true
                }
            }
        }
    }

    Log("無法將 LRMC 切到前景，將放棄本次點擊", "WARN")
    return false
}

; ========= 穩健送出 Ctrl+F1（同 PID 多視窗嘗試，提升命中率） =========
SendCtrlF1(pid, preferredHwnd := 0) {
    targets := []
    seen := Map()

    if (preferredHwnd) {
        targets.Push(preferredHwnd)
        seen[preferredHwnd] := true
    }

    try {
        for hwnd in WinGetList("ahk_pid " pid) {
            if !seen.Has(hwnd) {
                targets.Push(hwnd)
                seen[hwnd] := true
            }
        }
    }

    if (targets.Length = 0) {
        Log("SendCtrlF1: 找不到可送鍵的目標視窗，PID=" pid, "WARN")
        return
    }

    ; 第一輪：背景 PostMessage
    for hwnd in targets {
        try {
            PostMessage 0x100, 0x11, 0, , "ahk_id " hwnd  ; VK_CONTROL down
            PostMessage 0x100, 0x70, 0, , "ahk_id " hwnd  ; VK_F1 down
            PostMessage 0x101, 0x70, 0, , "ahk_id " hwnd  ; VK_F1 up
            PostMessage 0x101, 0x11, 0, , "ahk_id " hwnd  ; VK_CONTROL up
            Log("SendCtrlF1: 已對 hwnd=" hwnd " 送出 PostMessage")
        }
    }

    Sleep 100

    ; 第二輪：ControlSend（仍不切焦點）
    for hwnd in targets {
        try {
            ControlSend("{Ctrl down}{F1}{Ctrl up}", , "ahk_id " hwnd)
            Log("SendCtrlF1: 已對 hwnd=" hwnd " 送出 ControlSend")
        }
    }

    ; 第三輪：必要時才做一次前景備援（用 preferredHwnd 優先）
    fallbackHwnd := preferredHwnd ? preferredHwnd : targets[1]
    try {
        WinActivate "ahk_id " fallbackHwnd
        WinWaitActive "ahk_id " fallbackHwnd, , 0.6
        Sleep 40
        Send "{Ctrl down}{F1}{Ctrl up}"
        Log("SendCtrlF1: 前景備援已送出，hwnd=" fallbackHwnd)
    } catch as e {
        Log("SendCtrlF1: 前景備援失敗: " e.Message, "WARN")
    }

    Sleep 120
}

StrJoin(items, sep := ", ") {
    out := ""
    for index, item in items {
        if (index > 1)
            out .= sep
        out .= item
    }
    return out
}

; ===== 放在同一支檔案結尾：函式定義 =====
WaitWindowByKeywords(pid, keywords, timeout := 600) {
    ; 用正則一次匹配多關鍵字，僅限於該 pid 的視窗
    SetTitleMatchMode "RegEx"
    pat := "(?i)"
    for kw in keywords
        pat .= ".*" RegExReplace(kw, "([\\^$.|?*+(){}\[\]])", "\\$1")
    pat .= ""  ; 收尾
    if !WinWait(pat " ahk_pid " pid, , timeout)
        return 0
    hwnd := WinExist()  ; WinWait 命中後，WinExist() 回傳該視窗
    SetTitleMatchMode "Fast"
    return hwnd
}