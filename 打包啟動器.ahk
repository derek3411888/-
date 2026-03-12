#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir

; 初始化備用日誌系統（獨立實現，避免依賴外部檔案）
WriteLog(msg, level := "INFO") {
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    line := ts " [" level "] " msg "`r`n"
    try FileAppend(line, A_ScriptDir "\打包啟動器_fallback.log", "UTF-8")
}

WriteLog("打包啟動器開始: " A_ScriptFullPath)

IniReadSafe(file, section, key, default := "") {
    try {
        return IniRead(file, section, key, default)
    } catch {
        return default
    }
}

JsonGetString(jsonText, key) {
    pattern := '"' key '"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"'
    if RegExMatch(jsonText, pattern, &m) {
        val := m[1]
        val := StrReplace(val, "\\/", "/")
        val := StrReplace(val, '\\"', '"')
        val := StrReplace(val, "\\n", "`n")
        val := StrReplace(val, "\\r", "`r")
        val := StrReplace(val, "\\t", "`t")
        return val
    }
    return ""
}

GetFileSha256(filePath) {
    outFile := A_Temp "\\hash_" A_TickCount ".txt"
    try {
        cmd := 'cmd /c certutil -hashfile "' filePath '" SHA256 > "' outFile '"'
        rc := RunWait(cmd, , "Hide")
        if (rc != 0)
            return ""

        txt := FileRead(outFile, "UTF-8")
        if RegExMatch(txt, "im)^([0-9A-F ]{64,})$", &m) {
            return StrLower(StrReplace(Trim(m[1]), " "))
        }
        return ""
    } catch {
        return ""
    } finally {
        try FileDelete(outFile)
    }
}

; 若 URL 為 raw.githubusercontent.com，自動轉換為 GitHub API 端點（不受 CDN 快取影響）
ConvertToGitHubApiUrl(url) {
    if RegExMatch(url, "^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)/(.+)$", &m)
        return "https://api.github.com/repos/" m[1] "/" m[2] "/contents/" m[4] "?ref=" m[3]
    return url
}

; HTTP GET 並返回文字（使用系統 Proxy，附帶 no-cache 標頭）
HttpGetText(url, extraHeaders := Map()) {
    http := ComObject("Msxml2.XMLHTTP.6.0")
    http.open("GET", url, false)
    http.setRequestHeader("Cache-Control", "no-cache, no-store, must-revalidate")
    http.setRequestHeader("Pragma", "no-cache")
    http.setRequestHeader("User-Agent", "AHK-Launcher/2.0")
    for k, v in extraHeaders
        http.setRequestHeader(k, v)
    http.send()
    if (http.status != 200)
        throw Error("HTTP " http.status " for: " url)
    return http.responseText
}

; HTTP GET 並將二進位結果寫入檔案（使用系統 Proxy，附帶 no-cache 標頭）
HttpDownloadFile(url, destPath, extraHeaders := Map()) {
    http := ComObject("Msxml2.XMLHTTP.6.0")
    http.open("GET", url, false)
    http.setRequestHeader("Cache-Control", "no-cache, no-store, must-revalidate")
    http.setRequestHeader("Pragma", "no-cache")
    http.setRequestHeader("User-Agent", "AHK-Launcher/2.0")
    for k, v in extraHeaders
        http.setRequestHeader(k, v)
    http.send()
    if (http.status != 200)
        throw Error("HTTP " http.status " for: " url)
    stream := ComObject("ADODB.Stream")
    stream.Type := 1  ; adTypeBinary
    stream.Open()
    stream.Write(http.responseBody)
    stream.SaveToFile(destPath, 2)  ; adSaveCreateOverWrite
    stream.Close()
}

TryPrepareRemotePayloadUpdate(workDir, dataDir, &forcedVersion := "") {
    WriteLog("開始檢查遠端更新設定...")
    cfgFile := dataDir "\\config.ini"
    defaultManifestUrl := "https://api.github.com/repos/derek3411888/-/contents/update_manifest.example.json?ref=main"

    ; 零設定預設啟用；若使用者手動設為 0 才關閉
    enabled := IniReadSafe(cfgFile, "updater", "enabled", "1")
    if (enabled != "1") {
        WriteLog("遠端更新未啟用（[updater] enabled!=1）")
        return false
    }

    ; 若未提供 manifest_url，使用內建預設網址
    manifestUrl := Trim(IniReadSafe(cfgFile, "updater", "manifest_url", defaultManifestUrl), ' "')
    if (manifestUrl = "") {
        WriteLog("遠端更新已啟用但未設定 manifest_url", "WARN")
        return false
    }

    currentVerFile := dataDir "\\payload_remote_version.txt"
    currentVer := ""
    if FileExist(currentVerFile) {
        try currentVer := Trim(FileRead(currentVerFile, "UTF-8"), " `t`r`n")
    }

    ; 自動將 raw.githubusercontent.com 轉為 GitHub API 端點（繞過 CDN 快取）
    manifestApiUrl := ConvertToGitHubApiUrl(manifestUrl)
    manifestText := ""
    try {
        manifestText := HttpGetText(manifestApiUrl, Map("Accept", "application/vnd.github.raw+v3"))
    } catch as e {
        WriteLog("下載 manifest 失敗: " e.Message, "WARN")
        return false
    }

    try {
        remoteVer := Trim(JsonGetString(manifestText, "version"), " `t`r`n")
        payloadUrl := Trim(JsonGetString(manifestText, "payload_url"), " `t`r`n")
        payloadSha := StrLower(Trim(JsonGetString(manifestText, "payload_sha256"), " `t`r`n"))

        if (remoteVer = "" || payloadUrl = "") {
            WriteLog("manifest 缺少 version 或 payload_url", "WARN")
            return false
        }

        if (remoteVer = currentVer) {
            WriteLog("遠端版本一致，無需更新：" remoteVer)
            return false
        }

        WriteLog("檢測到新版本：" currentVer " -> " remoteVer)
        zipTmp := A_Temp "\\payload_update_" A_TickCount ".zip"
        payloadReqUrl := payloadUrl
        payloadReqUrl .= (InStr(payloadReqUrl, "?") ? "&" : "?") "ver=" remoteVer
        try {
            HttpDownloadFile(payloadReqUrl, zipTmp)
        } catch as e {
            WriteLog("下載 payload 更新包失敗: " e.Message, "WARN")
            return false
        }

        if (payloadSha != "") {
            gotSha := GetFileSha256(zipTmp)
            if (gotSha = "") {
                WriteLog("無法計算更新包 SHA256", "WARN")
                try FileDelete(zipTmp)
                return false
            }
            if (gotSha != payloadSha) {
                WriteLog("更新包 SHA256 不符，預期=" payloadSha " 實際=" gotSha, "WARN")
                try FileDelete(zipTmp)
                return false
            }
            WriteLog("更新包 SHA256 驗證通過")
        } else {
            WriteLog("manifest 未提供 payload_sha256，略過雜湊驗證", "WARN")
        }

        payloadPath := workDir "\\payload.zip"
        backupPath := workDir "\\payload.zip.bak"
        try {
            if FileExist(backupPath)
                FileDelete(backupPath)
            if FileExist(payloadPath)
                FileCopy(payloadPath, backupPath, 1)
            FileCopy(zipTmp, payloadPath, 1)
            WriteLog("已套用新 payload.zip")
        } catch as e {
            WriteLog("覆蓋 payload.zip 失敗: " e.Message, "WARN")
            try {
                if FileExist(backupPath)
                    FileCopy(backupPath, payloadPath, 1)
            }
            try FileDelete(zipTmp)
            return false
        }

        try FileDelete(zipTmp)
        forcedVersion := remoteVer
        WriteLog("已準備遠端更新，待解壓套用版本：" forcedVersion)
        return true
    }
}

; 設置進程優先級為普通，減少系統負擔
try {
    ProcessSetPriority("Normal", DllCall("GetCurrentProcessId"))
    WriteLog("已設置進程優先級為 Normal")
} catch as e {
    WriteLog("設置進程優先級失敗: " e.Message, "WARN")
}

; 需要系統管理員（若無權限，提權後結束當前執行）
if !A_IsAdmin {
    WriteLog("需要管理員權限，嘗試提權...")
    try Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp
}

; =========================
; 自我組織功能：建立專用資料夾並移動exe
; =========================
autoFolderName := "自動鋤地"
currentDir := A_ScriptDir
autoFolderPath := currentDir "\" autoFolderName
currentExePath := A_ScriptFullPath
SplitPath(currentExePath, &exeFileName)

; 檢查是否已經在「自動鋤地」資料夾內
if !InStr(currentDir, autoFolderName) {
    WriteLog("開始自我組織：建立專用資料夾並複製所有程式檔案...")
    
    ; 建立「自動鋤地」資料夾
    if !DirExist(autoFolderPath) {
        try {
            DirCreate(autoFolderPath)
            WriteLog("建立資料夾：" autoFolderPath)
        } catch as e {
            WriteLog("建立資料夾失敗: " e.Message, "ERROR")
            MsgBox("無法建立資料夾 '" autoFolderName "'：" e.Message, "錯誤", 16)
            ExitApp
        }
    }
    
    ; 複製所有相關檔案到新資料夾
    newExePath := autoFolderPath "\" exeFileName
    try {
        ; 複製主要exe
        if FileExist(newExePath) {
            FileDelete(newExePath)
            Sleep(100)
        }
        FileCopy(currentExePath, newExePath, 1)
        WriteLog("複製主程式到：" newExePath)
        
        ; 只複製必要的相關檔案，不複製所有檔案
        essentialFiles := ["payload.zip", "AutoHotkey64.exe"]
        for fileName in essentialFiles {
            sourceFile := currentDir "\" fileName
            if FileExist(sourceFile) {
                targetPath := autoFolderPath "\" fileName
                try {
                    FileCopy(sourceFile, targetPath, 1)
                    WriteLog("複製必要檔案：" fileName)
                } catch as e {
                    WriteLog("複製必要檔案失敗 " fileName ": " e.Message, "WARN")
                }
            }
        }
        
        ; 不複製其他目錄，避免複製不相關的檔案
        WriteLog("跳過複製其他目錄，避免複製不相關檔案")
        
        ; 啟動新位置的exe
        Run('"' newExePath '"', autoFolderPath)
        WriteLog("啟動新位置的程式，準備清理原檔案")
        
        ; 延遲清理原目錄的檔案（給新程序時間啟動）
        SetTimer(CleanupOriginalFiles, 3000)
        
        ExitApp
        
        CleanupOriginalFiles() {
            try {
                ; 刪除原exe
                FileDelete(currentExePath)
                WriteLog("已刪除原程式：" currentExePath)
                
                ; 只刪除我們複製過的必要檔案，不要刪除其他檔案
                essentialFiles := ["payload.zip", "AutoHotkey64.exe"]
                for fileName in essentialFiles {
                    sourceFile := currentDir "\" fileName
                    if FileExist(sourceFile) {
                        try {
                            FileDelete(sourceFile)
                            WriteLog("已刪除原檔案：" fileName)
                        } catch as e {
                            WriteLog("刪除原檔案失敗 " fileName ": " e.Message, "WARN")
                        }
                    }
                }
                
                ; 不刪除其他目錄和檔案，避免意外刪除用戶資料
                WriteLog("跳過刪除其他目錄，避免意外刪除用戶資料")
                
                ; 刪除可能的備份日誌檔案
                Loop Files, currentDir "\*_fallback.log", "F" {
                    try {
                        FileDelete(A_LoopFileFullPath)
                        WriteLog("已刪除備份日誌：" A_LoopFileName)
                    } catch as e {
                        WriteLog("刪除備份日誌失敗 " A_LoopFileName ": " e.Message, "WARN")
                    }
                }
                
                WriteLog("原檔案清理完成")
            } catch as e {
                WriteLog("清理原檔案時發生錯誤: " e.Message, "ERROR")
            }
        }
        
    } catch as e {
        WriteLog("自我組織失敗: " e.Message, "ERROR")
        MsgBox("無法完成自我組織：" e.Message "`n`n將在當前位置繼續執行。", "警告", 48)
        ; 繼續在當前位置執行
    }
} else {
    WriteLog("已在專用資料夾內，跳過自我組織")
}

; =========================
; 可調整參數（自動調整路徑到專用資料夾）
; =========================
MAIN_FILE := "全自動.ahk"            ; 主程式（全自動負責啟動前檢查並協調所有輔助腳本）

; 確保在「自動鋤地」資料夾內工作
if InStr(A_ScriptDir, "自動鋤地") {
    ; 已經在專用資料夾內
    WORK_DIR := A_ScriptDir
} else {
    ; 還在原位置（理論上不會執行到這裡，因為前面已經處理了自我組織）
    WORK_DIR := A_ScriptDir "\自動鋤地"
}

APP_DIR   := WORK_DIR "\payload"       ; 解壓到專用資料夾的payload
DATA_DIR  := WORK_DIR "\config"        ; 設定檔放專用資料夾的config
STAMP     := WORK_DIR "\.version"      ; 版本戳
REMOTE_VER_FILE := DATA_DIR "\payload_remote_version.txt"

WriteLog("工作目錄設定為：" WORK_DIR)

; =========================
; Ahk2Exe 打包指令（編譯時加入）
;@Ahk2Exe-Base Unicode 64-bit
;@Ahk2Exe-AddResource payload.zip, payload.zip
;@Ahk2Exe-AddResource AutoHotkey64.exe, AutoHotkey64.exe
; （可選）;@Ahk2Exe-SetMainIcon "your.ico"
; =========================
; 注意：打包前請確保 AutoHotkey64.exe 與本腳本在同一目錄
; 提示：可從 https://www.autohotkey.com 下載 AutoHotkey v2
; =========================



; 建立目錄
DirCreate(DATA_DIR)
if !DirExist(APP_DIR)
    DirCreate(APP_DIR)

; 釋出內嵌檔案到專用資料夾
WriteLog("正在處理內嵌檔案...")

; 確保 payload.zip 存在並解壓
payloadPath := WORK_DIR "\payload.zip"
try {
    FileInstall("payload.zip", payloadPath, 1)
    WriteLog("成功釋出 payload.zip 到 " payloadPath)
} catch as e {
    ; 如果FileInstall失敗，檢查是否已存在
    if FileExist(payloadPath) {
        WriteLog("payload.zip 已存在，繼續使用現有檔案")
    } else {
        WriteLog("無法釋出 payload.zip: " e.Message, "ERROR")
        MsgBox("無法釋出 payload.zip: " e.Message, "錯誤", 16)
        ExitApp
    }
}

; 釋出 AutoHotkey64.exe 到專用資料夾
ahkPath := WORK_DIR "\AutoHotkey64.exe"
try {
    FileInstall("AutoHotkey64.exe", ahkPath, 1)
    WriteLog("成功釋出 AutoHotkey64.exe 到 " ahkPath)
} catch as e {
    WriteLog("無法釋出 AutoHotkey64.exe: " e.Message, "WARN")
    
    ; 首先檢查本地是否已有 AutoHotkey64.exe
    if FileExist(ahkPath) {
        WriteLog("發現現有的 AutoHotkey64.exe: " ahkPath)
        ; 繼續使用現有檔案，不重設 ahkPath
    } else {
        ; 如果本地沒有，尋找系統安裝的版本
        systemPaths := [
            A_ProgramFiles "\AutoHotkey\AutoHotkey.exe",
            "C:\Program Files\AutoHotkey\AutoHotkey.exe",
            "C:\AutoHotkey\AutoHotkey.exe"
        ]
        
        foundSystemAhk := ""
        for sysPath in systemPaths {
            if FileExist(sysPath) {
                foundSystemAhk := sysPath
                WriteLog("找到系統安裝的 AutoHotkey: " sysPath)
                break
            }
        }
        
        if foundSystemAhk {
            ahkPath := foundSystemAhk
        } else {
            WriteLog("找不到任何可用的 AutoHotkey 執行檔", "ERROR")
            MsgBox("錯誤：找不到 AutoHotkey 執行檔！`n`n請確保：`n1. AutoHotkey64.exe 已內嵌到程式中`n2. 或系統已安裝 AutoHotkey v2`n`n下載網址：https://www.autohotkey.com", "缺少AutoHotkey", 16)
            ExitApp
        }
    }
}

; 以本 EXE 的最後修改時間作為版本判斷
exeMTime   := FileGetTime(A_ScriptFullPath, "M")
WriteLog("當前 EXE 時間戳: " exeMTime)

; 檢查版本戳檔案
currentStamp := ""
if FileExist(STAMP) {
    try {
        currentStamp := Trim(FileRead(STAMP, "UTF-8-RAW"))
        WriteLog("現有版本戳: " currentStamp)
    } catch as e {
        WriteLog("讀取版本戳失敗: " e.Message, "WARN")
    }
} else {
    WriteLog("版本戳檔案不存在")
}

needUnpack := !FileExist(STAMP) || (currentStamp != exeMTime)
remotePreparedVersion := ""

; 檢查遠端更新（若命中會覆蓋 payload.zip 並強制解壓）
if TryPrepareRemotePayloadUpdate(WORK_DIR, DATA_DIR, &remotePreparedVersion) {
    needUnpack := true
    WriteLog("遠端更新已準備完成，強制執行解壓更新")
}

; 如果有命令列參數 --force-update，強制重新解壓
for param in A_Args {
    if (param = "--force-update") {
        needUnpack := true
        WriteLog("偵測到 --force-update 參數，強制重新解壓")
        break
    }
}

WriteLog("是否需要解壓: " (needUnpack ? "是" : "否"))

if needUnpack {
    WriteLog("需要解壓 payload.zip，開始解壓...")
    
    ; --- 強制結束正在運行的相關進程，避免檔案鎖定導致無法刪除/覆蓋 ---
    WriteLog("正在檢查並終止舊的進程以釋放檔案鎖定...")
    try {
        ; 使用 WMI 查詢來精確匹配命令行，避免誤殺其他 AHK 腳本
        wmi := ComObjGet("winmgmts:")
        query := "Select * from Win32_Process Where Name LIKE 'AutoHotkey%'"
        
        for process in wmi.ExecQuery(query) {
            try {
                cmdLine := process.CommandLine
                ; 檢查命令行是否包含我們的關鍵字或路徑
                if (cmdLine && (InStr(cmdLine, "全自動") || InStr(cmdLine, "進程管理器") || InStr(cmdLine, "LRMC") || InStr(cmdLine, "payload"))) {
                    pid := process.ProcessId
                    ProcessClose(pid)
                    WriteLog("已終止舊進程 PID: " pid)
                }
            } catch {
                continue
            }
        }
        
        ; 額外保險：如果使用了 taskkill
        RunWait("taskkill /F /IM 全自動.exe", , "Hide")
        
        ; 等待進程完全釋放資源
        Sleep(1000)
    } catch as e {
        WriteLog("終止進程時發生錯誤 (非致命): " e.Message, "WARN")
    }

    ; --- 1) 備份現有 config（保留的副檔名可擴充） ---
    cfgTmp := A_ScriptDir "\cfg_backup"
    if DirExist(cfgTmp)
        DirDelete cfgTmp, 1
    DirCreate(cfgTmp)
    for pat in ["*.ini","*.json","*.cfg"] {
        Loop Files, DATA_DIR "\" pat, "F" {
            try FileCopy(A_LoopFileFullPath, cfgTmp "\" A_LoopFileName, 1)
        }
    }

    ; --- 2) 解壓 payload 到 APP_DIR ---
    ; 如果APP_DIR已存在，完全刪除重建（確保覆蓋）
    if DirExist(APP_DIR) {
        WriteLog("完全清理舊的 payload 目錄...")
        try {
            DirDelete(APP_DIR, 1)
            WriteLog("舊 payload 目錄已刪除")
        } catch as e {
            WriteLog("刪除舊 payload 目錄失敗: " e.Message, "WARN")
            ; 如果無法刪除，嘗試覆蓋重要檔案
            Loop Files, APP_DIR "\*.ahk", "R" {
                try {
                    FileDelete(A_LoopFileFullPath)
                    WriteLog("已刪除舊 .ahk 檔案: " A_LoopFileName)
                } catch as e2 {
                    WriteLog("刪除舊 .ahk 檔案失敗 " A_LoopFileName ": " e2.Message, "WARN")
                }
            }
        }
        Sleep(500)  ; 等待檔案系統同步
    }
    
    ; 重新建立目錄
    if !DirExist(APP_DIR) {
        DirCreate(APP_DIR)
        WriteLog("已重建 payload 目錄")
    }
    
    ; 檢查 payload.zip 是否存在且可讀
    if !FileExist(payloadPath) {
        WriteLog("錯誤：找不到 payload.zip 檔案", "ERROR")
        MsgBox("錯誤：找不到 payload.zip 檔案，無法繼續。", "檔案錯誤", 16)
        ExitApp
    }
    
    ; 檢查檔案大小
    try {
        fileSize := FileGetSize(payloadPath)
        if (fileSize < 1000) {  ; 檔案太小，可能損壞
            WriteLog("警告：payload.zip 檔案大小異常: " fileSize " bytes", "WARN")
        } else {
            WriteLog("payload.zip 檔案大小正常: " fileSize " bytes")
        }
    } catch as e {
        WriteLog("無法讀取 payload.zip 檔案大小: " e.Message, "WARN")
    }

    ; 直接解壓到 APP_DIR
    sh  := ComObject("Shell.Application")
    src := sh.NameSpace(payloadPath)
    dst := sh.NameSpace(APP_DIR)
    if !src || !dst {
        WriteLog("解壓初始化失敗：無法建立 Shell 物件", "ERROR")
        MsgBox("解壓初始化失敗。可能是檔案損壞或權限問題。", "解壓錯誤", 16)
        ExitApp
    }
    
    try {
        dst.CopyHere(src.Items, 16)  ; 16=靜默
        
        ; 增加等待循環，確保解壓完成
        Loop 20 {
            if FileExist(APP_DIR "\" MAIN_FILE) || DirExist(APP_DIR "\payload")
                break
            Sleep 200
        }
        Sleep(1000)  ; 額外緩衝
        
        WriteLog("payload.zip 解壓完成到 " APP_DIR)
        
        ; --- 智能目錄結構修正 (遞歸搜尋 MAIN_FILE) ---
        ; 解決各種打包層級問題 (例如 payload/payload/..., 全自動/payload/..., 等)
        if !FileExist(APP_DIR "\" MAIN_FILE) {
            WriteLog("根目錄未找到 " MAIN_FILE "，搜尋子目錄...")
            foundPath := ""
            Loop Files, APP_DIR "\" MAIN_FILE, "R" {
                foundPath := A_LoopFileFullPath
                break ; 找到第一個就停止
            }
            
            if (foundPath) {
                WriteLog("在子目錄找到主文件: " foundPath)
                SplitPath(foundPath, , &correctDir)
                
                ; 使用逐檔案複製方式替代 DirMove，更可靠
                try {
                    ; 1. 複製所有檔案到臨時目錄
                    tempFix := A_ScriptDir "\temp_fix_" A_TickCount
                    DirCreate(tempFix)
                    
                    Loop Files, correctDir "\*.*", "R" {
                        srcFile := A_LoopFileFullPath
                        relPath := SubStr(srcFile, StrLen(correctDir) + 2)
                        destFile := tempFix "\" relPath
                        
                        ; 建立目標檔案的父目錄
                        SplitPath(destFile, , &parentDir)
                        if !DirExist(parentDir) {
                            DirCreate(parentDir)
                        }
                        
                        ; 複製檔案
                        try {
                            FileCopy(srcFile, destFile, 1)  ; 1=覆蓋
                        } catch as copyErr {
                            WriteLog("複製檔案失敗 " A_LoopFileName ": " copyErr.Message, "WARN")
                        }
                    }
                    
                    ; 2. 清空 APP_DIR
                    try {
                        DirDelete(APP_DIR, 1)
                    } catch {
                        ; 如果刪除失敗，嘗試逐檔案刪除
                        Loop Files, APP_DIR "\*.*", "R" {
                            try FileDelete(A_LoopFileFullPath)
                        }
                    }
                    Sleep(300)
                    
                    ; 3. 重新建立 APP_DIR
                    if DirExist(APP_DIR) {
                        try DirDelete(APP_DIR, 1)
                    }
                    DirCreate(APP_DIR)
                    
                    ; 4. 複製臨時目錄回 APP_DIR
                    Loop Files, tempFix "\*.*", "R" {
                        srcFile := A_LoopFileFullPath
                        relPath := SubStr(srcFile, StrLen(tempFix) + 2)
                        destFile := APP_DIR "\" relPath
                        
                        SplitPath(destFile, , &parentDir)
                        if !DirExist(parentDir) {
                            DirCreate(parentDir)
                        }
                        
                        try {
                            FileCopy(srcFile, destFile, 1)
                        } catch as copyErr {
                            WriteLog("最終複製失敗 " A_LoopFileName ": " copyErr.Message, "WARN")
                        }
                    }
                    
                    ; 5. 清理臨時目錄
                    try {
                        DirDelete(tempFix, 1)
                    } catch {
                        WriteLog("無法刪除臨時目錄: " tempFix, "WARN")
                    }
                    
                    WriteLog("已自動修正目錄結構")
                } catch as e {
                    WriteLog("修正目錄結構失敗: " e.Message, "ERROR")
                }
            } else {
                WriteLog("警告: 在 payload 中完全找不到 " MAIN_FILE, "WARN")
            }
        }

        ; 驗證關鍵檔案是否存在
        keyFiles := ["全自動.ahk", "進程管理器.ahk", "LogManager.ahk"]
        for fileName in keyFiles {
            filePath := APP_DIR "\" fileName
            if FileExist(filePath) {
                fileSize := FileGetSize(filePath)
                WriteLog("驗證檔案: " fileName " (大小: " fileSize " bytes)")
            } else {
                WriteLog("警告: 關鍵檔案不存在: " fileName, "WARN")
            }
        }
        
    } catch as e {
        WriteLog("解壓過程發生錯誤: " e.Message, "ERROR")
        MsgBox("解壓過程發生錯誤: " e.Message, "解壓錯誤", 16)
        ExitApp
    }

    ; --- 3) 還原使用者設定（覆蓋回去） ---
    if DirExist(cfgTmp) {
        Loop Files, cfgTmp "\*.*", "F" {
            try {
                destPath := DATA_DIR "\" A_LoopFileName
                SplitPath(destPath, , &destDir)
                if !DirExist(destDir)
                    DirCreate(destDir)
                FileCopy(A_LoopFileFullPath, destPath, 1)
                WriteLog("還原設定檔: " A_LoopFileName)
            } catch as e {
                WriteLog("警告: 無法還原設定文件 " A_LoopFileName ": " e.Message, "WARN")
            }
        }
        DirDelete(cfgTmp, 1)
    }

    ; --- 4) 寫入版本戳 ---
    try {
        if FileExist(STAMP)
            FileDelete(STAMP)
        FileAppend(exeMTime, STAMP, "UTF-8-RAW")
        WriteLog("寫入版本戳: " exeMTime)
    } catch as e {
        WriteLog("警告: 無法寫入版本戳: " e.Message, "WARN")
    }

    ; --- 5) 若本次套用了遠端更新，記錄遠端 payload 版本 ---
    if (remotePreparedVersion != "") {
        try {
            if FileExist(REMOTE_VER_FILE)
                FileDelete(REMOTE_VER_FILE)
            FileAppend(remotePreparedVersion, REMOTE_VER_FILE, "UTF-8-RAW")
            WriteLog("寫入遠端 payload 版本: " remotePreparedVersion)
        } catch as e {
            WriteLog("警告: 無法寫入遠端 payload 版本: " e.Message, "WARN")
        }
    }
} else {
    WriteLog("payload已是最新版本，跳過解壓")
}

; 確認 AutoHotkey 執行檔可用
if !FileExist(ahkPath) {
    WriteLog("錯誤：AutoHotkey 執行檔不存在: " ahkPath, "ERROR")
    MsgBox("錯誤：找不到 AutoHotkey 執行檔！`n`n請確保：`n1. AutoHotkey64.exe 已包含在程式中`n2. 或系統已安裝 AutoHotkey v2`n`n下載網址：https://www.autohotkey.com", "缺少AutoHotkey", 16)
    ExitApp
}

WriteLog("將使用 AutoHotkey: " ahkPath)

; 對子腳本注入環境變數
WriteLog("設置環境變數: APP_DIR=" APP_DIR)
WriteLog("設置環境變數: DATA_DIR=" DATA_DIR)
EnvSet("PACK_APP_DIR",  APP_DIR)
EnvSet("PACK_DATA_DIR", DATA_DIR)

; 解析主腳本路徑
if (MAIN_FILE = "") {
    found := ""
    Loop Files, APP_DIR "\*.ahk", "F" {
        if RegExMatch(A_LoopFileName, "i)(OKWW|LRMC)") {
            found := A_LoopFileFullPath
            break
        }
    }
    if (found = "") {
        Loop Files, APP_DIR "\*.ahk", "F" {
            found := A_LoopFileFullPath
            break
        }
    }
    if (found = "") {
        MsgBox("app 目錄未找到任何 .ahk。請檢查 payload.zip 內容。")
        ExitApp
    }
    MAIN_PATH := found
} else {
    MAIN_PATH := APP_DIR "\" MAIN_FILE
    if !FileExist(MAIN_PATH) {
        MsgBox("指定的 MAIN_FILE 不存在：`n" MAIN_PATH)
        ExitApp
    }
}

; 執行主腳本（工作目錄設為 APP_DIR）
WriteLog("啟動主腳本: " MAIN_PATH)
WriteLog("使用 AutoHotkey: " ahkPath)
WriteLog("工作目錄: " APP_DIR)

; 全自動腳本會自動協調其他腳本，無需在此處強制關閉現有實例

try {
    Run('"' ahkPath '" "' MAIN_PATH '"', APP_DIR)
    WriteLog("主腳本已成功啟動")
    
    ; 等待一小段時間確認腳本啟動
    Sleep 2000
    
    ; 檢查全自動腳本是否成功啟動
    processStarted := false
    Loop 5 {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%AutoHotkey%'") {
            try {
                cmdLine := proc.CommandLine
                if (InStr(cmdLine, "全自動.ahk")) {
                    WriteLog("確認全自動腳本已啟動: PID=" proc.ProcessId)
                    processStarted := true
                    break
                }
            } catch {
                ; 忽略錯誤
            }
        }
        if (processStarted)
            break
        Sleep 1000
    }
    
    if (!processStarted) {
        WriteLog("警告：無法確認全自動腳本是否成功啟動", "WARN")
    }
    
} catch as e {
    WriteLog("啟動主腳本失敗: " e.Message, "ERROR")
    
    ; 提供更詳細的錯誤信息
    errDetails := "啟動主腳本失敗：" e.Message "`n`n"
    errDetails .= "AutoHotkey 路徑：" ahkPath "`n"
    errDetails .= "主腳本路徑：" MAIN_PATH "`n"
    errDetails .= "工作目錄：" APP_DIR "`n`n"
    
    ; 檢查檔案是否存在
    if !FileExist(ahkPath)
        errDetails .= "❌ AutoHotkey 執行檔不存在`n"
    else
        errDetails .= "✅ AutoHotkey 執行檔存在`n"
        
    if !FileExist(MAIN_PATH)
        errDetails .= "❌ 主腳本檔案不存在`n"
    else
        errDetails .= "✅ 主腳本檔案存在`n"
        
    if !DirExist(APP_DIR)
        errDetails .= "❌ 工作目錄不存在`n"
    else
        errDetails .= "✅ 工作目錄存在`n"
    
    errDetails .= "`n請檢查以上資訊並重試。"
    
    MsgBox(errDetails, "啟動錯誤", 16)
}

WriteLog("打包啟動器任務完成，即將退出")
ExitApp
