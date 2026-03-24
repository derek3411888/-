#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir

; 🛡️ 自動提權
if !A_IsAdmin {
    try Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp
}

; ⚡ 設定普通優先級以減少系統負擔
ProcessSetPriority("Normal")

; DPI 感知（避免縮放改變座標/影像）
try DllCall("SetProcessDpiAwarenessContext", "ptr", -4)  ; PER_MONITOR_AWARE_V2
catch 
    try DllCall("shcore\SetProcessDpiAwareness", "int", 2)

#Include plugin\RapidOcr\RapidOcr.ahk
#Include plugin\ImagePut-1.11\ImagePut.ahk
#Include LogManager.ahk

; 初始化新的日誌系統
global logger := InitLogger("全自動")
RegisterLifecycleLogging("全自動")
global RUN_ID := A_Now "@" A_TickCount
global STEP_SEQ := 0

; 收尾監測設定（命中兩條「電台_一鍵領取」後延遲關閉）
global REWARD_LOG_FILE := "D:\LRMCAI\log\LRMCAI.log"
global REWARD_START_DELAY_MS := 60000
global REWARD_CHECK_INTERVAL_MS := 3000
global REWARD_SHUTDOWN_DELAY_MS := 5000
global REWARD_MATCH_NEED_COUNT := 2
global MAIL_NOTIFY_ENABLED := 1
global MAIL_SECTION := "mail_notify"
global __MAIL_SETUP := ""
global __WUTHERING_AUDIO_MUTED := false
global __WUTHERING_MUTE_PENDING := false
global WUTHERING_PROCESS_EXE := "Client-Win64-Shipping.exe"

; 保底：任何方式離開腳本時都嘗試恢復聲音
OnExit(RestoreWutheringAudioOnExit)

; 提示工具（開頭加5個空白避免被滑鼠遮擋）
ShowTip(msg, duration := 1200) {
    ToolTip "          " msg
    if (duration > 0)
        SetTimer(() => ToolTip(), -duration)
}

; 去除路徑前後的引號和空白
NormalizePath(p) {
    return Trim(p, ' "')
}

MuteWutheringAudioAtStartup() {
    global __WUTHERING_MUTE_PENDING
    __WUTHERING_MUTE_PENDING := true
    TryMuteWutheringAudio("主流程前置")
    SetTimer(WutheringMuteTick, 3000)
}

WutheringMuteTick() {
    global __WUTHERING_MUTE_PENDING
    if !__WUTHERING_MUTE_PENDING {
        SetTimer(WutheringMuteTick, 0)
        return
    }

    if TrySetWutheringProcessMute(true) {
        __WUTHERING_MUTE_PENDING := false
        SetTimer(WutheringMuteTick, 0)
        WriteLog("已成功套用鳴潮單獨靜音")
    }
}

TryMuteWutheringAudio(reason := "") {
    global __WUTHERING_MUTE_PENDING
    if TrySetWutheringProcessMute(true) {
        __WUTHERING_MUTE_PENDING := false
        SetTimer(WutheringMuteTick, 0)
        msg := "已啟用鳴潮單獨靜音"
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
        return true
    }
    return false
}

UnmuteWutheringAudio(reason := "") {
    global __WUTHERING_AUDIO_MUTED, __WUTHERING_MUTE_PENDING
    __WUTHERING_MUTE_PENDING := false
    SetTimer(WutheringMuteTick, 0)

    if TrySetWutheringProcessMute(false) {
        msg := "已恢復鳴潮聲音"
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
    } else {
        WriteLog("恢復鳴潮聲音失敗或尚未建立音訊 Session", "WARN")
    }
}

RestoreWutheringAudioOnExit(exitReason, exitCode) {
    UnmuteWutheringAudio("腳本結束保底")
}

GetWutheringAudioTargets() {
    global CFG_FILE, WUTHERING_PROCESS_EXE

    pidMap := Map()
    nameMap := Map()

    for title in ["鸣潮", "鳴潮"] {
        hwnd := WinExist(title)
        if !hwnd
            continue

        try {
            pid := WinGetPID("ahk_id " hwnd)
            if (pid > 0)
                pidMap[String(pid)] := 1
        }

        try {
            procName := WinGetProcessName("ahk_id " hwnd)
            procName := RegExReplace(procName, "i)\.exe$")
            if (procName != "")
                nameMap[StrLower(procName)] := 1
        }
    }

    if ProcessExist(WUTHERING_PROCESS_EXE)
        nameMap[StrLower(RegExReplace(WUTHERING_PROCESS_EXE, "i)\.exe$"))] := 1

    if IsSet(CFG_FILE) {
        cfgWuthering := NormalizePath(IniReadSafe(CFG_FILE, "paths", "WUTHERING", ""))
        if (cfgWuthering != "") {
            SplitPath cfgWuthering, &cfgExeName
            cfgExeName := RegExReplace(cfgExeName, "i)\.exe$")
            if (cfgExeName != "")
                nameMap[StrLower(cfgExeName)] := 1
        }
    }

    pidCsv := ""
    for pidText, _ in pidMap {
        if (pidCsv != "")
            pidCsv .= ","
        pidCsv .= pidText
    }

    nameCsv := ""
    for exeName, _ in nameMap {
        if (nameCsv != "")
            nameCsv .= ","
        nameCsv .= exeName
    }

    return { pids: pidCsv, names: nameCsv }
}

TrySetWutheringProcessMute(mute := true) {
    global WUTHERING_PROCESS_EXE, __WUTHERING_AUDIO_MUTED

    psFile := A_Temp "\\mute_wuthering_" A_TickCount ".ps1"
    targets := GetWutheringAudioTargets()
    pidCsv := StrReplace(targets.pids, "'", "''")
    nameCsv := StrReplace(targets.names, "'", "''")

        csharp := "
    (
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace AudioUtil {
    enum EDataFlow { eRender, eCapture, eAll }
    enum ERole { eConsole, eMultimedia, eCommunications }
    [Flags] enum CLSCTX : uint { INPROC_SERVER = 0x1, INPROC_HANDLER = 0x2, LOCAL_SERVER = 0x4, REMOTE_SERVER = 0x10, ALL = INPROC_SERVER | INPROC_HANDLER | LOCAL_SERVER | REMOTE_SERVER }
    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject {}
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")] interface IMMDeviceEnumerator { int NotImpl1(); int GetDefaultAudioEndpoint(EDataFlow dataFlow, ERole role, out IMMDevice ppDevice); }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("D666063F-1587-4E43-81F1-B948E807363F")] interface IMMDevice { int Activate(ref Guid iid, CLSCTX dwClsCtx, IntPtr pActivationParams, [MarshalAs(UnmanagedType.IUnknown)] out object ppInterface); }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F")] interface IAudioSessionManager2 {
        int GetAudioSessionControl(ref Guid AudioSessionGuid, uint StreamFlags, out IAudioSessionControl SessionControl);
        int GetSimpleAudioVolume(ref Guid AudioSessionGuid, uint StreamFlags, out ISimpleAudioVolume AudioVolume);
        int GetSessionEnumerator(out IAudioSessionEnumerator SessionEnum);
        int RegisterSessionNotification(IntPtr SessionNotification);
        int UnregisterSessionNotification(IntPtr SessionNotification);
    }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8")] interface IAudioSessionEnumerator { int GetCount(out int SessionCount); int GetSession(int SessionCount, out IAudioSessionControl Session); }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD")] interface IAudioSessionControl {
        int GetState(out int pRetVal);
        int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetGroupingParam(out Guid pRetVal);
        int SetGroupingParam(ref Guid Override, ref Guid EventContext);
        int RegisterAudioSessionNotification(IntPtr NewNotifications);
        int UnregisterAudioSessionNotification(IntPtr NewNotifications);
    }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d")] interface IAudioSessionControl2 {
        int GetState(out int pRetVal);
        int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string Value, ref Guid EventContext);
        int GetGroupingParam(out Guid pRetVal);
        int SetGroupingParam(ref Guid Override, ref Guid EventContext);
        int RegisterAudioSessionNotification(IntPtr NewNotifications);
        int UnregisterAudioSessionNotification(IntPtr NewNotifications);
        int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string pRetVal);
        int GetProcessId(out uint pRetVal);
        int IsSystemSoundsSession();
        int SetDuckingPreference(bool optOut);
    }
    [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8")] interface ISimpleAudioVolume { int SetMasterVolume(float fLevel, ref Guid EventContext); int GetMasterVolume(out float pfLevel); int SetMute(bool bMute, ref Guid EventContext); int GetMute(out bool pbMute); }
    public static class SessionMute {
        static bool TryGetSessionManager(IMMDeviceEnumerator deviceEnumerator, ERole role, out IAudioSessionManager2 mgr) {
            mgr = null;
            IMMDevice device;
            int hr = deviceEnumerator.GetDefaultAudioEndpoint(EDataFlow.eRender, role, out device);
            if (hr != 0 || device == null) return false;

            Guid iid = typeof(IAudioSessionManager2).GUID;
            object o;
            hr = device.Activate(ref iid, CLSCTX.ALL, IntPtr.Zero, out o);
            if (hr != 0 || o == null) return false;

            mgr = (IAudioSessionManager2)o;
            return mgr != null;
        }

        static bool IsTargetSession(IAudioSessionControl ctrl, System.Collections.Generic.HashSet<int> pidSet, System.Collections.Generic.HashSet<string> nameSet, out uint pidOut) {
            pidOut = 0;
            if (ctrl == null) return false;

            IntPtr unk = IntPtr.Zero;
            try {
                unk = Marshal.GetIUnknownForObject(ctrl);
                var c2 = (IAudioSessionControl2)Marshal.GetTypedObjectForIUnknown(unk, typeof(IAudioSessionControl2));
                if (c2 == null) return false;

                uint pid;
                if (c2.GetProcessId(out pid) != 0 || pid == 0) return false;
                pidOut = pid;

                if (pidSet.Contains((int)pid)) return true;

                try {
                    var p = Process.GetProcessById((int)pid);
                    var procName = p.ProcessName;
                    if (!string.IsNullOrWhiteSpace(procName) && nameSet.Contains(procName))
                        return true;
                } catch { }

                return false;
            } catch {
                return false;
            } finally {
                if (unk != IntPtr.Zero)
                    Marshal.Release(unk);
            }
        }

        static bool TrySetMuteOnControl(IAudioSessionControl ctrl, bool mute) {
            if (ctrl == null) return false;
            IntPtr unk = IntPtr.Zero;
            try {
                unk = Marshal.GetIUnknownForObject(ctrl);
                var vol = (ISimpleAudioVolume)Marshal.GetTypedObjectForIUnknown(unk, typeof(ISimpleAudioVolume));
                if (vol == null) return false;
                Guid g = Guid.Empty;
                vol.SetMute(mute, ref g);
                return true;
            } catch {
                return false;
            } finally {
                if (unk != IntPtr.Zero)
                    Marshal.Release(unk);
            }
        }

        static bool TryMuteOnRole(IMMDeviceEnumerator deviceEnumerator, ERole role, System.Collections.Generic.HashSet<int> pidSet, System.Collections.Generic.HashSet<string> nameSet, bool mute) {
            IAudioSessionManager2 mgr;
            if (!TryGetSessionManager(deviceEnumerator, role, out mgr))
                return false;

            IAudioSessionEnumerator en;
            if (mgr.GetSessionEnumerator(out en) != 0 || en == null)
                return false;

            int count;
            en.GetCount(out count);
            bool mutedAny = false;

            for (int i = 0; i < count; i++) {
                IAudioSessionControl ctrl;
                if (en.GetSession(i, out ctrl) != 0 || ctrl == null)
                    continue;

                uint pid;
                if (!IsTargetSession(ctrl, pidSet, nameSet, out pid))
                    continue;

                if (TrySetMuteOnControl(ctrl, mute))
                    mutedAny = true;
            }

            return mutedAny;
        }

        public static int SetMuteByTargets(string pidCsv, string nameCsv, bool mute) {
            var pidSet = new System.Collections.Generic.HashSet<int>();
            if (!string.IsNullOrWhiteSpace(pidCsv)) {
                foreach (var s in pidCsv.Split(',')) {
                    int p;
                    if (int.TryParse(s.Trim(), out p) && p > 0)
                        pidSet.Add(p);
                }
            }

            var nameSet = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (!string.IsNullOrWhiteSpace(nameCsv)) {
                foreach (var s in nameCsv.Split(',')) {
                    var n = s.Trim();
                    if (!string.IsNullOrWhiteSpace(n))
                        nameSet.Add(n);
                }
            }

            var deviceEnumerator = (IMMDeviceEnumerator)(new MMDeviceEnumeratorComObject());
            bool ok = false;

            ok = TryMuteOnRole(deviceEnumerator, ERole.eMultimedia, pidSet, nameSet, mute) || ok;
            ok = TryMuteOnRole(deviceEnumerator, ERole.eConsole, pidSet, nameSet, mute) || ok;
            ok = TryMuteOnRole(deviceEnumerator, ERole.eCommunications, pidSet, nameSet, mute) || ok;

            return ok ? 0 : 2;
        }
    }
}
)"

        script := "$ErrorActionPreference='Stop'`n"
        script .= "$pids='" pidCsv "'`n"
        script .= "$names='" nameCsv "'`n"
        script .= "$mute=" (mute ? "$true" : "$false") "`n"
        script .= "$code=@'`n" csharp "`n'@`n"
        script .= "Add-Type -TypeDefinition $code -Language CSharp | Out-Null`n"
        script .= "$ret = [AudioUtil.SessionMute]::SetMuteByTargets($pids, $names, $mute)`n"
        script .= "exit $ret`n"

    try FileDelete psFile
    FileAppend script, psFile, "UTF-8"

    cmd := 'powershell -NoProfile -ExecutionPolicy Bypass -File "' psFile '"'
    try {
        code := RunWait(cmd, , "Hide") + 0
    } catch {
        try FileDelete psFile
        WriteLog("鳴潮音訊控制執行失敗（PowerShell 呼叫錯誤）", "WARN")
        return false
    }

    try FileDelete psFile
    if (code = 0) {
        __WUTHERING_AUDIO_MUTED := mute ? true : false
        return true
    }

    WriteLog("鳴潮音訊控制未命中任何 Session，退出碼=" code " pids=" targets.pids " names=" targets.names, "WARN")
    return false
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
        try FileAppend(line, A_ScriptDir "\main_fallback.log", "UTF-8")
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

WriteLog("全自動腳本啟動: " A_ScriptFullPath)
WriteStep("啟動", "PID=" DllCall("GetCurrentProcessId") " AHK=" A_AhkVersion)

; 鍵盤更穩
SendMode "Input"
SetKeyDelay 40, 40



; === 使用啟動器解壓的位置 ===
; 現在AutoHotkey64.exe位於工作目錄的上層（自動鋤地資料夾）
AhkExe := A_ScriptDir "\..\AutoHotkey64.exe"
WriteLog("嘗試使用 AutoHotkey: " AhkExe)
if !FileExist(AhkExe) {
    WriteLog("未找到預設位置的 AutoHotkey，嘗試從環境變數獲取", "WARN")
    ; 如果找不到，嘗試從環境變數獲取
    packAppDir := EnvGet("PACK_APP_DIR")
    if (packAppDir != "") {
        AhkExe := StrReplace(packAppDir, "\payload", "") "\AutoHotkey64.exe"
        WriteLog("從環境變數嘗試路徑: " AhkExe)
    }
    if !FileExist(AhkExe) {
        WriteLog("找不到任何 AutoHotkey 執行檔: " AhkExe, "ERROR")
        MsgBox "找不到 AutoHotkey64.exe：`n" AhkExe "`n請先執行「打包啟動器」完成解壓。"
        ExitApp
    }
} else {
    WriteLog("成功找到 AutoHotkey: " AhkExe)
}

; ★ 啟動 UE4 崩潰全域監看（獨立 UE4-Client 視窗）
StartCrashWatcher()

okwwExe := "OK-WW.exe"   ; 由工作管理員確認

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
WriteLog("dataDir=" dataDir)
WriteLog("CFG_FILE=" CFG_FILE)
WriteStep("載入設定", "config=" CFG_FILE)
LoadMailNotifyEnabled()
SetupTrayMenu()

; ★ 流程開始前統一檢查：程式路徑 + 郵件通知設定
WriteStep("前置檢查", "程式路徑與通知設定")
EnsureAllConfigAtStartup()

; ★ 啟動前檢測：確保三個程式都沒有在運行
WriteLog("執行啟動前檢測，確保所有目標程式都已關閉...")
WriteStep("清場", "關閉既有目標進程")
CheckAndCloseExistingProcesses()

; 讀取重啟計數器（避免無限循環）
global MAX_RESTART_COUNT := 3
global restartCount := Integer(IniReadSafe(CFG_FILE, "restart_tracking", "auto_restart_count", "0"))
WriteLog("目前重啟次數: " restartCount "/" MAX_RESTART_COUNT)

; 檢查是否為重啟模式（遊戲更新後需要重新啟動OKWW）
isRestart := false
if A_Args.Length > 0 && A_Args[1] = "restart" {
    isRestart := true
    WriteLog("檢測到重啟模式，遊戲更新後將重新啟動OKWW")
}

; 1) 先處理鳴潮更新／登入，OKWW 之後再啟動
maxUpdateLoops := 3
updateLoops := 0
loginDetected := false
okwwStarted := false

EnsureWutheringRunning()
WriteStep("鳴潮檢查", "更新與登入流程")

loop {
    loginDetected := false
    updated := DetectWutheringAndExit(&loginDetected)
    if updated {
        updateLoops++
        WriteLog("偵測到鳴潮更新，等待遊戲自動重啟後再次檢測 (" updateLoops "/" maxUpdateLoops ")")
        Sleep 8000
        if (updateLoops >= maxUpdateLoops) {
            WriteLog("鳴潮更新檢測達上限，停止自動迴圈，繼續後續流程", "WARN")
            break
        }
        continue
    }
    break
}

; 登入畫面時：稍等並點擊視窗中央，喚醒到可操作狀態
if (loginDetected) {
    WriteLog("登入畫面階段啟動 OKWW，點擊視窗前先啟動")
    StartOKWWFlow(isRestart)
    okwwStarted := true

    hwndLogin := GetWutheringGameHwnd()
    WriteLog("檢測到登入畫面，嘗試點擊視窗中心喚醒")
    if !hwndLogin {
        hwndLogin := WaitForWutheringGameWindow(20)
    }
    if hwndLogin {
        try WinRestore "ahk_id " hwndLogin
        try WinActivate "ahk_id " hwndLogin
        WinWaitActive "ahk_id " hwndLogin, , 3
        Sleep 5000
        ok := ClickWindowCenter(hwndLogin)
        if !ok {
            Sleep 1200
            ClickWindowCenter(hwndLogin)
        }
        ; 點擊後等待遊戲進入主介面（從登入到可操作需要時間）
        WriteLog("登入後等待遊戲載入主介面...")
        Sleep 15000  ; 額外等待15秒讓遊戲完全進入
        ShowTip("✅ 已點擊登入畫面中央")
    } else {
        WriteLog("登入畫面點擊失敗：找不到鳴潮視窗", "WARN")
            ShowTip("❗ 找不到鳴潮視窗", 1200)
    }
}

; 2) 登入後啟動 OKWW 並確認啟動成功
if !okwwStarted {
    WriteLog("登入完成，開始啟動 OKWW...")
    WriteStep("啟動OKWW", isRestart ? "重啟模式" : "一般模式")
    StartOKWWFlow(isRestart)
    okwwStarted := true
}

; 3) 用主畫面模板比對驗證遊戲是否可操作（去抖動）
gameHwnd := GetWutheringGameHwnd()
WriteLog("開始主畫面模板驗證（最多 90 秒）...")
if !WaitEscMenuOCR(gameHwnd, 90) {
    WriteLog("鳴潮無法使用或超時，觸發重啟機制", "ERROR")
    ShowTip("⚠️ 鳴潮無法使用，重新啟動...", 3000)
    Sleep 3000
    RestartAutoScript()
    return
}
WriteStep("遊戲可操作驗證", "模板比對通過")

; 4) 執行聲骸合成流程
WriteLog("啟動聲骸合成腳本...")
WriteStep("啟動聲骸合成", "等待完成或重啟標記")
ShowTip("🔧 正在執行聲骸合成...", 1500)
; 額外等待確保OKWW啟動後鳴潮完全穩定
WriteLog("等待OKWW初始化完成，確保遊戲穩定...")
Sleep 5000  ; 再等5秒，確保鳴潮完全穩定
try {
    Run('"' AhkExe '" "' A_ScriptDir '\聲骸合成.ahk"')
    WriteLog("聲骸合成腳本已啟動")
    
    ; 等待聲骸合成完成（檢查進程是否還在運行）
    maxWaitTime := 1800000  ; 最多等待30分鐘
    startTime := A_TickCount
    
    Sleep 5000  ; 先等5秒讓腳本啟動
    
    ; 持續檢查聲骸合成進程是否還在運行
    while (A_TickCount - startTime < maxWaitTime) {
        found := false
        try {
            for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process") {
                try {
                    if (InStr(proc.Name, "AutoHotkey")) {
                        cmdLine := proc.CommandLine
                        if (InStr(cmdLine, "聲骸合成.ahk")) {
                            found := true
                            break
                        }
                    }
                } catch {
                    continue
                }
            }
        } catch as e {
            WriteLog("檢查聲骸合成進程時出錯: " e.Message, "WARN")
        }
        
        if (!found) {
            WriteLog("聲骸合成已完成")
            ShowTip("✅ 聲骸合成已完成", 2000)
            
            ; 檢查是否有重啟標記
            flagFile := dataDir "\synthesis_restart.flag"
            if FileExist(flagFile) {
                WriteLog("偵測到聲骸合成要求重啟，刪除標記並觸發重啟機制", "WARN")
                try FileDelete(flagFile)
                Sleep 2000
                RestartAutoScript()
                return
            }
            break
        }
        
        Sleep 2000  ; 每2秒檢查一次
    }
    
    if (A_TickCount - startTime >= maxWaitTime) {
        WriteLog("聲骸合成超時，觸發重啟機制", "ERROR")
        ShowTip("⚠️ 聲骸合成超時，重新啟動...", 3000)
        Sleep 3000
        RestartAutoScript()
        return
    }
    
} catch as e {
    WriteLog("聲骸合成腳本啟動失敗，跳過並繼續後續流程: " e.Message, "ERROR")
    ShowTip("⚠️ 聲骸合成啟動失敗，繼續執行...", 2000)
    Sleep 2000
}

; 4) 啟動 LRMC 管理腳本（由該腳本負責LRMC的啟動與管理）
WriteLog("啟動 LRMC 管理腳本...")
WriteStep("啟動LRMC", "交由開啟LRMC.ahk 控制")
Run('"' AhkExe '" "' A_ScriptDir '\開啟LRMC.ahk"')
ShowTip("🟢 已啟動 LRMC 管理腳本", 3000)


; 成功完成流程，重置重啟計數器
IniWrite "0", CFG_FILE, "restart_tracking", "auto_restart_count"
WriteLog("流程成功完成，已重置重啟計數器")
WriteStep("主流程完成", "重啟計數已歸零")

WriteLog("全自動流程完成，進入收尾監測（等待電台一鍵領取達標）")
WriteStep("收尾監測", "等待電台一鍵領取條件")
MonitorRewardAndShutdown()
ExitApp


; ======================== 函式區 ========================

; ★ OKWW 啟動＋前置流程（啟動 → 等待 → F11 → 最小化）
StartOKWWFlow(isRestart) {
    WriteLog("啟動 OKWW 管理腳本...")
    if isRestart {
        ShowTip("🔄 重啟模式：重新啟動 OKWW", 1500)
        Sleep 1500
    }
    ahkCommand := '"' AhkExe '" "' A_ScriptDir '\自動開啟OKWW.ahk"'
    WriteLog("執行命令: " ahkCommand)
    try {
        Run(ahkCommand)
        WriteLog("OKWW 管理腳本啟動成功" . (isRestart ? "（重啟模式）" : ""))
    } catch as e {
        WriteLog("OKWW 管理腳本啟動失敗: " e.Message, "ERROR")
    }
    ShowTip("🟢 已啟動 OKWW 管理腳本" . (isRestart ? "（重新啟動）" : ""), 3000)

    WriteLog("等待 OKWW 視窗出現...")
    Sleep 20000
    
    ; 尋找並激活 OKWW 主視窗
    WriteLog("尋找 OKWW 主視窗並發送 F11...")
    okwwHwnd := 0
    maxAttempts := 10
    attempt := 0
    
    while (attempt < maxAttempts && !okwwHwnd) {
        attempt++
        try {
            ; 尋找標題包含 "OK-WW" 和 "Global" 的視窗（格式: OK-WW v版本數字 Global）
            for hwnd in WinGetList() {
                title := WinGetTitle(hwnd)
                ; 匹配 "OK-WW v版本數字 Global" 格式
                if (InStr(title, "OK-WW") && InStr(title, "Global")) {
                    okwwHwnd := hwnd
                    WriteLog("找到 OKWW 視窗: " title)
                    break
                }
            }
        }
        if (!okwwHwnd) {
            WriteLog("第 " attempt " 次尋找 OKWW 視窗失敗，2秒後重試...")
            Sleep 2000
        }
    }
    
    if (okwwHwnd) {
        ; 激活 OKWW 視窗
        try {
            WinActivate "ahk_id " okwwHwnd
            WinWaitActive "ahk_id " okwwHwnd, , 3
            Sleep 500
            
            ; 截圖OKWW視窗並OCR識別
            WriteLog("開始OCR識別OKWW視窗中的啟動遊戲/F11字樣...")
            tempFile := A_Temp "\okww_launch_" A_TickCount ".jpg"
            try {
                ImagePutFile("ahk_id " okwwHwnd, tempFile)
                
                ; OCR識別
                ocr := RapidOcr()
                res := ocr.ocr_from_file(tempFile, , true)
                
                if FileExist(tempFile)
                    FileDelete(tempFile)
                
                ; 搜尋啟動遊戲或F11相關文字
                foundButton := false
                clickX := 0
                clickY := 0
                
                if IsObject(res) {
                    for block in res {
                        clean := StrReplace(StrReplace(block.text, "`r", ""), "`n", "")
                        clean := StrReplace(clean, " ", "")
                        
                        ; 檢測啟動遊戲、開始（繁體、簡體）或 F11
                        if InStr(clean, "啟動遊戲") || InStr(clean, "启动游戏") || InStr(clean, "開始") || InStr(clean, "开始") || InStr(clean, "F11") {
                            WriteLog("找到啟動按鈕文字: " block.text)
                            ; 計算文字中心點 - 支持 box 和 boxPoint 兩種格式
                            boxData := ""
                            if block.HasOwnProp("box") && IsObject(block.box) && block.box.Length >= 4 {
                                boxData := block.box
                            } else if block.HasOwnProp("boxPoint") && IsObject(block.boxPoint) && block.boxPoint.Length >= 3 {
                                boxData := block.boxPoint
                            }
                            
                            if (boxData != "") {
                                if (boxData[1].HasOwnProp("x")) {
                                    ; boxPoint 格式：[{x,y}, {x,y}, {x,y}, {x,y}]
                                    clickX := (boxData[1].x + boxData[3].x) / 2
                                    clickY := (boxData[1].y + boxData[3].y) / 2
                                } else {
                                    ; box 格式：[[x,y], [x,y], [x,y], [x,y]]
                                    clickX := (boxData[1][1] + boxData[3][1]) / 2
                                    clickY := (boxData[1][2] + boxData[3][2]) / 2
                                }
                                foundButton := true
                                WriteLog("計算點擊座標: " clickX ", " clickY)
                                break
                            } else {
                                WriteLog("警告：文字框座標格式不正確", "WARN")
                            }
                        }
                    }
                }
                
                ; 如果找到按鈕，點擊它
                if (foundButton && clickX > 0 && clickY > 0) {
                    WriteLog("點擊啟動按鈕座標: " clickX ", " clickY)
                    MouseMove clickX, clickY
                    Sleep 200
                    MouseClick "left"
                    WriteLog("已點擊OKWW啟動按鈕")
                    Sleep 1000
                } else {
                    WriteLog("未找到啟動遊戲按鈕，嘗試使用備用方案F11", "WARN")
                    SendEvent "{F11}"
                    WriteLog("已發送F11備用快捷鍵")
                    Sleep 1000
                }
            } catch as e {
                WriteLog("OKWW OCR識別失敗: " e.Message ", 使用備用方案F11", "WARN")
                SendEvent "{F11}"
                WriteLog("已發送F11備用快捷鍵")
                Sleep 1000
            }
        } catch as e {
            WriteLog("激活OKWW視窗失敗: " e.Message, "ERROR")
        }
    } else {
        WriteLog("無法找到 OKWW 視窗，跳過啟動", "WARN")
    }
    
    Sleep 1000
    MinimizeOKWWWindows()
}

; ★ 最小化 OKWW 視窗
MinimizeOKWWWindows() {
    WriteLog("開始尋找並最小化 OKWW 視窗...")
    foundCount := 0
    
    ; 尋找所有可能的 OKWW 視窗
    for hwnd in WinGetList() {
        try {
            title := WinGetTitle(hwnd)
            processName := WinGetProcessName(hwnd)
            titleLower := StrLower(title)
            
            ; 排除編輯器和開發工具
            isEditor := (InStr(titleLower, "visual studio code") || 
                        InStr(titleLower, "notepad") || 
                        InStr(titleLower, "vscode") ||
                        InStr(processName, "Code.exe") ||
                        InStr(processName, "notepad"))
            
            ; 檢查是否為 OKWW 視窗
            isOKWWWindow := false
            
            ; 方法1: 檢查標題包含 OKWW 或 OK-WW
            if ((InStr(titleLower, "ok-ww") || InStr(titleLower, "okww")) && !isEditor) {
                isOKWWWindow := true
            }
            
            ; 方法2: 檢查是否為相關進程
            if (processName = "ok-ww.exe" || 
                (processName = "pythonw.exe" && InStr(titleLower, "ok"))) {
                isOKWWWindow := true
            }
            
            if (isOKWWWindow) {
                try {
                    WinMinimize(hwnd)
                    foundCount++
                    WriteLog("已最小化 OKWW 視窗: " title " (進程: " processName ")")
                } catch as e {
                    WriteLog("最小化視窗失敗: " title " - " e.Message, "WARN")
                }
            }
        } catch as e {
            ; 忽略無法存取的視窗
        }
    }
    
    if (foundCount > 0) {
        WriteLog("成功最小化 " foundCount " 個 OKWW 視窗")
        ShowTip("📥 已最小化 " foundCount " 個 OKWW 視窗", 1500)
    } else {
        WriteLog("未找到可最小化的 OKWW 視窗", "WARN")
    }
}

; ★ 啟動前檢測：關閉所有目標程式
CheckAndCloseExistingProcesses() {
    WriteLog("開始檢測現有程式...")
    
    ; 定義要檢測的程式（使用實際檢測到的程式名稱）
    processes := [
        {name: "ok-ww.exe", display: "OKWW主程式"},
        {name: "pythonw.exe", display: "OKWW更新檢測", filter: "OK-WW"},
        {name: "Client-Win64-Shipping.exe", display: "鳴潮遊戲"},
        {name: "LRMCAI.exe", display: "LRMC自動"}
    ]
    
    ; 檢測並關閉程式
    foundAny := false
    for process in processes {
        ; 檢查進程是否存在
        processExists := false
        targetPID := 0
        
        ; 先用ProcessExist快速檢查
        pid := ProcessExist(process.name)
        if (pid) {
            ; 對於pythonw.exe，需要額外檢查是否是OKWW程式
            if (process.name = "pythonw.exe" && process.HasOwnProp("filter")) {
                isTargetProcess := false
                
                ; 方法1：檢查視窗標題
                try {
                    for hwnd in WinGetList() {
                        if (WinGetProcessName("ahk_id " hwnd) = "pythonw.exe") {
                            title := WinGetTitle("ahk_id " hwnd)
                            titleLower := StrLower(title)
                            
                            ; 排除編輯器和開發工具
                            isEditor := (InStr(titleLower, "visual studio code") || 
                                        InStr(titleLower, "notepad") || 
                                        InStr(titleLower, "vscode"))
                            
                            ; 只檢測真正的OKWW程式視窗，排除編輯器
                            if (InStr(titleLower, StrLower(process.filter)) && !isEditor) {
                                isTargetProcess := true
                                targetPID := WinGetPID("ahk_id " hwnd)
                                WriteLog("通過視窗標題找到OKWW程式: " title " (PID:" targetPID ")")
                                break
                            }
                        }
                    }
                } catch as e {
                    WriteLog("檢查視窗標題時出錯: " e.Message, "WARN")
                }
                
                processExists := isTargetProcess
            } else {
                processExists := true
                targetPID := pid
            }
        }
        
        if (processExists) {
            foundAny := true
            WriteLog("檢測到運行中的 " process.display " (" process.name " PID:" targetPID ")，正在關閉...")
            ShowTip("🔄 關閉現有的 " process.display " 程式...", 1200)
            
            try {
                if (targetPID > 0) {
                    ProcessClose(targetPID)
                } else {
                    ProcessClose(process.name)
                }
                Sleep 1000  ; 等待程式關閉
                
                ; 確認是否已關閉
                if ProcessExist(process.name) {
                    WriteLog("嘗試強制關閉 " process.name, "WARN")
                    Run("taskkill /F /IM " process.name, , "Hide")
                    Sleep 1000
                }
                WriteLog("已成功關閉 " process.display)
            } catch as e {
                WriteLog("關閉 " process.name " 時出錯: " e.Message, "ERROR")
            }
        }
    }
    
    ; 額外檢測：關閉所有 AutoHotkey 進程（除了自己）
    currentPID := DllCall("GetCurrentProcessId")
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%AutoHotkey%'") {
            if (proc.ProcessId != currentPID) {
                try {
                    cmdLine := proc.CommandLine
                    if (InStr(cmdLine, "自動開啟OKWW.ahk") || InStr(cmdLine, "開啟LRMC.ahk")) {
                        WriteLog("關閉現有的 AutoHotkey 腳本: PID=" proc.ProcessId " 命令行=" cmdLine)
                        ProcessClose(proc.ProcessId)
                        foundAny := true
                    }
                } catch {
                    ; 忽略訪問被拒絕的錯誤
                }
            }
        }
    } catch as e {
        WriteLog("檢測AutoHotkey進程時出錯: " e.Message, "WARN")
    }
    
    if foundAny {
        WriteLog("等待程式完全關閉...")
        ShowTip("⏳ 等待程式完全關閉...", 3000)
        WriteLog("啟動前清理完成")
    } else {
        WriteLog("沒有檢測到運行中的目標程式，可以開始主流程")
    }
}

; ★ 全域 UE4 崩潰監看（獨立 UE4-Client 視窗）
StartCrashWatcher() {
    SetTimer CrashWatcherTick, 5000  ; 從2秒進一步降低到5秒，大幅減少系統負擔
}
CrashWatcherTick() {
    static busy := false
    if busy
        return
    hwndC := WinExist("UE4-Client")
    if !hwndC
        return

    busy := true
    try {
        ocr := RapidOcr()
        ; 使用唯一臨時檔案名，避免衝突
        tempFile := A_ScriptDir "\ue4crash_" A_TickCount ".png"
        try {
            ImagePutFile("ahk_id " hwndC, tempFile)
            res := ocr.ocr_from_file(tempFile, , true)
            
            ; 立即清理臨時檔案
            if FileExist(tempFile)
                FileDelete(tempFile)
        } catch as e {
            WriteLog("崩潰檢測 OCR 失敗: " e.Message, "WARN")
            if FileExist(tempFile)
                FileDelete(tempFile)
            busy := false
            return
        }

        btn := ""
        if IsObject(res) {
            for block in res {
                t := StrReplace(StrReplace(block.text, "`r",""), "`n","")
                t := StrReplace(t, " ", "")
                t := ToSimp(t)
                if (block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3) {
                    if (InStr(t, "确定") || InStr(t, "確定") || InStr(t, "OK") || InStr(t, "确认") || InStr(t, "Confirm")) {
                        cx := (block.boxPoint[1].x + block.boxPoint[3].x) / 2
                        cy := (block.boxPoint[1].y + block.boxPoint[3].y) / 2
                        btn := [Round(cx), Round(cy)]
                        break
                    }
                }
            }
        }

        WinActivate "ahk_id " hwndC
        Sleep 120
        if IsObject(btn)
            MouseClick "left", btn[1], btn[2]
        else
            Send "{Enter}"
        Sleep 1000

        ; 關閉 OKWW 程式，因為遊戲崩潰重啟時 OKWW 也需要重新啟動
        try ProcessClose "ok-ww.exe"
        catch
            try ProcessClose "OK-WW.exe"
        Sleep 2000

        ; 以 AhkExe 重新啟動整支腳本，添加 restart 參數
        ; 重啟後將重新啟動 OKWW，確保崩潰後的完整恢復
        global AhkExe
        Run('"' AhkExe '" "' A_ScriptFullPath '" restart')
        ExitApp
    } finally busy := false
}

; A) 更新彈窗偵測（簡體關鍵詞）＋ OCR 算出【退出】中心點點擊
;    進入前：把鳴潮視窗貼齊右上角
DetectWutheringAndExit(&loginDetected := false) {
    loginDetected := false
    SetTitleMatchMode 2
    hwnd := WaitForWutheringGameWindow(120)
    if !hwnd {
        ShowTip("找不到「Client-Win64-Shipping.exe」遊戲視窗（逾時）。", 1200)
        return false
    }

    ; 視窗貼齊右上角（確保在螢幕內）— 非關鍵，失敗不中斷
    try MoveWindowTopRight(hwnd, 0, 0)
    catch as e
        WriteLog("視窗移動失敗（非致命）: " e.Message, "WARN")

    ; ⏱️ 至少等待 30 秒讓遊戲完全啟動（登入畫面一般需要 25-35 秒）
    earlyExitDeadline := A_TickCount + 30000
    
    deadline := A_TickCount + 1800000   ; 1800 秒（30 分鐘）
    kwUpdate1 := "更新完成"
    kwUpdate2 := "请重新启动游戏"
    kwUpdate3 := "遊戲即將重啟"
    kwUpdate4 := "游戏即将重启"
    kwBtn     := "退出"
    
    ; 優化：登入畫面檢測需要多個指標同時出現（降低誤判）
    ; 登入按鈕相關詞彙（包括「點擊連接」）
    loginBtnKeywords := [ "點擊開始", "点击开始", "點選開始", "点选开始", "開始遊戲", "开始游戏", "點擊連接", "点击连接", "點選連接", "点选连接" ]
    ; 登入UI相關詞彙（如賬號/伺服器選擇）
    loginUIKeywords := [ "伺服器", "服务器", "賬號", "账号", "帳號", "账户" ]

    while (A_TickCount < deadline) {
        hwnd := GetWutheringGameHwnd()
        if !hwnd
            break

        ; 使用唯一臨時檔案名，執行後清理（減少磁碟 I/O 衝突）
        tempFile := A_ScriptDir "\temp_update_" A_TickCount ".png"
        try {
            ImagePutFile("ahk_id " hwnd, tempFile)
            ocr := RapidOcr()
            res := ocr.ocr_from_file(tempFile, , true)
            
            ; 立即清理臨時檔案，釋放磁碟空間
            if FileExist(tempFile)
                FileDelete(tempFile)
        } catch as e {
            WriteLog("更新檢測 OCR 失敗: " e.Message, "WARN")
            if FileExist(tempFile)
                FileDelete(tempFile)
            Sleep 1000
            continue
        }

        foundUpdate := false
        foundLoginBtn := false
        foundLoginUI := false
        btnCenter := ""

        if IsObject(res) {
            for block in res {
                clean := StrReplace(StrReplace(block.text, "`r", ""), "`n", "")
                clean := StrReplace(clean, " ", "")
                
                ; 檢測更新相關文字
                if InStr(clean, kwUpdate1) || InStr(clean, kwUpdate2) || InStr(clean, kwUpdate3) || InStr(clean, kwUpdate4)
                    foundUpdate := true
                
                ; 檢測登入按鈕相關文字
                for _, btnKw in loginBtnKeywords {
                    if InStr(clean, btnKw) {
                        foundLoginBtn := true
                        WriteLog("檢測到登入按鈕關鍵字: " btnKw " 在文字: " clean)
                        break
                    }
                }
                
                ; 檢測登入UI相關文字
                for _, uiKw in loginUIKeywords {
                    if InStr(clean, uiKw) {
                        foundLoginUI := true
                        WriteLog("檢測到登入UI關鍵字: " uiKw " 在文字: " clean)
                        break
                    }
                }

                ; 檢測退出按鈕
                if InStr(clean, kwBtn) && block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3 {
                    x1 := block.boxPoint[1].x, y1 := block.boxPoint[1].y
                    x2 := block.boxPoint[3].x, y2 := block.boxPoint[3].y
                    btnCenter := [ Round((x1 + x2) / 2), Round((y1 + y2) / 2) ]
                }
                
                ; 檢測確認按鈕（確認、确认、確定、确定）
                if (InStr(clean, "確認") || InStr(clean, "确认") || InStr(clean, "確定") || InStr(clean, "确定")) && 
                   block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3 {
                    x1 := block.boxPoint[1].x, y1 := block.boxPoint[1].y
                    x2 := block.boxPoint[3].x, y2 := block.boxPoint[3].y
                    btnCenter := [ Round((x1 + x2) / 2), Round((y1 + y2) / 2) ]
                    WriteLog("找到確認按鈕: " clean " 位置: " btnCenter[1] "," btnCenter[2])
                }
            }
        }

        if (foundUpdate && IsObject(btnCenter)) {
            ShowTip("✅ 偵測到更新完成 → 點擊按鈕", 800)
            MouseClick "left", btnCenter[1], btnCenter[2]
            ShowTip("已點擊按鈕，準備重新執行腳本。", 1200)
            return true
        }
        
        ; ✅ 優化：檢測到登入按鈕相關文字，且超過最小等待時間（30秒）才判定為登入畫面
        if (foundLoginBtn && A_TickCount >= earlyExitDeadline) {
            loginDetected := true
            WriteLog("✅ 檢測到登入畫面（已超過 30 秒啟動時間，找到登入按鈕關鍵字），無需更新，繼續正常流程")
            MuteWutheringAudioAtStartup()
            TryMuteWutheringAudio("檢測到登入畫面後")
            ShowTip("✅ 檢測到登入畫面，無需更新", 1000)
            return false
        }
        
        ; 如果只find到登入UI但沒找到按鈕，也要等待足夠時間再判定
        if (foundLoginUI && A_TickCount >= earlyExitDeadline + 10000) {
            loginDetected := true
            WriteLog("⚠️ 檢測到登入UI（伺服器/賬號相關），判定為登入畫面，繼續")
            MuteWutheringAudioAtStartup()
            TryMuteWutheringAudio("檢測到登入UI後")
            ShowTip("✅ 檢測到登入畫面UI，無需更新", 1000)
            return false
        }
        
        Sleep 900
    }

    ShowTip("未檢測到更新或登入畫面，繼續正常流程。", 900)
    return false
}

; B) 去抖動主畫面模板比對（右下 ROI）
WaitEscMenuOCR(hwnd, timeoutSec := 120) {
    oldPixelMode := A_CoordModePixel
    CoordMode "Pixel", "Screen"

    if !hwnd {
        hwnd := GetWutheringGameHwnd()
        if !hwnd {
            CoordMode "Pixel", oldPixelMode
            return false
        }
    }

    templateFile := A_ScriptDir "\icon_main.png"

    if !FileExist(templateFile) {
        WriteLog("模板驗證失敗：找不到模板檔 " templateFile, "WARN")
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

    WriteLog("模板驗證參數: template=" templateFile " roi=" roiWidth "x" roiHeight " timeout=" timeoutSec "s")

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
            WriteLog("模板驗證取視窗座標失敗: " e.Message, "WARN")
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
            ShowTip("✅ 模板偵測 " stable "/" stableNeeded "（Var=" matchedVar "）", 600)
            if (stable >= stableNeeded) {
                return true
            }
        } else {
            stable := 0
        }

        if (A_TickCount - lastProgressLog >= 5000) {
            remainSec := Round((deadline - A_TickCount) / 1000.0, 1)
            WriteLog("模板驗證進行中: 樣本=" sampleCount " 連續命中=" stable "/" stableNeeded " 最後Var=" (bestVar ? bestVar : "-") " 剩餘=" remainSec "s")
            lastProgressLog := A_TickCount
        }

        Sleep checkIntervalMs
    }

    WriteLog("模板驗證超時: 樣本=" sampleCount " 未達連續命中 " stableNeeded, "WARN")
    CoordMode "Pixel", oldPixelMode
    return false
}

; E) 點擊指定窗口中心
ClickWindowCenter(hwnd) {
    if !hwnd
        return false
    try {
        oldMode := A_CoordModeMouse
        CoordMode "Mouse", "Screen"
        WinGetPos(&x, &y, &w, &h, "ahk_id " hwnd)
        if (w = "" || h = "" || w <= 0 || h <= 0)
            return false
        cx := x + (w // 2)
        cy := y + (h // 2)
        WriteLog("點擊視窗中心: " cx "," cy)
        MouseClick "left", cx, cy
        return true
    } catch as e {
        WriteLog("點擊視窗中心失敗: " e.Message, "WARN")
        return false
    } finally {
        if IsSet(oldMode)
            CoordMode "Mouse", oldMode
    }
}

; F) 取得並啟動鳴潮路徑（可記憶）
EnsureWutheringRunning() {
    ; ✅ 只檢查遊戲進程是否存在，不檢查視窗尺寸
    ;    這樣防止因視窗最小化而誤判為「遊戲未運行」
    if (IsWutheringProcessRunning()) {
        return true
    }
    
    path := GetPathWithAsk("WUTHERING", "請選擇鳴潮遊戲主程式或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
    if (!path) {
        WriteLog("未設定鳴潮路徑，無法啟動", "ERROR")
        MsgBox "未設定鳴潮遊戲路徑。請重新執行並選擇。"
        ExitApp
    }
    WriteLog("啟動鳴潮: " path)
    ShowTip("🎮 正在啟動鳴潮...", 1500)
    try Run(path)
    catch as e {
        WriteLog("啟動鳴潮失敗: " e.Message, "ERROR")
        ShowTip("❌ 鳴潮啟動失敗", 1500)
    }
    Sleep 5000
    return true
}

; ✅ 只檢查遊戲進程是否存在
IsWutheringProcessRunning() {
    hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe ahk_class UnrealWindow")
    if (hwndList.Length > 0)
        return true
    
    hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe")
    return (hwndList.Length > 0)
}

GetWutheringGameHwnd() {
    ; ✅ 優先條件：執行程序 + UnrealWindow 類別（完全初始化的遊戲視窗）
    hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe ahk_class UnrealWindow")
    if (hwndList.Length > 0) {
        hwnd := hwndList[1]
        if (IsValidGameWindow(hwnd))
            return hwnd
    }

    ; ⚠️ 回退：部分環境 class 可能不同，但需驗證視窗有效性
    ;   這個回退會延遲遊戲啟動的判定，避免找到臨時初始化視窗
    hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe")
    if (hwndList.Length > 0) {
        for hwnd in hwndList {
            if (IsValidGameWindow(hwnd))
                return hwnd
        }
    }

    return 0
}

; ✅ 驗證視窗是否為真正的遊戲視窗（而非臨時初始化視窗）
IsValidGameWindow(hwnd) {
    if !hwnd
        return false
    
    ; 檢查視窗是否存在
    if !WinExist("ahk_id " hwnd)
        return false
    
    ; 取得視窗寬高
    try WinGetPos , , &w, &h, "ahk_id " hwnd
    catch {
        return false
    }
    
    ; 檢查視窗有合理的尺寸（排除 0x0 或異常小的初始化視窗）
    ; 遊戲視窗通常至少 800x600
    if (w < 800 || h < 600) {
        return false
    }
    
    ; ✅ 視窗有效
    return true
}

WaitForWutheringGameWindow(timeoutSec := 120) {
    deadline := A_TickCount + timeoutSec * 1000
    while (A_TickCount < deadline) {
        hwnd := GetWutheringGameHwnd()
        if hwnd
            return hwnd
        Sleep 300
    }
    return 0
}

EnsureCoreProgramPathsAtStartup() {
    return EnsureAllConfigAtStartup(false, "啟動前檢查核心程式路徑")
}

GetPathWithAsk(key, prompt, filter) {
    global CFG_FILE
    path := NormalizePath(IniReadSafe(CFG_FILE, "paths", key, ""))
    if (path != "" && FileExist(path))
        return path

    WriteLog("路徑未設定或檔案不存在，打開整合設定視窗: " key, "WARN")
    ShowTip("📂 路徑缺失，請完成設定", 1200)
    EnsureAllConfigAtStartup(false, "偵測到路徑缺失或失效（" key "）")

    path := NormalizePath(IniReadSafe(CFG_FILE, "paths", key, ""))
    if (path != "" && FileExist(path))
        return path

    WriteLog("整合設定後仍無有效路徑: " key, "ERROR")
    return path
}

AskPathGui(prompt, defaultPath := "", filter := "All Files (*.*)", force := false) {
    sel := { path: "", keep: 0 }
    g := Gui("+AlwaysOnTop -MinimizeBox", prompt)
    g.SetFont("s10")
    g.Add("Text", "xm ym", "執行檔路徑：")
    e := g.AddEdit("xm w520 vPATH", defaultPath)
    b := g.AddButton("x+m w90", "瀏覽...")
    b.OnEvent("Click", (*) => FileBrowse())
    cb := g.AddCheckbox("xm vKEEP", "下次不再詢問")
    ok := g.AddButton("xm w120 Default", "確定")
    cancel := g.AddButton("x+m w90", "取消")
    ok.OnEvent("Click", (*) => Confirm())
    cancel.OnEvent("Click", (*) => CancelSel())
    g.Show("AutoSize Center")
    WinWaitClose g.Hwnd
    return sel

    FileBrowse() {
        ShowTip("📂 選擇檔案中...", 1000)
        p := FileSelect(, "", prompt, filter)
        if (p)
            e.Value := p
    }

    Confirm() {
        sel.path := Trim(e.Value)
        sel.keep := cb.Value ? 1 : 0
        ShowTip("✅ 已選擇路徑", 800)
        g.Hide()
    }

    CancelSel() {
        sel.path := ""
        ShowTip("❌ 已取消選擇", 800)
        g.Hide()
    }
}

IniReadSafe(file, section, key, default) {
    try {
        return IniRead(file, section, key, default)
    } catch {
        return default
    }
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

; C) 將指定窗口貼齊螢幕右上角；若過大則縮到螢幕內（完全貼邊）
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

; D) 繁→簡（常見詞）
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

; 重啟全自動腳本（帶重啟計數）
RestartAutoScript() {
    global CFG_FILE, restartCount, MAX_RESTART_COUNT
    
    ; 增加重啟計數
    restartCount++
    WriteLog("準備重啟全自動腳本，第 " restartCount " 次重啟")
    
    ; 檢查是否超過最大重啟次數
    if (restartCount > MAX_RESTART_COUNT) {
        WriteLog("重啟次數已達上限 (" MAX_RESTART_COUNT ")，停止重啟以避免無限循環", "ERROR")
        ShowTip("❌ 重啟次數過多，停止執行", 5000)
        Sleep 5000
        ; 重置計數器
        IniWrite "0", CFG_FILE, "restart_tracking", "auto_restart_count"
        ExitApp
    }
    
    ; 儲存重啟計數
    IniWrite restartCount, CFG_FILE, "restart_tracking", "auto_restart_count"
    
    ; 關閉所有相關進程
    WriteLog("關閉所有相關進程...")
    CheckAndCloseExistingProcesses()
    
    Sleep 3000
    
    ; 重新啟動腳本
    WriteLog("重新啟動全自動腳本...")
    try {
        Run('"' A_ScriptFullPath '"')
        WriteLog("重啟命令已發送")
    } catch as e {
        WriteLog("重啟失敗: " e.Message, "ERROR")
    }
    
    ; 結束當前進程
    Sleep 1000
    ExitApp
}

MonitorRewardAndShutdown() {
    global REWARD_LOG_FILE, REWARD_START_DELAY_MS, REWARD_CHECK_INTERVAL_MS, REWARD_SHUTDOWN_DELAY_MS, REWARD_MATCH_NEED_COUNT

    logPath := ResolveRewardLogPath()
    if (logPath = "") {
        WriteLog("收尾監測未設定日誌檔，跳過監測", "WARN")
        return
    }

    if !FileExist(logPath) {
        WriteLog("收尾監測找不到日誌檔: " logPath, "WARN")
        return
    }

    startDelaySec := Round(REWARD_START_DELAY_MS / 1000)
    WriteLog("主流程完成，先等待 " startDelaySec " 秒再開始監測最新日誌: " logPath)
    ShowTip("⏳ 主流程完成，" startDelaySec "秒後開始監測", 1500)
    Sleep REWARD_START_DELAY_MS

    lastPos := GetLogFileLength(logPath)
    hit := 0
    seenClickReward := false
    seenNoReward := false
    seenDailyRewardSuccess := false
    seenSolaraRewardFail := false
    WriteLog("開始持續監測『最新新增』日誌，起始偏移: " lastPos)
    ShowTip("🧭 開始監測最新日誌...", 1200)

    loop {
        chunk := ReadLogAppended(logPath, &lastPos)
        if (chunk != "") {
            for line in StrSplit(chunk, "`n") {
                line := Trim(line, "`r`t ")
                if (line = "")
                    continue

                if (line ~= "i)(电台.*一键领取|電台.*一鍵領取)") {
                    seenClickReward := true
                    hit += 1
                    WriteLog("監測命中『電台_一鍵領取』(" hit "/" REWARD_MATCH_NEED_COUNT "): " line)
                    if (hit >= REWARD_MATCH_NEED_COUNT) {
                        delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                        WriteLog("已監測到 " REWARD_MATCH_NEED_COUNT " 條『電台_一鍵領取』，" delaySec " 秒後開始關閉流程")
                        ShowTip("✅ 監測命中，" delaySec "秒後關閉程式", 2000)
                        Sleep REWARD_SHUTDOWN_DELAY_MS
                        ShutdownGameLrmcOkww()
                        return
                    }
                }

                if (line ~= "i)(没有奖励能领取|沒有獎勵能領取)") {
                    seenNoReward := true
                    WriteLog("監測命中『沒有獎勵能領取』: " line)
                }

                if (line ~= "i)(领取每日奖励成功|領取每日獎勵成功)") {
                    seenDailyRewardSuccess := true
                    WriteLog("監測命中『領取每日獎勵成功』: " line)
                }

                if (line ~= "i)(索拉奖励领取失败|索拉獎勵領取失敗|索拉獎勵錄取失敗)") {
                    seenSolaraRewardFail := true
                    WriteLog("監測命中『索拉獎勵領取失敗』: " line)
                }

                if (seenClickReward && seenNoReward) {
                    delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                    WriteLog("已同時監測到『點擊電台一鍵領取』與『沒有獎勵能領取』，" delaySec " 秒後開始關閉流程")
                    ShowTip("✅ 監測到一鍵領取+無獎勵，" delaySec "秒後關閉", 2000)
                    Sleep REWARD_SHUTDOWN_DELAY_MS
                    ShutdownGameLrmcOkww()
                    return
                }

                if (seenDailyRewardSuccess && seenNoReward) {
                    delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                    WriteLog("已同時監測到『領取每日獎勵成功』與『沒有獎勵能領取』，" delaySec " 秒後開始關閉流程")
                    ShowTip("✅ 監測到每日獎勵成功+無獎勵，" delaySec "秒後關閉", 2000)
                    Sleep REWARD_SHUTDOWN_DELAY_MS
                    ShutdownGameLrmcOkww()
                    return
                }

                if (seenSolaraRewardFail && seenNoReward) {
                    delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                    WriteLog("已同時監測到『索拉獎勵領取失敗』與『沒有獎勵能領取』，" delaySec " 秒後開始關閉流程")
                    ShowTip("✅ 監測到索拉獎勵失敗+無獎勵，" delaySec "秒後關閉", 2000)
                    Sleep REWARD_SHUTDOWN_DELAY_MS
                    ShutdownGameLrmcOkww()
                    return
                }
            }
        }
        Sleep REWARD_CHECK_INTERVAL_MS
    }
}

ResolveRewardLogPath() {
    global CFG_FILE, REWARD_LOG_FILE

    lrmcExe := NormalizePath(IniReadSafe(CFG_FILE, "paths", "LRMC", ""))
    if (lrmcExe != "") {
        lrmcResolved := ResolveLrmcPathForLog(lrmcExe)
        SplitPath lrmcResolved, , &lrmcDir
        if (lrmcDir != "") {
            candidate := lrmcDir "\log\LRMCAI.log"
            if FileExist(candidate) {
                WriteLog("收尾監測日誌路徑（由 LRMC 路徑推導）: " candidate "，來源=" lrmcResolved)
                return candidate
            }

            WriteLog("由 LRMC 路徑推導的日誌不存在，改用後備路徑: " candidate "，來源=" lrmcResolved, "WARN")
        }
    }

    cfgFallback := NormalizePath(IniReadSafe(CFG_FILE, "reward_monitor", "fallback_log_file", ""))
    if (cfgFallback = "") {
        cfgFallback := Trim(REWARD_LOG_FILE, ' "')
        if (cfgFallback != "") {
            try IniWrite cfgFallback, CFG_FILE, "reward_monitor", "fallback_log_file"
            WriteLog("已初始化後備日誌路徑到設定檔: " cfgFallback)
        }
    }

    if (cfgFallback != "") {
        WriteLog("收尾監測使用後備日誌路徑: " cfgFallback, "WARN")
        return cfgFallback
    }

    return ""
}

ResolveLrmcPathForLog(pathVal) {
    p := NormalizePath(pathVal)
    if (p = "")
        return ""

    ; 若設定的是捷徑，先解析到實際目標程式，避免用到開始功能表目錄。
    if (p ~= "i)\.lnk$") {
        try {
            target := "", outDir := "", outArgs := "", outDesc := "", outIcon := "", outIconNum := 0, outRunState := 0
            FileGetShortcut p, &target, &outDir, &outArgs, &outDesc, &outIcon, &outIconNum, &outRunState
            target := NormalizePath(target)
            if (target != "") {
                WriteLog("LRMC 捷徑已解析：" p " -> " target)
                return target
            }

            if (outDir != "") {
                candidateExe := NormalizePath(outDir "\\LRMCAI.exe")
                if FileExist(candidateExe) {
                    WriteLog("LRMC 捷徑目標為空，改用捷徑工作目錄推導：" candidateExe, "WARN")
                    return candidateExe
                }
            }

            WriteLog("LRMC 捷徑解析失敗，沿用原路徑：" p, "WARN")
            return p
        } catch as e {
            WriteLog("LRMC 捷徑解析例外，沿用原路徑：" p "，" e.Message, "WARN")
            return p
        }
    }

    return p
}

GetLogFileLength(filePath) {
    try {
        f := FileOpen(filePath, "r")
        if !IsObject(f)
            return 0

        size := f.Length
        f.Close()
        return size
    } catch {
        return 0
    }
}

ReadLogAppended(filePath, &lastPos) {
    try {
        f := FileOpen(filePath, "r")
        if !IsObject(f)
            return ""

        size := f.Length

        ; 日誌輪替或被截斷時，從頭重新讀
        if (size < lastPos)
            lastPos := 0

        if (size = lastPos) {
            f.Close()
            return ""
        }

        f.Pos := lastPos
        txt := f.Read()
        lastPos := size
        f.Close()

        return txt
    } catch {
        return ""
    }
}

ShutdownGameLrmcOkww() {
    UnmuteWutheringAudio("監測到結束，開始收尾")
    WriteLog("開始關閉收尾目標程式：鳴潮、LRMCAI、OKWW")
    ShowTip("🛑 正在關閉鳴潮/LRMCAI/OKWW...", 1500)

    ; 1) 鳴潮
    try ProcessClose("Client-Win64-Shipping.exe")
    catch
        try Run("taskkill /F /IM Client-Win64-Shipping.exe", , "Hide")
    Sleep 600

    ; 2) LRMCAI
    try ProcessClose("LRMCAI.exe")
    catch
        try Run("taskkill /F /IM LRMCAI.exe", , "Hide")
    Sleep 600

    ; 3) OKWW（主程式 + 更新檢測）
    try ProcessClose("ok-ww.exe")
    catch
        try ProcessClose("OK-WW.exe")
    try Run("taskkill /F /IM ok-ww.exe", , "Hide")
    try Run("taskkill /F /IM OK-WW.exe", , "Hide")
    try Run("taskkill /F /IM pythonw.exe", , "Hide")

    ; 停止監看計時器，避免後續流程再觸發
    try SetTimer(CrashWatcherTick, 0)

    ; 關閉相關 AutoHotkey 管理腳本（保留自己，最後再 ExitApp）
    currentPID := DllCall("GetCurrentProcessId")
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%AutoHotkey%'") {
            if (proc.ProcessId = currentPID)
                continue
            try {
                cmdLine := proc.CommandLine
                if (InStr(cmdLine, "開啟LRMC.ahk") || InStr(cmdLine, "自動開啟OKWW.ahk") || InStr(cmdLine, "聲骸合成.ahk") || InStr(cmdLine, "全自動.ahk"))
                    ProcessClose(proc.ProcessId)
            }
        }
    }

    if MAIL_NOTIFY_ENABLED {
        mailResult := SendShutdownNotifyMail()
        if mailResult.ok
            WriteLog("收尾通知信已寄出")
        else
            WriteLog("收尾通知信寄送失敗: " mailResult.message, "WARN")
    }

    WriteLog("收尾關閉流程已完成，所有流程已停止")
    ShowTip("✅ 已關閉並停止所有流程", 2000)
    Sleep 800
    ExitApp
}

SendShutdownNotifyMail() {
    global CFG_FILE, MAIL_SECTION

    state := ReadCombinedConfigState()
    if state.needSetup {
        WriteLog("收尾寄信前偵測到設定缺漏，重新打開整合設定視窗", "WARN")
        ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, "收尾寄信前偵測到設定有空白或錯誤")
        if !ok
            return { ok: false, message: "使用者取消整合設定" }

        state := ReadCombinedConfigState()
        if state.needSetup
            return { ok: false, message: "設定仍不完整: " state.errorText }
    }

    cfgPath := Trim(CFG_FILE, " `t`r`n")
    section := Trim(MAIL_SECTION, " `t`r`n")
    if (cfgPath = "")
        return { ok: false, message: "CFG_FILE 未設定" }
    if !FileExist(cfgPath)
        return { ok: false, message: "找不到設定檔: " cfgPath }

    smtpHost := Trim(IniRead(cfgPath, section, "smtp_host", ""), " `t`r`n")
    smtpPort := Trim(IniRead(cfgPath, section, "smtp_port", "587"), " `t`r`n")
    smtpUser := Trim(IniRead(cfgPath, section, "smtp_user", ""), " `t`r`n")
    smtpPass := Trim(IniRead(cfgPath, section, "smtp_pass", ""), " `t`r`n")
    if (smtpPass = "")
        smtpPass := Trim(IniRead(cfgPath, section, "smtp_password", ""), " `t`r`n")
    mailFrom := Trim(IniRead(cfgPath, section, "from", ""), " `t`r`n")
    mailTo := Trim(IniRead(cfgPath, section, "to", ""), " `t`r`n")
    subjectPrefix := Trim(IniRead(cfgPath, section, "subject_prefix", "LRMCAI"), " `t`r`n")
    useSsl := Trim(IniRead(cfgPath, section, "use_ssl", "1"), " `t`r`n")

    if (smtpHost = "" || smtpUser = "" || smtpPass = "" || mailFrom = "" || mailTo = "")
        return { ok: false, message: "mail_config.ini 欄位不完整" }
    if !(smtpPort ~= "^\d+$")
        return { ok: false, message: "smtp_port 不是數字: " smtpPort }

    nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    subject := subjectPrefix " 關閉完成通知 " nowText
    body := "全自動收尾已完成。`r`n時間：" nowText "`r`n主機：" A_ComputerName "`r`n腳本：" A_ScriptFullPath

    return SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl)
}

EnsureMailConfigAtStartup() {
    return EnsureAllConfigAtStartup(false, "郵件設定檢查")
}

EnsureAllConfigAtStartup(force := false, reason := "") {
    global CFG_FILE, MAIL_SECTION

    state := ReadCombinedConfigState()
    if (!force && !state.needSetup)
        return true

    if (reason = "")
        reason := "偵測到設定缺漏或錯誤"

    WriteLog("打開整合設定視窗：" reason, "WARN")
    ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, reason)
    if !ok {
        MsgBox "你已取消設定。為了確保流程一致，本次不啟動主流程。", "整合設定", "Iconx"
        ExitApp
    }

    verify := ReadCombinedConfigState()
    if verify.needSetup {
        msg := "儲存後仍有未完成項目：`n" verify.errorText
        MsgBox msg, "整合設定", "Iconx"
        ExitApp
    }

    WriteLog("整合設定檢查完成，繼續主流程")
    return true
}

ReadCombinedConfigState() {
    global CFG_FILE, MAIL_NOTIFY_ENABLED, MAIL_SECTION, REWARD_LOG_FILE

    state := {}
    state.okwwPath := NormalizePath(IniReadSafe(CFG_FILE, "paths", "OKWW", ""))
    state.lrmcPath := NormalizePath(IniReadSafe(CFG_FILE, "paths", "LRMC", ""))
    state.wuPath := NormalizePath(IniReadSafe(CFG_FILE, "paths", "WUTHERING", ""))

    state.smtpHost := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "smtp_host", ""), " `t`r`n")
    state.smtpPort := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "smtp_port", "587"), " `t`r`n")
    state.smtpUser := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "smtp_user", ""), " `t`r`n")
    state.smtpPass := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "smtp_pass", ""), " `t`r`n")
    if (state.smtpPass = "")
        state.smtpPass := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "smtp_password", ""), " `t`r`n")
    state.mailFrom := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "from", ""), " `t`r`n")
    state.mailTo := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "to", ""), " `t`r`n")
    state.subjectPrefix := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "subject_prefix", "LRMCAI"), " `t`r`n")
    state.useSsl := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "use_ssl", "1"), " `t`r`n")
    state.sendEnabled := ParseBool01(IniReadSafe(CFG_FILE, MAIL_SECTION, "send_enabled", "1"), 1)
    MAIL_NOTIFY_ENABLED := state.sendEnabled
    state.fallbackLogFile := NormalizePath(IniReadSafe(CFG_FILE, "reward_monitor", "fallback_log_file", ""))
    if (state.fallbackLogFile = "")
        state.fallbackLogFile := Trim(REWARD_LOG_FILE, ' "')

    err := []
    if (state.okwwPath = "")
        err.Push("OKWW 路徑為空")
    else if !FileExist(state.okwwPath)
        err.Push("OKWW 路徑不存在")

    if (state.lrmcPath = "")
        err.Push("LRMCAI 路徑為空")
    else if !FileExist(state.lrmcPath)
        err.Push("LRMCAI 路徑不存在")

    if (state.wuPath = "")
        err.Push("鳴潮路徑為空")
    else if !FileExist(state.wuPath)
        err.Push("鳴潮路徑不存在")

    if MAIL_NOTIFY_ENABLED {
        if (state.smtpHost = "")
            err.Push("smtp_host 為空")
        if (state.smtpPort = "")
            err.Push("smtp_port 為空")
        else if !(state.smtpPort ~= "^\d+$")
            err.Push("smtp_port 不是數字")
        if (state.smtpUser = "")
            err.Push("smtp_user 為空")
        if (state.smtpPass = "")
            err.Push("smtp_pass 為空")
        if (state.mailFrom = "")
            err.Push("from 為空")
        if (state.mailTo = "")
            err.Push("to 為空")
    }

    state.errors := err
    state.needSetup := (err.Length > 0)
    state.errorText := ""
    for item in err
        state.errorText .= "- " item "`n"

    return state
}

ShowCombinedConfigSetupGui(cfgPath, section, state, reason := "") {
    g := Gui("+AlwaysOnTop +MinSize760x760", "整合設定（程式路徑 + 郵件通知）")
    g.SetFont("s10", "Microsoft JhengHei UI")

    g.AddText("w720", "【觸發原因】" reason)
    g.AddText("w720", "【設定檔位置】" cfgPath)
    g.AddText("w720", "【說明】以下欄位會載入目前設定，你可以一次全部修改後儲存。")
    g.AddText("w720", "【路徑要求】三個程式路徑都必須存在；若之後檢測到空白或錯誤，會再次跳出此視窗。")

    summary := "目前偵測值：`r`n"
    summary .= "OKWW: " state.okwwPath "`r`n"
    summary .= "LRMCAI: " state.lrmcPath "`r`n"
    summary .= "鳴潮: " state.wuPath "`r`n"
    summary .= "smtp_host: " state.smtpHost "`r`n"
    summary .= "smtp_port: " state.smtpPort "`r`n"
    summary .= "smtp_user: " state.smtpUser "`r`n"
    summary .= "from: " state.mailFrom "`r`n"
    summary .= "to: " state.mailTo "`r`n"
    summary .= "send_enabled: " (state.sendEnabled ? "1(啟用)" : "0(停用)") "`r`n"
    summary .= "fallback_log_file: " state.fallbackLogFile
    g.AddEdit("xm w720 r8 ReadOnly", summary)

    if (state.needSetup)
        g.AddEdit("xm y+8 w720 r4 ReadOnly", "目前需修正：`r`n" state.errorText)

    g.AddText("xm y+12 w120", "OKWW 路徑")
    edOkww := g.AddEdit("x+10 w500", state.okwwPath)
    btnOkww := g.AddButton("x+8 w90", "瀏覽...")

    g.AddText("xm y+10 w120", "LRMCAI 路徑")
    edLrmc := g.AddEdit("x+10 w500", state.lrmcPath)
    btnLrmc := g.AddButton("x+8 w90", "瀏覽...")

    g.AddText("xm y+10 w120", "鳴潮 路徑")
    edWu := g.AddEdit("x+10 w500", state.wuPath)
    btnWu := g.AddButton("x+8 w90", "瀏覽...")

    g.AddText("xm y+10 w120", "後備 log 路徑")
    edFallbackLog := g.AddEdit("x+10 w500", state.fallbackLogFile)
    btnFallbackLog := g.AddButton("x+8 w90", "瀏覽...")
    txtFallbackHint := g.AddText("xm y+4 w720 cE6A700", "")

    g.AddText("xm y+14 w720", "【郵件設定】Gmail: smtp.gmail.com / 587 / use_ssl=1；密碼請使用應用程式密碼")
    cbSendEnabled := g.AddCheckbox("xm y+8", "啟用收尾通知寄信")
    cbSendEnabled.Value := state.sendEnabled ? 1 : 0
    txtMailHint := g.AddText("x+12 w420", state.sendEnabled ? "目前啟用寄信：需填寫 SMTP 欄位" : "目前停用寄信：可略過 SMTP 欄位")

    g.AddText("xm y+10 w120", "smtp_host")
    edHost := g.AddEdit("x+10 w500", state.smtpHost)

    g.AddText("xm y+10 w120", "smtp_port")
    edPort := g.AddEdit("x+10 w120", state.smtpPort)
    g.AddText("x+12 w120", "use_ssl")
    ddSsl := g.AddDropDownList("x+10 w80", ["1", "0"])
    ddSsl.Value := (state.useSsl = "0") ? 2 : 1

    g.AddText("xm y+10 w120", "smtp_user")
    edUser := g.AddEdit("x+10 w500", state.smtpUser)

    g.AddText("xm y+10 w120", "smtp_pass")
    edPass := g.AddEdit("x+10 w500 Password", state.smtpPass)

    g.AddText("xm y+10 w120", "from")
    edFrom := g.AddEdit("x+10 w500", state.mailFrom)

    g.AddText("xm y+10 w120", "to")
    edTo := g.AddEdit("x+10 w500", state.mailTo)

    g.AddText("xm y+10 w120", "subject_prefix")
    edPrefix := g.AddEdit("x+10 w500", state.subjectPrefix)

    btnSave := g.AddButton("xm y+18 w170 h34 Default", "儲存全部並繼續")
    btnCancel := g.AddButton("x+12 w110 h34", "取消")

    global __MAIL_SETUP
    __MAIL_SETUP := {
        done: false,
        saved: false,
        gui: g,
        cfgPath: cfgPath,
        section: section,
        edOkww: edOkww,
        edLrmc: edLrmc,
        edWu: edWu,
        edFallbackLog: edFallbackLog,
        txtFallbackHint: txtFallbackHint,
        edHost: edHost,
        edPort: edPort,
        edUser: edUser,
        edPass: edPass,
        edFrom: edFrom,
        edTo: edTo,
        edPrefix: edPrefix,
        ddSsl: ddSsl,
        cbSendEnabled: cbSendEnabled,
        txtMailHint: txtMailHint
    }

    btnOkww.OnEvent("Click", OnCombinedBrowseOkww)
    btnLrmc.OnEvent("Click", OnCombinedBrowseLrmc)
    btnWu.OnEvent("Click", OnCombinedBrowseWu)
    btnFallbackLog.OnEvent("Click", OnCombinedBrowseFallbackLog)
    edFallbackLog.OnEvent("Change", OnFallbackLogChanged)
    cbSendEnabled.OnEvent("Click", OnSendEnabledChanged)
    btnSave.OnEvent("Click", OnCombinedSetupSave)
    btnCancel.OnEvent("Click", OnCombinedSetupCancel)
    g.OnEvent("Close", OnCombinedSetupClose)

    RefreshFallbackLogHint()
    RefreshMailInputsEnabled()

    g.Show("AutoSize")
    while !__MAIL_SETUP.done
        Sleep 50

    saved := __MAIL_SETUP.saved
    __MAIL_SETUP := ""
    return saved
}

OnCombinedBrowseOkww(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "選擇 OKWW 可執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
    if (p)
        __MAIL_SETUP.edOkww.Value := p
}

OnCombinedBrowseLrmc(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "選擇 LRMCAI 可執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
    if (p)
        __MAIL_SETUP.edLrmc.Value := p
}

OnCombinedBrowseWu(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "選擇鳴潮可執行檔或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
    if (p)
        __MAIL_SETUP.edWu.Value := p
}

OnCombinedBrowseFallbackLog(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "選擇後備 LRMCAI.log", "Log 檔 (*.log)")
    if (p) {
        __MAIL_SETUP.edFallbackLog.Value := p
        RefreshFallbackLogHint()
    }
}

OnFallbackLogChanged(*) {
    RefreshFallbackLogHint()
}

RefreshFallbackLogHint() {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    p := NormalizePath(__MAIL_SETUP.edFallbackLog.Value)
    if (p = "") {
        __MAIL_SETUP.txtFallbackHint.Value := "提示：後備 log 路徑為空，會改用預設或由 LRMC 路徑推導。"
        return
    }

    if FileExist(p)
        __MAIL_SETUP.txtFallbackHint.Value := "提示：後備 log 路徑存在，可作為監測後備來源。"
    else
        __MAIL_SETUP.txtFallbackHint.Value := "⚠ 警告：後備 log 檔不存在，儲存仍可繼續，但監測時可能找不到後備日誌。"
}

OnCombinedSetupSave(*) {
    global __MAIL_SETUP, MAIL_NOTIFY_ENABLED
    st := __MAIL_SETUP

    okwwPath := NormalizePath(st.edOkww.Value)
    lrmcPath := NormalizePath(st.edLrmc.Value)
    wuPath := NormalizePath(st.edWu.Value)
    fallbackLogVal := NormalizePath(st.edFallbackLog.Value)

    hostVal := Trim(st.edHost.Value, " `t`r`n")
    portVal := Trim(st.edPort.Value, " `t`r`n")
    userVal := Trim(st.edUser.Value, " `t`r`n")
    passVal := Trim(st.edPass.Value, " `t`r`n")
    fromVal := Trim(st.edFrom.Value, " `t`r`n")
    toVal := Trim(st.edTo.Value, " `t`r`n")
    prefixVal := Trim(st.edPrefix.Value, " `t`r`n")
    sslVal := st.ddSsl.Text
    sendEnabledVal := st.cbSendEnabled.Value ? 1 : 0

    if (okwwPath = "" || !FileExist(okwwPath)) {
        MsgBox "OKWW 路徑空白或不存在", "整合設定", "Iconx"
        return
    }
    if (lrmcPath = "" || !FileExist(lrmcPath)) {
        MsgBox "LRMCAI 路徑空白或不存在", "整合設定", "Iconx"
        return
    }
    if (wuPath = "" || !FileExist(wuPath)) {
        MsgBox "鳴潮路徑空白或不存在", "整合設定", "Iconx"
        return
    }

    if sendEnabledVal {
        if (hostVal = "" || portVal = "" || userVal = "" || passVal = "" || fromVal = "" || toVal = "") {
            MsgBox "郵件欄位不可空白：smtp_host/smtp_port/smtp_user/smtp_pass/from/to", "整合設定", "Iconx"
            return
        }
        if !(portVal ~= "^\d+$") {
            MsgBox "smtp_port 必須是數字", "整合設定", "Iconx"
            return
        }
    }

    IniWrite okwwPath, st.cfgPath, "paths", "OKWW"
    IniWrite "1", st.cfgPath, "flags", "OKWW_remember"
    IniWrite lrmcPath, st.cfgPath, "paths", "LRMC"
    IniWrite "1", st.cfgPath, "flags", "LRMC_remember"
    IniWrite wuPath, st.cfgPath, "paths", "WUTHERING"
    IniWrite "1", st.cfgPath, "flags", "WUTHERING_remember"

    IniWrite fallbackLogVal, st.cfgPath, "reward_monitor", "fallback_log_file"

    IniWrite hostVal, st.cfgPath, st.section, "smtp_host"
    IniWrite portVal, st.cfgPath, st.section, "smtp_port"
    IniWrite userVal, st.cfgPath, st.section, "smtp_user"
    IniWrite passVal, st.cfgPath, st.section, "smtp_pass"
    IniWrite fromVal, st.cfgPath, st.section, "from"
    IniWrite toVal, st.cfgPath, st.section, "to"
    IniWrite (prefixVal = "" ? "LRMCAI" : prefixVal), st.cfgPath, st.section, "subject_prefix"
    IniWrite sslVal, st.cfgPath, st.section, "use_ssl"
    IniWrite sendEnabledVal, st.cfgPath, st.section, "send_enabled"
    MAIL_NOTIFY_ENABLED := sendEnabledVal

    __MAIL_SETUP.saved := true
    __MAIL_SETUP.done := true
    st.gui.Destroy()
}

OnSendEnabledChanged(*) {
    RefreshMailInputsEnabled()
}

RefreshMailInputsEnabled() {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    enabled := __MAIL_SETUP.cbSendEnabled.Value ? true : false
    __MAIL_SETUP.edHost.Enabled := enabled
    __MAIL_SETUP.edPort.Enabled := enabled
    __MAIL_SETUP.edUser.Enabled := enabled
    __MAIL_SETUP.edPass.Enabled := enabled
    __MAIL_SETUP.edFrom.Enabled := enabled
    __MAIL_SETUP.edTo.Enabled := enabled
    __MAIL_SETUP.edPrefix.Enabled := enabled
    __MAIL_SETUP.ddSsl.Enabled := enabled
    __MAIL_SETUP.txtMailHint.Value := enabled ? "目前啟用寄信：需填寫 SMTP 欄位" : "目前停用寄信：可略過 SMTP 欄位"
}

LoadMailNotifyEnabled() {
    global CFG_FILE, MAIL_SECTION, MAIL_NOTIFY_ENABLED
    MAIL_NOTIFY_ENABLED := ParseBool01(IniReadSafe(CFG_FILE, MAIL_SECTION, "send_enabled", "1"), 1)
    WriteLog("郵件通知開關(send_enabled)=" MAIL_NOTIFY_ENABLED)
}

ParseBool01(val, defaultVal := 1) {
    s := StrLower(Trim(val, " `t`r`n"))
    if (s = "")
        return defaultVal
    if (s = "1" || s = "true" || s = "yes" || s = "on")
        return 1
    if (s = "0" || s = "false" || s = "no" || s = "off")
        return 0
    return defaultVal
}

SetupTrayMenu() {
    try {
        A_TrayMenu.Delete("開啟設定 UI")
    }

    A_TrayMenu.Add("開啟設定 UI", OpenSettingsFromTray)
    A_TrayMenu.Add()
}

OpenSettingsFromTray(*) {
    global CFG_FILE, MAIL_SECTION

    WriteLog("使用者由系統匣開啟設定 UI")
    state := ReadCombinedConfigState()
    ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, "由系統匣手動開啟設定")
    if ok {
        LoadMailNotifyEnabled()
        WriteLog("系統匣設定已儲存")
        ShowTip("✅ 設定已儲存", 1200)
    } else {
        WriteLog("系統匣設定已取消", "WARN")
        ShowTip("⚠️ 已取消設定", 1200)
    }
}

OnCombinedSetupCancel(*) {
    global __MAIL_SETUP
    __MAIL_SETUP.saved := false
    __MAIL_SETUP.done := true
    try __MAIL_SETUP.gui.Destroy()
}

OnCombinedSetupClose(*) {
    global __MAIL_SETUP
    __MAIL_SETUP.saved := false
    __MAIL_SETUP.done := true
}

SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl := "1") {
    psFile := A_Temp "\send_mail_main_" A_TickCount ".ps1"
    errFile := A_Temp "\send_mail_main_err_" A_TickCount ".txt"

    escHost := PsEsc(smtpHost)
    escUser := PsEsc(smtpUser)
    escPass := PsEsc(smtpPass)
    escFrom := PsEsc(mailFrom)
    escTo := PsEsc(mailTo)
    escSubject := PsEsc(subject)
    escBody := PsEsc(body)

    script := "$ErrorActionPreference = 'Stop'`n"
    script .= "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12`n"
    script .= "$smtpHost = '" escHost "'`n"
    script .= "$smtpPort = " smtpPort "`n"
    script .= "$smtpUser = '" escUser "'`n"
    script .= "$smtpPass = '" escPass "'`n"
    script .= "$mailFrom = '" escFrom "'`n"
    script .= "$mailTo = '" escTo "'`n"
    script .= "$subject = '" escSubject "'`n"
    script .= "$body = '" escBody "'`n"
    script .= "$useSsl = " ((useSsl = "1" || StrLower(useSsl) = "true") ? "$true" : "$false") "`n"
    script .= "try {`n"
    script .= "  $msg = New-Object System.Net.Mail.MailMessage`n"
    script .= "  $msg.From = $mailFrom`n"
    script .= "  $msg.To.Add($mailTo)`n"
    script .= "  $msg.Subject = $subject`n"
    script .= "  $msg.Body = $body`n"
    script .= "  $msg.BodyEncoding = [System.Text.Encoding]::UTF8`n"
    script .= "  $msg.SubjectEncoding = [System.Text.Encoding]::UTF8`n"
    script .= "  $smtp = New-Object System.Net.Mail.SmtpClient($smtpHost, $smtpPort)`n"
    script .= "  $smtp.UseDefaultCredentials = $false`n"
    script .= "  $smtp.EnableSsl = $useSsl`n"
    script .= "  $smtp.Credentials = New-Object System.Net.NetworkCredential($smtpUser, $smtpPass)`n"
    script .= "  $smtp.Send($msg)`n"
    script .= "  exit 0`n"
    script .= "} catch {`n"
    script .= "  $m = $_.Exception.Message`n"
    script .= "  if ($_.Exception.InnerException) { $m += ' | Inner: ' + $_.Exception.InnerException.Message }`n"
    script .= "  Write-Output $m`n"
    script .= "  exit 1`n"
    script .= "}`n"

    try FileDelete(psFile)
    try FileDelete(errFile)
    FileAppend(script, psFile, "UTF-8")

    cmd := 'powershell -NoProfile -ExecutionPolicy Bypass -File "' psFile '" > "' errFile '" 2>&1'
    exitCode := RunWait(cmd, , "Hide")

    errMsg := ""
    try errMsg := Trim(FileRead(errFile, "UTF-8"), "`r`n`t ")
    if (errMsg = "")
        try errMsg := Trim(FileRead(errFile), "`r`n`t ")

    try FileDelete(psFile)
    try FileDelete(errFile)

    if (exitCode = 0)
        return { ok: true, message: "" }

    if (errMsg = "")
        errMsg := "PowerShell SMTP 呼叫失敗，ExitCode=" exitCode
    return { ok: false, message: errMsg }
}

PsEsc(text) {
    return StrReplace(text, "'", "''")
}
