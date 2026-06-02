#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir
global BUNDLED_AHK_EXE := ResolveBundledAhkExe()

; 🛡️ 自動提權
if !A_IsAdmin {
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
global RUN_START_TS := A_Now
global STEP_SEQ := 0
global TOOLTIP_SLOT := 1
global TOOLTIP_UNTIL_TICK := 0
global TOOLTIP_CONTENT := ""

; 收尾監測設定（命中兩條「電台_一鍵領取」後延遲關閉）
global REWARD_LOG_FILE := "D:\LRMCAI\log\LRMCAI.log"
global REWARD_START_DELAY_MS := 60000
global REWARD_CHECK_INTERVAL_MS := 3000
global REWARD_SHUTDOWN_DELAY_MS := 5000
global REWARD_MATCH_NEED_COUNT := 2
global REWARD_INVALID_HWND_NEED_COUNT := 6
global REWARD_LRMCAI_RESTART_COOLDOWN_MS := 15000
global MAIL_NOTIFY_ENABLED := 1
global MAIL_SECTION := "mail_notify"
global SCREEN_RECORDING_ENABLED := 0
global SCREEN_RECORDING_SECTION := "screen_recording"
global SCREEN_RECORDING_ENGINE := "ffmpeg"
global SCREEN_RECORDING_FFMPEG_EXE := ""
global SCREEN_RECORDING_FFMPEG_ARGS := "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p"
global SCREEN_RECORDING_OUTPUT_DIR := "recordings"
global SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK := 1
global SCREEN_RECORDING_STOP_MODE := "exit"
global SCREEN_RECORDING_STOP_TEMPLATE := "login"
global SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM := ""
global SCREEN_RECORDING_STOP_LRMC_TASK := ""
global __SCREEN_RECORDING_ACTIVE := false
global __SCREEN_RECORDING_PID := 0
global __SCREEN_RECORDING_OUTPUT_PATH := ""
global __SCREEN_RECORDING_TEMPLATE_WARNED := false
global __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := false
global __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := 0
global __RESTART_IN_PROGRESS := false
global __NEXTSERVER_RESTART := false
global __MAIL_SETUP := ""
global __SERVER_PREVIEW := ""
global __WUTHERING_AUDIO_MUTED := false
global __WUTHERING_MUTE_PENDING := false
global WUTHERING_PROCESS_EXE := "Client-Win64-Shipping.exe"
global LAST_RESTART_REASON := ""
global PROCESS_DETECT_RETRY_COUNT := 6
global PROCESS_DETECT_RETRY_DELAY_MS := 800
global WUTHERING_STARTUP_WAIT_SEC := 45
global WUTHERING_UPDATE_RECOVERY_WAIT_SEC := 120
global WUTHERING_NO_WINDOW_TOLERANCE := 3
global WUTHERING_NO_WINDOW_RESTART_SEC := 180
global SERVER_SCHEDULE_ENABLED := false
global SERVER_SCHEDULE_LIST := []
global SERVER_SCHEDULE_INDEX := 1
global CURRENT_SERVER_TARGET := ""
global SERVER_SWITCH_POINT_X := 640
global SERVER_SWITCH_POINT_Y := 549
global LRMCAI_FLOW_STARTED := false
global SERVER_COMPLETED_CYCLE_MAP := Map()  ; 記錄各伺服器在當日循環的完成狀態

; 保底：任何方式離開腳本時都嘗試恢復聲音
OnExit(RestoreWutheringAudioOnExit)

; 提示工具（開頭加5個空白避免被滑鼠遮擋）
ShowTip(msg, duration := 5000) {
    global TOOLTIP_SLOT, TOOLTIP_UNTIL_TICK, TOOLTIP_CONTENT
    if (duration < 5000)
        duration := 5000
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

FindBundledFfmpegExe() {
    candidates := []
    candidates.Push(A_ScriptDir "\\tools\\ffmpeg\\bin\\ffmpeg.exe")
    candidates.Push(A_ScriptDir "\\ffmpeg\\bin\\ffmpeg.exe")
    candidates.Push(A_ScriptDir "\\plugin\\ffmpeg\\bin\\ffmpeg.exe")
    candidates.Push(A_ScriptDir "\\ffmpeg.exe")

    for _, candidate in candidates {
        p := NormalizePath(candidate)
        if (p != "" && FileExist(p))
            return p
    }
    return ""
}

ResolveDefaultScreenRecordingFfmpegExe() {
    bundled := FindBundledFfmpegExe()
    if (bundled != "")
        return bundled
    return "ffmpeg"
}

ResolveScreenRecordingFfmpegExePath(configuredValue := "") {
    raw := NormalizePath(configuredValue)
    if (raw = "")
        raw := SCREEN_RECORDING_FFMPEG_EXE
    raw := NormalizePath(raw)

    if (raw = "" || raw = "ffmpeg" || raw = "ffmpeg.exe") {
        bundled := FindBundledFfmpegExe()
        return (bundled != "") ? bundled : "ffmpeg"
    }

    if RegExMatch(raw, "i)^[a-z]:\\")
        return raw
    if (SubStr(raw, 1, 2) = "\\\\")
        return raw

    candidate := A_ScriptDir "\\" raw
    if FileExist(candidate)
        return candidate
    return raw
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
    global __RESTART_IN_PROGRESS, __NEXTSERVER_RESTART
    if (!__RESTART_IN_PROGRESS || __NEXTSERVER_RESTART)
        TryStopScreenRecording("腳本結束保底")
    else
        WriteLog("重啟模式：保留錄影不中斷，略過結束保底停止", "WARN")
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
    ShowTip("📌 " stepName)
}

WriteStepResult(stepName, ok, detail := "") {
    level := ok ? "INFO" : "WARN"
    status := ok ? "成功" : "失敗"
    WriteStep(stepName, status (detail != "" ? " | " detail : ""), level)
}

WriteLog("全自動腳本啟動: " A_ScriptFullPath)
WriteStep("啟動", "PID=" DllCall("GetCurrentProcessId") " AHK=" A_AhkVersion)

; 鍵盤更穩
SendMode "Input"
SetKeyDelay 40, 40



; === 使用啟動器解壓的位置 ===
; 現在 AutoHotkey64.exe 位於工作目錄的上層（自動鋤地資料夾）
AhkExe := BUNDLED_AHK_EXE
WriteLog("嘗試使用 AutoHotkey: " AhkExe)
if !FileExist(AhkExe) {
    WriteLog("找不到任何 AutoHotkey 執行檔: " AhkExe, "ERROR")
    MsgBox "找不到 AutoHotkey64.exe：`n" AhkExe "`n請先執行「打包啟動器」完成解壓。"
    ExitApp
}
WriteLog("成功找到 AutoHotkey: " AhkExe)

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
LoadScreenRecordingEnabled()
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
isNextServerCycle := false
global CRASH_RESTART_MODE := false
if A_Args.Length > 0 && A_Args[1] = "restart" {
    isRestart := true
    WriteLog("檢測到重啟模式，遊戲更新後將重新啟動OKWW")
    prevReason := Trim(IniReadSafe(CFG_FILE, "restart_tracking", "last_restart_reason", ""), " `t`r`n")
    prevTime := Trim(IniReadSafe(CFG_FILE, "restart_tracking", "last_restart_time", ""), " `t`r`n")
    if (prevReason != "") {
        detail := prevReason
        if (prevTime != "")
            detail .= " @ " prevTime
        WriteStep("上次重啟原因", detail, "WARN")
    }
}

if A_Args.Length > 1 && A_Args[1] = "restart" && A_Args[2] = "crash" {
    CRASH_RESTART_MODE := true
    WriteLog("檢測到崩潰重啟模式，LRMCAI 將使用快捷鍵啟動")
}

isNextServerCycle := false
if A_Args.Length > 0 && A_Args[1] = "nextserver" {
    isNextServerCycle := true
    WriteLog("檢測到伺服器排程續跑模式，將沿用下一個伺服器索引")
}

if (!isRestart && !isNextServerCycle)
    ResetRestartTrackingOnFreshStart()

LoadServerScheduleContext(isNextServerCycle)

if MAIL_NOTIFY_ENABLED {
    startMailResult := SendStartNotifyMail()
    if startMailResult.ok
        WriteLog("開始通知信已寄出")
    else
        WriteLog("開始通知信寄送失敗: " startMailResult.message, "WARN")
}

; 1) 先處理鳴潮更新／登入，OKWW 之後再啟動
maxUpdateLoops := 3
updateLoops := 0
loginDetected := false
okwwStarted := false
updateRecoveryActive := false
updateRecoveryStartTick := 0
noWindowLoopCount := 0
noWindowSinceTick := 0

if !isRestart
    TryStartScreenRecording("主流程開始")
else
    WriteLog("重啟模式：保留既有錄影，不重新觸發 Alt+F9")
EnsureWutheringRunning()
WriteStep("鳴潮檢查", "更新與登入流程")

loop {
    loginDetected := false
    detectState := DetectWutheringAndExit(&loginDetected)
    if (detectState = "update") {
        updateLoops++
        WriteLog("偵測到鳴潮更新，等待遊戲自動重啟後再次檢測 (" updateLoops "/" maxUpdateLoops ")")

        ; 啟用更新後恢復追蹤：若後續長時間 no_window，就主動重跑啟動流程。
        updateRecoveryActive := true
        updateRecoveryStartTick := A_TickCount
        Sleep 8000

        if (updateLoops >= maxUpdateLoops) {
            WriteLog("鳴潮更新檢測達上限，停止自動迴圈，繼續後續流程", "WARN")
            break
        }
        continue
    }

    if (detectState = "no_window") {
        noWindowLoopCount += 1
        if (noWindowSinceTick = 0)
            noWindowSinceTick := A_TickCount

        if (updateRecoveryActive) {
            elapsedSec := Floor((A_TickCount - updateRecoveryStartTick) / 1000)
            if (elapsedSec >= WUTHERING_UPDATE_RECOVERY_WAIT_SEC) {
                WriteLog("更新後等待 " WUTHERING_UPDATE_RECOVERY_WAIT_SEC " 秒仍抓不到鳴潮視窗，執行完整重啟流程", "ERROR")
                ShowTip("⚠️ 更新後超時未啟動，完整重啟流程", 2200)
                RequestRestart("遊戲更新後點擊確認，等待2分鐘仍未啟動（疑似閃退/當機）")
                return
            }
            WriteLog("更新後恢復等待中（" elapsedSec "/" WUTHERING_UPDATE_RECOVERY_WAIT_SEC " 秒），暫不重啟", "WARN")
        }

        elapsedNoWindowSec := Floor((A_TickCount - noWindowSinceTick) / 1000)
        if (elapsedNoWindowSec >= WUTHERING_NO_WINDOW_RESTART_SEC) {
            WriteLog("鳴潮長時間 no_window（" elapsedNoWindowSec " 秒），判定當機/閃退，執行完整重啟", "ERROR")
            ShowTip("❌ 鳴潮長時間無視窗，完整重啟流程", 2200)
            RequestRestart("鳴潮長時間無視窗（疑似閃退/當機）")
            return
        }

        WriteLog("鳴潮視窗尚未就緒（no_window），等待後重試（連續=" noWindowLoopCount "，累計=" elapsedNoWindowSec " 秒）", "WARN")
        Sleep 3000
        continue
    }

    noWindowLoopCount := 0
    noWindowSinceTick := 0

    if (detectState = "unknown") {
        WriteLog("鳴潮狀態尚未明確（unknown），不提前判定登入", "WARN")
    }

    updateRecoveryActive := false
    break
}

; 登入畫面時：先做伺服器切換（如有設定），再交由 OKWW 接手點擊流程
serverSwitchOk := true
if (loginDetected) {
    hwndLogin := GetWutheringGameHwnd()
    if !hwndLogin {
        hwndLogin := WaitForWutheringGameWindow(20)
    }

    ; 先切換伺服器，再啟動 OKWW。
    if hwndLogin {
        serverSwitchOk := TrySelectScheduledServer(hwndLogin)
        if !serverSwitchOk
            WriteLog("伺服器切換未完成，將停止本輪避免誤進錯服", "WARN")
    } else {
        serverSwitchOk := false
        WriteLog("伺服器切換未完成：找不到鳴潮登入視窗", "WARN")
    }

    if !serverSwitchOk {
        WriteLog("伺服器切換失敗（重試後仍未成功），改由 OKWW 繼續後續流程", "WARN")
        ShowTip("⚠️ 切服失敗，交由 OKWW 繼續", 1200)
    }

    WriteLog("登入畫面階段啟動 OKWW，後續點擊改由 OKWW 接手")
    ClickTemplateIfFound(A_ScriptDir "\0510.png")
    ClickTemplateIfFound(A_ScriptDir "\登入.png")
    StartOKWWFlow(isRestart)
    okwwStarted := true
    WriteLog("檢測到登入畫面後不再由全自動點擊遊戲視窗，等待 OKWW 執行")
    Sleep 3000
}

; 2) 登入後啟動 OKWW 並確認啟動成功
if !okwwStarted {
    WriteLog("遊戲可操作驗證通過前，不提前宣告登入完成")
}

; 3) 用主畫面模板比對驗證遊戲是否可操作（去抖動）
gameHwnd := GetWutheringGameHwnd()
WriteLog("開始主畫面模板驗證（最多 90 秒）...")
if !WaitEscMenuOCR(gameHwnd, 90) {
    WriteLog("鳴潮無法使用或超時，觸發重啟機制", "ERROR")
    ShowTip("⚠️ 鳴潮無法使用，重新啟動...", 3000)
    Sleep 3000
    RequestRestart("遊戲可操作驗證超時或失敗")
    return
}
WriteStep("遊戲可操作驗證", "模板比對通過")

; 4) 只有在可操作驗證通過後，才啟動 OKWW（避免過早啟動）
if !okwwStarted {
    WriteLog("遊戲已可操作，開始啟動 OKWW...")
    WriteStep("啟動OKWW", isRestart ? "重啟模式" : "一般模式")
    ClickTemplateIfFound(A_ScriptDir "\0510.png")
    ClickTemplateIfFound(A_ScriptDir "\登入.png")
    StartOKWWFlow(isRestart)
    okwwStarted := true
}

; 5) 執行聲骸合成流程
WriteLog("啟動聲骸合成腳本...")
WriteStep("啟動聲骸合成", "等待完成或重啟標記")
ShowTip("🔧 正在執行聲骸合成...", 1500)
; 額外等待確保OKWW啟動後鳴潮完全穩定
WriteLog("等待OKWW初始化完成，確保遊戲穩定...")
Sleep 20000  ; 再等20秒，確保鳴潮完全穩定
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
            TryStopScreenRecordingByMode("synthesis_end")
            
            ; 檢查是否有重啟標記
            flagFile := dataDir "\synthesis_restart.flag"
            if FileExist(flagFile) {
                WriteLog("偵測到聲骸合成要求重啟，刪除標記並觸發重啟機制", "WARN")
                try FileDelete(flagFile)
                Sleep 2000
                RequestRestart("聲骸合成回報重啟旗標 synthesis_restart.flag", "WARN")
                return
            }
            break
        }

        TryStopScreenRecordingByTemplate()
        
        Sleep 2000  ; 每2秒檢查一次
    }
    
    if (A_TickCount - startTime >= maxWaitTime) {
        WriteLog("聲骸合成超時，觸發重啟機制", "ERROR")
        ShowTip("⚠️ 聲骸合成超時，重新啟動...", 3000)
        Sleep 3000
        RequestRestart("聲骸合成流程超時")
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
LRMCAI_FLOW_STARTED := true
lrmcCmd := '"' AhkExe '" "' A_ScriptDir '\開啟LRMC.ahk"'
if (CRASH_RESTART_MODE)
    lrmcCmd .= ' hotkey'
Run(lrmcCmd)
ShowTip("🟢 已啟動 LRMC 管理腳本", 3000)


; 成功完成流程，重置重啟計數器
IniWrite "0", CFG_FILE, "restart_tracking", "auto_restart_count"
WriteLog("流程成功完成，已重置重啟計數器")
WriteStep("主流程完成", "重啟計數已歸零")

; 新增：標記當前伺服器為已完成
global CURRENT_SERVER_TARGET, SERVER_SCHEDULE_ENABLED
if (SERVER_SCHEDULE_ENABLED && CURRENT_SERVER_TARGET != "") {
    MarkServerCompletedInCurrentCycle(CURRENT_SERVER_TARGET)
}

WriteLog("全自動流程完成，進入收尾監測（等待電台一鍵領取達標）")
WriteStep("收尾監測", "等待電台一鍵領取條件")
MonitorRewardAndShutdown()
ExitApp


; ======================== 函式區 ========================

; ★ OKWW 啟動＋前置流程（啟動 → 等待 → F11 → 最小化）
StartOKWWFlow(isRestart) {
    WriteStep("OKWW流程", "入口 isRestart=" (isRestart ? "1" : "0"))
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
            WriteStepResult("OKWW流程", false, "激活視窗失敗")
        }
    } else {
        WriteLog("無法找到 OKWW 視窗，跳過啟動", "WARN")
        WriteStepResult("OKWW流程", false, "找不到 OKWW 視窗")
    }
    
    Sleep 1000
    MinimizeOKWWWindows()
    WriteStepResult("OKWW流程", true, "已完成啟動與最小化")
}

; ★ 最小化 OKWW 視窗
MinimizeOKWWWindows() {
    WriteStep("最小化OKWW", "入口")
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
        WriteStepResult("最小化OKWW", true, "count=" foundCount)
    } else {
        WriteLog("未找到可最小化的 OKWW 視窗", "WARN")
        WriteStepResult("最小化OKWW", false, "count=0")
    }
}

; ★ 啟動前檢測：關閉所有目標程式
CheckAndCloseExistingProcesses() {
    WriteStep("清場流程", "入口：檢測並關閉既有進程")
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
        WriteStepResult("清場流程", true, "已有進程已清理")
    } else {
        WriteLog("沒有檢測到運行中的目標程式，可以開始主流程")
        WriteStepResult("清場流程", true, "無需清理")
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

        ; 以 AhkExe 重新啟動整支腳本。
        ; 僅在 LRMCAI 已啟動後發生崩潰時，才帶 crash 參數進入快捷鍵模式。
        global AhkExe
        restartCmd := '"' AhkExe '" "' A_ScriptFullPath '" restart'
        if ShouldUseCrashRestartHotkey("UE4-Client 崩潰重啟")
            restartCmd .= ' crash'
        Run(restartCmd)
        ExitApp
    } finally busy := false
}

; A) 更新彈窗偵測（簡體關鍵詞）＋ OCR 算出【退出】中心點點擊
;    進入前：把鳴潮視窗貼齊右上角
DetectWutheringAndExit(&loginDetected := false) {
    global WUTHERING_NO_WINDOW_TOLERANCE

    WriteStep("鳴潮檢測", "入口：更新/登入畫面辨識")

    loginDetected := false
    SetTitleMatchMode 2
    hwnd := WaitForWutheringGameWindow(120)
    if !hwnd {
        ShowTip("找不到「Client-Win64-Shipping.exe」遊戲視窗（逾時）。", 1200)
        WriteStepResult("鳴潮檢測", false, "no_window")
        return "no_window"
    }

    ; 視窗移動策略：先偵測到穩定目標視窗，再開始持續重試移動。
    movedTopRight := false
    nextMoveRetryTick := A_TickCount
    foundTargetWindow := false
    stableWindowHit := 0

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
    noWindowStreak := 0

    while (A_TickCount < deadline) {
        hwnd := GetWutheringGameHwnd()
        if !hwnd {
            stableWindowHit := 0

            ; 尚未真正抓到目標視窗前，不做 no_window 累計，避免啟動初期誤判。
            if !foundTargetWindow {
                Sleep 500
                continue
            }

            noWindowStreak += 1
            if (noWindowStreak >= WUTHERING_NO_WINDOW_TOLERANCE) {
                WriteLog("檢測途中連續 " noWindowStreak " 次失去鳴潮視窗，標記為 no_window", "WARN")
                WriteStepResult("鳴潮檢測", false, "no_window_streak=" noWindowStreak)
                return "no_window"
            }
            WriteLog("檢測途中短暫找不到鳴潮視窗（" noWindowStreak "/" WUTHERING_NO_WINDOW_TOLERANCE "），等待後重試", "WARN")
            Sleep 1200
            continue
        }
        noWindowStreak := 0
        stableWindowHit += 1
        if !foundTargetWindow {
            foundTargetWindow := true
            WriteLog("已找到目標鳴潮視窗，開始準備移動到右上角")
        }

        ; 需要連續命中至少 2 次同類視窗，才開始移動，降低初始化中假視窗干擾。
        if (!movedTopRight && stableWindowHit >= 2 && A_TickCount >= nextMoveRetryTick) {
            okMove := false
            try okMove := MoveWindowTopRight(hwnd, 0, 0)
            catch as e {
                WriteLog("視窗移動失敗（非致命）: " e.Message, "WARN")
                okMove := false
            }

            if okMove {
                movedTopRight := true
                WriteLog("視窗已固定在右上角，後續不再重試移動")
            } else {
                nextMoveRetryTick := A_TickCount + 1500
            }
        }

        ; 首先用模板檢測叉叉按鈕（不涉及 OCR，更快速）
        closeIconPath := A_ScriptDir "\0510.png"
        if FileExist(closeIconPath) {
            try {
                ImageSearch &foundX, &foundY, 0, 0, 1920, 1440, closeIconPath
                if (foundX > 0 && foundY > 0) {
                    ShowTip("✅ 檢測到叉叉提示 → 自動點擊", 800)
                    MouseClick "left", foundX, foundY
                    WriteLog("已點擊叉叉按鈕 位置:" foundX "," foundY, "INFO")
                    Sleep 1000
                    continue
                }
            } catch as e {
                WriteLog("模板檢測叉叉失敗: " e.Message, "WARN")
            }
        }

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
            WriteStepResult("鳴潮檢測", true, "update")
            return "update"
        }
        
        
        ; ✅ 優化：檢測到登入按鈕相關文字，且超過最小等待時間（30秒）才判定為登入畫面
        if (foundLoginBtn && A_TickCount >= earlyExitDeadline) {
            loginDetected := true
            WriteLog("✅ 檢測到登入畫面（已超過 30 秒啟動時間，找到登入按鈕關鍵字），無需更新，繼續正常流程")
            MuteWutheringAudioAtStartup()
            TryMuteWutheringAudio("檢測到登入畫面後")
            ShowTip("✅ 檢測到登入畫面，無需更新", 1000)
            WriteStepResult("鳴潮檢測", true, "login(btn)")
            return "login"
        }
        
        ; 如果只find到登入UI但沒找到按鈕，也要等待足夠時間再判定
        if (foundLoginUI && A_TickCount >= earlyExitDeadline + 10000) {
            loginDetected := true
            WriteLog("⚠️ 檢測到登入UI（伺服器/賬號相關），判定為登入畫面，繼續")
            MuteWutheringAudioAtStartup()
            TryMuteWutheringAudio("檢測到登入UI後")
            ShowTip("✅ 檢測到登入畫面UI，無需更新", 1000)
            WriteStepResult("鳴潮檢測", true, "login(ui)")
            return "login"
        }
        
        Sleep 900
    }

    ShowTip("未檢測到更新或登入畫面，回傳 unknown。", 900)
    WriteStepResult("鳴潮檢測", false, "unknown")
    return "unknown"
}

; B) 去抖動主畫面模板比對（右下 ROI）
WaitEscMenuOCR(hwnd, timeoutSec := 120) {
    WriteStep("主畫面模板驗證", "入口 timeout=" timeoutSec "s")
    oldPixelMode := A_CoordModePixel
    CoordMode "Pixel", "Screen"

    if !hwnd {
        hwnd := GetWutheringGameHwnd()
        if !hwnd {
            CoordMode "Pixel", oldPixelMode
            WriteStepResult("主畫面模板驗證", false, "無有效視窗")
            return false
        }
    }

    templateFile := A_ScriptDir "\icon_main.png"

    if !FileExist(templateFile) {
        WriteLog("模板驗證失敗：找不到模板檔 " templateFile, "WARN")
        CoordMode "Pixel", oldPixelMode
        WriteStepResult("主畫面模板驗證", false, "模板不存在")
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
                CoordMode "Pixel", oldPixelMode
                WriteStepResult("主畫面模板驗證", true, "樣本=" sampleCount " var=" matchedVar)
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
    WriteStepResult("主畫面模板驗證", false, "超時樣本=" sampleCount)
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
    global WUTHERING_STARTUP_WAIT_SEC

    WriteStep("啟動鳴潮", "入口")

    ; ✅ 只檢查遊戲進程是否存在，不檢查視窗尺寸
    ;    這樣防止因視窗最小化而誤判為「遊戲未運行」
    if (IsWutheringProcessRunning()) {
        WriteStepResult("啟動鳴潮", true, "進程已存在")
        return true
    }
    
    path := GetPathWithAsk("WUTHERING", "請選擇鳴潮遊戲主程式或捷徑", "可執行檔或捷徑 (*.exe;*.lnk)")
    if (!path) {
        WriteLog("未設定鳴潮路徑，無法啟動", "ERROR")
        MsgBox "未設定鳴潮遊戲路徑。請重新執行並選擇。"
        WriteStepResult("啟動鳴潮", false, "未設定路徑")
        ExitApp
    }
    WriteLog("啟動鳴潮: " path)
    ShowTip("🎮 正在啟動鳴潮...", 1500)
    try Run(path)
    catch as e {
        WriteLog("啟動鳴潮失敗: " e.Message, "ERROR")
        ShowTip("❌ 鳴潮啟動失敗", 1500)
        WriteStepResult("啟動鳴潮", false, "Run失敗")
        return false
    }

    ShowTip("⏳ 等待鳴潮進程初始化...", 1500)
    if !WaitForProcessRunning("Client-Win64-Shipping.exe", WUTHERING_STARTUP_WAIT_SEC) {
        WriteLog("鳴潮啟動後逾時，未偵測到進程（" WUTHERING_STARTUP_WAIT_SEC " 秒）", "ERROR")
        ShowTip("❌ 鳴潮啟動逾時", 1800)
        WriteStepResult("啟動鳴潮", false, "進程逾時")
        return false
    }

    ; 給初始化中的視窗一點緩衝，避免剛啟動就誤判 no_window。
    Sleep 2000
    WriteLog("已偵測到鳴潮進程，繼續後續視窗檢測")
    WriteStepResult("啟動鳴潮", true, "進程已就緒")
    return true
}

LaunchWutheringGameFlowAfterUpdate() {
    WriteLog("準備重新執行鳴潮啟動流程（更新後視窗逾時）")
    ShowTip("🎮 重新啟動鳴潮中...", 1500)

    try ProcessClose("Client-Win64-Shipping.exe")
    catch
        try Run("taskkill /F /IM Client-Win64-Shipping.exe", , "Hide")

    Sleep 1500
    return EnsureWutheringRunning()
}

; ✅ 只檢查遊戲進程是否存在
IsWutheringProcessRunning() {
    global PROCESS_DETECT_RETRY_COUNT, PROCESS_DETECT_RETRY_DELAY_MS

    Loop PROCESS_DETECT_RETRY_COUNT {
        hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe ahk_class UnrealWindow")
        if (hwndList.Length > 0)
            return true

        hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe")
        if (hwndList.Length > 0)
            return true

        if (A_Index < PROCESS_DETECT_RETRY_COUNT)
            Sleep PROCESS_DETECT_RETRY_DELAY_MS
    }

    return false
}

WaitForProcessRunning(exeName, timeoutSec := 30) {
    deadline := A_TickCount + timeoutSec * 1000
    while (A_TickCount < deadline) {
        if ProcessExist(exeName)
            return true

        ; 有些遊戲在初始化期間會先有視窗再穩定到指定 exe，這裡一起判斷。
        if (exeName = "Client-Win64-Shipping.exe") {
            hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe")
            if (hwndList.Length > 0)
                return true
        }

        Sleep 500
    }

    return false
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

        ; 遊戲初始化期間可能重建視窗，舊 hwnd 會瞬間失效，先重新校驗一次。
        if !WinExist("ahk_id " hwnd) {
            newHwnd := GetWutheringGameHwnd()
            if newHwnd {
                WriteLog("原視窗句柄失效，改用新句柄: " newHwnd, "WARN")
                hwnd := newHwnd
            } else {
                WriteLog("目前找不到可用鳴潮視窗句柄，稍後重試", "WARN")
                if (attempt < 3) {
                    Sleep 500
                    continue
                }
                return false
            }
        }
        
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

            wa := GetWorkArea()
            maxW := wa.width - marginX
            maxH := wa.height - marginY
            newW := (w > maxW) ? maxW : w
            newH := (h > maxH) ? maxH : h

            newX := wa.right - newW - marginX  ; 貼齊工作區右側
            newY := wa.top + marginY           ; 貼齊工作區上側
            
            WriteLog("移動視窗: 從 (" x "," y "," w "," h ") 到 (" newX "," newY "," newW "," newH ")")
            WinMove(newX, newY, newW, newH, "ahk_id " hwnd)
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
            if InStr(e.Message, "Target window not found") {
                newHwnd := GetWutheringGameHwnd()
                if newHwnd {
                    WriteLog("移動時句柄失效，重抓新句柄後重試: " newHwnd, "WARN")
                    hwnd := newHwnd
                }
            }
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

; ======================== 伺服器完成記錄機制 ========================

; 判斷兩個時間是否在同一日循環（上午4點～隔天上午4點）
IsSameDayCircle(time1Str, time2Str) {
    ; 解析時間字串 "yyyy-MM-dd HH:mm:ss"
    if (time1Str = "" || time2Str = "")
        return false

    try {
        ; 轉換為分鐘數（以上午4點為循環起點）
        GetDayCircleMinutes(t) {
            parts := StrSplit(t, A_Space)
            if (parts.Length < 2)
                return -1
            
            timeParts := StrSplit(parts[2], ":")
            if (timeParts.Length < 2)
                return -1
            
            hour := Integer(timeParts[1])
            minute := Integer(timeParts[2])
            
            ; 上午4點前（0-3點）算上一天的循環
            if (hour < 4) {
                ; 換算成分鐘，並加上前一天24小時
                return (hour * 60 + minute) + 1440
            } else {
                ; 正常換算
                return hour * 60 + minute
            }
        }
        
        min1 := GetDayCircleMinutes(time1Str)
        min2 := GetDayCircleMinutes(time2Str)
        
        if (min1 < 0 || min2 < 0)
            return false
        
        ; 判斷兩個時間是否在同一天
        parts1 := StrSplit(time1Str, A_Space)
        parts2 := StrSplit(time2Str, A_Space)
        
        date1 := parts1[1]
        date2 := parts2[1]
        
        ; 如果日期相同，直接算同一循環
        if (date1 = date2)
            return true
        
        ; 日期不同，檢查是否跨越上午4點
        ; 例：4月1日3點59分 和 4月2日4點01分 不在同一循環
        ; 但 4月2日3點59分 和 4月1日8點00分 在同一循環
        
        ; 簡化：比較 time1 的分鐘數和 time2 的分鐘數
        ; 如果 time1 是 >= 1440（即前一天的0-3點），time2 也是 >= 1440，則同循環
        ; 或都 < 1440，則同循環
        return ((min1 >= 1440 && min2 >= 1440) || (min1 < 1440 && min2 < 1440))
    } catch as e {
        WriteLog("IsSameDayCircle 時間判斷失敗: " e.Message, "WARN")
        return false
    }
}

; 檢查伺服器是否在當日循環已完成
IsServerCompletedInCurrentCycle(server, currentTime := "") {
    global SERVER_COMPLETED_CYCLE_MAP, CFG_FILE
    
    if (server = "")
        return false
    
    if (currentTime = "")
        currentTime := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    
    ; 首先檢查內存 Map
    if SERVER_COMPLETED_CYCLE_MAP.Has(server) {
        completedTime := SERVER_COMPLETED_CYCLE_MAP[server]
        if (completedTime != "") {
            if IsSameDayCircle(completedTime, currentTime) {
                WriteLog("伺服器『" server "』已在當日循環完成過（完成於 " completedTime "）", "INFO")
                return true
            } else {
                WriteLog("伺服器『" server "』的完成時間不在當日循環（完成於 " completedTime "）", "INFO")
                return false
            }
        }
    }
    
    ; 檢查設定檔
    savedTime := Trim(IniReadSafe(CFG_FILE, "server_completed", server, ""), " `t`r`n")
    if (savedTime != "") {
        if IsSameDayCircle(savedTime, currentTime) {
            SERVER_COMPLETED_CYCLE_MAP[server] := savedTime
            WriteLog("伺服器『" server "』已在當日循環完成過（從設定檔讀取，完成於 " savedTime "）", "INFO")
            return true
        } else {
            WriteLog("伺服器『" server "』的完成時間不在當日循環（從設定檔讀取，完成於 " savedTime "）", "INFO")
            return false
        }
    }
    
    return false
}

; 標記伺服器為當日循環已完成
MarkServerCompletedInCurrentCycle(server, completedTime := "") {
    global SERVER_COMPLETED_CYCLE_MAP, CFG_FILE
    
    if (server = "")
        return false
    
    if (completedTime = "")
        completedTime := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    
    SERVER_COMPLETED_CYCLE_MAP[server] := completedTime
    try {
        IniWrite completedTime, CFG_FILE, "server_completed", server
        WriteLog("已標記伺服器『" server "』為當日循環完成（時間: " completedTime "）", "INFO")
        return true
    } catch as e {
        WriteLog("標記伺服器『" server "』完成時寫入設定檔失敗: " e.Message, "WARN")
        return false
    }
}

RequestRestart(reason, level := "ERROR") {
    global LAST_RESTART_REASON, CRASH_RESTART_MODE

    reason := Trim(reason, " `t`r`n")
    if (reason = "")
        reason := "未提供"

    LAST_RESTART_REASON := reason
    if ShouldUseCrashRestartHotkey(reason)
        CRASH_RESTART_MODE := true
    else
        CRASH_RESTART_MODE := false
    WriteLog("觸發重啟請求，原因: " reason, level)
    RestartAutoScript(reason)
}

ShouldUseCrashRestartHotkey(reason) {
    global LRMCAI_FLOW_STARTED

    if !LRMCAI_FLOW_STARTED
        return false

    ; 僅允許「LRMCAI 已啟動後的遊戲閃退」走 hotkey 模式
    ; 來源1: UE4 崩潰監看
    ; 來源2: LRMCAI 日誌連續無效視窗控制代碼
    return RegExMatch(reason, "i)(UE4-Client|無效視窗控制代碼|LRMCAI.*閃退|遊戲閃退)")
}

; 重啟全自動腳本（帶重啟計數與重啟原因）
RestartAutoScript(reason := "") {
    global CFG_FILE, restartCount, MAX_RESTART_COUNT, LAST_RESTART_REASON, CRASH_RESTART_MODE, __RESTART_IN_PROGRESS, __NEXTSERVER_RESTART

    reason := Trim(reason, " `t`r`n")
    if (reason = "")
        reason := Trim(LAST_RESTART_REASON, " `t`r`n")
    if (reason = "")
        reason := "未提供"

    __RESTART_IN_PROGRESS := true
    __NEXTSERVER_RESTART := false
    
    ; 增加重啟計數
    restartCount++
    nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    WriteLog("準備重啟全自動腳本，第 " restartCount " 次重啟，原因: " reason, "WARN")

    ; 記錄最近一次重啟原因，供下一次啟動追蹤
    IniWrite reason, CFG_FILE, "restart_tracking", "last_restart_reason"
    IniWrite nowText, CFG_FILE, "restart_tracking", "last_restart_time"
    
    ; 檢查是否超過最大重啟次數
    if (restartCount > MAX_RESTART_COUNT) {
        WriteLog("重啟次數已達上限 (" MAX_RESTART_COUNT ")，停止重啟以避免無限循環。最後原因: " reason, "ERROR")
        ShowTip("❌ 重啟次數過多，停止執行", 5000)
        Sleep 5000
        ; 重置計數器
        IniWrite "0", CFG_FILE, "restart_tracking", "auto_restart_count"
        ExitApp
    }
    
    ; 儲存重啟計數
    IniWrite restartCount, CFG_FILE, "restart_tracking", "auto_restart_count"
    
    ; 檢查當前伺服器是否已在當日循環完成過
    global CURRENT_SERVER_TARGET, SERVER_SCHEDULE_ENABLED
    if (SERVER_SCHEDULE_ENABLED && CURRENT_SERVER_TARGET != "") {
        if IsServerCompletedInCurrentCycle(CURRENT_SERVER_TARGET) {
            WriteLog("伺服器『" CURRENT_SERVER_TARGET "』已在當日循環完成過，將跳過重新執行該伺服器，轉到下一個伺服器", "WARN")
            ShowTip("⏭️ 伺服器已完成，轉向下一個", 2000)
            Sleep 2000
            
            ; 嘗試切換到下一個伺服器
            if AdvanceServerScheduleForNextCycle() {
                WriteLog("已切換到下一個伺服器，使用 nextserver 模式重啟", "WARN")
                __NEXTSERVER_RESTART := true
                TryStopScreenRecording("切換下一個伺服器")
                CheckAndCloseExistingProcesses()
                Sleep 2000
                
                try {
                    global AhkExe
                    restartCmd := '"' AhkExe '" "' A_ScriptFullPath '" nextserver'
                    Run(restartCmd)
                    WriteLog("nextserver 重啟命令已發送")
                } catch as e {
                    WriteLog("nextserver 重啟失敗: " e.Message, "ERROR")
                }
                Sleep 1000
                ExitApp
            } else {
                WriteLog("無更多伺服器可切換，停止執行", "WARN")
                ShowTip("✅ 所有伺服器今日循環已完成", 3000)
                Sleep 3000
                ExitApp
            }
        }
    }
    
    ; 關閉所有相關進程
    WriteLog("關閉所有相關進程...")
    CheckAndCloseExistingProcesses()
    
    Sleep 3000
    
    ; 重新啟動腳本
    WriteLog("重新啟動全自動腳本...")
    try {
        global AhkExe
        restartCmd := '"' AhkExe '" "' A_ScriptFullPath '" restart'
        if (CRASH_RESTART_MODE)
            restartCmd .= ' crash'
        Run(restartCmd)
        WriteLog("重啟命令已發送")
    } catch as e {
        WriteLog("重啟失敗: " e.Message, "ERROR")
    }
    
    ; 結束當前進程
    Sleep 1000
    ExitApp
}

MonitorRewardAndShutdown() {
    global REWARD_LOG_FILE, REWARD_START_DELAY_MS, REWARD_CHECK_INTERVAL_MS, REWARD_SHUTDOWN_DELAY_MS, REWARD_MATCH_NEED_COUNT, REWARD_INVALID_HWND_NEED_COUNT

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
    invalidHwndHits := 0
    WriteLog("開始持續監測『最新新增』日誌，起始偏移: " lastPos)
    ShowTip("🧭 開始監測最新日誌...", 1200)

    loop {
        TryRecoverLrmcDuringRewardMonitor()

        chunk := ReadLogAppended(logPath, &lastPos)
        if (chunk != "") {
            for line in StrSplit(chunk, "`n") {
                line := Trim(line, "`r`t ")
                if (line = "")
                    continue

                TryStopScreenRecordingByLrmcTaskLine(line)

                if IsInvalidWindowHandleLogLine(line) {
                    invalidHwndHits += 1
                    WriteLog("監測命中『無效視窗控制代碼』累計次數: " invalidHwndHits "/" REWARD_INVALID_HWND_NEED_COUNT " | " line, "WARN")
                    if (invalidHwndHits >= REWARD_INVALID_HWND_NEED_COUNT) {
                        WriteLog("偵測到大量無效視窗控制代碼，判定為遊戲閃退，觸發重啟", "ERROR")
                        ShowTip("❌ 偵測遊戲閃退，準備重啟流程", 2500)
                        RequestRestart("LRMCAI 日誌大量無效視窗控制代碼，疑似遊戲閃退")
                        return
                    }
                }

                if (line ~= "i)(电台.*一键领取|電台.*一鍵領取)") {
                    seenClickReward := true
                    hit += 1
                    WriteLog("監測命中『電台_一鍵領取』(" hit "/" REWARD_MATCH_NEED_COUNT "): " line)
                    if (hit >= REWARD_MATCH_NEED_COUNT) {
                        delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                        WriteLog("已監測到 " REWARD_MATCH_NEED_COUNT " 條『電台_一鍵領取』，" delaySec " 秒後開始關閉流程")
                        ShowTip("✅ 監測命中，" delaySec "秒後關閉程式", 2000)
                        Sleep REWARD_SHUTDOWN_DELAY_MS
                        HandleCycleFinishAndShutdown()
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
                    HandleCycleFinishAndShutdown()
                    return
                }

                if (seenDailyRewardSuccess && seenNoReward) {
                    delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                    WriteLog("已同時監測到『領取每日獎勵成功』與『沒有獎勵能領取』，" delaySec " 秒後開始關閉流程")
                    ShowTip("✅ 監測到每日獎勵成功+無獎勵，" delaySec "秒後關閉", 2000)
                    Sleep REWARD_SHUTDOWN_DELAY_MS
                    HandleCycleFinishAndShutdown()
                    return
                }

                if (seenSolaraRewardFail && seenNoReward) {
                    delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                    WriteLog("已同時監測到『索拉獎勵領取失敗』與『沒有獎勵能領取』，" delaySec " 秒後開始關閉流程")
                    ShowTip("✅ 監測到索拉獎勵失敗+無獎勵，" delaySec "秒後關閉", 2000)
                    Sleep REWARD_SHUTDOWN_DELAY_MS
                    HandleCycleFinishAndShutdown()
                    return
                }
            }
        }
        TryStopScreenRecordingByTemplate()
        ClickTemplateIfFound(A_ScriptDir "\登入.png")
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

TryRecoverLrmcDuringRewardMonitor() {
    global REWARD_LRMCAI_RESTART_COOLDOWN_MS, __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK, AhkExe

    if ProcessExist("LRMCAI.exe") {
        __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := 0
        return false
    }

    if (__REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK > 0 && (A_TickCount - __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK) < REWARD_LRMCAI_RESTART_COOLDOWN_MS)
        return false

    if (!IsSet(AhkExe) || AhkExe = "" || !FileExist(AhkExe)) {
        WriteLog("收尾監測：LRMCAI 已退出，但找不到可用 AutoHotkey 執行檔，無法重啟", "ERROR")
        __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := A_TickCount
        return false
    }

    cmd := '"' AhkExe '" "' A_ScriptDir '\開啟LRMC.ahk" hotkey'
    try {
        Run(cmd)
        __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := A_TickCount
        WriteLog("收尾監測：偵測 LRMCAI 已退出，已用 hotkey 模式重啟（不走 OCR）", "WARN")
        ShowTip("⚠️ LRMCAI 退出，已自動 hotkey 重啟", 1200)
        return true
    } catch as e {
        __REWARD_MONITOR_LRMCAI_LAST_RESTART_TICK := A_TickCount
        WriteLog("收尾監測：LRMCAI hotkey 重啟失敗: " e.Message, "ERROR")
        return false
    }
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

IsInvalidWindowHandleLogLine(line) {
    return (line ~= "i)(無效(的)?視窗控制代碼|无效(的)?窗口控制代码|无效(的)?视窗控制代码|無效(的)?視窗句柄|无效(的)?窗口句柄|无效(的)?窗口控件句柄|invalid\s+(window\s+)?(handle|hwnd))")
}

ResetRestartTrackingOnFreshStart() {
    global CFG_FILE, restartCount, LAST_RESTART_REASON, CRASH_RESTART_MODE

    restartCount := 0
    LAST_RESTART_REASON := ""
    CRASH_RESTART_MODE := false

    IniWrite "0", CFG_FILE, "restart_tracking", "auto_restart_count"
    IniWrite "", CFG_FILE, "restart_tracking", "last_restart_reason"
    IniWrite "", CFG_FILE, "restart_tracking", "last_restart_time"
    WriteLog("正常首次啟動：已重置重啟計數器與重啟原因")
}

HandleCycleFinishAndShutdown() {
    TryStopScreenRecordingByMode("reward_end")

    if AdvanceServerScheduleForNextCycle() {
        global __NEXTSERVER_RESTART, __RESTART_IN_PROGRESS
        __RESTART_IN_PROGRESS := true
        __NEXTSERVER_RESTART := true
        TryStopScreenRecording("切換下一個伺服器")
        WriteLog("伺服器排程：本輪完成，關閉程式後自動啟動下一個伺服器流程", "WARN")
        ShutdownGameLrmcOkww(true)
        return
    }

    ShutdownGameLrmcOkww(false)
}

ShutdownGameLrmcOkww(relaunchForNextServer := false) {
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

    if relaunchForNextServer {
        WriteLog("伺服器排程：準備啟動下一輪流程", "WARN")
        ShowTip("🔁 切換下一個伺服器，準備重啟流程", 2000)
        Sleep 1200
        try Run('"' AhkExe '" "' A_ScriptFullPath '" nextserver')
        catch as e
            WriteLog("啟動下一輪伺服器流程失敗: " e.Message, "ERROR")
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
    body := BuildNotifyMailBody("全自動收尾已完成。", nowText)

    return SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl)
}

SendStartNotifyMail() {
    global CFG_FILE, MAIL_SECTION

    state := ReadCombinedConfigState()
    if state.needSetup {
        WriteLog("開始寄信前偵測到設定缺漏，重新打開整合設定視窗", "WARN")
        ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, "開始寄信前偵測到設定有空白或錯誤")
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
    subject := subjectPrefix " 開始鋤地通知 " nowText
    body := BuildNotifyMailBody("全自動鋤地流程已開始，請勿登入。", nowText)
    body .= "`r`n提醒：若需要登入，請先執行停止鋤地流程。"

    return SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl)
}

BuildNotifyMailBody(prefixLine, nowText := "") {
    if (nowText = "")
        nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")

    serverInfo := (CURRENT_SERVER_TARGET != "" ? "伺服器：" CURRENT_SERVER_TARGET "`r`n" : "")
    modeInfo := "模式：" (A_Args.Length > 0 ? A_Args[1] : "normal") "`r`n"
    return prefixLine "`r`n時間：" nowText "`r`n主機：" A_ComputerName "`r`n" modeInfo serverInfo "腳本：" A_ScriptFullPath
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
    global CFG_FILE, MAIL_NOTIFY_ENABLED, MAIL_SECTION, REWARD_LOG_FILE, SCREEN_RECORDING_ENABLED, SCREEN_RECORDING_SECTION
    global SCREEN_RECORDING_ENGINE, SCREEN_RECORDING_FFMPEG_EXE, SCREEN_RECORDING_FFMPEG_ARGS, SCREEN_RECORDING_OUTPUT_DIR, SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK
    global SCREEN_RECORDING_STOP_MODE, SCREEN_RECORDING_STOP_TEMPLATE, SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM, SCREEN_RECORDING_STOP_LRMC_TASK

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
    state.screenRecordingEnabled := ParseBool01(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "enabled", "0"), 0)
    state.screenRecordingEngine := NormalizeScreenRecordingEngine(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "engine", "ffmpeg"))
    state.screenRecordingAllowHotkeyFallback := ParseBool01(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "allow_hotkey_fallback", "1"), 1)
    state.screenRecordingFfmpegExe := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "ffmpeg_exe", ResolveDefaultScreenRecordingFfmpegExe()))
    if (state.screenRecordingFfmpegExe = "")
        state.screenRecordingFfmpegExe := ResolveDefaultScreenRecordingFfmpegExe()
    state.screenRecordingFfmpegArgs := Trim(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "ffmpeg_args", "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p"), " `t`r`n")
    if (state.screenRecordingFfmpegArgs = "")
        state.screenRecordingFfmpegArgs := "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p"
    state.screenRecordingOutputDir := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "output_dir", "recordings"))
    if (state.screenRecordingOutputDir = "")
        state.screenRecordingOutputDir := "recordings"
    state.screenRecordingStopMode := NormalizeScreenRecordingStopMode(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_mode", "exit"))
    state.screenRecordingStopTemplate := NormalizeScreenRecordingStopTemplate(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_template", "login"))
    state.screenRecordingStopTemplateCustom := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_template_custom", ""))
    state.screenRecordingStopLrmcTask := Trim(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_lrmc_task", ""), " `t`r`n")
    state.serverScheduleEnabled := ParseBool01(IniReadSafe(CFG_FILE, "server_schedule", "enabled", "0"), 0)
    state.serverScheduleList := Trim(IniReadSafe(CFG_FILE, "server_schedule", "list", ""), " `t`r`n")
    state.serverSwitchX := Trim(IniReadSafe(CFG_FILE, "server_schedule", "switch_x", "640"), " `t`r`n")
    state.serverSwitchY := Trim(IniReadSafe(CFG_FILE, "server_schedule", "switch_y", "549"), " `t`r`n")
    MAIL_NOTIFY_ENABLED := state.sendEnabled
    SCREEN_RECORDING_ENABLED := state.screenRecordingEnabled
    SCREEN_RECORDING_ENGINE := state.screenRecordingEngine
    SCREEN_RECORDING_FFMPEG_EXE := state.screenRecordingFfmpegExe
    SCREEN_RECORDING_FFMPEG_ARGS := state.screenRecordingFfmpegArgs
    SCREEN_RECORDING_OUTPUT_DIR := state.screenRecordingOutputDir
    SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK := state.screenRecordingAllowHotkeyFallback
    SCREEN_RECORDING_STOP_MODE := state.screenRecordingStopMode
    SCREEN_RECORDING_STOP_TEMPLATE := state.screenRecordingStopTemplate
    SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM := state.screenRecordingStopTemplateCustom
    SCREEN_RECORDING_STOP_LRMC_TASK := state.screenRecordingStopLrmcTask
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

    if (state.serverScheduleEnabled) {
        listParsed := ParseServerScheduleList(state.serverScheduleList)
        if (listParsed.Length = 0)
            err.Push("server_schedule.list 為空（啟用排程時必填）")
        if !(state.serverSwitchX ~= "^\d+$")
            err.Push("server_schedule.switch_x 不是數字")
        if !(state.serverSwitchY ~= "^\d+$")
            err.Push("server_schedule.switch_y 不是數字")
    }

    state.errors := err
    state.needSetup := (err.Length > 0)
    state.errorText := ""
    for item in err
        state.errorText .= "- " item "`n"

    return state
}

ShowCombinedConfigSetupGui(cfgPath, section, state, reason := "") {
    g := Gui("+AlwaysOnTop +Resize +MinSize640x520", "整合設定（程式路徑 + 郵件通知）")
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
    summary .= "screen_recording.enabled: " (state.screenRecordingEnabled ? "1(啟用)" : "0(停用)") "`r`n"
    summary .= "screen_recording.engine: " state.screenRecordingEngine "`r`n"
    summary .= "screen_recording.allow_hotkey_fallback: " state.screenRecordingAllowHotkeyFallback "`r`n"
    summary .= "screen_recording.ffmpeg_exe: " state.screenRecordingFfmpegExe "`r`n"
    summary .= "screen_recording.ffmpeg_args: " state.screenRecordingFfmpegArgs "`r`n"
    summary .= "screen_recording.output_dir: " state.screenRecordingOutputDir "`r`n"
    summary .= "screen_recording.stop_mode: " state.screenRecordingStopMode "`r`n"
    summary .= "screen_recording.stop_template: " state.screenRecordingStopTemplate "`r`n"
    summary .= "screen_recording.stop_template_custom: " state.screenRecordingStopTemplateCustom "`r`n"
    summary .= "screen_recording.stop_lrmc_task: " state.screenRecordingStopLrmcTask "`r`n"
    summary .= "server_schedule.enabled: " (state.serverScheduleEnabled ? "1(啟用)" : "0(停用)") "`r`n"
    summary .= "server_schedule.list: " state.serverScheduleList "`r`n"
    summary .= "server_schedule.switch: (" state.serverSwitchX "," state.serverSwitchY ")`r`n"
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

    g.AddText("xm y+14 w720", "【伺服器排程】啟用後會在登入畫面先切服（點擊視窗內座標），每輪完成後自動重啟跑下一個伺服器。")
    cbServerScheduleEnabled := g.AddCheckbox("xm y+8", "啟用伺服器排程")
    cbServerScheduleEnabled.Value := state.serverScheduleEnabled ? 1 : 0
    txtServerHint := g.AddText("x+12 w500", state.serverScheduleEnabled ? "目前啟用：會依清單逐一切服並續跑" : "目前停用：維持單伺服器流程")

    g.AddText("xm y+10 w120", "伺服器清單")
    edServerList := g.AddEdit("x+10 w500", state.serverScheduleList)
    btnServerPreview := g.AddButton("x+8 w90", "預覽排序")
    g.AddText("xm y+4 w720 c666666", "可用逗號/分號/換行分隔，例如：HMT(HK, MO, TW), SEA, America")

    g.AddText("xm y+10 w120", "切服按鈕座標")
    edServerSwitchX := g.AddEdit("x+10 w90", state.serverSwitchX)
    g.AddText("x+8 w24", ",")
    edServerSwitchY := g.AddEdit("x+8 w90", state.serverSwitchY)
    g.AddText("x+12 w460 c666666", "以 1280x720 為基準的視窗內相對座標，會自動縮放；預設 (640,549)")

    g.AddText("xm y+14 w720", "【郵件設定】Gmail: smtp.gmail.com / 587 / use_ssl=1；密碼請使用應用程式密碼")
    cbSendEnabled := g.AddCheckbox("xm y+8", "啟用收尾通知寄信")
    cbSendEnabled.Value := state.sendEnabled ? 1 : 0
    txtMailHint := g.AddText("x+12 w420", state.sendEnabled ? "目前啟用寄信：需填寫 SMTP 欄位" : "目前停用寄信：可略過 SMTP 欄位")

    g.AddText("xm y+12 w720", "【螢幕錄影】預設使用 FFmpeg（建議），也可回退 Alt+F9 快捷鍵模式。")
    cbScreenRecordingEnabled := g.AddCheckbox("xm y+8", "啟用螢幕錄影")
    cbScreenRecordingEnabled.Value := state.screenRecordingEnabled ? 1 : 0

    g.AddText("xm y+8 w120", "錄影引擎")
    ddScreenRecordingEngine := g.AddDropDownList("x+10 w300", ["ffmpeg:跨電腦建議", "hotkey:Alt+F9"])
    ddScreenRecordingEngine.Choose((state.screenRecordingEngine = "hotkey") ? 2 : 1)

    cbScreenRecordingAllowFallback := g.AddCheckbox("x+12", "FFmpeg 失敗時退回 Alt+F9")
    cbScreenRecordingAllowFallback.Value := state.screenRecordingAllowHotkeyFallback ? 1 : 0

    g.AddText("xm y+8 w120", "ffmpeg.exe")
    edScreenRecordingFfmpegExe := g.AddEdit("x+10 w500", state.screenRecordingFfmpegExe)
    btnScreenRecordingFfmpegExe := g.AddButton("x+8 w90", "瀏覽...")

    g.AddText("xm y+8 w120", "ffmpeg 參數")
    edScreenRecordingFfmpegArgs := g.AddEdit("x+10 w600", state.screenRecordingFfmpegArgs)

    g.AddText("xm y+8 w120", "輸出資料夾")
    edScreenRecordingOutputDir := g.AddEdit("x+10 w500", state.screenRecordingOutputDir)
    btnScreenRecordingOutputDir := g.AddButton("x+8 w90", "瀏覽...")

    g.AddText("xm y+8 w120", "停止時機")
    ddScreenRecordingStopMode := g.AddDropDownList("x+10 w300", ["exit:腳本結束時", "synthesis_end:聲骸合成結束時", "reward_end:收尾監測達標時", "template:模板命中時", "lrmc_task_end:LRMCAI任務完成時"])
    ddScreenRecordingStopMode.Choose((state.screenRecordingStopMode = "synthesis_end") ? 2 : (state.screenRecordingStopMode = "reward_end") ? 3 : (state.screenRecordingStopMode = "template") ? 4 : (state.screenRecordingStopMode = "lrmc_task_end") ? 5 : 1)

    g.AddText("xm y+8 w120", "模板來源")
    ddScreenRecordingStopTemplate := g.AddDropDownList("x+10 w220", ["login:登入.png", "close:0510.png", "custom:自訂模板"])
    ddScreenRecordingStopTemplate.Choose((state.screenRecordingStopTemplate = "close") ? 2 : (state.screenRecordingStopTemplate = "custom") ? 3 : 1)
    edScreenRecordingStopTemplateCustom := g.AddEdit("x+8 w272", state.screenRecordingStopTemplateCustom)
    btnScreenRecordingStopTemplateCustom := g.AddButton("x+8 w90", "瀏覽模板")

    g.AddText("xm y+8 w120", "任務名稱")
    edScreenRecordingStopLrmcTask := g.AddEdit("x+10 w500", state.screenRecordingStopLrmcTask)
    g.AddText("x+12 w200 c666666", "例如：七丘05 或 07落日堤嶼")

    txtScreenRecordingHint := g.AddText("xm y+4 w720 c666666", "提示：選擇 template:模板命中時 才會啟用模板停止；自訂模板可填絕對路徑或相對於 payload 的路徑。")

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
    g.AddText("x+12 w220 c666666", "可多位：逗號/分號/換行分隔")

    g.AddText("xm y+10 w120", "subject_prefix")
    edPrefix := g.AddEdit("x+10 w500", state.subjectPrefix)

    btnSave := g.AddButton("xm y+18 w170 h34 Default", "儲存全部並繼續")
    btnCancel := g.AddButton("x+12 w110 h34", "取消")

    global __MAIL_SETUP
    __MAIL_SETUP := {
        done: false,
        saved: false,
        gui: g,
        btnSave: btnSave,
        btnCancel: btnCancel,
        cfgPath: cfgPath,
        section: section,
        edOkww: edOkww,
        edLrmc: edLrmc,
        edWu: edWu,
        edFallbackLog: edFallbackLog,
        txtFallbackHint: txtFallbackHint,
        cbServerScheduleEnabled: cbServerScheduleEnabled,
        txtServerHint: txtServerHint,
        edServerList: edServerList,
        btnServerPreview: btnServerPreview,
        edServerSwitchX: edServerSwitchX,
        edServerSwitchY: edServerSwitchY,
        edHost: edHost,
        edPort: edPort,
        edUser: edUser,
        edPass: edPass,
        edFrom: edFrom,
        edTo: edTo,
        edPrefix: edPrefix,
        ddSsl: ddSsl,
        cbSendEnabled: cbSendEnabled,
        cbScreenRecordingEnabled: cbScreenRecordingEnabled,
        ddScreenRecordingEngine: ddScreenRecordingEngine,
        cbScreenRecordingAllowFallback: cbScreenRecordingAllowFallback,
        edScreenRecordingFfmpegExe: edScreenRecordingFfmpegExe,
        btnScreenRecordingFfmpegExe: btnScreenRecordingFfmpegExe,
        edScreenRecordingFfmpegArgs: edScreenRecordingFfmpegArgs,
        edScreenRecordingOutputDir: edScreenRecordingOutputDir,
        btnScreenRecordingOutputDir: btnScreenRecordingOutputDir,
        ddScreenRecordingStopMode: ddScreenRecordingStopMode,
        ddScreenRecordingStopTemplate: ddScreenRecordingStopTemplate,
        edScreenRecordingStopTemplateCustom: edScreenRecordingStopTemplateCustom,
        btnScreenRecordingStopTemplateCustom: btnScreenRecordingStopTemplateCustom,
        edScreenRecordingStopLrmcTask: edScreenRecordingStopLrmcTask,
        txtScreenRecordingHint: txtScreenRecordingHint,
        txtMailHint: txtMailHint
    }

    btnOkww.OnEvent("Click", OnCombinedBrowseOkww)
    btnLrmc.OnEvent("Click", OnCombinedBrowseLrmc)
    btnWu.OnEvent("Click", OnCombinedBrowseWu)
    btnFallbackLog.OnEvent("Click", OnCombinedBrowseFallbackLog)
    btnServerPreview.OnEvent("Click", OnServerSchedulePreview)
    edFallbackLog.OnEvent("Change", OnFallbackLogChanged)
    cbServerScheduleEnabled.OnEvent("Click", OnServerScheduleEnabledChanged)
    cbSendEnabled.OnEvent("Click", OnSendEnabledChanged)
    cbScreenRecordingEnabled.OnEvent("Click", OnScreenRecordingSettingChanged)
    ddScreenRecordingEngine.OnEvent("Change", OnScreenRecordingSettingChanged)
    cbScreenRecordingAllowFallback.OnEvent("Click", OnScreenRecordingSettingChanged)
    ddScreenRecordingStopMode.OnEvent("Change", OnScreenRecordingSettingChanged)
    ddScreenRecordingStopTemplate.OnEvent("Change", OnScreenRecordingSettingChanged)
    btnScreenRecordingFfmpegExe.OnEvent("Click", OnBrowseScreenRecordingFfmpegExe)
    btnScreenRecordingOutputDir.OnEvent("Click", OnBrowseScreenRecordingOutputDir)
    btnScreenRecordingStopTemplateCustom.OnEvent("Click", OnBrowseScreenRecordingTemplate)
    btnSave.OnEvent("Click", OnCombinedSetupSave)
    btnCancel.OnEvent("Click", OnCombinedSetupCancel)
    g.OnEvent("Size", OnCombinedSetupGuiSize)
    g.OnEvent("Close", OnCombinedSetupClose)

    RefreshFallbackLogHint()
    RefreshMailInputsEnabled()
    RefreshServerScheduleInputsEnabled()
    RefreshScreenRecordingInputsEnabled()

    ShowGuiFitToScreen(g)
    ReflowCombinedSetupFooterButtons()
    while !__MAIL_SETUP.done
        Sleep 50

    saved := __MAIL_SETUP.saved
    __MAIL_SETUP := ""
    return saved
}

ShowGuiFitToScreen(g, margin := 24) {
    g.Show("AutoSize Center")

    try {
        WinGetPos(&x, &y, &w, &h, "ahk_id " g.Hwnd)
        maxW := A_ScreenWidth - (margin * 2)
        maxH := A_ScreenHeight - (margin * 2)

        if (maxW < 640)
            maxW := 640
        if (maxH < 520)
            maxH := 520

        newW := (w > maxW) ? maxW : w
        newH := (h > maxH) ? maxH : h

        if (newW != w || newH != h) {
            newX := Floor((A_ScreenWidth - newW) / 2)
            newY := Floor((A_ScreenHeight - newH) / 2)
            if (newX < margin)
                newX := margin
            if (newY < margin)
                newY := margin
            WinMove(newX, newY, newW, newH, "ahk_id " g.Hwnd)
        }
    } catch {
    }
}

OnCombinedSetupGuiSize(thisGui, minMax, width, height) {
    ReflowCombinedSetupFooterButtons(width, height)
}

ReflowCombinedSetupFooterButtons(width := 0, height := 0) {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    if !IsSet(width) || (width <= 0) || !IsSet(height) || (height <= 0) {
        try WinGetClientPos(, , &width, &height, "ahk_id " __MAIL_SETUP.gui.Hwnd)
    }
    if (width <= 0 || height <= 0)
        return

    margin := 16
    gap := 12
    minSaveW := 130
    minCancelW := 90
    saveW := 170
    cancelW := 110
    btnH := 34

    avail := width - (margin * 2) - gap
    if (avail < (saveW + cancelW)) {
        if (avail < (minSaveW + minCancelW))
            avail := minSaveW + minCancelW
        saveW := Max(minSaveW, Floor(avail * 0.62))
        cancelW := Max(minCancelW, avail - saveW)
    }

    x1 := margin
    y := height - margin - btnH
    if (y < 8)
        y := 8

    x2 := x1 + saveW + gap
    __MAIL_SETUP.btnSave.Move(x1, y, saveW, btnH)
    __MAIL_SETUP.btnCancel.Move(x2, y, cancelW, btnH)
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
    global __MAIL_SETUP, MAIL_NOTIFY_ENABLED, SCREEN_RECORDING_ENABLED
    global SCREEN_RECORDING_ENGINE, SCREEN_RECORDING_FFMPEG_EXE, SCREEN_RECORDING_FFMPEG_ARGS, SCREEN_RECORDING_OUTPUT_DIR, SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK
    global SCREEN_RECORDING_STOP_MODE, SCREEN_RECORDING_STOP_TEMPLATE, SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM, SCREEN_RECORDING_STOP_LRMC_TASK
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
    serverScheduleEnabledVal := st.cbServerScheduleEnabled.Value ? 1 : 0
    serverListVal := Trim(st.edServerList.Value, " `t`r`n")
    serverSwitchXVal := Trim(st.edServerSwitchX.Value, " `t`r`n")
    serverSwitchYVal := Trim(st.edServerSwitchY.Value, " `t`r`n")
    sslVal := st.ddSsl.Text
    sendEnabledVal := st.cbSendEnabled.Value ? 1 : 0
    screenRecordingEnabledVal := st.cbScreenRecordingEnabled.Value ? 1 : 0
    recordingEngineVal := NormalizeScreenRecordingEngine(StrSplit(st.ddScreenRecordingEngine.Text, ":")[1])
    allowFallbackVal := st.cbScreenRecordingAllowFallback.Value ? 1 : 0
    ffmpegExeVal := NormalizePath(st.edScreenRecordingFfmpegExe.Value)
    ffmpegArgsVal := Trim(st.edScreenRecordingFfmpegArgs.Value, " `t`r`n")
    outputDirVal := NormalizePath(st.edScreenRecordingOutputDir.Value)
    stopModeVal := NormalizeScreenRecordingStopMode(StrSplit(st.ddScreenRecordingStopMode.Text, ":")[1])
    stopTemplateVal := NormalizeScreenRecordingStopTemplate(StrSplit(st.ddScreenRecordingStopTemplate.Text, ":")[1])
    stopTemplateCustomVal := NormalizePath(st.edScreenRecordingStopTemplateCustom.Value)
    stopLrmcTaskVal := Trim(st.edScreenRecordingStopLrmcTask.Value, " `t`r`n")

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

    if serverScheduleEnabledVal {
        parsed := ParseServerScheduleList(serverListVal)
        if (parsed.Length = 0) {
            MsgBox "啟用伺服器排程時，伺服器清單不可空白", "整合設定", "Iconx"
            return
        }
        if !(serverSwitchXVal ~= "^\d+$") || !(serverSwitchYVal ~= "^\d+$") {
            MsgBox "切服座標 X/Y 必須是數字", "整合設定", "Iconx"
            return
        }
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

    if (screenRecordingEnabledVal && stopModeVal = "template") {
        if (stopTemplateVal = "custom") {
            if (stopTemplateCustomVal = "") {
                MsgBox "錄影停止條件為模板命中時，自訂模板路徑不可空白", "整合設定", "Iconx"
                return
            }
        }
    }

    if (screenRecordingEnabledVal && stopModeVal = "lrmc_task_end") {
        if (stopLrmcTaskVal = "") {
            MsgBox "錄影停止條件為 LRMCAI 任務完成時，任務名稱不可空白", "整合設定", "Iconx"
            return
        }
    }

    if (screenRecordingEnabledVal && recordingEngineVal = "ffmpeg") {
        if (ffmpegArgsVal = "") {
            MsgBox "使用 FFmpeg 錄影時，ffmpeg 參數不可空白", "整合設定", "Iconx"
            return
        }
        if (outputDirVal = "") {
            MsgBox "使用 FFmpeg 錄影時，輸出資料夾不可空白", "整合設定", "Iconx"
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

    IniWrite serverScheduleEnabledVal, st.cfgPath, "server_schedule", "enabled"
    IniWrite serverListVal, st.cfgPath, "server_schedule", "list"
    IniWrite (serverSwitchXVal = "" ? "640" : serverSwitchXVal), st.cfgPath, "server_schedule", "switch_x"
    IniWrite (serverSwitchYVal = "" ? "549" : serverSwitchYVal), st.cfgPath, "server_schedule", "switch_y"
    IniWrite "1", st.cfgPath, "server_schedule", "current_index"

    IniWrite hostVal, st.cfgPath, st.section, "smtp_host"
    IniWrite portVal, st.cfgPath, st.section, "smtp_port"
    IniWrite userVal, st.cfgPath, st.section, "smtp_user"
    IniWrite passVal, st.cfgPath, st.section, "smtp_pass"
    IniWrite fromVal, st.cfgPath, st.section, "from"
    IniWrite toVal, st.cfgPath, st.section, "to"
    IniWrite (prefixVal = "" ? "LRMCAI" : prefixVal), st.cfgPath, st.section, "subject_prefix"
    IniWrite sslVal, st.cfgPath, st.section, "use_ssl"
    IniWrite sendEnabledVal, st.cfgPath, st.section, "send_enabled"
    IniWrite screenRecordingEnabledVal, st.cfgPath, "screen_recording", "enabled"
    IniWrite recordingEngineVal, st.cfgPath, "screen_recording", "engine"
    IniWrite allowFallbackVal, st.cfgPath, "screen_recording", "allow_hotkey_fallback"
    IniWrite (ffmpegExeVal = "" ? ResolveDefaultScreenRecordingFfmpegExe() : ffmpegExeVal), st.cfgPath, "screen_recording", "ffmpeg_exe"
    IniWrite (ffmpegArgsVal = "" ? "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p" : ffmpegArgsVal), st.cfgPath, "screen_recording", "ffmpeg_args"
    IniWrite (outputDirVal = "" ? "recordings" : outputDirVal), st.cfgPath, "screen_recording", "output_dir"
    IniWrite stopModeVal, st.cfgPath, "screen_recording", "stop_mode"
    IniWrite stopTemplateVal, st.cfgPath, "screen_recording", "stop_template"
    IniWrite stopTemplateCustomVal, st.cfgPath, "screen_recording", "stop_template_custom"
    IniWrite stopLrmcTaskVal, st.cfgPath, "screen_recording", "stop_lrmc_task"

    MAIL_NOTIFY_ENABLED := sendEnabledVal
    SCREEN_RECORDING_ENABLED := screenRecordingEnabledVal
    SCREEN_RECORDING_ENGINE := recordingEngineVal
    SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK := allowFallbackVal
    SCREEN_RECORDING_FFMPEG_EXE := (ffmpegExeVal = "" ? ResolveDefaultScreenRecordingFfmpegExe() : ffmpegExeVal)
    SCREEN_RECORDING_FFMPEG_ARGS := (ffmpegArgsVal = "" ? "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p" : ffmpegArgsVal)
    SCREEN_RECORDING_OUTPUT_DIR := (outputDirVal = "" ? "recordings" : outputDirVal)
    SCREEN_RECORDING_STOP_MODE := stopModeVal
    SCREEN_RECORDING_STOP_TEMPLATE := stopTemplateVal
    SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM := stopTemplateCustomVal
    SCREEN_RECORDING_STOP_LRMC_TASK := stopLrmcTaskVal

    __MAIL_SETUP.saved := true
    __MAIL_SETUP.done := true
    st.gui.Destroy()
}

OnSendEnabledChanged(*) {
    RefreshMailInputsEnabled()
}

OnScreenRecordingSettingChanged(*) {
    RefreshScreenRecordingInputsEnabled()
}

OnBrowseScreenRecordingTemplate(*) {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    p := FileSelect(, "", "選擇錄影停止模板", "圖片檔 (*.png;*.jpg;*.jpeg;*.bmp;*.webp)")
    if (p)
        __MAIL_SETUP.edScreenRecordingStopTemplateCustom.Value := p
}

OnBrowseScreenRecordingFfmpegExe(*) {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    p := FileSelect(, "", "選擇 ffmpeg.exe", "可執行檔 (*.exe)")
    if (p)
        __MAIL_SETUP.edScreenRecordingFfmpegExe.Value := p
}

OnBrowseScreenRecordingOutputDir(*) {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    p := DirSelect("", 3, "選擇錄影輸出資料夾")
    if (p)
        __MAIL_SETUP.edScreenRecordingOutputDir.Value := p
}

OnServerScheduleEnabledChanged(*) {
    RefreshServerScheduleInputsEnabled()
}

RefreshScreenRecordingInputsEnabled() {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    enabled := __MAIL_SETUP.cbScreenRecordingEnabled.Value ? true : false
    engineKey := NormalizeScreenRecordingEngine(StrSplit(__MAIL_SETUP.ddScreenRecordingEngine.Text, ":")[1])
    useFfmpeg := enabled && (engineKey = "ffmpeg")
    __MAIL_SETUP.ddScreenRecordingEngine.Enabled := enabled
    __MAIL_SETUP.cbScreenRecordingAllowFallback.Enabled := useFfmpeg
    __MAIL_SETUP.edScreenRecordingFfmpegExe.Enabled := useFfmpeg
    __MAIL_SETUP.btnScreenRecordingFfmpegExe.Enabled := useFfmpeg
    __MAIL_SETUP.edScreenRecordingFfmpegArgs.Enabled := useFfmpeg
    __MAIL_SETUP.edScreenRecordingOutputDir.Enabled := useFfmpeg
    __MAIL_SETUP.btnScreenRecordingOutputDir.Enabled := useFfmpeg
    __MAIL_SETUP.ddScreenRecordingStopMode.Enabled := enabled

    modeKey := NormalizeScreenRecordingStopMode(StrSplit(__MAIL_SETUP.ddScreenRecordingStopMode.Text, ":")[1])
    useTemplateMode := enabled && (modeKey = "template")
    useTaskMode := enabled && (modeKey = "lrmc_task_end")
    __MAIL_SETUP.ddScreenRecordingStopTemplate.Enabled := useTemplateMode

    templateKey := NormalizeScreenRecordingStopTemplate(StrSplit(__MAIL_SETUP.ddScreenRecordingStopTemplate.Text, ":")[1])
    useCustom := useTemplateMode && (templateKey = "custom")
    __MAIL_SETUP.edScreenRecordingStopTemplateCustom.Enabled := useCustom
    __MAIL_SETUP.btnScreenRecordingStopTemplateCustom.Enabled := useCustom
    __MAIL_SETUP.edScreenRecordingStopLrmcTask.Enabled := useTaskMode

    if !enabled
        __MAIL_SETUP.txtScreenRecordingHint.Value := "提示：螢幕錄影目前停用。"
    else if (engineKey = "ffmpeg")
        __MAIL_SETUP.txtScreenRecordingHint.Value := __MAIL_SETUP.cbScreenRecordingAllowFallback.Value ? "提示：目前使用 FFmpeg 錄影；失敗時可退回 Alt+F9。" : "提示：目前使用 FFmpeg 錄影；失敗時不退回 Alt+F9。"
    else if (modeKey = "template")
        __MAIL_SETUP.txtScreenRecordingHint.Value := useCustom ? "提示：請提供自訂模板檔路徑。" : "提示：目前使用預設模板作為停止條件。"
    else if (modeKey = "lrmc_task_end")
        __MAIL_SETUP.txtScreenRecordingHint.Value := "提示：偵測到『到達終點』後，下一條任務包命中任務名稱就停止錄影（繁簡互通）。"
    else if (modeKey = "synthesis_end")
        __MAIL_SETUP.txtScreenRecordingHint.Value := "提示：會在聲骸合成結束時停止錄影。"
    else if (modeKey = "reward_end")
        __MAIL_SETUP.txtScreenRecordingHint.Value := "提示：會在收尾監測達標時停止錄影。"
    else
        __MAIL_SETUP.txtScreenRecordingHint.Value := "提示：會在腳本結束時停止錄影。"
}

OnServerSchedulePreview(*) {
    global __MAIL_SETUP, __SERVER_PREVIEW
    if !IsObject(__MAIL_SETUP)
        return

    src := Trim(__MAIL_SETUP.edServerList.Value, " `t`r`n")
    arr := ParseServerScheduleList(src)
    if (arr.Length = 0) {
        MsgBox "伺服器清單是空的，請先輸入至少一個伺服器。", "伺服器清單預覽", "Iconx"
        return
    }

    g := Gui("+AlwaysOnTop +Owner" __MAIL_SETUP.gui.Hwnd " +MinSize540x360", "伺服器清單預覽排序")
    g.SetFont("s10", "Microsoft JhengHei UI")
    g.AddText("xm w500", "可用【上移/下移】調整順序，或按【字母排序】後套用回主設定。")

    lb := g.AddListBox("xm y+8 w500 r10", arr)
    lb.Choose(1)

    btnUp := g.AddButton("xm y+10 w90", "上移")
    btnDown := g.AddButton("x+8 w90", "下移")
    btnSort := g.AddButton("x+8 w110", "字母排序")
    btnRefresh := g.AddButton("x+8 w110", "重讀清單")
    btnApply := g.AddButton("xm y+14 w150 h32 Default", "套用回主清單")
    btnClose := g.AddButton("x+10 w90 h32", "關閉")

    __SERVER_PREVIEW := {
        gui: g,
        lb: lb,
        sourceEdit: __MAIL_SETUP.edServerList,
        sourceText: src
    }

    btnUp.OnEvent("Click", OnServerPreviewMoveUp)
    btnDown.OnEvent("Click", OnServerPreviewMoveDown)
    btnSort.OnEvent("Click", OnServerPreviewSort)
    btnRefresh.OnEvent("Click", OnServerPreviewReload)
    btnApply.OnEvent("Click", OnServerPreviewApply)
    btnClose.OnEvent("Click", OnServerPreviewClose)
    g.OnEvent("Close", OnServerPreviewClose)
    g.Show("AutoSize")
}

GetServerPreviewItems() {
    global __SERVER_PREVIEW
    items := []
    if !IsObject(__SERVER_PREVIEW)
        return items

    txt := __SERVER_PREVIEW.lb.Text
    ; ListBox Text 會回傳選中項目，改用主欄位重建更穩定
    src := Trim(__SERVER_PREVIEW.sourceEdit.Value, " `t`r`n")
    items := ParseServerScheduleList(src)
    if (items.Length = 0) {
        ; 從預覽建立時的來源回退
        items := ParseServerScheduleList(__SERVER_PREVIEW.sourceText)
    }
    return items
}

SetServerPreviewItems(items, selectedIndex := 1) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return
    __SERVER_PREVIEW.lb.Delete()
    for item in items
        __SERVER_PREVIEW.lb.Add([item])

    if (items.Length = 0)
        return

    if (selectedIndex < 1)
        selectedIndex := 1
    if (selectedIndex > items.Length)
        selectedIndex := items.Length
    __SERVER_PREVIEW.lb.Choose(selectedIndex)
}

OnServerPreviewMoveUp(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return

    items := GetServerPreviewItems()
    if (items.Length <= 1)
        return
    idx := __SERVER_PREVIEW.lb.Value
    if (idx <= 1)
        return

    tmp := items[idx - 1]
    items[idx - 1] := items[idx]
    items[idx] := tmp
    __SERVER_PREVIEW.sourceEdit.Value := JoinServerList(items)
    SetServerPreviewItems(items, idx - 1)
}

OnServerPreviewMoveDown(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return

    items := GetServerPreviewItems()
    if (items.Length <= 1)
        return
    idx := __SERVER_PREVIEW.lb.Value
    if (idx >= items.Length)
        return

    tmp := items[idx + 1]
    items[idx + 1] := items[idx]
    items[idx] := tmp
    __SERVER_PREVIEW.sourceEdit.Value := JoinServerList(items)
    SetServerPreviewItems(items, idx + 1)
}

OnServerPreviewSort(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return

    items := GetServerPreviewItems()
    if (items.Length <= 1)
        return
    items := SortServerList(items)
    __SERVER_PREVIEW.sourceEdit.Value := JoinServerList(items)
    SetServerPreviewItems(items, 1)
}

OnServerPreviewReload(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return

    items := ParseServerScheduleList(__SERVER_PREVIEW.sourceEdit.Value)
    if (items.Length = 0)
        items := ParseServerScheduleList(__SERVER_PREVIEW.sourceText)
    SetServerPreviewItems(items, 1)
}

OnServerPreviewApply(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return

    items := GetServerPreviewItems()
    if (items.Length = 0) {
        MsgBox "目前沒有可套用的伺服器項目。", "伺服器清單預覽", "Iconx"
        return
    }

    __SERVER_PREVIEW.sourceEdit.Value := JoinServerList(items)
    ShowTip("✅ 已套用伺服器排序", 1000)
}

OnServerPreviewClose(*) {
    global __SERVER_PREVIEW
    if !IsObject(__SERVER_PREVIEW)
        return
    try __SERVER_PREVIEW.gui.Destroy()
    __SERVER_PREVIEW := ""
}

JoinServerList(items) {
    out := ""
    for item in items {
        if (out != "")
            out .= ", "
        out .= item
    }
    return out
}

SortServerList(items) {
    buf := ""
    for item in items
        buf .= item "`n"
    sorted := Sort(RTrim(buf, "`n"), "CL")
    out := []
    for line in StrSplit(sorted, "`n") {
        line := Trim(line, " `t`r`n")
        if (line != "")
            out.Push(line)
    }
    return out
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

RefreshServerScheduleInputsEnabled() {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    enabled := __MAIL_SETUP.cbServerScheduleEnabled.Value ? true : false
    __MAIL_SETUP.edServerList.Enabled := enabled
    __MAIL_SETUP.btnServerPreview.Enabled := enabled
    __MAIL_SETUP.edServerSwitchX.Enabled := enabled
    __MAIL_SETUP.edServerSwitchY.Enabled := enabled
    __MAIL_SETUP.txtServerHint.Value := enabled ? "目前啟用：會依清單逐一切服並續跑" : "目前停用：維持單伺服器流程"
}

LoadMailNotifyEnabled() {
    global CFG_FILE, MAIL_SECTION, MAIL_NOTIFY_ENABLED
    MAIL_NOTIFY_ENABLED := ParseBool01(IniReadSafe(CFG_FILE, MAIL_SECTION, "send_enabled", "1"), 1)
    WriteLog("郵件通知開關(send_enabled)=" MAIL_NOTIFY_ENABLED)
}

LoadScreenRecordingEnabled() {
    global CFG_FILE, SCREEN_RECORDING_SECTION, SCREEN_RECORDING_ENABLED
    global SCREEN_RECORDING_ENGINE, SCREEN_RECORDING_FFMPEG_EXE, SCREEN_RECORDING_FFMPEG_ARGS, SCREEN_RECORDING_OUTPUT_DIR, SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK
    global SCREEN_RECORDING_STOP_MODE, SCREEN_RECORDING_STOP_TEMPLATE, SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM, SCREEN_RECORDING_STOP_LRMC_TASK
    global __SCREEN_RECORDING_TEMPLATE_WARNED, __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING, __SCREEN_RECORDING_PID, __SCREEN_RECORDING_OUTPUT_PATH
    SCREEN_RECORDING_ENABLED := ParseBool01(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "enabled", "0"), 0)
    SCREEN_RECORDING_ENGINE := NormalizeScreenRecordingEngine(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "engine", "ffmpeg"))
    SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK := ParseBool01(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "allow_hotkey_fallback", "1"), 1)
    SCREEN_RECORDING_FFMPEG_EXE := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "ffmpeg_exe", ResolveDefaultScreenRecordingFfmpegExe()))
    if (SCREEN_RECORDING_FFMPEG_EXE = "")
        SCREEN_RECORDING_FFMPEG_EXE := ResolveDefaultScreenRecordingFfmpegExe()
    SCREEN_RECORDING_FFMPEG_ARGS := Trim(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "ffmpeg_args", "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p"), " `t`r`n")
    if (SCREEN_RECORDING_FFMPEG_ARGS = "")
        SCREEN_RECORDING_FFMPEG_ARGS := "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p"
    SCREEN_RECORDING_OUTPUT_DIR := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "output_dir", "recordings"))
    if (SCREEN_RECORDING_OUTPUT_DIR = "")
        SCREEN_RECORDING_OUTPUT_DIR := "recordings"
    SCREEN_RECORDING_STOP_MODE := NormalizeScreenRecordingStopMode(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_mode", "exit"))
    SCREEN_RECORDING_STOP_TEMPLATE := NormalizeScreenRecordingStopTemplate(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_template", "login"))
    SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM := NormalizePath(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_template_custom", ""))
    SCREEN_RECORDING_STOP_LRMC_TASK := Trim(IniReadSafe(CFG_FILE, SCREEN_RECORDING_SECTION, "stop_lrmc_task", ""), " `t`r`n")
    __SCREEN_RECORDING_TEMPLATE_WARNED := false
    __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := false
    __SCREEN_RECORDING_PID := 0
    __SCREEN_RECORDING_OUTPUT_PATH := ""
    WriteLog("螢幕錄影開關(enabled)=" SCREEN_RECORDING_ENABLED)
    WriteLog("螢幕錄影引擎(engine)=" SCREEN_RECORDING_ENGINE " ffmpeg_exe=" SCREEN_RECORDING_FFMPEG_EXE " allow_hotkey_fallback=" SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK)
    WriteLog("螢幕錄影停止條件 stop_mode=" SCREEN_RECORDING_STOP_MODE " stop_template=" SCREEN_RECORDING_STOP_TEMPLATE)
}

TryStartScreenRecording(reason := "") {
    global SCREEN_RECORDING_ENABLED, SCREEN_RECORDING_ENGINE, SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK, __SCREEN_RECORDING_ACTIVE
    global __SCREEN_RECORDING_PID, __SCREEN_RECORDING_OUTPUT_PATH

    if !SCREEN_RECORDING_ENABLED {
        WriteLog("螢幕錄影未啟用，略過開始", "INFO")
        return false
    }
    if __SCREEN_RECORDING_ACTIVE
        return true

    if (SCREEN_RECORDING_ENGINE = "ffmpeg") {
        if StartFfmpegScreenRecording(&outPath, &pid) {
            __SCREEN_RECORDING_ACTIVE := true
            __SCREEN_RECORDING_PID := pid
            __SCREEN_RECORDING_OUTPUT_PATH := outPath
            msg := "已啟動 FFmpeg 螢幕錄影 PID=" pid " 檔案=" outPath
            if (reason != "")
                msg .= "（" reason "）"
            WriteLog(msg)
            return true
        }

        if SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK
            WriteLog("FFmpeg 錄影啟動失敗，回退 Alt+F9", "WARN")
        else {
            WriteLog("FFmpeg 錄影啟動失敗，且已設定不回退 Alt+F9", "WARN")
            return false
        }
    }

    try {
        Send "!{F9}"
        __SCREEN_RECORDING_ACTIVE := true
        __SCREEN_RECORDING_PID := 0
        __SCREEN_RECORDING_OUTPUT_PATH := ""
        msg := "已送出 Alt+F9 開始螢幕錄影"
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
        return true
    } catch as e {
        WriteLog("開始螢幕錄影失敗: " e.Message, "WARN")
        return false
    }
}

TryStopScreenRecording(reason := "") {
    global SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK, __SCREEN_RECORDING_ACTIVE, __SCREEN_RECORDING_PID, __SCREEN_RECORDING_OUTPUT_PATH

    if !__SCREEN_RECORDING_ACTIVE
        return false

    if (__SCREEN_RECORDING_PID > 0) {
        pid := __SCREEN_RECORDING_PID
        if StopFfmpegScreenRecording(pid) {
            __SCREEN_RECORDING_ACTIVE := false
            __SCREEN_RECORDING_PID := 0
            msg := "已停止 FFmpeg 螢幕錄影 PID=" pid
            if (__SCREEN_RECORDING_OUTPUT_PATH != "")
                msg .= " 檔案=" __SCREEN_RECORDING_OUTPUT_PATH
            if (reason != "")
                msg .= "（" reason "）"
            WriteLog(msg)
            __SCREEN_RECORDING_OUTPUT_PATH := ""
            return true
        }

        if SCREEN_RECORDING_ALLOW_HOTKEY_FALLBACK
            WriteLog("停止 FFmpeg 錄影失敗，嘗試 Alt+F9 備援", "WARN")
        else {
            WriteLog("停止 FFmpeg 錄影失敗，且已設定不回退 Alt+F9", "WARN")
            return false
        }
    }

    try {
        Send "!{F9}"
        __SCREEN_RECORDING_ACTIVE := false
        __SCREEN_RECORDING_PID := 0
        __SCREEN_RECORDING_OUTPUT_PATH := ""
        msg := "已送出 Alt+F9 停止螢幕錄影"
        if (reason != "")
            msg .= "（" reason "）"
        WriteLog(msg)
        return true
    } catch as e {
        WriteLog("停止螢幕錄影失敗: " e.Message, "WARN")
        return false
    }
}

NormalizeScreenRecordingEngine(val) {
    s := StrLower(Trim(val, " `t`r`n"))
    if (s = "hotkey")
        return "hotkey"
    return "ffmpeg"
}

ResolveScreenRecordingOutputDir() {
    global SCREEN_RECORDING_OUTPUT_DIR

    p := NormalizePath(SCREEN_RECORDING_OUTPUT_DIR)
    if (p = "")
        p := "recordings"

    if RegExMatch(p, "i)^[a-z]:\\")
        return p
    if (SubStr(p, 1, 2) = "\\\\")
        return p
    return A_ScriptDir "\\" p
}

StartFfmpegScreenRecording(&outPath, &pid) {
    global SCREEN_RECORDING_FFMPEG_EXE, SCREEN_RECORDING_FFMPEG_ARGS

    outPath := ""
    pid := 0

    ffmpegExe := ResolveScreenRecordingFfmpegExePath(SCREEN_RECORDING_FFMPEG_EXE)

    outDir := ResolveScreenRecordingOutputDir()
    try DirCreate(outDir)

    ts := FormatTime(A_Now, "yyyyMMdd_HHmmss")
    outPath := outDir "\\recording_" ts ".mp4"
    args := Trim(SCREEN_RECORDING_FFMPEG_ARGS, " `t`r`n")
    if (args = "")
        args := "-y -f gdigrab -framerate 30 -i desktop -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p"

    cmd := '"' ffmpegExe '" ' args ' "' outPath '"'
    try {
        Run(cmd, "", "Hide", &pid)
        if (pid <= 0)
            return false

        Sleep 300
        if !ProcessExist(pid)
            return false
        return true
    } catch as e {
        WriteLog("啟動 FFmpeg 失敗: " e.Message, "WARN")
        return false
    }
}

StopFfmpegScreenRecording(pid) {
    if (pid <= 0)
        return false

    try ProcessClose(pid)

    deadline := A_TickCount + 3000
    while (A_TickCount < deadline) {
        if !ProcessExist(pid)
            return true
        Sleep 100
    }
    return !ProcessExist(pid)
}

NormalizeScreenRecordingStopMode(val) {
    s := StrLower(Trim(val, " `t`r`n"))
    if (s = "exit" || s = "synthesis_end" || s = "reward_end" || s = "template" || s = "lrmc_task_end")
        return s
    return "exit"
}

NormalizeScreenRecordingStopTemplate(val) {
    s := StrLower(Trim(val, " `t`r`n"))
    if (s = "login" || s = "close" || s = "custom")
        return s
    return "login"
}

ResolveScreenRecordingStopTemplatePath() {
    global SCREEN_RECORDING_STOP_TEMPLATE, SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM

    if (SCREEN_RECORDING_STOP_TEMPLATE = "login")
        return A_ScriptDir "\登入.png"
    if (SCREEN_RECORDING_STOP_TEMPLATE = "close")
        return A_ScriptDir "\0510.png"

    p := NormalizePath(SCREEN_RECORDING_STOP_TEMPLATE_CUSTOM)
    if (p = "")
        return ""

    if RegExMatch(p, "i)^[a-z]:\\")
        return p
    if (SubStr(p, 1, 2) = "\\\\")
        return p
    return A_ScriptDir "\" p
}

TryStopScreenRecordingByMode(stage) {
    global SCREEN_RECORDING_ENABLED, SCREEN_RECORDING_STOP_MODE

    if !SCREEN_RECORDING_ENABLED
        return false
    if (SCREEN_RECORDING_STOP_MODE = "synthesis_end" && stage = "synthesis_end")
        return TryStopScreenRecording("聲骸合成結束")
    if (SCREEN_RECORDING_STOP_MODE = "reward_end" && stage = "reward_end")
        return TryStopScreenRecording("收尾監測達標")
    return false
}

NormalizeZhTaskText(s) {
    t := StrLower(Trim(s, " `t`r`n"))
    if (t = "")
        return ""

    ; 常見繁簡轉換，覆蓋任務名常見字
    t := StrReplace(t, "嶼", "屿")
    t := StrReplace(t, "區", "区")
    t := StrReplace(t, "務", "务")
    t := StrReplace(t, "達", "达")
    t := StrReplace(t, "終", "终")
    t := StrReplace(t, "點", "点")
    t := StrReplace(t, "時", "时")
    t := StrReplace(t, "領", "领")
    t := StrReplace(t, "獎", "奖")
    t := StrReplace(t, "體", "体")
    t := StrReplace(t, "經", "经")

    t := RegExReplace(t, "[\s\-_:：，,。.!！？()（）\[\]{}]+", "")
    return t
}

IsLrmcArrivalLine(line) {
    t := NormalizeZhTaskText(line)
    if (t = "")
        return false
    return (InStr(t, "到达终点") || InStr(t, "判定为到达终点"))
}

IsLrmcRewardOrStaminaLine(line) {
    t := NormalizeZhTaskText(line)
    if (t = "")
        return false
    return InStr(t, "已经领取奖励或体力不足了") ? true : false
}

ParseLrmcTaskPackageName(line) {
    t := Trim(line, " `t`r`n")
    if (t = "")
        return ""
    if !(InStr(t, "任务包:") || InStr(t, "任務包:"))
        return ""

    p := RegExReplace(t, "^.*?(任务包:|任務包:)", "")
    p := RegExReplace(p, "(用时|用時)[:：].*$", "")
    p := Trim(p, " `t`r`n")
    if (p = "")
        return ""

    last := p
    if InStr(p, "\\") {
        arr := StrSplit(p, "\\")
        if (arr.Length > 0)
            last := arr[arr.Length]
    } else if InStr(p, "/") {
        arr := StrSplit(p, "/")
        if (arr.Length > 0)
            last := arr[arr.Length]
    }

    return Trim(last, " `t`r`n")
}

TryStopScreenRecordingByLrmcTaskLine(line) {
    global SCREEN_RECORDING_ENABLED, SCREEN_RECORDING_STOP_MODE, SCREEN_RECORDING_STOP_LRMC_TASK, __SCREEN_RECORDING_ACTIVE, __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING

    if !SCREEN_RECORDING_ENABLED
        return false
    if !__SCREEN_RECORDING_ACTIVE
        return false
    if (SCREEN_RECORDING_STOP_MODE != "lrmc_task_end")
        return false

    if IsLrmcArrivalLine(line) {
        __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := true
        WriteLog("錄影任務停止：已偵測到到達終點，等待任務包行", "INFO")
        return false
    }

    if IsLrmcRewardOrStaminaLine(line) {
        __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := true
        WriteLog("錄影任務停止：已偵測到領獎/體力不足，等待任務包行", "INFO")
        return false
    }

    taskName := ParseLrmcTaskPackageName(line)
    if (taskName = "")
        return false

    if !__SCREEN_RECORDING_LRMC_ARRIVAL_PENDING
        return false

    target := NormalizeZhTaskText(SCREEN_RECORDING_STOP_LRMC_TASK)
    current := NormalizeZhTaskText(taskName)
    __SCREEN_RECORDING_LRMC_ARRIVAL_PENDING := false

    if (target = "")
        return false

    if (InStr(current, target) || InStr(target, current)) {
        WriteLog("錄影任務停止命中：" taskName "（設定=" SCREEN_RECORDING_STOP_LRMC_TASK "）")
        return TryStopScreenRecording("LRMCAI任務完成")
    }

    WriteLog("錄影任務停止未命中：" taskName "（設定=" SCREEN_RECORDING_STOP_LRMC_TASK "）", "INFO")
    return false
}

TryStopScreenRecordingByTemplate() {
    global SCREEN_RECORDING_ENABLED, SCREEN_RECORDING_STOP_MODE, __SCREEN_RECORDING_ACTIVE, __SCREEN_RECORDING_TEMPLATE_WARNED

    if !SCREEN_RECORDING_ENABLED
        return false
    if !__SCREEN_RECORDING_ACTIVE
        return false
    if (SCREEN_RECORDING_STOP_MODE != "template")
        return false

    templatePath := ResolveScreenRecordingStopTemplatePath()
    if (templatePath = "") {
        if !__SCREEN_RECORDING_TEMPLATE_WARNED {
            WriteLog("螢幕錄影模板停止條件未設定有效模板路徑", "WARN")
            __SCREEN_RECORDING_TEMPLATE_WARNED := true
        }
        return false
    }
    if !FileExist(templatePath) {
        if !__SCREEN_RECORDING_TEMPLATE_WARNED {
            WriteLog("螢幕錄影模板檔不存在: " templatePath, "WARN")
            __SCREEN_RECORDING_TEMPLATE_WARNED := true
        }
        return false
    }

    x := 0
    y := 0
    try {
        if ImageSearch(&x, &y, 0, 0, A_ScreenWidth, A_ScreenHeight, templatePath) {
            WriteLog("螢幕錄影停止模板命中: " templatePath " @" x "," y)
            return TryStopScreenRecording("模板命中")
        }
    } catch as e {
        if !__SCREEN_RECORDING_TEMPLATE_WARNED {
            WriteLog("螢幕錄影模板檢測失敗: " e.Message, "WARN")
            __SCREEN_RECORDING_TEMPLATE_WARNED := true
        }
    }
    return false
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

ParseServerScheduleList(raw) {
    out := []
    seen := Map()
    if !IsSet(raw)
        return out

    txt := StrReplace(raw, "`r", "`n")
    token := ""
    depth := 0

    Loop Parse, txt {
        ch := A_LoopField

        if (ch = "(" || ch = "（") {
            depth += 1
            token .= ch
            continue
        }

        if (ch = ")" || ch = "）") {
            if (depth > 0)
                depth -= 1
            token .= ch
            continue
        }

        isSeparator := (ch = "," || ch = ";" || ch = "|" || ch = "`n")
        if (isSeparator && depth = 0) {
            name := Trim(token, " `t`r`n")
            if (name != "") {
                key := StrLower(name)
                if !seen.Has(key) {
                    seen[key] := 1
                    out.Push(name)
                }
            }
            token := ""
            continue
        }

        token .= ch
    }

    name := Trim(token, " `t`r`n")
    if (name != "") {
        key := StrLower(name)
        if !seen.Has(key) {
            seen[key] := 1
            out.Push(name)
        }
    }
    return out
}

NormalizeServerMatchText(s) {
    t := StrLower(Trim(s, " `t`r`n"))
    if (t = "")
        return ""

    ; 常見伺服器名稱別名正規化（中英互通）
    t := StrReplace(t, "亞洲", "asia")
    t := StrReplace(t, "亚服", "asia")
    t := StrReplace(t, "亞服", "asia")
    t := StrReplace(t, "東南亞", "sea")
    t := StrReplace(t, "东南亚", "sea")
    t := StrReplace(t, "美洲", "america")
    t := StrReplace(t, "美服", "america")
    t := StrReplace(t, "歐洲", "europe")
    t := StrReplace(t, "欧洲", "europe")
    t := StrReplace(t, "歐服", "europe")
    t := StrReplace(t, "欧服", "europe")
    t := StrReplace(t, "港澳台", "hmt")

    ; 去除括號內容，讓「HMT(HK, MO, TW)」與「HMT」可以互相命中
    t := RegExReplace(t, "\([^)]*\)", "")
    t := RegExReplace(t, "（[^）]*）", "")

    ; 去除常見空白與分隔符，降低 OCR 標點差異影響
    t := RegExReplace(t, "[\s,，;；|]", "")
    return t
}

IsServerTargetMatch(ocrText, targetText) {
    a := NormalizeServerMatchText(ocrText)
    b := NormalizeServerMatchText(targetText)
    if (a = "" || b = "")
        return false

    ; 先做雙向包含，再回退到原字串包含
    if (InStr(a, b) || InStr(b, a))
        return true
    return InStr(StrLower(ocrText), StrLower(targetText)) ? true : false
}

IsLikelyServerNameText(ocrText) {
    t := NormalizeServerMatchText(ocrText)
    if (t = "")
        return false

    ; 常見伺服器名稱或縮寫（含 OCR 常見變形）
    if (InStr(t, "hmt") || InStr(t, "asia") || InStr(t, "sea") || InStr(t, "america") || InStr(t, "europe"))
        return true

    ; 例如 HMT(HK, MO, TW) 去括號後可能殘留 hk/mo/tw
    if (InStr(t, "hk") || InStr(t, "mo") || InStr(t, "tw"))
        return true

    return false
}

IsServerConfirmText(ocrText) {
    t := Trim(StrReplace(StrReplace(ocrText, "`r", ""), "`n", ""), " `t")
    if (t = "")
        return false

    return (InStr(t, "確認") || InStr(t, "确认") || InStr(t, "確定") || InStr(t, "确定"))
}

LoadServerScheduleContext(isContinueCycle := false) {
    global CFG_FILE, SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_LIST, SERVER_SCHEDULE_INDEX, CURRENT_SERVER_TARGET, SERVER_SWITCH_POINT_X, SERVER_SWITCH_POINT_Y

    SERVER_SCHEDULE_ENABLED := ParseBool01(IniReadSafe(CFG_FILE, "server_schedule", "enabled", "0"), 0) ? true : false
    rawList := Trim(IniReadSafe(CFG_FILE, "server_schedule", "list", ""), " `t`r`n")
    SERVER_SCHEDULE_LIST := ParseServerScheduleList(rawList)

    WriteLog("伺服器排程狀態載入：enabled=" (SERVER_SCHEDULE_ENABLED ? "1" : "0") ", 清單=" rawList " (" SERVER_SCHEDULE_LIST.Length " 項)")

    sx := Trim(IniReadSafe(CFG_FILE, "server_schedule", "switch_x", "640"), " `t`r`n")
    sy := Trim(IniReadSafe(CFG_FILE, "server_schedule", "switch_y", "549"), " `t`r`n")
    SERVER_SWITCH_POINT_X := (sx ~= "^\d+$") ? Integer(sx) : 640
    SERVER_SWITCH_POINT_Y := (sy ~= "^\d+$") ? Integer(sy) : 549

    if (!SERVER_SCHEDULE_ENABLED || SERVER_SCHEDULE_LIST.Length = 0) {
        CURRENT_SERVER_TARGET := ""
        SERVER_SCHEDULE_INDEX := 1
        WriteLog("伺服器排程未啟用或清單為空，不執行切服")
        return
    }

    idxRaw := Trim(IniReadSafe(CFG_FILE, "server_schedule", "current_index", "1"), " `t`r`n")
    idx := (idxRaw ~= "^\d+$") ? Integer(idxRaw) : 1
    if !isContinueCycle
        idx := 1

    if (idx < 1)
        idx := 1
    if (idx > SERVER_SCHEDULE_LIST.Length)
        idx := 1

    SERVER_SCHEDULE_INDEX := idx
    CURRENT_SERVER_TARGET := SERVER_SCHEDULE_LIST[idx]
    IniWrite idx, CFG_FILE, "server_schedule", "current_index"
    WriteLog("伺服器排程已載入：第 " idx "/" SERVER_SCHEDULE_LIST.Length " 個，目標=" CURRENT_SERVER_TARGET)
}

AdvanceServerScheduleForNextCycle() {
    global CFG_FILE, SERVER_SCHEDULE_ENABLED, SERVER_SCHEDULE_LIST, SERVER_SCHEDULE_INDEX

    if (!SERVER_SCHEDULE_ENABLED || SERVER_SCHEDULE_LIST.Length <= 1)
        return false

    nextIndex := SERVER_SCHEDULE_INDEX + 1
    if (nextIndex > SERVER_SCHEDULE_LIST.Length) {
        IniWrite "1", CFG_FILE, "server_schedule", "current_index"
        WriteLog("伺服器排程已完成全部清單，本輪後不再續跑")
        return false
    }

    IniWrite nextIndex, CFG_FILE, "server_schedule", "current_index"
    WriteLog("伺服器排程切換到下一個：第 " nextIndex "/" SERVER_SCHEDULE_LIST.Length " 個")
    return true
}

GetOcrBlockCenter(block) {
    if (block.HasOwnProp("boxPoint") && IsObject(block.boxPoint)) {
        minX := 2147483647, minY := 2147483647
        maxX := -2147483648, maxY := -2147483648
        found := false
        for _, pt in block.boxPoint {
            if (!IsObject(pt) || !pt.HasOwnProp("x") || !pt.HasOwnProp("y"))
                continue
            x := pt.x, y := pt.y
            if (x < minX)
                minX := x
            if (y < minY)
                minY := y
            if (x > maxX)
                maxX := x
            if (y > maxY)
                maxY := y
            found := true
        }
        if found
            return [Round((minX + maxX) / 2), Round((minY + maxY) / 2)]
    }
    if (block.HasOwnProp("box") && IsObject(block.box)) {
        minX := 2147483647, minY := 2147483647
        maxX := -2147483648, maxY := -2147483648
        found := false
        for _, pt in block.box {
            if (!IsObject(pt) || pt.Length < 2)
                continue
            x := pt[1], y := pt[2]
            if (x < minX)
                minX := x
            if (y < minY)
                minY := y
            if (x > maxX)
                maxX := x
            if (y > maxY)
                maxY := y
            found := true
        }
        if found
            return [Round((minX + maxX) / 2), Round((minY + maxY) / 2)]
    }
    return ""
}

ServerClickClient(hwnd, x, y, logText := "") {
    if !hwnd
        return false

    oldMouseMode := A_CoordModeMouse
    try WinActivate "ahk_id " hwnd
    Sleep 100
    CoordMode "Mouse", "Client"

    MouseMove Round(x), Round(y)
    Sleep 50
    Click
    Sleep 100

    CoordMode "Mouse", oldMouseMode
    if (logText != "")
        WriteLog(logText "，點擊客戶區座標=" Round(x) "," Round(y))
    return true
}

MapReferencePointToClient(hwnd, refX, refY, refW := 1280, refH := 720) {
    if !hwnd
        return ""

    try WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " hwnd)
    catch
        return ""

    if (cw <= 0 || ch <= 0 || refW <= 0 || refH <= 0)
        return ""

    px := cx + Round((refX * cw) / refW)
    py := cy + Round((refY * ch) / refH)
    return [px, py, cw, ch]
}

TrySelectScheduledServer(hwnd, attempt := 1) {
    global CURRENT_SERVER_TARGET, SERVER_SWITCH_POINT_X, SERVER_SWITCH_POINT_Y

    WriteStep("伺服器切換", "入口 target=" CURRENT_SERVER_TARGET " attempt=" attempt)

    if (CURRENT_SERVER_TARGET = "") {
        WriteStepResult("伺服器切換", true, "目標為空，略過")
        return true
    }
    if !hwnd
        return false

    maxAttempts := 3
    if (attempt > maxAttempts) {
        WriteStepResult("伺服器切換", false, "超過最大重試")
        return false
    }

    WriteLog("伺服器排程：準備選擇伺服器 -> " CURRENT_SERVER_TARGET "（嘗試 " attempt "/" maxAttempts "）")
    try WinActivate "ahk_id " hwnd
    try WinRestore "ahk_id " hwnd
    WinWaitActive "ahk_id " hwnd, , 3
    Sleep 400

    ; 先在登入畫面做一次 OCR：若已是目標伺服器，直接略過切換，不做任何點擊
    preMatched := false
    preTempFile := A_Temp "\\server_precheck_" A_TickCount ".png"
    WriteLog("伺服器排程：開始預檢登入畫面是否已是目標伺服器 (" CURRENT_SERVER_TARGET ")")
    try {
        ImagePutFile(hwnd, preTempFile)
        preOcr := RapidOcr()
        preRes := preOcr.ocr_from_file(preTempFile, , true)
        ocrRecognized := ""
        if IsObject(preRes) {
            for block in preRes {
                txt := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
                if (txt = "")
                    continue
                ocrRecognized .= (ocrRecognized = "" ? "" : " | ") txt
                if IsServerTargetMatch(txt, CURRENT_SERVER_TARGET) {
                    preMatched := true
                    break
                }
            }
            WriteLog("伺服器排程：預檢 OCR 辨識結果：" ocrRecognized)
        } else {
            WriteLog("伺服器排程：預檢 OCR 無結果（res 不是物件）", "WARN")
        }
    } catch as e {
        WriteLog("伺服器排程：預檢 OCR 失敗，改走切服流程: " e.Message, "WARN")
    }
    try FileDelete(preTempFile)

    if preMatched {
        WriteLog("伺服器排程：登入畫面已是目標伺服器 " CURRENT_SERVER_TARGET "，略過切換動作")
        WriteStepResult("伺服器切換", true, "已是目標伺服器")
        return true
    }

    if (CURRENT_SERVER_TARGET = "") {
        WriteLog("伺服器排程：目標伺服器為空，略過切換")
        WriteStepResult("伺服器切換", true, "目標為空")
        return true
    }

    WriteLog("伺服器排程：登入畫面不是目標伺服器，需要執行切換 -> " CURRENT_SERVER_TARGET)

    WriteLog("伺服器排程：準備用 OCR 找伺服器名稱區塊並點擊開選單")

    tempFile := A_Temp "\\server_menu_" A_TickCount ".png"
    serverMenuOpened := false
    menuOpenBy := ""
    try {
        ImagePutFile(hwnd, tempFile)
        ocr := RapidOcr()
        res := ocr.ocr_from_file(tempFile, , true)
        if IsObject(res) {
            for block in res {
                txt := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
                if (txt = "")
                    continue

                c := GetOcrBlockCenter(block)
                if (IsObject(c) && IsLikelyServerNameText(txt)) {
                    ServerClickClient(hwnd, c[1], c[2], "伺服器排程：找到伺服器名稱區塊（" txt "）")
                    serverMenuOpened := true
                    menuOpenBy := "server-name"
                    Sleep 1600
                    break
                }
            }
        }
    } catch as e {
        WriteLog("伺服器排程：OCR 掃伺服器名稱區塊失敗: " e.Message, "WARN")
    }
    try FileDelete(tempFile)

    ; 若 OCR 沒找到伺服器名稱區塊，直接用客戶區內固定座標（例如 640,549）
    if !serverMenuOpened {
        ServerClickClient(hwnd, SERVER_SWITCH_POINT_X, SERVER_SWITCH_POINT_Y, "伺服器排程：OCR 未找到伺服器名稱區塊，改用客戶區固定座標=" SERVER_SWITCH_POINT_X "," SERVER_SWITCH_POINT_Y)
        Sleep 1600
    } else {
        WriteLog("伺服器排程：已開啟伺服器選單，方式=" menuOpenBy)
    }

    tempFile := A_Temp "\\server_pick_" A_TickCount ".png"
    try {
        ImagePutFile(hwnd, tempFile)
        ocr := RapidOcr()
        res := ocr.ocr_from_file(tempFile, , true)
    } catch as e {
        WriteLog("伺服器排程：OCR 失敗: " e.Message, "WARN")
        try FileDelete(tempFile)
        Sleep 800
        return TrySelectScheduledServer(hwnd, attempt + 1)
    }
    try FileDelete(tempFile)

    targetClicked := false

    if IsObject(res) {
        for block in res {
            txt := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
            if (txt = "")
                continue

            if (!targetClicked && IsServerTargetMatch(txt, CURRENT_SERVER_TARGET)) {
                c := GetOcrBlockCenter(block)
                if IsObject(c) {
                    ServerClickClient(hwnd, c[1], c[2], "伺服器排程：已點選伺服器 " CURRENT_SERVER_TARGET "（OCR: " txt "）")
                    targetClicked := true
                    Sleep 500
                    break
                }
            }
        }
    }

    if !targetClicked {
        WriteLog("伺服器排程：未在列表中找到目標伺服器文字 -> " CURRENT_SERVER_TARGET, "WARN")
        WriteStepResult("伺服器切換", false, "找不到目標伺服器文字")
        Sleep 800
        return TrySelectScheduledServer(hwnd, attempt + 1)
    }

    ; 點選伺服器後需再點擊「確認」
    confirmClicked := false
    tempFile := A_Temp "\\server_confirm_" A_TickCount ".png"
    try {
        ImagePutFile(hwnd, tempFile)
        ocr := RapidOcr()
        resConfirm := ocr.ocr_from_file(tempFile, , true)
        if IsObject(resConfirm) {
            for block in resConfirm {
                txt := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
                if (txt = "")
                    continue

                if IsServerConfirmText(txt) {
                    c := GetOcrBlockCenter(block)
                    if IsObject(c) {
                        ServerClickClient(hwnd, c[1], c[2], "伺服器排程：已點擊確認按鈕（OCR: " txt "）")
                        confirmClicked := true
                        Sleep 600
                        break
                    }
                }
            }
        }
    } catch as e {
        WriteLog("伺服器排程：OCR 掃確認按鈕失敗: " e.Message, "WARN")
    }
    try FileDelete(tempFile)

    if !confirmClicked {
        confirmX := 890
        confirmY := 543
        ServerClickClient(hwnd, confirmX, confirmY, "伺服器排程：未找到確認文字，改用固定確認座標")
        Sleep 600
        confirmClicked := true
    }

    if confirmClicked {
        WriteLog("伺服器排程：伺服器切換完成 -> " CURRENT_SERVER_TARGET)
        WriteStepResult("伺服器切換", true, "target=" CURRENT_SERVER_TARGET)
        return true
    }

    WriteLog("伺服器排程：確認按鈕點擊失敗，準備重試", "WARN")
    WriteStepResult("伺服器切換", false, "確認按鈕點擊失敗")
    Sleep 800
    return TrySelectScheduledServer(hwnd, attempt + 1)
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
        LoadScreenRecordingEnabled()
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
    recipients := ParseMailRecipients(mailTo)
    if (recipients.Length = 0)
        return { ok: false, message: "收件者為空，請在 to 填入至少一位收件者" }

    mailToCsv := ""
    for idx, addr in recipients {
        if (idx > 1)
            mailToCsv .= ","
        mailToCsv .= addr
    }

    escHost := PsEsc(smtpHost)
    escUser := PsEsc(smtpUser)
    escPass := PsEsc(smtpPass)
    escFrom := PsEsc(mailFrom)
    escToCsv := PsEsc(mailToCsv)
    escSubject := PsEsc(subject)
    escBody := PsEsc(body)

    script := "$ErrorActionPreference = 'Stop'`n"
    script .= "[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12`n"
    script .= "$smtpHost = '" escHost "'`n"
    script .= "$smtpPort = " smtpPort "`n"
    script .= "$smtpUser = '" escUser "'`n"
    script .= "$smtpPass = '" escPass "'`n"
    script .= "$mailFrom = '" escFrom "'`n"
    script .= "$mailToCsv = '" escToCsv "'`n"
    script .= "$subject = '" escSubject "'`n"
    script .= "$body = '" escBody "'`n"
    script .= "$useSsl = " ((useSsl = "1" || StrLower(useSsl) = "true") ? "$true" : "$false") "`n"
    script .= "try {`n"
    script .= "  $msg = New-Object System.Net.Mail.MailMessage`n"
    script .= "  $msg.From = $mailFrom`n"
    script .= "  $mailToList = $mailToCsv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }`n"
    script .= "  foreach ($to in $mailToList) { $msg.To.Add($to) }`n"
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

    cmd := A_ComSpec ' /D /C ""powershell" -NoProfile -ExecutionPolicy Bypass -File "' psFile '" > "' errFile '" 2>&1"'
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

ParseMailRecipients(mailToText) {
    text := StrReplace(mailToText, "`r`n", ",")
    text := StrReplace(text, "`n", ",")
    text := StrReplace(text, ";", ",")

    recipients := []
    for _, part in StrSplit(text, ",") {
        addr := Trim(part, " `t`r`n")
        if (addr != "")
            recipients.Push(addr)
    }
    return recipients
}

PsEsc(text) {
    return StrReplace(text, "'", "''")
}


; =========================================================
; 額外模板檢測與點擊邏輯
; =========================================================
ClickTemplateIfFound(templatePath) {
    x := 0
    y := 0
    try {
        if ImageSearch(&x, &y, 0, 0, A_ScreenWidth, A_ScreenHeight, templatePath) {
            Click x, y
            WriteLog("模板檢測到並點擊: " . templatePath)
            return true
        }
    } catch as e {
        ; 可選檢測：任何錯誤都不影響主流程。
        WriteLog("模板檢測略過（不影響主流程）: " . templatePath . " | " . e.Message, "WARN")
        return false
    }
    WriteLog("模板未檢測到: " . templatePath, "INFO")
    return false
}
