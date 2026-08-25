#Requires AutoHotkey v2.0+
#SingleInstance Off
#Warn
SetWorkingDir A_ScriptDir
#Warn LocalSameAsGlobal, Off
global BUNDLED_AHK_EXE := ResolveBundledAhkExe()

#Include plugin\RapidOcr\RapidOcr.ahk
#Include plugin\ImagePut-1.11\ImagePut.ahk
#Include LogManager.ahk
#Include RuntimeFilePaths.ahk

global OKWW_HANDOFF_NONCE := ""
global OKWW_HANDOFF_PATH := ""
global OKWW_HANDOFF_DEADLINE := 0
global OKWW_HANDOFF_WRITTEN := false
global OKWW_HANDOFF_REQUESTED := false
global OKWW_HANDOFF_ARG_ERROR := ""
global OKWW_HANDOFF_CANCEL_PATH := ""
global OKWW_HANDOFF_CANCELLED := false
global OKWW_HANDOFF_ABORT_LOGGED := false
global OKWW_ACQUISITION_MODE := "unknown"
global OKWW_MANAGER_MUTEX_HANDLE := 0
global OKWW_MANAGER_MUTEX_OWNED := false

; ====================== 新的日誌系統 ======================
global logger := InitLogger("自動開啟OKWW")
RegisterLifecycleLogging("自動開啟OKWW")
global RUN_ID := A_Now "@" A_TickCount
global STEP_SEQ := 0
global TOOLTIP_SLOT := 3
global TOOLTIP_UNTIL_TICK := 0
global TOOLTIP_CONTENT := ""

InitializeOkwwHandoffRequest()
if (OKWW_HANDOFF_ARG_ERROR != "") {
    Log("OKWW handoff request 參數無效，拒絕啟動: " OKWW_HANDOFF_ARG_ERROR, "ERROR")
    ExitApp
}

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
            if ShouldAbortOkwwHandoff(&elevationAbortReason)
                ExitApp
            elevatedCommand := '*RunAs ' QuoteOkwwCommandArgument(BUNDLED_AHK_EXE)
                . ' ' QuoteOkwwCommandArgument(A_ScriptFullPath)
            for _, arg in A_Args
                elevatedCommand .= ' ' QuoteOkwwCommandArgument(arg)
            if ShouldAbortOkwwHandoff(&elevationAbortReason)
                ExitApp
            Run(elevatedCommand)
        }
    } else {
        if OKWW_HANDOFF_REQUESTED
            Log("找不到 AutoHotkey64.exe，handoff 模式無法提權", "ERROR")
        else
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
    global OKWW_HANDOFF_REQUESTED
    ; handoff manager 是主程式的非互動子程序，不顯示任何 UI。
    if OKWW_HANDOFF_REQUESTED
        return
    if (duration < 3000)
        duration := 3000
    else if (duration > 30000)
        duration := 30000
    msg := StrReplace(msg, "`r", "")

    if (A_TickCount < TOOLTIP_UNTIL_TICK && TOOLTIP_CONTENT != "") {
        lineCount := StrSplit(TOOLTIP_CONTENT, "`n").Length
        if (lineCount >= 5)
            TOOLTIP_CONTENT := msg
        else
            TOOLTIP_CONTENT := TOOLTIP_CONTENT "`n" msg
    } else
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
if !OKWW_HANDOFF_REQUESTED {
    Hotkey("^F2", (*) => ForceAskAndSave("OKWW", "請選擇 ok-ww 可執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)"))
    Hotkey("^F3", (*) => ForceAskAndSave("WUTHERING", "請選擇「鳴潮」遊戲主程式或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)"))
}

; 🔒 額外的啟動前安全檢查
StartupSafetyCheck() {
    Log("執行啟動前安全檢查...")
    WriteStep("前置安全檢查", "掃描 AutoHotkey/OKWW 相關進程")
    if ShouldAbortOkwwHandoff(&abortReason)
        return
    
    ; 檢查是否有其他同類腳本正在運行
    currentPID := DllCall("GetCurrentProcessId")
    scriptCount := 0
    
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process") {
            if ShouldAbortOkwwHandoff(&abortReason)
                return
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
    
    if (scriptCount > 0)
        Log("檢測到 " scriptCount " 個其他 manager 程序；本次已由 named mutex 序列化，繼續執行", "WARN")
    
    Log("啟動前安全檢查通過")
}

; 手動模式若需要互動設定，必須在持有 global manager mutex 前完成；handoff
; 模式完全禁止 AskPathGui/MsgBox，缺設定時稍後只記錄失敗並退出。
if !OKWW_HANDOFF_REQUESTED {
    if !IsWutheringGameRunning() {
        if !LaunchWuthering() {
            Log("手動模式未完成鳴潮路徑設定，取得 manager mutex 前退出", "WARN")
            ExitApp
        }
    }
    existingOkwwBeforeMutex := ProcessExist("ok-ww.exe") || ListOkwwWindows().Length > 0
    if (!existingOkwwBeforeMutex && !LaunchOKWW()) {
        Log("手動模式未完成 OKWW 路徑設定，取得 manager mutex 前退出", "WARN")
        ExitApp
    }
}

; 手動設定只允許發生在 mutex 之前。關閉 hotkey 後，才可能進入序列化區段。
if !OKWW_HANDOFF_REQUESTED {
    Hotkey("^F2", "Off")
    Hotkey("^F3", "Off")
}

; 提權與任何允許的手動設定完成後才取得 mutex。後來的 request 依自己的
; absolute deadline 排隊，不會搶殺或吞掉舊 nonce request。
if !AcquireOkwwManagerMutexUntilDeadline() {
    Log("在 handoff deadline 內無法取得 OKWW manager mutex，停止本次 request"
        " | nonce=" OKWW_HANDOFF_NONCE " deadline=" OKWW_HANDOFF_DEADLINE, "ERROR")
    ExitApp
}
OnExit(ReleaseOkwwManagerMutex)
if ShouldAbortOkwwHandoff(&startupAbortReason) {
    Log("取得 manager mutex 後立即中止 handoff request | reason=" startupAbortReason, "WARN")
    ExitApp
}

; 執行安全檢查
WriteStep("前置安全檢查", "重複實例與進程衝突檢查")
StartupSafetyCheck()
if ShouldAbortOkwwHandoff(&startupAbortReason) {
    Log("啟動前安全檢查期間 handoff 已中止 | reason=" startupAbortReason, "WARN")
    ExitApp
}
WriteStep("前置安全檢查", "通過")

LaunchOKWW() {
    return GetPathWithAsk("OKWW", "請選擇 ok-ww 可執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
}

LaunchWuthering() {
    return GetPathWithAsk("WUTHERING", "請選擇「鳴潮」遊戲主程式或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
}

GetPathWithAsk(key, prompt, filter) {
    global CFG_FILE, OKWW_HANDOFF_REQUESTED, OKWW_MANAGER_MUTEX_OWNED
    path     := NormalizePath(IniReadSafe(CFG_FILE, "paths", key, ""))
    remember := IniReadSafe(CFG_FILE, "flags", key "_remember", "0")
    Log("GetPathWithAsk key=" key " remember=" remember " path=" path)
    if (remember != "1" || !FileExist(path)) {
        if (OKWW_HANDOFF_REQUESTED || OKWW_MANAGER_MUTEX_OWNED) {
            Log("禁止在 handoff／持有 manager mutex 時互動選路徑；設定缺失或檔案不存在"
                " | key=" key " path=" path " mutexOwned=" (OKWW_MANAGER_MUTEX_OWNED ? 1 : 0), "ERROR")
            return ""
        }
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
    global OKWW_HANDOFF_REQUESTED, OKWW_MANAGER_MUTEX_OWNED
    if (OKWW_HANDOFF_REQUESTED || OKWW_MANAGER_MUTEX_OWNED) {
        Log("handoff／持有 manager mutex 時拒絕進入 AskPathGui | prompt=" prompt
            " mutexOwned=" (OKWW_MANAGER_MUTEX_OWNED ? 1 : 0), "ERROR")
        return { path: "", keep: 0 }
    }
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
    if ShouldAbortOkwwHandoff(&abortReason)
        return list
    Log("開始搜尋OKWW視窗...")
    currentPID := DllCall("GetCurrentProcessId")
    
    ; 搜尋所有視窗
    for hwnd in WinGetList() {
        if ShouldAbortOkwwHandoff(&abortReason)
            return list
        try {
            title := WinGetTitle(hwnd)
            processName := WinGetProcessName(hwnd)
            pid := WinGetPID(hwnd)
            wclass := ""
            try wclass := WinGetClass(hwnd)
            
            ; 檢查標題包含OKWW或OK-WW（不區分大小寫）
            titleLower := StrLower(title)
            processLower := StrLower(processName)
            classLower := StrLower(wclass)

            ; 排除自己這支守門腳本（避免把本腳本 tooltip/視窗當成 OKWW）
            if (pid = currentPID)
                continue

            ; 排除 Tooltip 類視窗（常見誤判來源）
            if (classLower = "tooltips_class32")
                continue
            
            ; 排除編輯器和開發工具
            isEditor := (InStr(titleLower, "visual studio code") || 
                        InStr(titleLower, "notepad") || 
                        InStr(titleLower, "vscode") ||
                        InStr(processName, "Code.exe") ||
                        InStr(processName, "notepad"))

            ; 只允許真正可能的 OKWW 相關進程來源
            isOkwwProcess := (processLower = "ok-ww.exe" || processLower = "pythonw.exe")
            if !isOkwwProcess
                continue
            
            ; 只檢測真正的 OKWW 程式視窗，排除編輯器。
            if ((InStr(titleLower, "ok-ww") || InStr(titleLower, "okww")) && !isEditor) {
                ; 最終可操作 UI 由 pythonw.exe 承載；ok-ww.exe 的無版本號視窗才是升級 UI。
                ; ok-ww-siw/service 僅為背景服務，絕不可當成 OCR／滑鼠操作目標。
                isServiceWindow := InStr(titleLower, "-siw") || InStr(titleLower, "service")
                isFinalWindow := (processLower = "pythonw.exe"
                    && RegExMatch(title, "i)^OK-WW\s+v[\d.]+\s+Global(?:\s*-\s*OK-WW)?\s*$"))
                isUpgradeWindow := (processLower = "ok-ww.exe"
                    && !isServiceWindow && Trim(titleLower) = "ok-ww")
                isInteractiveWindow := isFinalWindow || isUpgradeWindow
                windowType := isFinalWindow ? "最終主視窗"
                    : (isUpgradeWindow ? "升級視窗"
                    : (isServiceWindow ? "背景服務" : "其他非互動視窗"))
                
                Log("找到OKWW視窗: pid=" pid " hwnd=" hwnd " title=" title
                    " process=" processName " 視窗類型=" windowType
                    " interactive=" (isInteractiveWindow ? "yes" : "no"))
                list.Push({
                    pid: pid, 
                    hwnd: hwnd, 
                    title: title, 
                    process: processName, 
                    isFinal: isFinalWindow,
                    isService: isServiceWindow,
                    isUpgrade: isUpgradeWindow,
                    isInteractive: isInteractiveWindow
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
    if ShouldAbortOkwwHandoff(&abortReason)
        return {attached: false, pid: 0, hwnd: 0, aborted: true}
    if !IsSet(curPid)
        curPid := 0
    if !IsSet(curHwnd)
        curHwnd := 0

    wins := ListOkwwWindows()
    if ShouldAbortOkwwHandoff(&abortReason)
        return {attached: false, pid: 0, hwnd: 0, aborted: true}
    if (wins.Length = 0) {
        Log("AttachNewestOkww: 沒有找到OKWW視窗", "WARN")
        return {attached: false, pid: 0, hwnd: 0}
    }
    
    finalWindows := []
    upgradeWindows := []
    ignoredWindows := []

    for i, w in wins {
        if ShouldAbortOkwwHandoff(&abortReason)
            return {attached: false, pid: 0, hwnd: 0, aborted: true}
        if (w.HasOwnProp("isFinal") && w.isFinal)
            finalWindows.Push(w)
        else if (w.HasOwnProp("isUpgrade") && w.isUpgrade)
            upgradeWindows.Push(w)
        else
            ignoredWindows.Push(w)
    }

    Log("視窗分類結果: 最終主視窗=" finalWindows.Length
        " 升級視窗=" upgradeWindows.Length
        " 非互動/背景視窗=" ignoredWindows.Length)

    ; 最終 pythonw v...Global 已存在時代表可操作 UI 已就緒，優先於殘留的升級視窗。
    newest := ""
    if (finalWindows.Length > 0) {
        newest := finalWindows[1]
        for i, w in finalWindows {
            if ShouldAbortOkwwHandoff(&abortReason)
                return {attached: false, pid: 0, hwnd: 0, aborted: true}
            if (w.pid > newest.pid)
                newest := w
        }
        Log("AttachNewestOkww: 選擇最終 pythonw 主視窗 '" newest.title "' PID=" newest.pid)
    } else if (upgradeWindows.Length > 0) {
        newest := upgradeWindows[1]
        for i, w in upgradeWindows {
            if ShouldAbortOkwwHandoff(&abortReason)
                return {attached: false, pid: 0, hwnd: 0, aborted: true}
            if (w.pid > newest.pid)
                newest := w
        }
        Log("AttachNewestOkww: 尚無最終主視窗，選擇真正升級 UI '" newest.title "' PID=" newest.pid)
    } else {
        Log("AttachNewestOkww: 目前只有 service/非互動視窗，繼續等待有效 OKWW 視窗", "WARN")
        return {attached: false, pid: 0, hwnd: 0}
    }
    
    ; =========================================================================
    ; 重要：已移除所有 ProcessClose 相關邏輯，確保此函數只附加，不關閉。
    ; killOld 參數雖然保留，但不再有實際作用。
    ; =========================================================================
    
    curPid := newest.pid
    curHwnd := newest.hwnd
    Log("AttachNewestOkww: 接手視窗 hwnd=" curHwnd " pid=" curPid " title=" newest.title)
    
    ; 標題或宿主可能在列舉後立即切換，再驗證一次，絕不讓 service 視窗混入。
    if !IsInteractiveOkwwHwnd(curHwnd) {
        Log("AttachNewestOkww: 接手前視窗已失效或轉為非互動視窗，hwnd=" curHwnd, "WARN")
        curPid := 0
        curHwnd := 0
        return {attached: false, pid: 0, hwnd: 0}
    }
    
    if (GetOkwwWindowKind(curHwnd) = "final") {
        Log("AttachNewestOkww: 最終 pythonw 主視窗已就緒，立即交由全自動主程式；不再激活或 OCR")
        return {attached: true, pid: curPid, hwnd: curHwnd, oldPidClosed: 0, kind: "final"}
    }

    try {
        if ShouldAbortOkwwHandoff(&abortReason)
            return {attached: false, pid: 0, hwnd: 0, aborted: true}
        WinActivate("ahk_id " . curHwnd)
    } catch as e {
        Log("AttachNewestOkww: 激活視窗失敗: " e.Message, "WARN")
    }
    
    if !WaitForOkwwWindowActive(curHwnd, 1000, &abortReason)
        if ShouldAbortOkwwHandoff(&abortReason)
            return {attached: false, pid: 0, hwnd: 0, aborted: true}
    
    return {attached: true, pid: curPid, hwnd: curHwnd, oldPidClosed: 0}
}

WaitForInteractiveOkww(&curPid, &curHwnd, maxAttempts := 30, delayMs := 3000) {
    curHwnd := 0
    Loop maxAttempts {
        if ShouldAbortOkwwHandoff(&abortReason)
            return false
        result := AttachNewestOkww(&curPid, &curHwnd, false)
        if (result.HasOwnProp("aborted") && result.aborted)
            return false
        if (result.attached && curHwnd) {
            Log("等待後找到有效 OKWW 互動視窗，attempt=" A_Index "/" maxAttempts
                " pid=" curPid " hwnd=" curHwnd)
            return true
        }

        curHwnd := 0
        if (Mod(A_Index, 5) = 0)
            WriteStep("OKWW守門", "等待有效互動視窗 | attempt=" A_Index "/" maxAttempts, "WARN")
        Log("尚未找到最終 pythonw／真正升級 UI，繼續等待，第 " A_Index "/" maxAttempts " 次", "WARN")
        if (A_Index < maxAttempts && SleepOkwwWithAbort(delayMs, &abortReason))
            return false
    }

    return false
}

LaunchNewOkwwAndWait(exePath, &curPid, &curHwnd) {
    if ShouldAbortOkwwHandoff(&abortReason)
        return false
    ; 僅清理由設定路徑解析出的同名啟動程式；pythonw 最終 UI 由全自動主流程依 PID/視窗管理。
    SplitPath(exePath, &exeName)
    if (exeName) {
        processes := []
        try {
            for proc in ComObjGet("winmgmts:").ExecQuery(
                "Select * from Win32_Process where Name = '" exeName "'") {
                if ShouldAbortOkwwHandoff(&abortReason)
                    return false
                processes.Push({pid: proc.ProcessId, name: proc.Name})
            }
        }

        if (processes.Length > 0) {
            Log("發現 " processes.Length " 個可能的 OKWW 啟動程式已在運行，依 PID 關閉")
            for proc in processes {
                if ShouldAbortOkwwHandoff(&abortReason)
                    return false
                try {
                    if ShouldAbortOkwwHandoff(&abortReason)
                        return false
                    ProcessClose(proc.pid)
                    Log("關閉進程: " proc.name " (PID: " proc.pid ")")
                    if SleepOkwwWithAbort(200, &abortReason)
                        return false
                } catch as e {
                    Log("無法關閉進程 " proc.name " (PID: " proc.pid "): " e.Message, "WARN")
                }
            }
            if SleepOkwwWithAbort(500, &abortReason)
                return false
        }
    }

    Log("運行OKWW: " exePath)
    if ShouldAbortOkwwHandoff(&abortReason)
        return false
    Run exePath,,, &curPid
    if ShouldAbortOkwwHandoff(&abortReason)
        return false
    if (!curPid) {
        WriteStep("啟動OKWW", "啟動失敗，無 PID", "ERROR")
        Log("無法獲取新啟動進程的PID", "ERROR")
        return false
    }

    WriteStep("啟動OKWW", "啟動成功 | pid=" curPid)
    Log("OKWW已啟動，PID=" curPid)
    try {
        if WaitForOkwwProcess(curPid, 5000, &abortReason)
            Log("進程已成功運行")
        else if ShouldAbortOkwwHandoff(&abortReason)
            return false
        else
            Log("等待進程運行逾時", "WARN")
    } catch as e {
        Log("等待進程運行失敗: " e.Message, "WARN")
    }

    if SleepOkwwWithAbort(1500, &abortReason)
        return false
    Log("開始等待 OKWW 最終主視窗／真正升級 UI 出現...")
    if WaitForInteractiveOkww(&curPid, &curHwnd, 30, 3000) {
        WriteStep("等待OKWW主視窗", "成功 | pid=" curPid " hwnd=" curHwnd)
        return true
    }
    if ShouldAbortOkwwHandoff(&abortReason)
        return false

    WriteStep("等待OKWW主視窗", "90 秒內無有效互動視窗", "ERROR")
    Log("等待 OKWW 有效互動視窗超時", "ERROR")
    return false
}


; ====================== 啟動與視窗鎖定 ======================
global targetHwnd := 0
pid := 0

; 先嘗試接手既有，但不關閉其他進程
Log("檢查是否存在已運行的OKWW進程...")

; 🔧 增強型重複啟動檢測：多層檢查確保不重複啟動
; 第一層：檢查視窗
wins0 := ListOkwwWindows()
if ShouldAbortOkwwHandoff(&startupAbortReason)
    ExitApp
; 第二層：檢查進程名稱
okwwProcess := ProcessExist("ok-ww.exe")
pythonwWithOKWW := false

; 第三層：檢查pythonw是否為OKWW相關
if (!okwwProcess) {
    for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name='pythonw.exe'") {
        if ShouldAbortOkwwHandoff(&startupAbortReason)
            ExitApp
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
    OKWW_ACQUISITION_MODE := "attached_existing"
    WriteStep("OKWW守門", "發現既有實例，改為接手")
    Log("發現已運行的OKWW (視窗:" wins0.Length " 進程:" (okwwProcess ? "yes" : "no") " pythonw:" (pythonwWithOKWW ? "yes" : "no") ")，嘗試接手")
    if WaitForInteractiveOkww(&pid, &targetHwnd, 30, 3000) {
        Log("已成功接手現有 OKWW 互動視窗，PID=" pid)
        WriteStep("OKWW守門", "接手完成 | pid=" pid)
    } else {
        if ShouldAbortOkwwHandoff(&startupAbortReason)
            ExitApp
        Log("既有 OKWW 在 90 秒內仍沒有有效互動視窗", "ERROR")
        WriteStep("OKWW守門", "既有實例無有效互動視窗", "ERROR")
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
            if !OKWW_HANDOFF_REQUESTED
                TrayTip "未設定鳴潮遊戲路徑", "請按 Ctrl+F3 重新指定", 2
            ExitApp
        }

        Log("準備啟動鳴潮: " gameExe)
        if ShouldAbortOkwwHandoff(&startupAbortReason)
            ExitApp
        Run gameExe,,, &gamePid
        if ShouldAbortOkwwHandoff(&startupAbortReason)
            ExitApp
        if (gamePid) {
            Log("鳴潮已啟動，PID=" gamePid)
            try {
                if !WaitForOkwwProcess(gamePid, 5000, &startupAbortReason)
                    if ShouldAbortOkwwHandoff(&startupAbortReason)
                        ExitApp
            } catch as e
                Log("等待鳴潮進程失敗: " e.Message, "WARN")
        } else {
            Log("無法取得鳴潮進程 PID，可能啟動失敗", "WARN")
        }

        if SleepOkwwWithAbort(2000, &startupAbortReason)
            ExitApp
    } else {
        WriteStep("鳴潮啟動", "已在運行，略過")
        Log("偵測到鳴潮已在運行，略過啟動")
    }
    WriteStep("啟動OKWW", "讀取路徑並準備啟動")
    exePath := LaunchOKWW()
    if (!exePath) {
        WriteStep("啟動OKWW", "未設定路徑", "ERROR")
        Log("未設定OKWW路徑，無法啟動", "ERROR")
        if !OKWW_HANDOFF_REQUESTED
            TrayTip "未設定 OKWW 路徑", "請按 Ctrl+F2 重新指定", 2
        ExitApp
    }
    
    Log("準備啟動OKWW: " exePath)
    
    ; 🚨 啟動前最終檢查：確保沒有OKWW程式已經在啟動過程中
    Log("執行啟動前最終檢查...")
    if SleepOkwwWithAbort(1000, &startupAbortReason)
        ExitApp
    
    ; 再次檢查是否有OKWW進程出現
    finalCheck := ListOkwwWindows()
    if ShouldAbortOkwwHandoff(&startupAbortReason)
        ExitApp
    finalProcessCheck := ProcessExist("ok-ww.exe")
    
    if (finalCheck.Length > 0 || finalProcessCheck) {
        OKWW_ACQUISITION_MODE := "attached_concurrent"
        Log("最終檢查發現 OKWW 已在啟動中 (視窗:" finalCheck.Length
            " 進程:" (finalProcessCheck ? "yes" : "no") ")，改為等待有效互動視窗", "WARN")
        WriteStep("啟動OKWW", "並發啟動已存在，等待接手", "WARN")
        WaitForInteractiveOkww(&pid, &targetHwnd, 30, 3000)
        if ShouldAbortOkwwHandoff(&startupAbortReason)
            ExitApp
    } else {
        OKWW_ACQUISITION_MODE := "launched_new"
        LaunchNewOkwwAndWait(exePath, &pid, &targetHwnd)
        if ShouldAbortOkwwHandoff(&startupAbortReason)
            ExitApp
    }
}

if !targetHwnd {
    WriteStep("OKWW主視窗", "找不到最終 pythonw／真正升級 UI，結束", "ERROR")
    Log("找不到有效 OKWW 互動視窗；拒絕使用 service/ok-ww-siw 或寬鬆標題備援", "ERROR")
    if !OKWW_HANDOFF_REQUESTED
        TrayTip "找不到 OKWW 主視窗", "請檢查 OKWW 是否正常啟動", 3
    ExitApp
}

if (GetOkwwWindowKind(targetHwnd) = "final") {
    if !CommitOkwwFinalHandoffUntilDeadline(targetHwnd, OKWW_ACQUISITION_MODE) {
        WriteStep("OKWW交接", "healthy final 已確認，但 handoff 寫入失敗", "ERROR")
        ExitApp
    }
    WriteStep("OKWW交接", "最終 pythonw 主視窗已就緒；不激活、不 OCR，交由全自動主程式")
    Log("final pythonw ready; updater manager exits immediately")
    ExitApp
}

; ====================== 截圖 + OCR 工具 ======================
EnsureOkwwWindow() {
    global targetHwnd, pid
    if ShouldAbortOkwwHandoff(&abortReason)
        return false
    if IsInteractiveOkwwHwnd(targetHwnd)
        return true
    Log("EnsureOkwwWindow: lost/invalid/non-interactive hwnd, reattach", "WARN")
    targetHwnd := 0
    _ := AttachNewestOkww(&pid, &targetHwnd, true)
    if ShouldAbortOkwwHandoff(&abortReason)
        return false
    return IsInteractiveOkwwHwnd(targetHwnd)
}

IsValidHwnd(hwnd) {
    try {
        return !!(hwnd && DllCall("IsWindow", "ptr", hwnd, "int"))
    } catch {
        return false
    }
}

IsInteractiveOkwwHwnd(hwnd) {
    return GetOkwwWindowKind(hwnd) != ""
}

GetOkwwWindowKind(hwnd) {
    if !IsValidHwnd(hwnd)
        return ""

    try {
        title := Trim(WinGetTitle("ahk_id " hwnd))
        titleLower := StrLower(title)
        processLower := StrLower(WinGetProcessName("ahk_id " hwnd))
        if (InStr(titleLower, "-siw") || InStr(titleLower, "service"))
            return ""

        isFinal := (processLower = "pythonw.exe"
            && RegExMatch(title, "i)^OK-WW\s+v[\d.]+\s+Global(?:\s*-\s*OK-WW)?\s*$"))
        isUpgrade := (processLower = "ok-ww.exe" && titleLower = "ok-ww")
        return isFinal ? "final" : (isUpgrade ? "upgrade" : "")
    } catch {
        return ""
    }
}

CaptureAndOCR(minSize := 8192, imgPath := "") {
    global targetHwnd, OKWW_ACQUISITION_MODE
    if ShouldAbortOkwwHandoff(&abortReason)
        return {ok: false, blocks: [], reason: "handoff_aborted"}
    if (imgPath = "")
        imgPath := RuntimeFiles_NewImagePath("okww_update_ocr")
    if !EnsureOkwwWindow() {
        if ShouldAbortOkwwHandoff(&abortReason)
            return {ok: false, blocks: [], reason: "handoff_aborted"}
        return {ok: false, blocks: [], reason: "no_interactive_window"}
    }
    if ShouldAbortOkwwHandoff(&abortReason)
        return {ok: false, blocks: [], reason: "handoff_aborted"}
    if (GetOkwwWindowKind(targetHwnd) = "final") {
        if !CommitOkwwFinalHandoffUntilDeadline(targetHwnd,
            OKWW_ACQUISITION_MODE "_transition") {
            if ShouldAbortOkwwHandoff(&abortReason)
                return {ok: false, blocks: [], reason: "handoff_aborted"}
            return {ok: false, blocks: [], reason: "final_handoff_failed"}
        }
        Log("CaptureAndOCR: 最終 pythonw 主視窗已出現，停止管理器 OCR 並交接")
        return {ok: false, blocks: [], reason: "final_ready"}
    }
    if !IsValidHwnd(targetHwnd) {
        Log("CaptureAndOCR: invalid hwnd before capture", "WARN")
        return {ok: false, blocks: [], reason: "invalid_hwnd_before_capture"}
    }
    try {
        try {
            if ShouldAbortOkwwHandoff(&abortReason)
                return {ok: false, blocks: [], reason: "handoff_aborted"}
            WinActivate("ahk_id " . targetHwnd)
        } catch {
            ; ignore
        }
        if !WaitForOkwwWindowActive(targetHwnd, 500, &abortReason)
            if ShouldAbortOkwwHandoff(&abortReason)
                return {ok: false, blocks: [], reason: "handoff_aborted"}
    }
    if ShouldAbortOkwwHandoff(&abortReason)
        return {ok: false, blocks: [], reason: "handoff_aborted"}
    if !IsValidHwnd(targetHwnd) {
        Log("CaptureAndOCR: hwnd became invalid after activate", "WARN")
        return {ok: false, blocks: [], reason: "invalid_hwnd_after_activate"}
    }
    try {
        if ShouldAbortOkwwHandoff(&abortReason)
            return {ok: false, blocks: [], reason: "handoff_aborted"}
        ImagePutFile(targetHwnd, imgPath)
    } catch as e {
        Log("ImagePutFile failed: " e.Message, "WARN")
        try FileDelete(imgPath)
        return {ok: false, blocks: [], reason: "capture_failed"}
    }
    if ShouldAbortOkwwHandoff(&abortReason) {
        try FileDelete(imgPath)
        return {ok: false, blocks: [], reason: "handoff_aborted"}
    }
    if !FileExist(imgPath) {
        Log("capture file not exist", "WARN")
        return {ok: false, blocks: [], reason: "capture_file_missing"}
    }
    sz := FileGetSize(imgPath, "B")
    if (sz < minSize) {
        Log("capture too small size=" sz, "WARN")
        try FileDelete(imgPath)
        return {ok: false, blocks: [], reason: "capture_too_small"}
    }
    try {
        if ShouldAbortOkwwHandoff(&abortReason)
            return {ok: false, blocks: [], reason: "handoff_aborted"}
        ocr := RapidOcr()
        if ShouldAbortOkwwHandoff(&abortReason)
            return {ok: false, blocks: [], reason: "handoff_aborted"}
        blocks := ocr.ocr_from_file(imgPath, , true)
        if ShouldAbortOkwwHandoff(&abortReason)
            return {ok: false, blocks: [], reason: "handoff_aborted"}
        n := (blocks is Array) ? blocks.Length : 0
        Log("OCR done blocks=" n " size=" sz)
        return {ok: true, blocks: (blocks is Array ? blocks : []), reason: ""}
    } catch as e {
        Log("OCR exception: " e.Message, "ERROR")
        return {ok: false, blocks: [], reason: "ocr_exception"}
    } finally {
        try FileDelete(imgPath)
    }
}

QuoteOkwwCommandArgument(value) {
    return '"' StrReplace(value, '"', '""') '"'
}

ShouldAbortOkwwHandoff(&reason := "") {
    global OKWW_HANDOFF_REQUESTED, OKWW_HANDOFF_DEADLINE
    global OKWW_HANDOFF_CANCEL_PATH, OKWW_HANDOFF_CANCELLED
    global OKWW_HANDOFF_ABORT_LOGGED

    reason := ""
    if !OKWW_HANDOFF_REQUESTED
        return false
    if (OKWW_HANDOFF_CANCEL_PATH != "" && FileExist(OKWW_HANDOFF_CANCEL_PATH)) {
        OKWW_HANDOFF_CANCELLED := true
        reason := "cancelled"
    } else {
        nowTick := DllCall("kernel32\GetTickCount64", "uint64")
        if (OKWW_HANDOFF_DEADLINE <= 0 || nowTick > OKWW_HANDOFF_DEADLINE)
            reason := "deadline_expired now=" nowTick " deadline=" OKWW_HANDOFF_DEADLINE
    }
    if (reason = "")
        return false
    if !OKWW_HANDOFF_ABORT_LOGGED {
        OKWW_HANDOFF_ABORT_LOGGED := true
        Log("OKWW handoff 工作已要求中止 | reason=" reason, "WARN")
    }
    return true
}

SleepOkwwWithAbort(delayMs, &reason := "") {
    global OKWW_HANDOFF_REQUESTED
    reason := ""
    totalMs := Max(0, Integer(delayMs))
    if !OKWW_HANDOFF_REQUESTED {
        Sleep totalMs
        return false
    }
    endTick := DllCall("kernel32\GetTickCount64", "uint64") + totalMs
    loop {
        if ShouldAbortOkwwHandoff(&reason)
            return true
        nowTick := DllCall("kernel32\GetTickCount64", "uint64")
        if (nowTick >= endTick)
            return false
        Sleep Min(100, endTick - nowTick)
    }
}

WaitForOkwwProcess(processId, timeoutMs := 5000, &reason := "") {
    reason := ""
    deadline := DllCall("kernel32\GetTickCount64", "uint64")
        + Max(0, Integer(timeoutMs))
    loop {
        if ShouldAbortOkwwHandoff(&reason)
            return false
        if ProcessExist(processId)
            return true
        nowTick := DllCall("kernel32\GetTickCount64", "uint64")
        if (nowTick >= deadline)
            return false
        if SleepOkwwWithAbort(Min(100, deadline - nowTick), &reason)
            return false
    }
}

WaitForOkwwWindowActive(hwnd, timeoutMs := 1000, &reason := "") {
    reason := ""
    deadline := DllCall("kernel32\GetTickCount64", "uint64")
        + Max(0, Integer(timeoutMs))
    loop {
        if ShouldAbortOkwwHandoff(&reason)
            return false
        try {
            if WinActive("ahk_id " hwnd)
                return true
        }
        nowTick := DllCall("kernel32\GetTickCount64", "uint64")
        if (nowTick >= deadline)
            return false
        if SleepOkwwWithAbort(Min(50, deadline - nowTick), &reason)
            return false
    }
}

InitializeOkwwHandoffRequest() {
    global OKWW_HANDOFF_NONCE, OKWW_HANDOFF_PATH, OKWW_HANDOFF_DEADLINE
    global OKWW_HANDOFF_REQUESTED, OKWW_HANDOFF_ARG_ERROR, OKWW_HANDOFF_CANCEL_PATH

    nonce := ""
    reportPath := ""
    deadline := 0
    sawNonce := false
    sawPath := false
    sawDeadline := false
    i := 1
    while (i <= A_Args.Length) {
        arg := A_Args[i]
        if (arg = "--handoff-nonce" && i < A_Args.Length) {
            nonce := A_Args[i + 1]
            sawNonce := true
            i += 2
            continue
        }
        if (arg = "--handoff-path" && i < A_Args.Length) {
            reportPath := A_Args[i + 1]
            sawPath := true
            i += 2
            continue
        }
        if (arg = "--handoff-deadline" && i < A_Args.Length) {
            sawDeadline := true
            try deadline := Integer(A_Args[i + 1])
            catch as e {
                OKWW_HANDOFF_ARG_ERROR := "deadline_not_integer:" e.Message
                return
            }
            i += 2
            continue
        }
        i += 1
    }

    OKWW_HANDOFF_REQUESTED := sawNonce || sawPath || sawDeadline
    if !OKWW_HANDOFF_REQUESTED
        return
    if (!sawNonce || !sawPath || !sawDeadline) {
        OKWW_HANDOFF_ARG_ERROR := "required_argument_missing"
        return
    }
    if !RegExMatch(nonce, "^[0-9A-Za-z_-]{16,96}$") {
        OKWW_HANDOFF_ARG_ERROR := "nonce_invalid"
        return
    }

    expectedPath := RuntimeFiles_EnsureDir("暫存") "\okww_handoff_" nonce ".ini"
    if (StrLower(StrReplace(reportPath, "/", "\"))
        != StrLower(StrReplace(expectedPath, "/", "\"))) {
        OKWW_HANDOFF_ARG_ERROR := "path_invalid_or_outside_runtime_temp"
        return
    }

    nowTick := DllCall("kernel32\GetTickCount64", "uint64")
    maxFutureMs := 15 * 60 * 1000
    if (deadline <= nowTick || deadline > nowTick + maxFutureMs) {
        OKWW_HANDOFF_ARG_ERROR := "deadline_expired_or_unreasonable now=" nowTick
            . " deadline=" deadline
        return
    }

    OKWW_HANDOFF_NONCE := nonce
    OKWW_HANDOFF_PATH := expectedPath
    OKWW_HANDOFF_DEADLINE := deadline
    OKWW_HANDOFF_CANCEL_PATH := expectedPath ".cancel"
    Log("已接收 OKWW handoff 請求 | nonce=" nonce
        " path=" expectedPath " deadline=" OKWW_HANDOFF_DEADLINE)
}

AcquireOkwwManagerMutexUntilDeadline() {
    global OKWW_MANAGER_MUTEX_HANDLE, OKWW_MANAGER_MUTEX_OWNED
    global OKWW_HANDOFF_REQUESTED, OKWW_HANDOFF_DEADLINE

    mutexName := "Local\WutheringAuto_OKWW_Manager_Request_V2"
    DllCall("kernel32\SetLastError", "uint", 0)
    handle := DllCall("kernel32\CreateMutexW", "ptr", 0, "int", true,
        "str", mutexName, "ptr")
    createError := A_LastError
    if !handle {
        Log("CreateMutexW 失敗: " createError, "ERROR")
        return false
    }
    OKWW_MANAGER_MUTEX_HANDLE := handle

    ; 新建 mutex 且 initialOwner=true 時已取得所有權；既有 mutex 才需要等待。
    alreadyExists := (createError = 183)
    if !alreadyExists {
        OKWW_MANAGER_MUTEX_OWNED := true
        return true
    }

    nowTick := DllCall("kernel32\GetTickCount64", "uint64")
    effectiveDeadline := OKWW_HANDOFF_REQUESTED
        ? OKWW_HANDOFF_DEADLINE : nowTick + 90000
    waitResult := 0x102
    loop {
        if ShouldAbortOkwwHandoff(&abortReason)
            break
        nowTick := DllCall("kernel32\GetTickCount64", "uint64")
        remaining := effectiveDeadline > nowTick ? effectiveDeadline - nowTick : 0
        if (remaining <= 0)
            break
        waitResult := DllCall("kernel32\WaitForSingleObject", "ptr", handle,
            "uint", Min(200, remaining), "uint")
        if (waitResult = 0 || waitResult = 0x80) { ; WAIT_OBJECT_0 / WAIT_ABANDONED
            OKWW_MANAGER_MUTEX_OWNED := true
            return true
        }
        if (waitResult != 0x102)
            break
    }

    DllCall("kernel32\CloseHandle", "ptr", handle)
    OKWW_MANAGER_MUTEX_HANDLE := 0
    Log("等待 OKWW manager mutex 失敗 | result=" waitResult
        " error=" A_LastError, "ERROR")
    return false
}

ReleaseOkwwManagerMutex(*) {
    global OKWW_MANAGER_MUTEX_HANDLE, OKWW_MANAGER_MUTEX_OWNED
    if OKWW_MANAGER_MUTEX_HANDLE {
        if OKWW_MANAGER_MUTEX_OWNED
            try DllCall("kernel32\ReleaseMutex", "ptr", OKWW_MANAGER_MUTEX_HANDLE, "int")
        try DllCall("kernel32\CloseHandle", "ptr", OKWW_MANAGER_MUTEX_HANDLE, "int")
    }
    OKWW_MANAGER_MUTEX_HANDLE := 0
    OKWW_MANAGER_MUTEX_OWNED := false
}

GetHealthyFinalOkwwForHandoff(hwnd, &pid := 0, &title := "", &reason := "") {
    pid := 0
    title := ""
    reason := ""
    if (GetOkwwWindowKind(hwnd) != "final") {
        reason := "identity_mismatch"
        return false
    }

    try {
        pid := WinGetPID("ahk_id " hwnd)
        title := WinGetTitle("ahk_id " hwnd)
        root := DllCall("user32\GetAncestor", "ptr", hwnd, "uint", 2, "ptr")
        if (pid <= 0 || root != hwnd) {
            reason := "pid_or_root_invalid"
            return false
        }
        if !DllCall("user32\IsWindowVisible", "ptr", hwnd, "int") {
            reason := "not_visible"
            return false
        }
        if !DllCall("user32\IsWindowEnabled", "ptr", hwnd, "int") {
            reason := "not_enabled"
            return false
        }
        if DllCall("user32\IsHungAppWindow", "ptr", hwnd, "int") {
            reason := "window_hung"
            return false
        }
        if (WinGetExStyle("ahk_id " hwnd) & 0x08000000) {
            reason := "no_activate_style"
            return false
        }
        cloaked := Buffer(4, 0)
        try {
            hr := DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14,
                "ptr", cloaked.Ptr, "uint", 4, "int")
            if (hr = 0 && NumGet(cloaked, 0, "uint") != 0) {
                reason := "cloaked"
                return false
            }
        }
        if (WinGetMinMax("ahk_id " hwnd) != -1) {
            WinGetPos(, , &width, &height, "ahk_id " hwnd)
            if (width < 500 || height < 280) {
                reason := "window_too_small"
                return false
            }
        }
        return true
    } catch as e {
        reason := "inspect_failed:" e.Message
        return false
    }
}

CountHealthyFinalOkwwForHandoff(selectedHwnd, &selectedIncluded := false) {
    selectedIncluded := false
    count := 0
    try {
        for candidateHwnd in WinGetList() {
            if ShouldAbortOkwwHandoff(&abortReason)
                return count
            reason := ""
            if !GetHealthyFinalOkwwForHandoff(candidateHwnd, &candidatePid,
                &candidateTitle, &reason)
                continue
            count += 1
            if (candidateHwnd = selectedHwnd)
                selectedIncluded := true
        }
    }
    return count
}

TryWriteOkwwFinalHandoff(hwnd, result := "final_confirmed") {
    global OKWW_HANDOFF_NONCE, OKWW_HANDOFF_PATH, OKWW_HANDOFF_DEADLINE
    global OKWW_HANDOFF_WRITTEN, OKWW_HANDOFF_CANCEL_PATH, OKWW_HANDOFF_CANCELLED

    if ShouldAbortOkwwHandoff(&abortReason)
        return false
    if (OKWW_HANDOFF_NONCE = "" || OKWW_HANDOFF_PATH = "")
        return false
    if OKWW_HANDOFF_WRITTEN
        return true
    nowTick := DllCall("kernel32\GetTickCount64", "uint64")
    if (OKWW_HANDOFF_DEADLINE > 0 && nowTick > OKWW_HANDOFF_DEADLINE) {
        Log("OKWW handoff 已逾主程式等待期限，不再回寫 | hwnd=" hwnd, "WARN")
        return false
    }

    lockHandle := 0
    if !AcquireOkwwHandoffMutex(&lockHandle)
        return false
    try {
        if ShouldAbortOkwwHandoff(&abortReason)
            return false
        if FileExist(OKWW_HANDOFF_CANCEL_PATH) {
            OKWW_HANDOFF_CANCELLED := true
            Log("OKWW handoff 已由主程式取消，不再回寫 | nonce=" OKWW_HANDOFF_NONCE, "WARN")
            return false
        }
        nowTick := DllCall("kernel32\GetTickCount64", "uint64")
        if (nowTick > OKWW_HANDOFF_DEADLINE)
            return false

        reason := ""
        if !GetHealthyFinalOkwwForHandoff(hwnd, &confirmedPid, &confirmedTitle, &reason) {
            Log("OKWW handoff 拒絕不健康的 final 視窗 | hwnd=" hwnd " reason=" reason, "WARN")
            return false
        }
        healthyCandidateCount := CountHealthyFinalOkwwForHandoff(hwnd, &selectedIncluded)
        if ShouldAbortOkwwHandoff(&abortReason)
            return false
        if !selectedIncluded || healthyCandidateCount < 1 {
            Log("OKWW handoff 候選集合已改變，拒絕回寫 | selected=" hwnd
                " count=" healthyCandidateCount, "ERROR")
            return false
        }

        tempPath := OKWW_HANDOFF_PATH ".tmp."
            . DllCall("kernel32\GetCurrentProcessId", "uint") "." nowTick
        try {
            if ShouldAbortOkwwHandoff(&abortReason)
                return false
            try FileDelete(tempPath)
            IniWrite(OKWW_HANDOFF_NONCE, tempPath, "handoff", "nonce")
            IniWrite(result, tempPath, "handoff", "result")
            IniWrite(confirmedPid, tempPath, "handoff", "pid")
            IniWrite(hwnd, tempPath, "handoff", "hwnd")
            IniWrite(confirmedTitle, tempPath, "handoff", "title")
            IniWrite(healthyCandidateCount, tempPath, "handoff", "candidateCount")
            IniWrite(result, tempPath, "handoff", "selectionSource")
            ; 與主程式 cleanup 共用 per-nonce mutex；搬移前再次檢查 deadline/cancel，
            ; 保證 cleanup 一旦取得 mutex 後不會再出現晚到的 orphan report。
            if (ShouldAbortOkwwHandoff(&abortReason)
                || DllCall("kernel32\GetTickCount64", "uint64") > OKWW_HANDOFF_DEADLINE
                || FileExist(OKWW_HANDOFF_CANCEL_PATH)) {
                if FileExist(OKWW_HANDOFF_CANCEL_PATH)
                    OKWW_HANDOFF_CANCELLED := true
                try FileDelete(tempPath)
                return false
            }
            FileMove(tempPath, OKWW_HANDOFF_PATH, 1)
            OKWW_HANDOFF_WRITTEN := true
            Log("OKWW handoff 已原子回寫 | result=" result " pid=" confirmedPid
                " hwnd=" hwnd " candidates=" healthyCandidateCount
                " title=" confirmedTitle)
            return true
        } catch as e {
            try FileDelete(tempPath)
            Log("OKWW handoff 回寫失敗: " e.Message " | path=" OKWW_HANDOFF_PATH, "ERROR")
            return false
        }
    } finally {
        ReleaseOkwwHandoffMutex(lockHandle)
    }
}

AcquireOkwwHandoffMutex(&handle := 0) {
    global OKWW_HANDOFF_NONCE, OKWW_HANDOFF_DEADLINE
    handle := DllCall("kernel32\CreateMutexW", "ptr", 0, "int", false,
        "str", "Local\WutheringAuto_OKWW_Handoff_" OKWW_HANDOFF_NONCE, "ptr")
    if !handle
        return false
    loop {
        if ShouldAbortOkwwHandoff(&abortReason)
            break
        nowTick := DllCall("kernel32\GetTickCount64", "uint64")
        remaining := OKWW_HANDOFF_DEADLINE > nowTick ? OKWW_HANDOFF_DEADLINE - nowTick : 0
        if (remaining <= 0)
            break
        waitResult := DllCall("kernel32\WaitForSingleObject", "ptr", handle,
            "uint", Min(100, remaining), "uint")
        if (waitResult = 0 || waitResult = 0x80)
            return true
        if (waitResult != 0x102)
            break
    }
    DllCall("kernel32\CloseHandle", "ptr", handle)
    handle := 0
    return false
}

ReleaseOkwwHandoffMutex(handle) {
    if !handle
        return
    try DllCall("kernel32\ReleaseMutex", "ptr", handle, "int")
    try DllCall("kernel32\CloseHandle", "ptr", handle, "int")
}

CommitOkwwFinalHandoffUntilDeadline(hwnd, result := "final_confirmed") {
    global OKWW_HANDOFF_REQUESTED, OKWW_HANDOFF_DEADLINE
    global OKWW_HANDOFF_CANCELLED

    if !OKWW_HANDOFF_REQUESTED
        return true
    attempts := 0
    while (DllCall("kernel32\GetTickCount64", "uint64") <= OKWW_HANDOFF_DEADLINE) {
        if ShouldAbortOkwwHandoff(&abortReason)
            break
        attempts += 1
        if TryWriteOkwwFinalHandoff(hwnd, result)
            return true
        if ShouldAbortOkwwHandoff(&abortReason) || OKWW_HANDOFF_CANCELLED
            break
        remaining := OKWW_HANDOFF_DEADLINE
            - DllCall("kernel32\GetTickCount64", "uint64")
        if (remaining <= 0)
            break
        if SleepOkwwWithAbort(Min(200, remaining), &abortReason)
            break
    }
    Log("OKWW healthy-final handoff 在 absolute deadline 內寫入失敗"
        " | result=" result " hwnd=" hwnd " attempts=" attempts
        " cancelled=" (OKWW_HANDOFF_CANCELLED ? 1 : 0), "ERROR")
    return false
}

DetectOCRText(keyword, maxMs := 15000) {
    Log("DetectOCRText start kw=" keyword " maxMs=" maxMs)
    if ShouldAbortOkwwHandoff(&abortReason)
        return "handoff_aborted"
    start := DllCall("kernel32\GetTickCount64", "uint64")
    stableHit := 0
    needStable := 2
    successfulCaptures := 0
    captureFailures := 0
    while (DllCall("kernel32\GetTickCount64", "uint64") - start < maxMs) {
        if ShouldAbortOkwwHandoff(&abortReason)
            return "handoff_aborted"
        elapsed := DllCall("kernel32\GetTickCount64", "uint64") - start
        interval := (elapsed < 3000) ? 500 : 1200  ; 從250/600ms改為500/1200ms，減少系統負擔
        if SleepOkwwWithAbort(interval, &abortReason)
            return "handoff_aborted"
        capture := CaptureAndOCR(8192)
        if ShouldAbortOkwwHandoff(&abortReason)
            return "handoff_aborted"
        if !capture.ok {
            if (capture.reason = "handoff_aborted")
                return "handoff_aborted"
            if (capture.reason = "final_ready") {
                Log("DetectOCRText: 最終 pythonw 主視窗已就緒，停止升級偵測並交接")
                return "final_ready"
            }
            if (capture.reason = "final_handoff_failed")
                return "final_handoff_failed"
            captureFailures += 1
            continue
        }
        successfulCaptures += 1
        blocks := capture.blocks
        hasKW := false
        for block in blocks {
            if ShouldAbortOkwwHandoff(&abortReason)
                return "handoff_aborted"
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
                return "found"
            }
        } else {
            if (stableHit != 0)
                Log("DetectOCRText reset hit from " stableHit " to 0")
            stableHit := 0
        }
    }
    if ShouldAbortOkwwHandoff(&abortReason)
        return "handoff_aborted"
    if (successfulCaptures < 2) {
        Log("DetectOCRText 無法可靠判斷：有效截圖/OCR=" successfulCaptures
            " 截圖失敗=" captureFailures " kw=" keyword, "ERROR")
        return "capture_failed"
    }

    Log("DetectOCRText 已完成 " successfulCaptures " 次有效 OCR，未找到 kw=" keyword, "WARN")
    return "not_found"
}

DoOCRClick(keyword, stageText, mode := "leftmost", sendHotkey := "", attempts := 6) {
    global targetHwnd
    if ShouldAbortOkwwHandoff(&abortReason)
        return false
    Log("DoOCRClick stage=" stageText " kw=" keyword " mode=" mode " tries=" attempts)
    ShowTip(stageText, 600)

    loop attempts {
        if ShouldAbortOkwwHandoff(&abortReason)
            return false
        capture := CaptureAndOCR(8192)
        if ShouldAbortOkwwHandoff(&abortReason)
            return false
        if !capture.ok {
            Log("DoOCRClick 截圖/OCR 失敗，reason=" capture.reason
                " remain=" (attempts - A_Index), "WARN")
            if (capture.reason = "handoff_aborted"
                || capture.reason = "final_ready"
                || capture.reason = "final_handoff_failed")
                return false
            if SleepOkwwWithAbort(400, &abortReason)
                return false
            continue
        }
        blocks := capture.blocks

        best := ""
        bestScore := (mode = "leftmost") ?  999999999 : -999999999
        for block in blocks {
            if ShouldAbortOkwwHandoff(&abortReason)
                return false
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
                    if ShouldAbortOkwwHandoff(&abortReason)
                        return false
                    try WinActivate("ahk_id " . targetHwnd)
                    if !WaitForOkwwWindowActive(targetHwnd, 600, &abortReason)
                        if ShouldAbortOkwwHandoff(&abortReason)
                            return false
                }
                if ShouldAbortOkwwHandoff(&abortReason)
                    return false
                MouseMove best[1], best[2]
                if SleepOkwwWithAbort(40, &abortReason)
                    return false
                if ShouldAbortOkwwHandoff(&abortReason)
                    return false
                MouseClick "left", best[1], best[2]
            } finally {
                CoordMode "Mouse", oldMode
            }
            if SleepOkwwWithAbort(350, &abortReason)
                return false
            if (sendHotkey != "") {
                Log("DoOCRClick send hotkey=" sendHotkey)
                if ShouldAbortOkwwHandoff(&abortReason)
                    return false
                Send(sendHotkey)
            }
            if SleepOkwwWithAbort(800, &abortReason)
                return false
            return true
        }
        Log("DoOCRClick not found this try, remain=" (attempts - A_Index))
        if SleepOkwwWithAbort(450, &abortReason)
            return false
    }

    Log("DoOCRClick failed kw=" keyword, "WARN")
    ShowTip(stageText "`n找不到「" keyword "」", 1200)
    return false
}

; ====================== 前檢查與四階段流程 ======================
WriteStep("升級檢測", "檢查是否需要執行升級流程")
upgradeDetectState := DetectOCRText("升级APP", 15000)
if (upgradeDetectState = "handoff_aborted") {
    Log("升級偵測因 handoff deadline/cancel 中止", "WARN")
    ExitApp
}
if (upgradeDetectState = "final_ready") {
    WriteStep("OKWW交接", "升級偵測期間最終 pythonw 主視窗已出現；立即交接")
    ExitApp
}
if (upgradeDetectState = "final_handoff_failed") {
    WriteStep("OKWW交接", "healthy final 已確認，但 handoff 在期限內寫入失敗", "ERROR")
    ExitApp
}
if (upgradeDetectState = "capture_failed") {
    WriteStep("升級檢測", "截圖/OCR 全程失敗，無法判定是否需更新", "ERROR")
    ShowTip("❌ OKWW 截圖失敗，無法確認更新狀態", 1800)
    Log("upgrade state unknown because capture/OCR failed; refusing to report no update", "ERROR")
    ExitApp
}
if (upgradeDetectState != "found") {
    WriteStep("升級檢測", "未偵測到升级APP，流程結束")
    ShowTip("🔍 未偵測到「升级APP」，不執行升級", 1200)
    Log("no upgrade keyword after repeated valid OCR, exit")
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
