; LogManager.ahk - 統一日誌管理系統
; 功能：
; 1. 統一日誌存放到 自動鋤地/log 目錄
; 2. 按腳本名稱分類建立子資料夾
; 3. 按時間戳命名日誌檔案
; 4. 自動清理，最多保留5份日誌

#Requires AutoHotkey v2.0+

class LogManager {
    static instances := Map()
    
    __New(scriptName) {
        this.scriptName := scriptName
        this.logFile := ""  ; 初始化為空字串
        this.logDir := ""   ; 初始化為空字串
        this.setupLogPath()
        this.cleanOldLogs()
        LogManager.instances[scriptName] := this
    }
    
    setupLogPath() {
        ; 確定主日誌目錄，優先使用自動鋤地資料夾
        baseDir := ""
        
        ; 首先檢查是否已在自動鋤地資料夾內（payload子目錄）
        if InStr(A_ScriptDir, "自動鋤地") && InStr(A_ScriptDir, "payload") {
            ; 在自動鋤地/payload內，日誌放在自動鋤地/log
            baseDir := RegExReplace(A_ScriptDir, "\\payload$", "")
        } else if InStr(A_ScriptDir, "自動鋤地") {
            ; 直接在自動鋤地資料夾內
            baseDir := A_ScriptDir
        } else {
            ; 不在自動鋤地資料夾內，檢查是否有自動鋤地子資料夾
            if DirExist(A_ScriptDir "\自動鋤地") {
                baseDir := A_ScriptDir "\自動鋤地"
            } else {
                ; 沒有自動鋤地資料夾，暫時不創建日誌
                ; 等待自我組織完成後再創建
                return
            }
        }
        
        ; 為每個腳本創建獨立的log資料夾
        this.logDir := baseDir "\log\" this.scriptName
        
        ; 建立日誌目錄
        try {
            DirCreate(this.logDir)
        } catch as e {
            ; 如果無法建立，使用腳本所在目錄作為備選
            this.logDir := A_ScriptDir "\log_" this.scriptName
            try DirCreate(this.logDir)
        }
        
        ; 生成時間戳日誌檔名（以腳本名稱為前綴）
        timestamp := FormatTime(, "yyyyMMdd_HHmmss")
        this.logFile := this.logDir "\" this.scriptName "_" timestamp ".log"
        
        ; 寫入初始訊息
        this.writeInitialMessage()
    }
    
    writeInitialMessage() {
        initMsg := "=== 日誌開始 ===`r`n"
        initMsg .= "腳本: " A_ScriptFullPath "`r`n"
        initMsg .= "時間: " FormatTime(, "yyyy-MM-dd HH:mm:ss") "`r`n"
        initMsg .= "PID: " DllCall("GetCurrentProcessId") "`r`n"
        initMsg .= "========================`r`n"
        
        try FileAppend(initMsg, this.logFile, "UTF-8")
    }
    
    cleanOldLogs() {
        ; 清理舊日誌，只保留當前腳本的最新5份
        try {
            logs := []
            ; 只查找屬於當前腳本的日誌檔案
            pattern := this.logDir "\" this.scriptName "_*.log"
            Loop Files, pattern, "F" {
                logs.Push({
                    path: A_LoopFileFullPath,
                    time: FileGetTime(A_LoopFileFullPath, "M")
                })
            }
            
            ; 按時間排序（新到舊）
            logs := this.sortLogsByTime(logs)
            
            ; 保留最新5份，刪除其餘
            if logs.Length > 5 {
                Loop logs.Length - 5 {
                    index := 5 + A_Index
                    try FileDelete(logs[index].path)
                }
            }
        } catch as e {
            ; 清理失敗不影響主要功能
        }
    }
    
    sortLogsByTime(logs) {
        ; 簡單的冒泡排序（按時間降序）
        n := logs.Length
        Loop n - 1 {
            i := A_Index
            Loop n - i {
                j := A_Index
                if logs[j].time < logs[j + 1].time {
                    temp := logs[j]
                    logs[j] := logs[j + 1]
                    logs[j + 1] := temp
                }
            }
        }
        return logs
    }
    
    log(msg, level := "INFO") {
        ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        line := ts " [" level "] " msg "`r`n"
        
        ; 如果日誌檔案路徑未設置或為空，嘗試重新設置
        if !this.logFile || this.logFile = "" {
            this.setupLogPath()
        }
        
        ; 如果有日誌檔案，嘗試寫入
        if this.logFile && this.logFile != "" {
            try {
                FileAppend(line, this.logFile, "UTF-8")
                return
            } catch {
                ; 主日誌失敗，繼續到備份邏輯
            }
        }
        
        ; 備份方案：在腳本目錄創建日誌
        fallbackFile := A_ScriptDir "\" this.scriptName "_fallback.log"
        try FileAppend(line, fallbackFile, "UTF-8")
    }
    
    ; 靜態方法：獲取或建立日誌管理器
    static getInstance(scriptName) {
        if !LogManager.instances.Has(scriptName) {
            LogManager.instances[scriptName] := LogManager(scriptName)
        }
        return LogManager.instances[scriptName]
    }
}

; 全域便利函數
InitLogger(scriptName) {
    return LogManager.getInstance(scriptName)
}

Log(msg, level := "INFO", scriptName := "") {
    if (scriptName = "") {
        ; 從腳本檔名推斷
        SplitPath(A_ScriptName, , , , &nameNoExt)
        scriptName := nameNoExt
    }
    
    logger := LogManager.getInstance(scriptName)
    logger.log(msg, level)
}
