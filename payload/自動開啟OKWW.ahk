#Requires AutoHotkey v2.0+
#SingleInstance Force
#Warn
SetWorkingDir A_ScriptDir
#Warn LocalSameAsGlobal, Off
global BUNDLED_AHK_EXE := ResolveBundledAhkExe()

#Include plugin\RapidOcr\RapidOcr.ahk
#Include plugin\ImagePut-1.11\ImagePut.ahk
#Include LogManager.ahk

; ====================== 單一實例互斥鎖 ======================
; 建立全域互斥量，確保即使打包為EXE也只會有一個程序執行
uniqueID := "OKWW_AutoUpdater_SingleInstance"
singletonMutex := DllCall("CreateMutex", "Ptr", 0, "Int", 0, "Str", uniqueID, "Ptr")
if (DllCall("GetLastError") = 183) { ; ERROR_ALREADY_EXISTS
    ; 如果互斥量已存在，表示程序已在運行
    ; 建立臨時日誌記錄退出原因
    try {
        tempLogger := InitLogger("自動開啟OKWW")
        tempLogger.log("另一個程序已經在執行，即將退出", "WARN")
    }
    Sleep 100
    ExitApp
}

; ====================== 新的日誌系統 ======================
global logger := InitLogger("自動開啟OKWW")
RegisterLifecycleLogging("自動開啟OKWW")
global RUN_ID := A_Now "@" A_TickCount
global STEP_SEQ := 0
global TOOLTIP_SLOT := 3
global TOOLTIP_UNTIL_TICK := 0
global TOOLTIP_CONTENT := ""

; 日誌函數（使用新的日誌系統，保持RUN_ID兼容性）
WriteLog(msg, level := "INFO") {
    global logger, RUN_ID
    if IsSet(logger) && IsObject(logger) {
        logger.log("[" RUN_ID "] " msg, level)
    } else {
        ; 備用方案
        ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        line := ts " [" level "] [" RUN_ID "] " msg "`r`n"
        try FileAppend(line, A_ScriptDir "\okww_fallback.log", "UTF-8")
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

Log("程序啟動: PID=" DllCall("GetCurrentProcessId") " 腳本=" A_ScriptFullPath)
WriteStep("啟動", "AHK=" A_AhkVersion)

; ⛑️ 自動提權（提權前也先記一筆）
if !A_IsAdmin {
    Log("需要管理員權限，嘗試提權", "INFO")
    if FileExist(BUNDLED_AHK_EXE) {
        try {
            Run('*RunAs "' BUNDLED_AHK_EXE '" "' A_ScriptFullPath '"')
        }
    } else {
        MsgBox "找不到 AutoHotkey64.exe，請先執行「打包啟動器」完成解壓。"
    }
    ExitApp
}

; ⚡ 設定普通優先級以減少系統負擔
ProcessSetPriority("Normal")

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
Log("dataDir=" dataDir)
Log("CFG_FILE=" CFG_FILE)

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

; ===== 快捷鍵 =====
Hotkey("^F2", (*) => ForceAskAndSave("OKWW", "請選擇 ok-ww 可執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)"))
Hotkey("^F3", (*) => ForceAskAndSave("WUTHERING", "請選擇「鳴潮」遊戲主程式或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)"))

; 🔒 額外的啟動前安全檢查
StartupSafetyCheck() {
    Log("執行啟動前安全檢查...")
    WriteStep("前置安全檢查", "掃描 AutoHotkey/OKWW 相關進程")
    
    ; 檢查是否有其他同類腳本正在運行
    currentPID := DllCall("GetCurrentProcessId")
    scriptCount := 0
    
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process") {
            try {
                if (proc.Name = "AutoHotkey64.exe" || proc.Name = "AutoHotkey32.exe" || InStr(proc.Name, "AutoHotkey")) {
                    cmdLine := proc.CommandLine
                    if (InStr(cmdLine, "自動開啟OKWW.ahk") && proc.ProcessId != currentPID) {
                        scriptCount++
                        Log("發現其他自動開啟OKWW腳本實例: PID=" proc.ProcessId, "WARN")
                    }
                }
            } catch {
                ; 忽略無法存取的進程
            }
        }
    } catch as e {
        Log("安全檢查時出錯: " e.Message, "WARN")
    }
    
    if (scriptCount > 0) {
        Log("檢測到 " scriptCount " 個其他腳本實例，為避免衝突將退出", "WARN")
        WriteStep("前置安全檢查", "檢測到重複實例，停止執行", "WARN")
        MsgBox("檢測到其他自動開啟OKWW腳本正在運行，`n為避免重複啟動將退出此實例。", "重複實例檢測", "T3")
        ExitApp
    }
    
    Log("啟動前安全檢查通過")
}

; 執行安全檢查
WriteStep("前置安全檢查", "重複實例與進程衝突檢查")
StartupSafetyCheck()
WriteStep("前置安全檢查", "通過")

LaunchOKWW() {
    return GetPathWithAsk("OKWW", "請選擇 ok-ww 可執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
}

LaunchWuthering() {
    return GetPathWithAsk("WUTHERING", "請選擇「鳴潮」遊戲主程式或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
}

GetPathWithAsk(key, prompt, filter) {
    global CFG_FILE
    path     := NormalizePath(IniReadSafe(CFG_FILE, "paths", key, ""))
    remember := IniReadSafe(CFG_FILE, "flags", key "_remember", "0")
    Log("GetPathWithAsk key=" key " remember=" remember " path=" path)
    if (remember != "1" || !FileExist(path)) {
        sel := AskPathGui(prompt, path, filter)
        if (!sel.path) {
            Log("user canceled path selection for " key, "WARN")
            return ""
        }
        path := NormalizePath(sel.path)
        IniWrite path,     CFG_FILE, "paths", key
        IniWrite sel.keep, CFG_FILE, "flags", key "_remember"
        Log("saved path for " key ": " path ", keep=" sel.keep)
    }
    return path
}

ForceAskAndSave(key, prompt, filter) {
    global CFG_FILE
    Log("ForceAskAndSave key=" key)
    cur := NormalizePath(IniReadSafe(CFG_FILE, "paths", key, ""))
    sel := AskPathGui(prompt, cur, filter, true)
    if (!sel.path) {
        Log("ForceAskAndSave canceled", "WARN")
        return
    }
    IniWrite sel.path, CFG_FILE, "paths", key
    IniWrite 1,        CFG_FILE, "flags", key "_remember"
    Log("ForceAskAndSave saved path=" sel.path)
    TrayTip "已更新 " key " 路徑", sel.path, 2
}

; --- GUI ---
AskPathGui(prompt, defaultPath := "", filter := "All Files (*.*)", force := false) {
    Log("AskPathGui prompt=" prompt " default=" defaultPath)
    sel := { path: "", keep: 0 }
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
    Log("AskPathGui result path=" sel.path " keep=" sel.keep)
    return sel
}

AskPathGui_Browse(e, prompt, filter, *) {
    p := FileSelect(, "", prompt, filter)
    if (p) {
        e.Value := p
        Log("FileSelect chosen file=" p)
    } else {
        Log("FileSelect canceled")
    }
}

AskPathGui_Ok(g, e, cb, sel, *) {
    sel.path := Trim(e.Value)
    sel.keep := cb.Value ? 1 : 0
    Log("AskPathGui OK path=" sel.path " keep=" sel.keep)
    g.Hide()
}

AskPathGui_Cancel(g, sel, *) {
    sel.path := ""
    Log("AskPathGui Cancel")
    g.Hide()
}

IniReadSafe(file, section, key, default) {
    try {
        v := IniRead(file, section, key, default)
        return v
    } catch {
        Log("IniReadSafe failed sec=" section " key=" key ", use default", "WARN")
        return default
    }
}

IsWutheringGameRunning() {
    ; ✅ 只檢查進程是否存在，不檢查視窗尺寸
    ;    這樣即使遊戲被最小化或視窗變小，也不會重新啟動遊戲
    
    ; 優先條件：完全初始化的遊戲視窗
    hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe ahk_class UnrealWindow")
    if (hwndList.Length > 0)
        return true

    ; 回退：只檢查進程是否存在
    hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe")
    return (hwndList.Length > 0)
}

; ✅ 驗證視窗是否為真正的遊戲視窗（而非臨時初始化視窗）
IsValidGameWindow(hwnd) {
    if !hwnd
        return false
    
    if !WinExist("ahk_id " hwnd)
        return false
    
    if !WinGetExStyle("ahk_id " hwnd) {
        return false
    }
    
    try WinGetPos , , &w, &h, "ahk_id " hwnd
    catch {
        return false
    }
    
    ; 遊戲視窗通常至少 800x600
    if (w < 800 || h < 600) {
        return false
    }
    
    return true
}

; ====================== 多實例守門員 ======================
; 列出所有標題含 ok-ww 的視窗（回傳陣列 [{pid, hwnd, title}]）
ListOkwwWindows() {
    list := []
    Log("開始搜尋OKWW視窗...")
    
    ; 搜尋所有視窗
    for hwnd in WinGetList() {
        try {
            title := WinGetTitle(hwnd)
            processName := WinGetProcessName(hwnd)
            
            ; 檢查標題包含OKWW或OK-WW（不區分大小寫）
            titleLower := StrLower(title)
            
            ; 排除編輯器和開發工具
            isEditor := (InStr(titleLower, "visual studio code") || 
                        InStr(titleLower, "notepad") || 
                        InStr(titleLower, "vscode") ||
                        InStr(processName, "Code.exe") ||
                        InStr(processName, "notepad"))
            
            ; 只檢測真正的OKWW程式視窗，排除編輯器
            if ((InStr(titleLower, "ok-ww") || InStr(titleLower, "okww")) && !isEditor) {
                pid := WinGetPID(hwnd)
                
                ; 🎯 重要：區分主程式和更新檢測程式，以及主視窗和背景服務視窗
                ; ok-ww.exe 是主程式，pythonw.exe 是更新檢測程式
                isMainProcess := (processName = "ok-ww.exe")
                processType := isMainProcess ? "主程式" : "更新檢測"
                
                ; 💡 額外標記：識別背景服務視窗和升級視窗
                isServiceWindow := InStr(titleLower, "-siw") || InStr(titleLower, "service")
                isUpgradeWindow := (title = "ok-ww" || (InStr(titleLower, "ok-ww") && !RegExMatch(title, "v\d+\.\d+") && !InStr(titleLower, "global") && !InStr(titleLower, "-siw")))
                
                windowType := isServiceWindow ? "背景服務" : (isUpgradeWindow ? "升級檢測" : "主程式")
                
                Log("找到OKWW視窗: pid=" pid " hwnd=" hwnd " title=" title " process=" processName " type=" processType " 視窗類型=" windowType)
                list.Push({
                    pid: pid, 
                    hwnd: hwnd, 
                    title: title, 
                    process: processName, 
                    isMain: isMainProcess,
                    isService: isServiceWindow,
                    isUpgrade: isUpgradeWindow
                })
            }
        } catch as e {
            Log("搜尋視窗時出錯: " e.Message, "WARN")
        }
    }
    
    Log("OKWW視窗搜尋完成，共找到 " list.Length " 個視窗")
    return list
}

; 嘗試接手「最新」視窗，但不再關閉舊 PID
; 回傳 {attached: true/false, pid, hwnd}
AttachNewestOkww(&curPid, &curHwnd, killOld := true) {
    if !IsSet(curPid)
        curPid := 0
    if !IsSet(curHwnd)
        curHwnd := 0

    wins := ListOkwwWindows()
    if (wins.Length = 0) {
        Log("AttachNewestOkww: 沒有找到OKWW視窗", "WARN")
        return {attached: false, pid: 0, hwnd: 0}
    }
    
    ; 🎯 優先選擇主程式（ok-ww.exe），並且智能識別升級視窗、主程式視窗和背景服務視窗
    mainProcessWins := []
    updateProcessWins := []
    serviceWindows := []
    upgradeWindows := []
    
    for i, w in wins {
        if w.isMain {
            if (w.HasOwnProp("isUpgrade") && w.isUpgrade) {
                upgradeWindows.Push(w)  ; 升級檢測視窗
            } else if (w.HasOwnProp("isService") && w.isService) {
                serviceWindows.Push(w)  ; 背景服務視窗
            } else {
                mainProcessWins.Push(w)  ; 主用戶界面視窗
            }
        } else {
            updateProcessWins.Push(w)
        }
    }
    
    Log("視窗分類結果: 升級視窗=" upgradeWindows.Length " 主界面視窗=" mainProcessWins.Length " 背景服務視窗=" serviceWindows.Length " 更新檢測視窗=" updateProcessWins.Length)
    
    ; 選擇目標視窗：智能判斷升級流程還是正常使用
    newest := ""
    if (upgradeWindows.Length > 0 && mainProcessWins.Length > 0) {
        ; 🔄 同時存在升級視窗和主程式視窗，優先處理升級流程
        newest := upgradeWindows[1]
        for i, w in upgradeWindows {
            if (w.pid > newest.pid) {
                newest := w
            }
        }
        Log("AttachNewestOkww: 檢測到升級和主程式視窗並存，選擇升級視窗 '" newest.title "' PID=" newest.pid " 進行升級流程")
    } else if (upgradeWindows.Length > 0) {
        ; 🔄 只有升級視窗，選擇它進行升級
        newest := upgradeWindows[1]
        for i, w in upgradeWindows {
            if (w.pid > newest.pid) {
                newest := w
            }
        }
        Log("AttachNewestOkww: 選擇升級視窗 '" newest.title "' PID=" newest.pid " 準備升級流程")
    } else if (mainProcessWins.Length > 0) {
        ; 🎯 正常主程式視窗選擇邏輯（帶版本號的視窗）
        ; 🎯 智能選擇主視窗：升級時選擇無版本號視窗，正常時選擇帶版本號視窗
        versionWindow := ""
        upgradeWindow := ""  ; 升級用的視窗（無版本號）
        nonServiceWindow := ""
        
        for i, w in mainProcessWins {
            titleLower := StrLower(w.title)
            
            ; 優先級1: 升級視窗檢測 - 純粹的 "ok-ww" 無版本號視窗
            if (w.title = "ok-ww" || (InStr(titleLower, "ok-ww") && !RegExMatch(w.title, "v\d+\.\d+") && !InStr(titleLower, "global") && !InStr(titleLower, "-siw"))) {
                if (!upgradeWindow || w.pid > upgradeWindow.pid) {
                    upgradeWindow := w
                }
            }
            ; 優先級2: 正常主程式視窗 - 包含版本號的視窗 (如 "OK-WW v2.6.19")
            else if (RegExMatch(w.title, "v\d+\.\d+") || InStr(titleLower, "global") || InStr(titleLower, "版本")) {
                if (!versionWindow || w.pid > versionWindow.pid) {
                    versionWindow := w
                }
            }
            ; 優先級3: 其他非服務背景視窗 (排除 ok-ww-siw)
            else if (!InStr(titleLower, "-siw") && !InStr(titleLower, "service")) {
                if (!nonServiceWindow || w.pid > nonServiceWindow.pid) {
                    nonServiceWindow := w
                }
            }
        }
        
        ; 🔄 選擇邏輯：升級視窗(無版本號) > 版本視窗(有版本號) > 非服務視窗 > 任意主程式視窗
        ; 如果存在升級視窗，優先處理升級流程；否則使用正常的主程式視窗
        if (upgradeWindow && versionWindow) {
            ; 同時存在升級視窗和版本視窗，優先選擇升級視窗處理升級流程
            newest := upgradeWindow
            Log("AttachNewestOkww: 檢測到升級和主程式視窗並存，選擇升級視窗 '" newest.title "' PID=" newest.pid " 進行升級流程")
        } else if (upgradeWindow) {
            ; 只有升級視窗，選擇它
            newest := upgradeWindow
            Log("AttachNewestOkww: 選擇升級視窗 '" newest.title "' PID=" newest.pid " 準備升級流程")
        } else if (versionWindow) {
            ; 只有版本視窗，正常使用
            newest := versionWindow
            Log("AttachNewestOkww: 選擇帶版本號的主視窗 '" newest.title "' PID=" newest.pid " 正常運行")
        } else if (nonServiceWindow) {
            newest := nonServiceWindow
            Log("AttachNewestOkww: 選擇非服務主視窗 '" newest.title "' PID=" newest.pid)
        } else {
            ; 備用方案：選擇PID最大的
            newest := mainProcessWins[1]
            for i, w in mainProcessWins {
                if (w.pid > newest.pid) {
                    newest := w
                }
            }
            Log("AttachNewestOkww: 備用選擇主程式視窗 '" newest.title "' PID=" newest.pid, "WARN")
        }
    } else if (serviceWindows.Length > 0) {
        ; 沒有主界面視窗，但有背景服務視窗，選擇PID最大的服務視窗
        newest := serviceWindows[1]
        for i, w in serviceWindows {
            if (w.pid > newest.pid) {
                newest := w
            }
        }
        Log("AttachNewestOkww: 只找到背景服務視窗 '" newest.title "' PID=" newest.pid, "WARN")
    } else if (updateProcessWins.Length > 0) {
        ; 沒有主程式，選擇PID最大的更新程式
        newest := updateProcessWins[1]
        for i, w in updateProcessWins {
            if (w.pid > newest.pid) {
                newest := w
            }
        }
        Log("AttachNewestOkww: 只找到更新檢測程式 pythonw.exe，PID=" newest.pid, "WARN")
    } else {
        Log("AttachNewestOkww: 沒有找到有效的OKWW視窗", "ERROR")
        return {attached: false, pid: 0, hwnd: 0}
    }
    
    ; =========================================================================
    ; 重要：已移除所有 ProcessClose 相關邏輯，確保此函數只附加，不關閉。
    ; killOld 參數雖然保留，但不再有實際作用。
    ; =========================================================================
    
    curPid := newest.pid
    curHwnd := newest.hwnd
    Log("AttachNewestOkww: 接手視窗 hwnd=" curHwnd " pid=" curPid " title=" newest.title)
    
    ; 確保窗口存在並活躍
    if (!WinExist("ahk_id " . curHwnd)) {
        Log("AttachNewestOkww: 接手的視窗句柄 " curHwnd " 已失效", "ERROR")
        return {attached: false, pid: 0, hwnd: 0}
    }
    
    try {
        WinActivate("ahk_id " . curHwnd)
    } catch as e {
        Log("AttachNewestOkww: 激活視窗失敗: " e.Message, "WARN")
    }
    
    try {
        WinWaitActive("ahk_id " . curHwnd, "", 1)
    } catch as e {
        Log("AttachNewestOkww: 等待視窗激活失敗: " e.Message, "WARN")
    }
    
    return {attached: true, pid: curPid, hwnd: curHwnd, oldPidClosed: 0}
}


; ====================== 啟動與視窗鎖定 ======================
global targetHwnd := 0
pid := 0

; 先嘗試接手既有，但不關閉其他進程
Log("檢查是否存在已運行的OKWW進程...")

; 🔧 增強型重複啟動檢測：多層檢查確保不重複啟動
; 第一層：檢查視窗
wins0 := ListOkwwWindows()
; 第二層：檢查進程名稱
okwwProcess := ProcessExist("ok-ww.exe")
pythonwWithOKWW := false

; 第三層：檢查pythonw是否為OKWW相關
if (!okwwProcess) {
    for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name='pythonw.exe'") {
        try {
            cmdLine := proc.CommandLine
            if (InStr(cmdLine, "OK-WW") || InStr(cmdLine, "ok-ww")) {
                pythonwWithOKWW := true
                Log("檢測到OKWW相關的pythonw進程: PID=" proc.ProcessId)
                break
            }
        } catch {
            ; 忽略無法存取的進程
        }
    }
}

; 綜合判斷是否已有OKWW運行
hasRunningOKWW := (wins0.Length > 0) || okwwProcess || pythonwWithOKWW

if (hasRunningOKWW) {
    WriteStep("OKWW守門", "發現既有實例，改為接手")
    Log("發現已運行的OKWW (視窗:" wins0.Length " 進程:" (okwwProcess ? "yes" : "no") " pythonw:" (pythonwWithOKWW ? "yes" : "no") ")，嘗試接手")
    if (wins0.Length > 0) {
        result := AttachNewestOkww(&pid, &targetHwnd, false)  ; 改為 false，不關閉舊進程
        Log("已成功接手現有OKWW進程，PID=" pid)
        WriteStep("OKWW守門", "接手完成 | pid=" pid)
    } else {
        Log("有OKWW進程但無視窗，等待視窗出現...")
        WriteStep("OKWW守門", "有進程無視窗，等待視窗出現", "WARN")
        ; 等待視窗出現，最多等30秒
        Loop 10 {
            Sleep 3000
            wins1 := ListOkwwWindows()
            if (wins1.Length > 0) {
                Log("等待後發現OKWW視窗，接手進程")
                result := AttachNewestOkww(&pid, &targetHwnd, false)
                WriteStep("OKWW守門", "等待後接手成功 | pid=" pid)
                break
            }
            if (Mod(A_Index, 3) = 0)
                WriteStep("OKWW守門", "等待視窗中 | attempt=" A_Index "/10")
            Log("等待OKWW視窗第" A_Index "次...")
        }
    }
} else {
    WriteStep("OKWW守門", "未發現既有實例，準備啟動新進程")
    Log("未發現已運行的OKWW進程，準備啟動新進程")

    ; 先啟動鳴潮遊戲，與 OKWW/LRMCAI 一樣記憶路徑
    wutheringRunning := IsWutheringGameRunning()
    if (!wutheringRunning) {
        WriteStep("鳴潮啟動", "未運行，準備啟動")
        gameExe := LaunchWuthering()
        if (!gameExe) {
            WriteStep("鳴潮啟動", "未設定路徑", "ERROR")
            Log("未設定鳴潮遊戲路徑，無法啟動", "ERROR")
            MsgBox "未設定鳴潮遊戲路徑。按 Ctrl+F3 重新指定。"
            ExitApp
        }

        Log("準備啟動鳴潮: " gameExe)
        Run gameExe,,, &gamePid
        if (gamePid) {
            Log("鳴潮已啟動，PID=" gamePid)
            try ProcessWait(gamePid, 5)
            catch as e
                Log("等待鳴潮進程失敗: " e.Message, "WARN")
        } else {
            Log("無法取得鳴潮進程 PID，可能啟動失敗", "WARN")
        }

        Sleep 2000  ; 留一點時間讓遊戲初始化
    } else {
        WriteStep("鳴潮啟動", "已在運行，略過")
        Log("偵測到鳴潮已在運行，略過啟動")
    }
    WriteStep("啟動OKWW", "讀取路徑並準備啟動")
    exePath := LaunchOKWW()
    if (!exePath) {
        WriteStep("啟動OKWW", "未設定路徑", "ERROR")
        Log("未設定OKWW路徑，無法啟動", "ERROR")
        MsgBox "未設定 ok-ww 路徑。按 Ctrl+F2 重新指定。"
        ExitApp
    }
    
    Log("準備啟動OKWW: " exePath)
    
    ; 🚨 啟動前最終檢查：確保沒有OKWW程式已經在啟動過程中
    Log("執行啟動前最終檢查...")
    Sleep 1000  ; 等待一秒讓可能的並發進程完成檢測
    
    ; 再次檢查是否有OKWW進程出現
    finalCheck := ListOkwwWindows()
    finalProcessCheck := ProcessExist("ok-ww.exe")
    
    if (finalCheck.Length > 0 || finalProcessCheck) {
        Log("最終檢查發現OKWW已啟動 (視窗:" finalCheck.Length " 進程:" (finalProcessCheck ? "yes" : "no") ")，取消啟動", "WARN")
        WriteStep("啟動OKWW", "最終檢查發現已啟動，改為接手", "WARN")
        if (finalCheck.Length > 0) {
            result := AttachNewestOkww(&pid, &targetHwnd, false)
            Log("改為接手已啟動的OKWW進程")
        }
        return  ; 取消啟動，避免重複
    }
    
    ; 嘗試運行前先檢查是否有同名進程
    SplitPath(exePath, &exeName)
    if (exeName) {
        processes := []
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name = '" exeName "'")
            processes.Push({pid: proc.ProcessId, name: proc.Name})
        
        if (processes.Length > 0) {
            Log("發現 " processes.Length " 個可能的OKWW進程已在運行，嘗試關閉")
            for proc in processes {
                try {
                    ProcessClose(proc.pid)
                    Log("關閉進程: " proc.name " (PID: " proc.pid ")")
                    Sleep 200
                } catch as e {
                    Log("無法關閉進程 " proc.name " (PID: " proc.pid "): " e.Message, "WARN")
                }
            }
            Sleep 500  ; 給進程一些時間完全關閉
        }
    }
    
    ; 使用Run啟動
    Log("運行OKWW: " exePath)
    Run exePath,,, &pid
    if (!pid) {
        WriteStep("啟動OKWW", "啟動失敗，無 PID", "ERROR")
        Log("無法獲取新啟動進程的PID", "ERROR")
        MsgBox "啟動OKWW失敗"
        ExitApp
    }
    WriteStep("啟動OKWW", "啟動成功 | pid=" pid)
    
    Log("OKWW已啟動，PID=" pid)
    try {
        ProcessWait(pid, 5)
        Log("進程已成功運行")
    } catch as e {
        Log("等待進程運行失敗: " e.Message, "WARN")
    }
    
    Sleep 1500  ; 給程序更多時間初始化
    
    ; 等主視窗（最多 ~90 秒）
    windowFound := false
    Log("開始等待OKWW主視窗出現...")
    Loop 30 {
        result := AttachNewestOkww(&pid, &targetHwnd, true)
        if (targetHwnd) {
            windowFound := true
            Log("已找到OKWW主視窗，耗時=" (A_Index * 3) "秒")
            WriteStep("等待OKWW主視窗", "成功 | 耗時=" (A_Index * 3) "秒")
            break
        }
        if (Mod(A_Index, 5) = 0)
            WriteStep("等待OKWW主視窗", "等待中 | attempt=" A_Index "/30")
        Log("等待OKWW視窗，第 " A_Index " 次嘗試")
        Sleep 3000
    }
    
    if (!windowFound) {
        WriteStep("等待OKWW主視窗", "超時，進入備援搜尋", "WARN")
        Log("等待OKWW視窗超時", "WARN")
    }
}

if !targetHwnd {
    WriteStep("OKWW主視窗", "常規搜尋失敗，嘗試備援條件", "WARN")
    Log("無法找到OKWW視窗，嘗試額外的搜尋方式", "WARN")
    
    ; 使用更寬鬆的視窗搜尋標準
    extraFoundHwnd := 0
    for hwnd in WinGetList() {
        try {
            title := WinGetTitle(hwnd)
            wclass := WinGetClass(hwnd)
            
            ; 擴大搜尋條件
            if (InStr(title, "OK") || InStr(title, "WW") || InStr(title, "ww") || 
                InStr(wclass, "OKWW") || InStr(wclass, "okww")) {
                
                extraFoundHwnd := hwnd
                Log("使用備用條件找到可能的OKWW視窗: hwnd=" hwnd " title=" title " class=" wclass, "WARN")
                
                ; 嘗試激活此窗口
                targetHwnd := hwnd
                try WinActivate("ahk_id " . targetHwnd)
                WriteStep("OKWW主視窗", "備援搜尋成功 | hwnd=" hwnd, "WARN")
                break
            }
        } catch as e {
            ; 忽略錯誤，繼續下一個視窗
            Log("檢查視窗時出錯: " e.Message, "WARN")
        }
    }
    
    if (!extraFoundHwnd) {
        WriteStep("OKWW主視窗", "備援搜尋失敗，結束", "ERROR")
        Log("使用所有方法都無法找到OKWW視窗，退出", "ERROR")
        MsgBox "❌ 無法找到 ok-ww 視窗，請手動啟動"
        ExitApp
    }
}

; ====================== 截圖 + OCR 工具 ======================
EnsureOkwwWindow() {
    global targetHwnd, pid
    if IsValidHwnd(targetHwnd)
        return true
    Log("EnsureOkwwWindow: lost hwnd, reattach", "WARN")
    _ := AttachNewestOkww(&pid, &targetHwnd, true)
    return IsValidHwnd(targetHwnd)
}

IsValidHwnd(hwnd) {
    try {
        return !!(hwnd && DllCall("IsWindow", "ptr", hwnd, "int"))
    } catch {
        return false
    }
}

CaptureAndOCR(minSize := 8192, imgPath := "temp.png") {
    global targetHwnd
    if !EnsureOkwwWindow()
        return ""
    if !IsValidHwnd(targetHwnd) {
        Log("CaptureAndOCR: invalid hwnd before capture", "WARN")
        return ""
    }
    try {
        try {
            WinActivate("ahk_id " . targetHwnd)
        } catch {
            ; ignore
        }
        try {
            WinWaitActive("ahk_id " . targetHwnd, "", 0.5)
        } catch {
            ; ignore
        }
    }
    if !IsValidHwnd(targetHwnd) {
        Log("CaptureAndOCR: hwnd became invalid after activate", "WARN")
        return ""
    }
    try {
        ImagePutFile(targetHwnd, imgPath)
    } catch {
        Log("ImagePutFile failed", "WARN")
        return ""
    }
    if !FileExist(imgPath) {
        Log("capture file not exist", "WARN")
        return ""
    }
    sz := FileGetSize(imgPath, "B")
    if (sz < minSize) {
        Log("capture too small size=" sz, "WARN")
        return ""
    }
    try {
        ocr := RapidOcr()
        blocks := ocr.ocr_from_file(imgPath, , true)
        n := (blocks is Array) ? blocks.Length : 0
        Log("OCR done blocks=" n " size=" sz)
        return (blocks is Array && blocks.Length) ? blocks : ""
    } catch {
        Log("OCR exception", "ERROR")
        return ""
    }
}

DetectOCRText(keyword, maxMs := 15000) {
    Log("DetectOCRText start kw=" keyword " maxMs=" maxMs)
    start := A_TickCount
    stableHit := 0
    needStable := 2
    while (A_TickCount - start < maxMs) {
        elapsed := A_TickCount - start
        interval := (elapsed < 3000) ? 500 : 1200  ; 從250/600ms改為500/1200ms，減少系統負擔
        Sleep interval
        blocks := CaptureAndOCR(8192, "temp.png")
        if (blocks = "")
            continue
        hasKW := false
        for block in blocks {
            if !block.HasOwnProp("text")
                continue
            clean := StrReplace(block.text, " ", "")
            if InStr(clean, keyword) {
                hasKW := true
                break
            }
        }
        if hasKW {
            stableHit += 1
            Log("DetectOCRText hit " stableHit "/" needStable)
            if (stableHit >= needStable) {
                Log("DetectOCRText success kw=" keyword)
                return true
            }
        } else {
            if (stableHit != 0)
                Log("DetectOCRText reset hit from " stableHit " to 0")
            stableHit := 0
        }
    }
    Log("DetectOCRText timeout kw=" keyword, "WARN")
    return false
}

DoOCRClick(keyword, stageText, mode := "leftmost", sendHotkey := "", attempts := 6) {
    global targetHwnd
    Log("DoOCRClick stage=" stageText " kw=" keyword " mode=" mode " tries=" attempts)
    ShowTip(stageText, 600)

    loop attempts {
        blocks := CaptureAndOCR(8192, "temp.png")
        if (blocks = "") {
            Sleep 400
            continue
        }

        best := ""
        bestScore := (mode = "leftmost") ?  999999999 : -999999999
        for block in blocks {
            if !block.HasOwnProp("text") || !block.HasOwnProp("boxPoint")
                continue
            clean := StrReplace(block.text, " ", "")
            if !InStr(clean, keyword)
                continue
            if !(block.boxPoint is Array) || (block.boxPoint.Length < 3)
                continue
            x1 := block.boxPoint[1].x, y1 := block.boxPoint[1].y
            x2 := block.boxPoint[3].x, y2 := block.boxPoint[3].y
            cx := Round((x1 + x2) / 2)
            cy := Round((y1 + y2) / 2)
            score := cx + cy
            if (mode = "leftmost"  && score < bestScore) || (mode = "rightbottom" && score > bestScore) {
                best := [cx, cy]
                bestScore := score
            }
        }

        if best is Array {
            Log("DoOCRClick click at x=" best[1] " y=" best[2] " score=" bestScore)
            ShowTip(stageText "`n→ 點擊: " best[1] ", " best[2], 500)
            oldMode := A_CoordModeMouse
            CoordMode "Mouse", "Screen"
            try {
                if IsValidHwnd(targetHwnd) {
                    try WinActivate("ahk_id " . targetHwnd)
                    try WinWaitActive("ahk_id " . targetHwnd, "", 0.6)
                }
                MouseMove best[1], best[2]
                Sleep 40
                MouseClick "left", best[1], best[2]
            } finally {
                CoordMode "Mouse", oldMode
            }
            Sleep 350
            if (sendHotkey != "") {
                Log("DoOCRClick send hotkey=" sendHotkey)
                Send(sendHotkey)
            }
            Sleep 800
            return true
        }
        Log("DoOCRClick not found this try, remain=" (attempts - A_Index))
        Sleep 450
    }

    Log("DoOCRClick failed kw=" keyword, "WARN")
    ShowTip(stageText "`n找不到「" keyword "」", 1200)
    return false
}

; ====================== 前檢查與四階段流程 ======================
WriteStep("升級檢測", "檢查是否需要執行升級流程")
if !DetectOCRText("升级APP", 15000) {
    WriteStep("升級檢測", "未偵測到升级APP，流程結束")
    ShowTip("🔍 未偵測到「升级APP」，不執行升級", 1200)
    Log("no upgrade needed, exit")
    ExitApp
}

WriteStep("升級流程", "階段1：點擊 升级APP")
if !DoOCRClick("升级APP",     "階段1：尋找 升級APP",     "leftmost") {
    WriteStep("升級流程", "階段1失敗", "WARN")
    ExitApp
}

WriteStep("升級流程", "階段2：點擊 確認UPDATE")
if !DoOCRClick("确认UPDATE",  "階段2：尋找 確認UPDATE",   "rightbottom") {
    WriteStep("升級流程", "階段2失敗", "WARN")
    ExitApp
}

WriteStep("升級流程", "階段3：點擊 完成")
if !DoOCRClick("完成",        "階段3：尋找 完成",         "rightbottom") {
    WriteStep("升級流程", "階段3失敗", "WARN")
    ExitApp
}

WriteStep("升級流程", "階段4：點擊 启动应用")
if !DoOCRClick("启动应用",    "階段4：尋找 啟動應用",     "leftmost")
    && !DoOCRClick("肩动应用","階段4：尋找 启动应用(容錯)","leftmost") {
    WriteStep("升級流程", "階段4失敗", "WARN")
    ExitApp
}

Log("flow done")
WriteStep("升級流程", "完成")
ShowTip("✅ 自動升級完成", 1500)
ExitApp
