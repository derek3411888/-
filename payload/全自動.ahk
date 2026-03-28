#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir

; 馃洝锔?鑷嫊鎻愭瑠
if !A_IsAdmin {
    try Run('*RunAs "' A_ScriptFullPath '"')
    ExitApp
}

; 鈿?瑷畾鏅€氬劒鍏堢礆浠ユ笡灏戠郴绲辫矤鎿?
ProcessSetPriority("Normal")

; DPI 鎰熺煡锛堥伩鍏嶇府鏀炬敼璁婂骇妯?褰卞儚锛?
try DllCall("SetProcessDpiAwarenessContext", "ptr", -4)  ; PER_MONITOR_AWARE_V2
catch 
    try DllCall("shcore\SetProcessDpiAwareness", "int", 2)

#Include plugin\RapidOcr\RapidOcr.ahk
#Include plugin\ImagePut-1.11\ImagePut.ahk
#Include LogManager.ahk

; 鍒濆鍖栨柊鐨勬棩瑾岀郴绲?
global logger := InitLogger("鍏ㄨ嚜鍕?)
RegisterLifecycleLogging("鍏ㄨ嚜鍕?)
global RUN_ID := A_Now "@" A_TickCount
global RUN_START_TS := A_Now
global STEP_SEQ := 0

; 鏀跺熬鐩ｆ脯瑷畾锛堝懡涓叐姊濄€岄浕鍙癬涓€閸甸牁鍙栥€嶅緦寤堕伈闂滈枆锛?
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
global LAST_RESTART_REASON := ""
global PROCESS_DETECT_RETRY_COUNT := 6
global PROCESS_DETECT_RETRY_DELAY_MS := 800
global WUTHERING_STARTUP_WAIT_SEC := 45
global WUTHERING_NO_WINDOW_TOLERANCE := 3

; 淇濆簳锛氫换浣曟柟寮忛洟闁嬭叧鏈檪閮藉槜瑭︽仮寰╄伈闊?
OnExit(RestoreWutheringAudioOnExit)

; 鎻愮ず宸ュ叿锛堥枊闋姞5鍊嬬┖鐧介伩鍏嶈婊戦紶閬搵锛?
ShowTip(msg, duration := 1200) {
    ToolTip "          " msg
    if (duration > 0)
        SetTimer(() => ToolTip(), -duration)
}

; 鍘婚櫎璺緫鍓嶅緦鐨勫紩铏熷拰绌虹櫧
NormalizePath(p) {
    return Trim(p, ' "')
}

MuteWutheringAudioAtStartup() {
    global __WUTHERING_MUTE_PENDING
    __WUTHERING_MUTE_PENDING := true
    TryMuteWutheringAudio("涓绘祦绋嬪墠缃?)
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
        WriteLog("宸叉垚鍔熷鐢ㄩ炒娼柈鐛ㄩ潨闊?)
    }
}

TryMuteWutheringAudio(reason := "") {
    global __WUTHERING_MUTE_PENDING
    if TrySetWutheringProcessMute(true) {
        __WUTHERING_MUTE_PENDING := false
        SetTimer(WutheringMuteTick, 0)
        msg := "宸插暉鐢ㄩ炒娼柈鐛ㄩ潨闊?
        if (reason != "")
            msg .= "锛? reason "锛?
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
        msg := "宸叉仮寰╅炒娼伈闊?
        if (reason != "")
            msg .= "锛? reason "锛?
        WriteLog(msg)
    } else {
        WriteLog("鎭㈠京槌存疆鑱查煶澶辨晽鎴栧皻鏈缓绔嬮煶瑷?Session", "WARN")
    }
}

RestoreWutheringAudioOnExit(exitReason, exitCode) {
    UnmuteWutheringAudio("鑵虫湰绲愭潫淇濆簳")
}

GetWutheringAudioTargets() {
    global CFG_FILE, WUTHERING_PROCESS_EXE

    pidMap := Map()
    nameMap := Map()

    for title in ["楦ｆ疆", "槌存疆"] {
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
        WriteLog("槌存疆闊宠▕鎺у埗鍩疯澶辨晽锛圥owerShell 鍛煎彨閷锛?, "WARN")
        return false
    }

    try FileDelete psFile
    if (code = 0) {
        __WUTHERING_AUDIO_MUTED := mute ? true : false
        return true
    }

    WriteLog("槌存疆闊宠▕鎺у埗鏈懡涓换浣?Session锛岄€€鍑虹⒓=" code " pids=" targets.pids " names=" targets.names, "WARN")
    return false
}

; 鏃ヨ獙鍑芥暩锛堜娇鐢ㄦ柊鐨勬棩瑾岀郴绲憋級
WriteLog(msg, level := "INFO") {
    global logger, RUN_ID
    if IsSet(logger) && IsObject(logger) {
        logger.log("[" RUN_ID "] " msg, level)
    } else {
        ; 鍌欑敤鏂规
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
    ShowTip("馃搶 " stepName, 700)
}

WriteLog("鍏ㄨ嚜鍕曡叧鏈暉鍕? " A_ScriptFullPath)
WriteStep("鍟熷嫊", "PID=" DllCall("GetCurrentProcessId") " AHK=" A_AhkVersion)

; 閸电洡鏇寸┅
SendMode "Input"
SetKeyDelay 40, 40



; === 浣跨敤鍟熷嫊鍣ㄨВ澹撶殑浣嶇疆 ===
; 鐝惧湪AutoHotkey64.exe浣嶆柤宸ヤ綔鐩寗鐨勪笂灞わ紙鑷嫊閶ゅ湴璩囨枡澶撅級
AhkExe := A_ScriptDir "\..\AutoHotkey64.exe"
WriteLog("鍢楄│浣跨敤 AutoHotkey: " AhkExe)
if !FileExist(AhkExe) {
    WriteLog("鏈壘鍒伴爯瑷綅缃殑 AutoHotkey锛屽槜瑭﹀緸鐠板璁婃暩鐛插彇", "WARN")
    ; 濡傛灉鎵句笉鍒帮紝鍢楄│寰炵挵澧冭畩鏁哥嵅鍙?
    packAppDir := EnvGet("PACK_APP_DIR")
    if (packAppDir != "") {
        AhkExe := StrReplace(packAppDir, "\payload", "") "\AutoHotkey64.exe"
        WriteLog("寰炵挵澧冭畩鏁稿槜瑭﹁矾寰? " AhkExe)
    }
    if !FileExist(AhkExe) {
        WriteLog("鎵句笉鍒颁换浣?AutoHotkey 鍩疯妾? " AhkExe, "ERROR")
        MsgBox "鎵句笉鍒?AutoHotkey64.exe锛歚n" AhkExe "`n璜嬪厛鍩疯銆屾墦鍖呭暉鍕曞櫒銆嶅畬鎴愯В澹撱€?
        ExitApp
    }
} else {
    WriteLog("鎴愬姛鎵惧埌 AutoHotkey: " AhkExe)
}

; 鈽?鍟熷嫊 UE4 宕╂桨鍏ㄥ煙鐩ｇ湅锛堢崹绔?UE4-Client 瑕栫獥锛?
StartCrashWatcher()

okwwExe := "OK-WW.exe"   ; 鐢卞伐浣滅鐞嗗摗纰鸿獚

; ===== 璺緫铏曠悊锛堝劒鍏堜娇鐢ㄦ墦鍖呭暉鍕曞櫒瑷畾鐨勭挵澧冭畩鏁革級=====
dataDir := EnvGet("PACK_DATA_DIR")
if (dataDir = "") {
    ; 濡傛灉娌掓湁鐠板璁婃暩锛屽槜瑭︿娇鐢ㄦ柊鐨勪綅缃?
    dataDir := A_ScriptDir "\..\config"
    if !DirExist(dataDir) {
        ; 鍚戝緦鍏煎鑸婁綅缃?
        dataDir := A_Temp "\okww_runtime\config"
    }
}
DirCreate dataDir
global CFG_FILE := dataDir "\config.ini"
WriteLog("dataDir=" dataDir)
WriteLog("CFG_FILE=" CFG_FILE)
WriteStep("杓夊叆瑷畾", "config=" CFG_FILE)
LoadMailNotifyEnabled()
SetupTrayMenu()

; 鈽?娴佺▼闁嬪鍓嶇当涓€妾㈡煡锛氱▼寮忚矾寰?+ 閮典欢閫氱煡瑷畾
WriteStep("鍓嶇疆妾㈡煡", "绋嬪紡璺緫鑸囬€氱煡瑷畾")
EnsureAllConfigAtStartup()

; 鈽?鍟熷嫊鍓嶆娓細纰轰繚涓夊€嬬▼寮忛兘娌掓湁鍦ㄩ亱琛?
WriteLog("鍩疯鍟熷嫊鍓嶆娓紝纰轰繚鎵€鏈夌洰妯欑▼寮忛兘宸查棞闁?..")
WriteStep("娓呭牬", "闂滈枆鏃㈡湁鐩閫茬▼")
CheckAndCloseExistingProcesses()

; 璁€鍙栭噸鍟熻▓鏁稿櫒锛堥伩鍏嶇劇闄愬惊鐠帮級
global MAX_RESTART_COUNT := 3
global restartCount := Integer(IniReadSafe(CFG_FILE, "restart_tracking", "auto_restart_count", "0"))
WriteLog("鐩墠閲嶅暉娆℃暩: " restartCount "/" MAX_RESTART_COUNT)

; 妾㈡煡鏄惁鐐洪噸鍟熸ā寮忥紙閬婃埐鏇存柊寰岄渶瑕侀噸鏂板暉鍕昈KWW锛?
isRestart := false
if A_Args.Length > 0 && A_Args[1] = "restart" {
    isRestart := true
    WriteLog("妾㈡脯鍒伴噸鍟熸ā寮忥紝閬婃埐鏇存柊寰屽皣閲嶆柊鍟熷嫊OKWW")
    prevReason := Trim(IniReadSafe(CFG_FILE, "restart_tracking", "last_restart_reason", ""), " `t`r`n")
    prevTime := Trim(IniReadSafe(CFG_FILE, "restart_tracking", "last_restart_time", ""), " `t`r`n")
    if (prevReason != "") {
        detail := prevReason
        if (prevTime != "")
            detail .= " @ " prevTime
        WriteStep("涓婃閲嶅暉鍘熷洜", detail, "WARN")
    }
}

; 1) 鍏堣檿鐞嗛炒娼洿鏂帮紡鐧诲叆锛孫KWW 涔嬪緦鍐嶅暉鍕?
maxUpdateLoops := 3
updateLoops := 0
loginDetected := false
okwwStarted := false

EnsureWutheringRunning()
WriteStep("槌存疆妾㈡煡", "鏇存柊鑸囩櫥鍏ユ祦绋?)

loop {
    loginDetected := false
    detectState := DetectWutheringAndExit(&loginDetected)
    if (detectState = "update") {
        updateLoops++
        WriteLog("鍋垫脯鍒伴炒娼洿鏂帮紝绛夊緟閬婃埐鑷嫊閲嶅暉寰屽啀娆℃娓?(" updateLoops "/" maxUpdateLoops ")")
        Sleep 8000
        if (updateLoops >= maxUpdateLoops) {
            WriteLog("槌存疆鏇存柊妾㈡脯閬斾笂闄愶紝鍋滄鑷嫊杩村湀锛岀辜绾屽緦绾屾祦绋?, "WARN")
            break
        }
        continue
    }

    if (detectState = "no_window") {
        WriteLog("槌存疆瑕栫獥灏氭湭灏辩窉锛坣o_window锛夛紝閬垮厤瑾ゅ垽鐧诲叆锛岀瓑寰呭緦閲嶈│", "WARN")
        Sleep 3000
        continue
    }

    if (detectState = "unknown") {
        WriteLog("槌存疆鐙€鎱嬪皻鏈槑纰猴紙unknown锛夛紝涓嶆彁鍓嶅垽瀹氱櫥鍏?, "WARN")
    }
    break
}

; 鐧诲叆鐣潰鏅傦細绋嶇瓑涓﹂粸鎿婅绐椾腑澶紝鍠氶啋鍒板彲鎿嶄綔鐙€鎱?
if (loginDetected) {
    WriteLog("鐧诲叆鐣潰闅庢鍟熷嫊 OKWW锛岄粸鎿婅绐楀墠鍏堝暉鍕?)
    StartOKWWFlow(isRestart)
    okwwStarted := true

    hwndLogin := GetWutheringGameHwnd()
    WriteLog("妾㈡脯鍒扮櫥鍏ョ暙闈紝鍢楄│榛炴搳瑕栫獥涓績鍠氶啋")
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
        ; 榛炴搳寰岀瓑寰呴亰鎴查€插叆涓讳粙闈紙寰炵櫥鍏ュ埌鍙搷浣滈渶瑕佹檪闁擄級
        WriteLog("鐧诲叆寰岀瓑寰呴亰鎴茶級鍏ヤ富浠嬮潰...")
        Sleep 15000  ; 椤嶅绛夊緟15绉掕畵閬婃埐瀹屽叏閫插叆
        ShowTip("鉁?宸查粸鎿婄櫥鍏ョ暙闈腑澶?)
    } else {
        WriteLog("鐧诲叆鐣潰榛炴搳澶辨晽锛氭壘涓嶅埌槌存疆瑕栫獥", "WARN")
            ShowTip("鉂?鎵句笉鍒伴炒娼绐?, 1200)
    }
}

; 2) 鐧诲叆寰屽暉鍕?OKWW 涓︾⒑瑾嶅暉鍕曟垚鍔?
if !okwwStarted {
    WriteLog("閬婃埐鍙搷浣滈璀夐€氶亷鍓嶏紝涓嶆彁鍓嶅鍛婄櫥鍏ュ畬鎴?)
}

; 3) 鐢ㄤ富鐣潰妯℃澘姣斿皪椹楄瓑閬婃埐鏄惁鍙搷浣滐紙鍘绘姈鍕曪級
gameHwnd := GetWutheringGameHwnd()
WriteLog("闁嬪涓荤暙闈㈡ā鏉块璀夛紙鏈€澶?90 绉掞級...")
if !WaitEscMenuOCR(gameHwnd, 90) {
    WriteLog("槌存疆鐒℃硶浣跨敤鎴栬秴鏅傦紝瑙哥櫦閲嶅暉姗熷埗", "ERROR")
    ShowTip("鈿狅笍 槌存疆鐒℃硶浣跨敤锛岄噸鏂板暉鍕?..", 3000)
    Sleep 3000
    RequestRestart("閬婃埐鍙搷浣滈璀夎秴鏅傛垨澶辨晽")
    return
}
WriteStep("閬婃埐鍙搷浣滈璀?, "妯℃澘姣斿皪閫氶亷")

; 4) 鍙湁鍦ㄥ彲鎿嶄綔椹楄瓑閫氶亷寰岋紝鎵嶅暉鍕?OKWW锛堥伩鍏嶉亷鏃╁暉鍕曪級
if !okwwStarted {
    WriteLog("閬婃埐宸插彲鎿嶄綔锛岄枊濮嬪暉鍕?OKWW...")
    WriteStep("鍟熷嫊OKWW", isRestart ? "閲嶅暉妯″紡" : "涓€鑸ā寮?)
    StartOKWWFlow(isRestart)
    okwwStarted := true
}

; 5) 鍩疯鑱查鍚堟垚娴佺▼
WriteLog("鍟熷嫊鑱查鍚堟垚鑵虫湰...")
WriteStep("鍟熷嫊鑱查鍚堟垚", "绛夊緟瀹屾垚鎴栭噸鍟熸瑷?)
ShowTip("馃敡 姝ｅ湪鍩疯鑱查鍚堟垚...", 1500)
; 椤嶅绛夊緟纰轰繚OKWW鍟熷嫊寰岄炒娼畬鍏ㄧ┅瀹?
WriteLog("绛夊緟OKWW鍒濆鍖栧畬鎴愶紝纰轰繚閬婃埐绌╁畾...")
Sleep 5000  ; 鍐嶇瓑5绉掞紝纰轰繚槌存疆瀹屽叏绌╁畾
try {
    Run('"' AhkExe '" "' A_ScriptDir '\鑱查鍚堟垚.ahk"')
    WriteLog("鑱查鍚堟垚鑵虫湰宸插暉鍕?)
    
    ; 绛夊緟鑱查鍚堟垚瀹屾垚锛堟鏌ラ€茬▼鏄惁閭勫湪閬嬭锛?
    maxWaitTime := 1800000  ; 鏈€澶氱瓑寰?0鍒嗛悩
    startTime := A_TickCount
    
    Sleep 5000  ; 鍏堢瓑5绉掕畵鑵虫湰鍟熷嫊
    
    ; 鎸佺簩妾㈡煡鑱查鍚堟垚閫茬▼鏄惁閭勫湪閬嬭
    while (A_TickCount - startTime < maxWaitTime) {
        found := false
        try {
            for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process") {
                try {
                    if (InStr(proc.Name, "AutoHotkey")) {
                        cmdLine := proc.CommandLine
                        if (InStr(cmdLine, "鑱查鍚堟垚.ahk")) {
                            found := true
                            break
                        }
                    }
                } catch {
                    continue
                }
            }
        } catch as e {
            WriteLog("妾㈡煡鑱查鍚堟垚閫茬▼鏅傚嚭閷? " e.Message, "WARN")
        }
        
        if (!found) {
            WriteLog("鑱查鍚堟垚宸插畬鎴?)
            ShowTip("鉁?鑱查鍚堟垚宸插畬鎴?, 2000)
            
            ; 妾㈡煡鏄惁鏈夐噸鍟熸瑷?
            flagFile := dataDir "\synthesis_restart.flag"
            if FileExist(flagFile) {
                WriteLog("鍋垫脯鍒拌伈楠稿悎鎴愯姹傞噸鍟燂紝鍒櫎妯欒涓﹁Ц鐧奸噸鍟熸鍒?, "WARN")
                try FileDelete(flagFile)
                Sleep 2000
                RequestRestart("鑱查鍚堟垚鍥炲牨閲嶅暉鏃楁 synthesis_restart.flag", "WARN")
                return
            }
            break
        }
        
        Sleep 2000  ; 姣?绉掓鏌ヤ竴娆?
    }
    
    if (A_TickCount - startTime >= maxWaitTime) {
        WriteLog("鑱查鍚堟垚瓒呮檪锛岃Ц鐧奸噸鍟熸鍒?, "ERROR")
        ShowTip("鈿狅笍 鑱查鍚堟垚瓒呮檪锛岄噸鏂板暉鍕?..", 3000)
        Sleep 3000
        RequestRestart("鑱查鍚堟垚娴佺▼瓒呮檪")
        return
    }
    
} catch as e {
    WriteLog("鑱查鍚堟垚鑵虫湰鍟熷嫊澶辨晽锛岃烦閬庝甫绻肩簩寰岀簩娴佺▼: " e.Message, "ERROR")
    ShowTip("鈿狅笍 鑱查鍚堟垚鍟熷嫊澶辨晽锛岀辜绾屽煼琛?..", 2000)
    Sleep 2000
}

; 4) 鍟熷嫊 LRMC 绠＄悊鑵虫湰锛堢敱瑭茶叧鏈矤璨琇RMC鐨勫暉鍕曡垏绠＄悊锛?
WriteLog("鍟熷嫊 LRMC 绠＄悊鑵虫湰...")
WriteStep("鍟熷嫊LRMC", "浜ょ敱闁嬪暉LRMC.ahk 鎺у埗")
Run('"' AhkExe '" "' A_ScriptDir '\闁嬪暉LRMC.ahk"')
ShowTip("馃煝 宸插暉鍕?LRMC 绠＄悊鑵虫湰", 3000)


; 鎴愬姛瀹屾垚娴佺▼锛岄噸缃噸鍟熻▓鏁稿櫒
IniWrite "0", CFG_FILE, "restart_tracking", "auto_restart_count"
WriteLog("娴佺▼鎴愬姛瀹屾垚锛屽凡閲嶇疆閲嶅暉瑷堟暩鍣?)
WriteStep("涓绘祦绋嬪畬鎴?, "閲嶅暉瑷堟暩宸叉闆?)

WriteLog("鍏ㄨ嚜鍕曟祦绋嬪畬鎴愶紝閫插叆鏀跺熬鐩ｆ脯锛堢瓑寰呴浕鍙颁竴閸甸牁鍙栭仈妯欙級")
WriteStep("鏀跺熬鐩ｆ脯", "绛夊緟闆诲彴涓€閸甸牁鍙栨浠?)
MonitorRewardAndShutdown()
ExitApp


; ======================== 鍑藉紡鍗€ ========================

; 鈽?OKWW 鍟熷嫊锛嬪墠缃祦绋嬶紙鍟熷嫊 鈫?绛夊緟 鈫?F11 鈫?鏈€灏忓寲锛?
StartOKWWFlow(isRestart) {
    WriteLog("鍟熷嫊 OKWW 绠＄悊鑵虫湰...")
    if isRestart {
        ShowTip("馃攧 閲嶅暉妯″紡锛氶噸鏂板暉鍕?OKWW", 1500)
        Sleep 1500
    }
    ahkCommand := '"' AhkExe '" "' A_ScriptDir '\鑷嫊闁嬪暉OKWW.ahk"'
    WriteLog("鍩疯鍛戒护: " ahkCommand)
    try {
        Run(ahkCommand)
        WriteLog("OKWW 绠＄悊鑵虫湰鍟熷嫊鎴愬姛" . (isRestart ? "锛堥噸鍟熸ā寮忥級" : ""))
    } catch as e {
        WriteLog("OKWW 绠＄悊鑵虫湰鍟熷嫊澶辨晽: " e.Message, "ERROR")
    }
    ShowTip("馃煝 宸插暉鍕?OKWW 绠＄悊鑵虫湰" . (isRestart ? "锛堥噸鏂板暉鍕曪級" : ""), 3000)

    WriteLog("绛夊緟 OKWW 瑕栫獥鍑虹従...")
    Sleep 20000
    
    ; 灏嬫壘涓︽縺娲?OKWW 涓昏绐?
    WriteLog("灏嬫壘 OKWW 涓昏绐椾甫鐧奸€?F11...")
    okwwHwnd := 0
    maxAttempts := 10
    attempt := 0
    
    while (attempt < maxAttempts && !okwwHwnd) {
        attempt++
        try {
            ; 灏嬫壘妯欓鍖呭惈 "OK-WW" 鍜?"Global" 鐨勮绐楋紙鏍煎紡: OK-WW v鐗堟湰鏁稿瓧 Global锛?
            for hwnd in WinGetList() {
                title := WinGetTitle(hwnd)
                ; 鍖归厤 "OK-WW v鐗堟湰鏁稿瓧 Global" 鏍煎紡
                if (InStr(title, "OK-WW") && InStr(title, "Global")) {
                    okwwHwnd := hwnd
                    WriteLog("鎵惧埌 OKWW 瑕栫獥: " title)
                    break
                }
            }
        }
        if (!okwwHwnd) {
            WriteLog("绗?" attempt " 娆″皨鎵?OKWW 瑕栫獥澶辨晽锛?绉掑緦閲嶈│...")
            Sleep 2000
        }
    }
    
    if (okwwHwnd) {
        ; 婵€娲?OKWW 瑕栫獥
        try {
            WinActivate "ahk_id " okwwHwnd
            WinWaitActive "ahk_id " okwwHwnd, , 3
            Sleep 500
            
            ; 鎴湒OKWW瑕栫獥涓CR璀樺垾
            WriteLog("闁嬪OCR璀樺垾OKWW瑕栫獥涓殑鍟熷嫊閬婃埐/F11瀛楁ǎ...")
            tempFile := A_Temp "\okww_launch_" A_TickCount ".jpg"
            try {
                ImagePutFile("ahk_id " okwwHwnd, tempFile)
                
                ; OCR璀樺垾
                ocr := RapidOcr()
                res := ocr.ocr_from_file(tempFile, , true)
                
                if FileExist(tempFile)
                    FileDelete(tempFile)
                
                ; 鎼滃皨鍟熷嫊閬婃埐鎴朏11鐩搁棞鏂囧瓧
                foundButton := false
                clickX := 0
                clickY := 0
                
                if IsObject(res) {
                    for block in res {
                        clean := StrReplace(StrReplace(block.text, "`r", ""), "`n", "")
                        clean := StrReplace(clean, " ", "")
                        
                        ; 妾㈡脯鍟熷嫊閬婃埐銆侀枊濮嬶紙绻侀珨銆佺啊楂旓級鎴?F11
                        if InStr(clean, "鍟熷嫊閬婃埐") || InStr(clean, "鍚姩娓告垙") || InStr(clean, "闁嬪") || InStr(clean, "寮€濮?) || InStr(clean, "F11") {
                            WriteLog("鎵惧埌鍟熷嫊鎸夐垥鏂囧瓧: " block.text)
                            ; 瑷堢畻鏂囧瓧涓績榛?- 鏀寔 box 鍜?boxPoint 鍏╃ó鏍煎紡
                            boxData := ""
                            if block.HasOwnProp("box") && IsObject(block.box) && block.box.Length >= 4 {
                                boxData := block.box
                            } else if block.HasOwnProp("boxPoint") && IsObject(block.boxPoint) && block.boxPoint.Length >= 3 {
                                boxData := block.boxPoint
                            }
                            
                            if (boxData != "") {
                                if (boxData[1].HasOwnProp("x")) {
                                    ; boxPoint 鏍煎紡锛歔{x,y}, {x,y}, {x,y}, {x,y}]
                                    clickX := (boxData[1].x + boxData[3].x) / 2
                                    clickY := (boxData[1].y + boxData[3].y) / 2
                                } else {
                                    ; box 鏍煎紡锛歔[x,y], [x,y], [x,y], [x,y]]
                                    clickX := (boxData[1][1] + boxData[3][1]) / 2
                                    clickY := (boxData[1][2] + boxData[3][2]) / 2
                                }
                                foundButton := true
                                WriteLog("瑷堢畻榛炴搳搴ф: " clickX ", " clickY)
                                break
                            } else {
                                WriteLog("璀﹀憡锛氭枃瀛楁搴ф鏍煎紡涓嶆纰?, "WARN")
                            }
                        }
                    }
                }
                
                ; 濡傛灉鎵惧埌鎸夐垥锛岄粸鎿婂畠
                if (foundButton && clickX > 0 && clickY > 0) {
                    WriteLog("榛炴搳鍟熷嫊鎸夐垥搴ф: " clickX ", " clickY)
                    MouseMove clickX, clickY
                    Sleep 200
                    MouseClick "left"
                    WriteLog("宸查粸鎿奜KWW鍟熷嫊鎸夐垥")
                    Sleep 1000
                } else {
                    WriteLog("鏈壘鍒板暉鍕曢亰鎴叉寜閳曪紝鍢楄│浣跨敤鍌欑敤鏂规F11", "WARN")
                    SendEvent "{F11}"
                    WriteLog("宸茬櫦閫丗11鍌欑敤蹇嵎閸?)
                    Sleep 1000
                }
            } catch as e {
                WriteLog("OKWW OCR璀樺垾澶辨晽: " e.Message ", 浣跨敤鍌欑敤鏂规F11", "WARN")
                SendEvent "{F11}"
                WriteLog("宸茬櫦閫丗11鍌欑敤蹇嵎閸?)
                Sleep 1000
            }
        } catch as e {
            WriteLog("婵€娲籓KWW瑕栫獥澶辨晽: " e.Message, "ERROR")
        }
    } else {
        WriteLog("鐒℃硶鎵惧埌 OKWW 瑕栫獥锛岃烦閬庡暉鍕?, "WARN")
    }
    
    Sleep 1000
    MinimizeOKWWWindows()
}

; 鈽?鏈€灏忓寲 OKWW 瑕栫獥
MinimizeOKWWWindows() {
    WriteLog("闁嬪灏嬫壘涓︽渶灏忓寲 OKWW 瑕栫獥...")
    foundCount := 0
    
    ; 灏嬫壘鎵€鏈夊彲鑳界殑 OKWW 瑕栫獥
    for hwnd in WinGetList() {
        try {
            title := WinGetTitle(hwnd)
            processName := WinGetProcessName(hwnd)
            titleLower := StrLower(title)
            
            ; 鎺掗櫎绶ㄨ集鍣ㄥ拰闁嬬櫦宸ュ叿
            isEditor := (InStr(titleLower, "visual studio code") || 
                        InStr(titleLower, "notepad") || 
                        InStr(titleLower, "vscode") ||
                        InStr(processName, "Code.exe") ||
                        InStr(processName, "notepad"))
            
            ; 妾㈡煡鏄惁鐐?OKWW 瑕栫獥
            isOKWWWindow := false
            
            ; 鏂规硶1: 妾㈡煡妯欓鍖呭惈 OKWW 鎴?OK-WW
            if ((InStr(titleLower, "ok-ww") || InStr(titleLower, "okww")) && !isEditor) {
                isOKWWWindow := true
            }
            
            ; 鏂规硶2: 妾㈡煡鏄惁鐐虹浉闂滈€茬▼
            if (processName = "ok-ww.exe" || 
                (processName = "pythonw.exe" && InStr(titleLower, "ok"))) {
                isOKWWWindow := true
            }
            
            if (isOKWWWindow) {
                try {
                    WinMinimize(hwnd)
                    foundCount++
                    WriteLog("宸叉渶灏忓寲 OKWW 瑕栫獥: " title " (閫茬▼: " processName ")")
                } catch as e {
                    WriteLog("鏈€灏忓寲瑕栫獥澶辨晽: " title " - " e.Message, "WARN")
                }
            }
        } catch as e {
            ; 蹇界暐鐒℃硶瀛樺彇鐨勮绐?
        }
    }
    
    if (foundCount > 0) {
        WriteLog("鎴愬姛鏈€灏忓寲 " foundCount " 鍊?OKWW 瑕栫獥")
        ShowTip("馃摜 宸叉渶灏忓寲 " foundCount " 鍊?OKWW 瑕栫獥", 1500)
    } else {
        WriteLog("鏈壘鍒板彲鏈€灏忓寲鐨?OKWW 瑕栫獥", "WARN")
    }
}

; 鈽?鍟熷嫊鍓嶆娓細闂滈枆鎵€鏈夌洰妯欑▼寮?
CheckAndCloseExistingProcesses() {
    WriteLog("闁嬪妾㈡脯鐝炬湁绋嬪紡...")
    
    ; 瀹氱京瑕佹娓殑绋嬪紡锛堜娇鐢ㄥ闅涙娓埌鐨勭▼寮忓悕绋憋級
    processes := [
        {name: "ok-ww.exe", display: "OKWW涓荤▼寮?},
        {name: "pythonw.exe", display: "OKWW鏇存柊妾㈡脯", filter: "OK-WW"},
        {name: "Client-Win64-Shipping.exe", display: "槌存疆閬婃埐"},
        {name: "LRMCAI.exe", display: "LRMC鑷嫊"}
    ]
    
    ; 妾㈡脯涓﹂棞闁夌▼寮?
    foundAny := false
    for process in processes {
        ; 妾㈡煡閫茬▼鏄惁瀛樺湪
        processExists := false
        targetPID := 0
        
        ; 鍏堢敤ProcessExist蹇€熸鏌?
        pid := ProcessExist(process.name)
        if (pid) {
            ; 灏嶆柤pythonw.exe锛岄渶瑕侀澶栨鏌ユ槸鍚︽槸OKWW绋嬪紡
            if (process.name = "pythonw.exe" && process.HasOwnProp("filter")) {
                isTargetProcess := false
                
                ; 鏂规硶1锛氭鏌ヨ绐楁椤?
                try {
                    for hwnd in WinGetList() {
                        if (WinGetProcessName("ahk_id " hwnd) = "pythonw.exe") {
                            title := WinGetTitle("ahk_id " hwnd)
                            titleLower := StrLower(title)
                            
                            ; 鎺掗櫎绶ㄨ集鍣ㄥ拰闁嬬櫦宸ュ叿
                            isEditor := (InStr(titleLower, "visual studio code") || 
                                        InStr(titleLower, "notepad") || 
                                        InStr(titleLower, "vscode"))
                            
                            ; 鍙娓湡姝ｇ殑OKWW绋嬪紡瑕栫獥锛屾帓闄ょ法杓櫒
                            if (InStr(titleLower, StrLower(process.filter)) && !isEditor) {
                                isTargetProcess := true
                                targetPID := WinGetPID("ahk_id " hwnd)
                                WriteLog("閫氶亷瑕栫獥妯欓鎵惧埌OKWW绋嬪紡: " title " (PID:" targetPID ")")
                                break
                            }
                        }
                    }
                } catch as e {
                    WriteLog("妾㈡煡瑕栫獥妯欓鏅傚嚭閷? " e.Message, "WARN")
                }
                
                processExists := isTargetProcess
            } else {
                processExists := true
                targetPID := pid
            }
        }
        
        if (processExists) {
            foundAny := true
            WriteLog("妾㈡脯鍒伴亱琛屼腑鐨?" process.display " (" process.name " PID:" targetPID ")锛屾鍦ㄩ棞闁?..")
            ShowTip("馃攧 闂滈枆鐝炬湁鐨?" process.display " 绋嬪紡...", 1200)
            
            try {
                if (targetPID > 0) {
                    ProcessClose(targetPID)
                } else {
                    ProcessClose(process.name)
                }
                Sleep 1000  ; 绛夊緟绋嬪紡闂滈枆
                
                ; 纰鸿獚鏄惁宸查棞闁?
                if ProcessExist(process.name) {
                    WriteLog("鍢楄│寮峰埗闂滈枆 " process.name, "WARN")
                    Run("taskkill /F /IM " process.name, , "Hide")
                    Sleep 1000
                }
                WriteLog("宸叉垚鍔熼棞闁?" process.display)
            } catch as e {
                WriteLog("闂滈枆 " process.name " 鏅傚嚭閷? " e.Message, "ERROR")
            }
        }
    }
    
    ; 椤嶅妾㈡脯锛氶棞闁夋墍鏈?AutoHotkey 閫茬▼锛堥櫎浜嗚嚜宸憋級
    currentPID := DllCall("GetCurrentProcessId")
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%AutoHotkey%'") {
            if (proc.ProcessId != currentPID) {
                try {
                    cmdLine := proc.CommandLine
                    if (InStr(cmdLine, "鑷嫊闁嬪暉OKWW.ahk") || InStr(cmdLine, "闁嬪暉LRMC.ahk")) {
                        WriteLog("闂滈枆鐝炬湁鐨?AutoHotkey 鑵虫湰: PID=" proc.ProcessId " 鍛戒护琛?" cmdLine)
                        ProcessClose(proc.ProcessId)
                        foundAny := true
                    }
                } catch {
                    ; 蹇界暐瑷晱琚嫆绲曠殑閷
                }
            }
        }
    } catch as e {
        WriteLog("妾㈡脯AutoHotkey閫茬▼鏅傚嚭閷? " e.Message, "WARN")
    }
    
    if foundAny {
        WriteLog("绛夊緟绋嬪紡瀹屽叏闂滈枆...")
        ShowTip("鈴?绛夊緟绋嬪紡瀹屽叏闂滈枆...", 3000)
        WriteLog("鍟熷嫊鍓嶆竻鐞嗗畬鎴?)
    } else {
        WriteLog("娌掓湁妾㈡脯鍒伴亱琛屼腑鐨勭洰妯欑▼寮忥紝鍙互闁嬪涓绘祦绋?)
    }
}

; 鈽?鍏ㄥ煙 UE4 宕╂桨鐩ｇ湅锛堢崹绔?UE4-Client 瑕栫獥锛?
StartCrashWatcher() {
    SetTimer CrashWatcherTick, 5000  ; 寰?绉掗€蹭竴姝ラ檷浣庡埌5绉掞紝澶у箙娓涘皯绯荤当璨犳摂
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
        ; 浣跨敤鍞竴鑷ㄦ檪妾旀鍚嶏紝閬垮厤琛濈獊
        tempFile := A_ScriptDir "\ue4crash_" A_TickCount ".png"
        try {
            ImagePutFile("ahk_id " hwndC, tempFile)
            res := ocr.ocr_from_file(tempFile, , true)
            
            ; 绔嬪嵆娓呯悊鑷ㄦ檪妾旀
            if FileExist(tempFile)
                FileDelete(tempFile)
        } catch as e {
            WriteLog("宕╂桨妾㈡脯 OCR 澶辨晽: " e.Message, "WARN")
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
                    if (InStr(t, "纭畾") || InStr(t, "纰哄畾") || InStr(t, "OK") || InStr(t, "纭") || InStr(t, "Confirm")) {
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

        ; 闂滈枆 OKWW 绋嬪紡锛屽洜鐐洪亰鎴插穿娼伴噸鍟熸檪 OKWW 涔熼渶瑕侀噸鏂板暉鍕?
        try ProcessClose "ok-ww.exe"
        catch
            try ProcessClose "OK-WW.exe"
        Sleep 2000

        ; 浠?AhkExe 閲嶆柊鍟熷嫊鏁存敮鑵虫湰锛屾坊鍔?restart 鍙冩暩
        ; 閲嶅暉寰屽皣閲嶆柊鍟熷嫊 OKWW锛岀⒑淇濆穿娼板緦鐨勫畬鏁存仮寰?
        global AhkExe
        Run('"' AhkExe '" "' A_ScriptFullPath '" restart')
        ExitApp
    } finally busy := false
}

; A) 鏇存柊褰堢獥鍋垫脯锛堢啊楂旈棞閸佃锛夛紜 OCR 绠楀嚭銆愰€€鍑恒€戜腑蹇冮粸榛炴搳
;    閫插叆鍓嶏細鎶婇炒娼绐楄布榻婂彸涓婅
DetectWutheringAndExit(&loginDetected := false) {
    global WUTHERING_NO_WINDOW_TOLERANCE

    loginDetected := false
    SetTitleMatchMode 2
    hwnd := WaitForWutheringGameWindow(120)
    if !hwnd {
        ShowTip("鎵句笉鍒般€孋lient-Win64-Shipping.exe銆嶉亰鎴茶绐楋紙閫炬檪锛夈€?, 1200)
        return "no_window"
    }

    ; 瑕栫獥璨奸綂鍙充笂瑙掞紙纰轰繚鍦ㄨ灑骞曞収锛夆€?闈為棞閸碉紝澶辨晽涓嶄腑鏂?
    try MoveWindowTopRight(hwnd, 0, 0)
    catch as e
        WriteLog("瑕栫獥绉诲嫊澶辨晽锛堥潪鑷村懡锛? " e.Message, "WARN")

    ; 鈴憋笍 鑷冲皯绛夊緟 30 绉掕畵閬婃埐瀹屽叏鍟熷嫊锛堢櫥鍏ョ暙闈竴鑸渶瑕?25-35 绉掞級
    earlyExitDeadline := A_TickCount + 30000
    
    deadline := A_TickCount + 1800000   ; 1800 绉掞紙30 鍒嗛悩锛?
    kwUpdate1 := "鏇存柊瀹屾垚"
    kwUpdate2 := "璇烽噸鏂板惎鍔ㄦ父鎴?
    kwUpdate3 := "閬婃埐鍗冲皣閲嶅暉"
    kwUpdate4 := "娓告垙鍗冲皢閲嶅惎"
    kwBtn     := "閫€鍑?
    
    ; 鍎寲锛氱櫥鍏ョ暙闈㈡娓渶瑕佸鍊嬫寚妯欏悓鏅傚嚭鐝撅紙闄嶄綆瑾ゅ垽锛?
    ; 鐧诲叆鎸夐垥鐩搁棞瑭炲綑锛堝寘鎷€岄粸鎿婇€ｆ帴銆嶏級
    loginBtnKeywords := [ "榛炴搳闁嬪", "鐐瑰嚮寮€濮?, "榛為伕闁嬪", "鐐归€夊紑濮?, "闁嬪閬婃埐", "寮€濮嬫父鎴?, "榛炴搳閫ｆ帴", "鐐瑰嚮杩炴帴", "榛為伕閫ｆ帴", "鐐归€夎繛鎺? ]
    ; 鐧诲叆UI鐩搁棞瑭炲綑锛堝璩櫉/浼烘湇鍣ㄩ伕鎿囷級
    loginUIKeywords := [ "浼烘湇鍣?, "鏈嶅姟鍣?, "璩櫉", "璐﹀彿", "甯宠櫉", "璐︽埛" ]
    noWindowStreak := 0

    while (A_TickCount < deadline) {
        hwnd := GetWutheringGameHwnd()
        if !hwnd {
            noWindowStreak += 1
            if (noWindowStreak >= WUTHERING_NO_WINDOW_TOLERANCE) {
                WriteLog("妾㈡脯閫斾腑閫ｇ簩 " noWindowStreak " 娆″け鍘婚炒娼绐楋紝妯欒鐐?no_window", "WARN")
                return "no_window"
            }
            WriteLog("妾㈡脯閫斾腑鐭毇鎵句笉鍒伴炒娼绐楋紙" noWindowStreak "/" WUTHERING_NO_WINDOW_TOLERANCE "锛夛紝绛夊緟寰岄噸瑭?, "WARN")
            Sleep 1200
            continue
        }
        noWindowStreak := 0

        ; 浣跨敤鍞竴鑷ㄦ檪妾旀鍚嶏紝鍩疯寰屾竻鐞嗭紙娓涘皯纾佺 I/O 琛濈獊锛?
        tempFile := A_ScriptDir "\temp_update_" A_TickCount ".png"
        try {
            ImagePutFile("ahk_id " hwnd, tempFile)
            ocr := RapidOcr()
            res := ocr.ocr_from_file(tempFile, , true)
            
            ; 绔嬪嵆娓呯悊鑷ㄦ檪妾旀锛岄噵鏀剧纰熺┖闁?
            if FileExist(tempFile)
                FileDelete(tempFile)
        } catch as e {
            WriteLog("鏇存柊妾㈡脯 OCR 澶辨晽: " e.Message, "WARN")
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
                
                ; 妾㈡脯鏇存柊鐩搁棞鏂囧瓧
                if InStr(clean, kwUpdate1) || InStr(clean, kwUpdate2) || InStr(clean, kwUpdate3) || InStr(clean, kwUpdate4)
                    foundUpdate := true
                
                ; 妾㈡脯鐧诲叆鎸夐垥鐩搁棞鏂囧瓧
                for _, btnKw in loginBtnKeywords {
                    if InStr(clean, btnKw) {
                        foundLoginBtn := true
                        WriteLog("妾㈡脯鍒扮櫥鍏ユ寜閳曢棞閸靛瓧: " btnKw " 鍦ㄦ枃瀛? " clean)
                        break
                    }
                }
                
                ; 妾㈡脯鐧诲叆UI鐩搁棞鏂囧瓧
                for _, uiKw in loginUIKeywords {
                    if InStr(clean, uiKw) {
                        foundLoginUI := true
                        WriteLog("妾㈡脯鍒扮櫥鍏I闂滈嵉瀛? " uiKw " 鍦ㄦ枃瀛? " clean)
                        break
                    }
                }

                ; 妾㈡脯閫€鍑烘寜閳?
                if InStr(clean, kwBtn) && block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3 {
                    x1 := block.boxPoint[1].x, y1 := block.boxPoint[1].y
                    x2 := block.boxPoint[3].x, y2 := block.boxPoint[3].y
                    btnCenter := [ Round((x1 + x2) / 2), Round((y1 + y2) / 2) ]
                }
                
                ; 妾㈡脯纰鸿獚鎸夐垥锛堢⒑瑾嶃€佺‘璁ゃ€佺⒑瀹氥€佺‘瀹氾級
                if (InStr(clean, "纰鸿獚") || InStr(clean, "纭") || InStr(clean, "纰哄畾") || InStr(clean, "纭畾")) && 
                   block.HasOwnProp("boxPoint") && block.boxPoint.Length >= 3 {
                    x1 := block.boxPoint[1].x, y1 := block.boxPoint[1].y
                    x2 := block.boxPoint[3].x, y2 := block.boxPoint[3].y
                    btnCenter := [ Round((x1 + x2) / 2), Round((y1 + y2) / 2) ]
                    WriteLog("鎵惧埌纰鸿獚鎸夐垥: " clean " 浣嶇疆: " btnCenter[1] "," btnCenter[2])
                }
            }
        }

        if (foundUpdate && IsObject(btnCenter)) {
            ShowTip("鉁?鍋垫脯鍒版洿鏂板畬鎴?鈫?榛炴搳鎸夐垥", 800)
            MouseClick "left", btnCenter[1], btnCenter[2]
            ShowTip("宸查粸鎿婃寜閳曪紝婧栧倷閲嶆柊鍩疯鑵虫湰銆?, 1200)
            return "update"
        }
        
        ; 鉁?鍎寲锛氭娓埌鐧诲叆鎸夐垥鐩搁棞鏂囧瓧锛屼笖瓒呴亷鏈€灏忕瓑寰呮檪闁擄紙30绉掞級鎵嶅垽瀹氱偤鐧诲叆鐣潰
        if (foundLoginBtn && A_TickCount >= earlyExitDeadline) {
            loginDetected := true
            WriteLog("鉁?妾㈡脯鍒扮櫥鍏ョ暙闈紙宸茶秴閬?30 绉掑暉鍕曟檪闁擄紝鎵惧埌鐧诲叆鎸夐垥闂滈嵉瀛楋級锛岀劇闇€鏇存柊锛岀辜绾屾甯告祦绋?)
            MuteWutheringAudioAtStartup()
            TryMuteWutheringAudio("妾㈡脯鍒扮櫥鍏ョ暙闈㈠緦")
            ShowTip("鉁?妾㈡脯鍒扮櫥鍏ョ暙闈紝鐒￠渶鏇存柊", 1000)
            return "login"
        }
        
        ; 濡傛灉鍙猣ind鍒扮櫥鍏I浣嗘矑鎵惧埌鎸夐垥锛屼篃瑕佺瓑寰呰冻澶犳檪闁撳啀鍒ゅ畾
        if (foundLoginUI && A_TickCount >= earlyExitDeadline + 10000) {
            loginDetected := true
            WriteLog("鈿狅笍 妾㈡脯鍒扮櫥鍏I锛堜己鏈嶅櫒/璩櫉鐩搁棞锛夛紝鍒ゅ畾鐐虹櫥鍏ョ暙闈紝绻肩簩")
            MuteWutheringAudioAtStartup()
            TryMuteWutheringAudio("妾㈡脯鍒扮櫥鍏I寰?)
            ShowTip("鉁?妾㈡脯鍒扮櫥鍏ョ暙闈I锛岀劇闇€鏇存柊", 1000)
            return "login"
        }
        
        Sleep 900
    }

    ShowTip("鏈娓埌鏇存柊鎴栫櫥鍏ョ暙闈紝鍥炲偝 unknown銆?, 900)
    return "unknown"
}

; B) 鍘绘姈鍕曚富鐣潰妯℃澘姣斿皪锛堝彸涓?ROI锛?
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
        WriteLog("妯℃澘椹楄瓑澶辨晽锛氭壘涓嶅埌妯℃澘妾?" templateFile, "WARN")
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

    WriteLog("妯℃澘椹楄瓑鍙冩暩: template=" templateFile " roi=" roiWidth "x" roiHeight " timeout=" timeoutSec "s")

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
            WriteLog("妯℃澘椹楄瓑鍙栬绐楀骇妯欏け鏁? " e.Message, "WARN")
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
            ShowTip("鉁?妯℃澘鍋垫脯 " stable "/" stableNeeded "锛圴ar=" matchedVar "锛?, 600)
            if (stable >= stableNeeded) {
                return true
            }
        } else {
            stable := 0
        }

        if (A_TickCount - lastProgressLog >= 5000) {
            remainSec := Round((deadline - A_TickCount) / 1000.0, 1)
            WriteLog("妯℃澘椹楄瓑閫茶涓? 妯ｆ湰=" sampleCount " 閫ｇ簩鍛戒腑=" stable "/" stableNeeded " 鏈€寰孷ar=" (bestVar ? bestVar : "-") " 鍓╅=" remainSec "s")
            lastProgressLog := A_TickCount
        }

        Sleep checkIntervalMs
    }

    WriteLog("妯℃澘椹楄瓑瓒呮檪: 妯ｆ湰=" sampleCount " 鏈仈閫ｇ簩鍛戒腑 " stableNeeded, "WARN")
    CoordMode "Pixel", oldPixelMode
    return false
}

; E) 榛炴搳鎸囧畾绐楀彛涓績
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
        WriteLog("榛炴搳瑕栫獥涓績: " cx "," cy)
        MouseClick "left", cx, cy
        return true
    } catch as e {
        WriteLog("榛炴搳瑕栫獥涓績澶辨晽: " e.Message, "WARN")
        return false
    } finally {
        if IsSet(oldMode)
            CoordMode "Mouse", oldMode
    }
}

; F) 鍙栧緱涓﹀暉鍕曢炒娼矾寰戯紙鍙鎲讹級
EnsureWutheringRunning() {
    global WUTHERING_STARTUP_WAIT_SEC

    ; 鉁?鍙鏌ラ亰鎴查€茬▼鏄惁瀛樺湪锛屼笉妾㈡煡瑕栫獥灏哄
    ;    閫欐ǎ闃叉鍥犺绐楁渶灏忓寲鑰岃鍒ょ偤銆岄亰鎴叉湭閬嬭銆?
    if (IsWutheringProcessRunning()) {
        return true
    }
    
    path := GetPathWithAsk("WUTHERING", "璜嬮伕鎿囬炒娼亰鎴蹭富绋嬪紡鎴栨嵎寰?, "鍙煼琛屾獢鎴栨嵎寰?(*.exe;*.lnk)")
    if (!path) {
        WriteLog("鏈ō瀹氶炒娼矾寰戯紝鐒℃硶鍟熷嫊", "ERROR")
        MsgBox "鏈ō瀹氶炒娼亰鎴茶矾寰戙€傝珛閲嶆柊鍩疯涓﹂伕鎿囥€?
        ExitApp
    }
    WriteLog("鍟熷嫊槌存疆: " path)
    ShowTip("馃幃 姝ｅ湪鍟熷嫊槌存疆...", 1500)
    try Run(path)
    catch as e {
        WriteLog("鍟熷嫊槌存疆澶辨晽: " e.Message, "ERROR")
        ShowTip("鉂?槌存疆鍟熷嫊澶辨晽", 1500)
        return false
    }

    ShowTip("鈴?绛夊緟槌存疆閫茬▼鍒濆鍖?..", 1500)
    if !WaitForProcessRunning("Client-Win64-Shipping.exe", WUTHERING_STARTUP_WAIT_SEC) {
        WriteLog("槌存疆鍟熷嫊寰岄€炬檪锛屾湭鍋垫脯鍒伴€茬▼锛? WUTHERING_STARTUP_WAIT_SEC " 绉掞級", "ERROR")
        ShowTip("鉂?槌存疆鍟熷嫊閫炬檪", 1800)
        return false
    }

    ; 绲﹀垵濮嬪寲涓殑瑕栫獥涓€榛炵珐琛濓紝閬垮厤鍓涘暉鍕曞氨瑾ゅ垽 no_window銆?
    Sleep 2000
    WriteLog("宸插伒娓埌槌存疆閫茬▼锛岀辜绾屽緦绾岃绐楁娓?)
    return true
}

; 鉁?鍙鏌ラ亰鎴查€茬▼鏄惁瀛樺湪
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

        ; 鏈変簺閬婃埐鍦ㄥ垵濮嬪寲鏈熼枔鏈冨厛鏈夎绐楀啀绌╁畾鍒版寚瀹?exe锛岄€欒！涓€璧峰垽鏂枫€?
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
    ; 鉁?鍎厛姊濅欢锛氬煼琛岀▼搴?+ UnrealWindow 椤炲垾锛堝畬鍏ㄥ垵濮嬪寲鐨勯亰鎴茶绐楋級
    hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe ahk_class UnrealWindow")
    if (hwndList.Length > 0) {
        hwnd := hwndList[1]
        if (IsValidGameWindow(hwnd))
            return hwnd
    }

    ; 鈿狅笍 鍥為€€锛氶儴鍒嗙挵澧?class 鍙兘涓嶅悓锛屼絾闇€椹楄瓑瑕栫獥鏈夋晥鎬?
    ;   閫欏€嬪洖閫€鏈冨欢閬查亰鎴插暉鍕曠殑鍒ゅ畾锛岄伩鍏嶆壘鍒拌嚚鏅傚垵濮嬪寲瑕栫獥
    hwndList := WinGetList("ahk_exe Client-Win64-Shipping.exe")
    if (hwndList.Length > 0) {
        for hwnd in hwndList {
            if (IsValidGameWindow(hwnd))
                return hwnd
        }
    }

    return 0
}

; 鉁?椹楄瓑瑕栫獥鏄惁鐐虹湡姝ｇ殑閬婃埐瑕栫獥锛堣€岄潪鑷ㄦ檪鍒濆鍖栬绐楋級
IsValidGameWindow(hwnd) {
    if !hwnd
        return false
    
    ; 妾㈡煡瑕栫獥鏄惁瀛樺湪
    if !WinExist("ahk_id " hwnd)
        return false
    
    ; 鍙栧緱瑕栫獥瀵珮
    try WinGetPos , , &w, &h, "ahk_id " hwnd
    catch {
        return false
    }
    
    ; 妾㈡煡瑕栫獥鏈夊悎鐞嗙殑灏哄锛堟帓闄?0x0 鎴栫暟甯稿皬鐨勫垵濮嬪寲瑕栫獥锛?
    ; 閬婃埐瑕栫獥閫氬父鑷冲皯 800x600
    if (w < 800 || h < 600) {
        return false
    }
    
    ; 鉁?瑕栫獥鏈夋晥
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
    return EnsureAllConfigAtStartup(false, "鍟熷嫊鍓嶆鏌ユ牳蹇冪▼寮忚矾寰?)
}

GetPathWithAsk(key, prompt, filter) {
    global CFG_FILE
    path := NormalizePath(IniReadSafe(CFG_FILE, "paths", key, ""))
    if (path != "" && FileExist(path))
        return path

    WriteLog("璺緫鏈ō瀹氭垨妾旀涓嶅瓨鍦紝鎵撻枊鏁村悎瑷畾瑕栫獥: " key, "WARN")
    ShowTip("馃搨 璺緫缂哄け锛岃珛瀹屾垚瑷畾", 1200)
    EnsureAllConfigAtStartup(false, "鍋垫脯鍒拌矾寰戠己澶辨垨澶辨晥锛? key "锛?)

    path := NormalizePath(IniReadSafe(CFG_FILE, "paths", key, ""))
    if (path != "" && FileExist(path))
        return path

    WriteLog("鏁村悎瑷畾寰屼粛鐒℃湁鏁堣矾寰? " key, "ERROR")
    return path
}

AskPathGui(prompt, defaultPath := "", filter := "All Files (*.*)", force := false) {
    sel := { path: "", keep: 0 }
    g := Gui("+AlwaysOnTop -MinimizeBox", prompt)
    g.SetFont("s10")
    g.Add("Text", "xm ym", "鍩疯妾旇矾寰戯細")
    e := g.AddEdit("xm w520 vPATH", defaultPath)
    b := g.AddButton("x+m w90", "鐎忚...")
    b.OnEvent("Click", (*) => FileBrowse())
    cb := g.AddCheckbox("xm vKEEP", "涓嬫涓嶅啀瑭㈠晱")
    ok := g.AddButton("xm w120 Default", "纰哄畾")
    cancel := g.AddButton("x+m w90", "鍙栨秷")
    ok.OnEvent("Click", (*) => Confirm())
    cancel.OnEvent("Click", (*) => CancelSel())
    g.Show("AutoSize Center")
    WinWaitClose g.Hwnd
    return sel

    FileBrowse() {
        ShowTip("馃搨 閬告搰妾旀涓?..", 1000)
        p := FileSelect(, "", prompt, filter)
        if (p)
            e.Value := p
    }

    Confirm() {
        sel.path := Trim(e.Value)
        sel.keep := cb.Value ? 1 : 0
        ShowTip("鉁?宸查伕鎿囪矾寰?, 800)
        g.Hide()
    }

    CancelSel() {
        sel.path := ""
        ShowTip("鉂?宸插彇娑堥伕鎿?, 800)
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

; 鐛插彇宸ヤ綔鍗€鍩熶俊鎭紙鎺掗櫎宸ヤ綔鍒楋級
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

; C) 灏囨寚瀹氱獥鍙ｈ布榻婅灑骞曞彸涓婅锛涜嫢閬庡ぇ鍓囩府鍒拌灑骞曞収锛堝畬鍏ㄨ布閭婏級
MoveWindowTopRight(hwnd, marginX := 0, marginY := 0) {
    if !hwnd {
        WriteLog("MoveWindowTopRight: 鐒℃晥鐨勮绐楀彞鏌?, "ERROR")
        return false
    }
    
    ; 鍢楄│鏈€澶?娆?
    Loop 3 {
        attempt := A_Index
        WriteLog("鍢楄│绉诲嫊瑕栫獥鍒板彸涓婅 (绗?" attempt " 娆?...")
        
        try {
            ; 鍏堥倓鍘熻绐楋紙閬垮厤鏈€澶у寲鐒℃硶绉诲嫊锛?
            WinRestore "ahk_id " hwnd
            Sleep 200  ; 绛夊緟瑕栫獥閭勫師瀹屾垚
            
            ; 纰轰繚瑕栫獥鍦ㄥ墠鍙?
            WinActivate "ahk_id " hwnd
            Sleep 100
        } catch as e {
            WriteLog("瑕栫獥閭勫師澶辨晽: " e.Message, "WARN")
        }

        try {
            WinGetPos &x, &y, &w, &h, "ahk_id " hwnd
            if (w = "" || h = "" || w <= 0 || h <= 0) {
                WriteLog("鐒℃硶鍙栧緱瑕栫獥灏哄: w=" w ", h=" h, "ERROR")
                if (attempt < 3) {
                    Sleep 500
                    continue
                }
                return false
            }

            sw := A_ScreenWidth, sh := A_ScreenHeight
            maxW := sw  ; 瀹屽叏璨奸倞锛屼笉淇濈暀閭婅窛
            maxH := sh  ; 瀹屽叏璨奸倞锛屼笉淇濈暀閭婅窛
            newW := (w > maxW) ? maxW : w
            newH := (h > maxH) ? maxH : h

            newX := sw - newW  ; 瀹屽叏璨奸綂鍙抽倞
            newY := 0          ; 瀹屽叏璨奸綂涓婇倞
            
            WriteLog("绉诲嫊瑕栫獥: 寰?(" x "," y "," w "," h ") 鍒?(" newX "," newY "," newW "," newH ")")
            WinMove newX, newY, newW, newH, "ahk_id " hwnd
            Sleep 300  ; 绛夊緟瑕栫獥绉诲嫊瀹屾垚
            
            ; 椹楄瓑绉诲嫊绲愭灉
            WinGetPos &actualX, &actualY, , , "ahk_id " hwnd
            if (Abs(actualX - newX) <= 10 && Abs(actualY - newY) <= 10) {
                WriteLog("鉁?瑕栫獥鎴愬姛绉诲嫊鍒板彸涓婅 (" actualX "," actualY ")")
                return true
            } else {
                WriteLog("瑕栫獥绉诲嫊浣嶇疆涓嶆纰? 鐩(" newX "," newY ") vs 瀵﹂殯(" actualX "," actualY ")", "WARN")
                if (attempt < 3) {
                    Sleep 500
                    continue
                }
            }
        } catch as e {
            WriteLog("瑕栫獥绉诲嫊澶辨晽: " e.Message, "ERROR")
            if (attempt < 3) {
                Sleep 500
                continue
            }
            return false
        }
    }
    
    WriteLog("瑕栫獥绉诲嫊澶辨晽锛堝凡閬旀渶澶ч噸瑭︽鏁革級", "ERROR")
    return false
}

; D) 绻佲啋绨★紙甯歌瑭烇級
ToSimp(s) {
    static phrase := Map(
        "绲傜","缁堢","娲诲嫊","娲诲姩","鍟嗗煄","鍟嗗煄","鍠氬彇","鍞ゅ彇","鍏遍炒鑰?,"鍏遍福鑰?,"绶ㄩ殜","缂栭槦",
        "鏁欑▼鐧剧","鏁欑▼鐧剧","浠诲嫏","浠诲姟","濂藉弸","濂藉弸","鎴愬氨","鎴愬氨","瑷疆","璁剧疆","鍦板湒","鍦板浘",
        "鐩告","鐩告満","閮典欢","閭欢","绀句氦","绀句氦","鏁告摎","鏁版嵁","绱㈡媺鎸囧崡","绱㈡媺鎸囧崡","鍏堢磩闆诲彴","鍏堢害鐢靛彴"
    )
    for k, v in phrase
        s := StrReplace(s, k, v)

    static single := Map("绲?,"缁?,"槌?,"楦?,"闅?,"闃?,"鍕?,"鍔?,"瑷?,"璁?,"鍦?,"鍥?,"绶?,"缂?,"琛?,"鏈?,"瀛?,"瀛?,"瑁?,"瑁?,"楂?,"浣?,"灏?,"瀵?,"闋?,"椤?,"鏁?,"鏁?,"绱?,"绾?,"闆?,"鐢?)
    for k, v in single
        s := StrReplace(s, k, v)

    return s
}

RequestRestart(reason, level := "ERROR") {
    global LAST_RESTART_REASON

    reason := Trim(reason, " `t`r`n")
    if (reason = "")
        reason := "鏈彁渚?

    LAST_RESTART_REASON := reason
    WriteLog("瑙哥櫦閲嶅暉璜嬫眰锛屽師鍥? " reason, level)
    RestartAutoScript(reason)
}

; 閲嶅暉鍏ㄨ嚜鍕曡叧鏈紙甯堕噸鍟熻▓鏁歌垏閲嶅暉鍘熷洜锛?
RestartAutoScript(reason := "") {
    global CFG_FILE, restartCount, MAX_RESTART_COUNT, LAST_RESTART_REASON

    reason := Trim(reason, " `t`r`n")
    if (reason = "")
        reason := Trim(LAST_RESTART_REASON, " `t`r`n")
    if (reason = "")
        reason := "鏈彁渚?
    
    ; 澧炲姞閲嶅暉瑷堟暩
    restartCount++
    nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    WriteLog("婧栧倷閲嶅暉鍏ㄨ嚜鍕曡叧鏈紝绗?" restartCount " 娆￠噸鍟燂紝鍘熷洜: " reason, "WARN")

    ; 瑷橀寗鏈€杩戜竴娆￠噸鍟熷師鍥狅紝渚涗笅涓€娆″暉鍕曡拷韫?
    IniWrite reason, CFG_FILE, "restart_tracking", "last_restart_reason"
    IniWrite nowText, CFG_FILE, "restart_tracking", "last_restart_time"
    
    ; 妾㈡煡鏄惁瓒呴亷鏈€澶ч噸鍟熸鏁?
    if (restartCount > MAX_RESTART_COUNT) {
        WriteLog("閲嶅暉娆℃暩宸查仈涓婇檺 (" MAX_RESTART_COUNT ")锛屽仠姝㈤噸鍟熶互閬垮厤鐒￠檺寰挵銆傛渶寰屽師鍥? " reason, "ERROR")
        ShowTip("鉂?閲嶅暉娆℃暩閬庡锛屽仠姝㈠煼琛?, 5000)
        Sleep 5000
        ; 閲嶇疆瑷堟暩鍣?
        IniWrite "0", CFG_FILE, "restart_tracking", "auto_restart_count"
        ExitApp
    }
    
    ; 鍎插瓨閲嶅暉瑷堟暩
    IniWrite restartCount, CFG_FILE, "restart_tracking", "auto_restart_count"
    
    ; 闂滈枆鎵€鏈夌浉闂滈€茬▼
    WriteLog("闂滈枆鎵€鏈夌浉闂滈€茬▼...")
    CheckAndCloseExistingProcesses()
    
    Sleep 3000
    
    ; 閲嶆柊鍟熷嫊鑵虫湰
    WriteLog("閲嶆柊鍟熷嫊鍏ㄨ嚜鍕曡叧鏈?..")
    try {
        Run('"' A_ScriptFullPath '"')
        WriteLog("閲嶅暉鍛戒护宸茬櫦閫?)
    } catch as e {
        WriteLog("閲嶅暉澶辨晽: " e.Message, "ERROR")
    }
    
    ; 绲愭潫鐣跺墠閫茬▼
    Sleep 1000
    ExitApp
}

MonitorRewardAndShutdown() {
    global REWARD_LOG_FILE, REWARD_START_DELAY_MS, REWARD_CHECK_INTERVAL_MS, REWARD_SHUTDOWN_DELAY_MS, REWARD_MATCH_NEED_COUNT

    logPath := ResolveRewardLogPath()
    if (logPath = "") {
        WriteLog("鏀跺熬鐩ｆ脯鏈ō瀹氭棩瑾屾獢锛岃烦閬庣洠娓?, "WARN")
        return
    }

    if !FileExist(logPath) {
        WriteLog("鏀跺熬鐩ｆ脯鎵句笉鍒版棩瑾屾獢: " logPath, "WARN")
        return
    }

    startDelaySec := Round(REWARD_START_DELAY_MS / 1000)
    WriteLog("涓绘祦绋嬪畬鎴愶紝鍏堢瓑寰?" startDelaySec " 绉掑啀闁嬪鐩ｆ脯鏈€鏂版棩瑾? " logPath)
    ShowTip("鈴?涓绘祦绋嬪畬鎴愶紝" startDelaySec "绉掑緦闁嬪鐩ｆ脯", 1500)
    Sleep REWARD_START_DELAY_MS

    lastPos := GetLogFileLength(logPath)
    hit := 0
    seenClickReward := false
    seenNoReward := false
    seenDailyRewardSuccess := false
    seenSolaraRewardFail := false
    WriteLog("闁嬪鎸佺簩鐩ｆ脯銆庢渶鏂版柊澧炪€忔棩瑾岋紝璧峰鍋忕Щ: " lastPos)
    ShowTip("馃Л 闁嬪鐩ｆ脯鏈€鏂版棩瑾?..", 1200)

    loop {
        chunk := ReadLogAppended(logPath, &lastPos)
        if (chunk != "") {
            for line in StrSplit(chunk, "`n") {
                line := Trim(line, "`r`t ")
                if (line = "")
                    continue

                if (line ~= "i)(鐢靛彴.*涓€閿鍙東闆诲彴.*涓€閸甸牁鍙?") {
                    seenClickReward := true
                    hit += 1
                    WriteLog("鐩ｆ脯鍛戒腑銆庨浕鍙癬涓€閸甸牁鍙栥€?" hit "/" REWARD_MATCH_NEED_COUNT "): " line)
                    if (hit >= REWARD_MATCH_NEED_COUNT) {
                        delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                        WriteLog("宸茬洠娓埌 " REWARD_MATCH_NEED_COUNT " 姊濄€庨浕鍙癬涓€閸甸牁鍙栥€忥紝" delaySec " 绉掑緦闁嬪闂滈枆娴佺▼")
                        ShowTip("鉁?鐩ｆ脯鍛戒腑锛? delaySec "绉掑緦闂滈枆绋嬪紡", 2000)
                        Sleep REWARD_SHUTDOWN_DELAY_MS
                        ShutdownGameLrmcOkww()
                        return
                    }
                }

                if (line ~= "i)(娌℃湁濂栧姳鑳介鍙東娌掓湁鐛庡嫷鑳介牁鍙?") {
                    seenNoReward := true
                    WriteLog("鐩ｆ脯鍛戒腑銆庢矑鏈夌崕鍕佃兘闋樺彇銆? " line)
                }

                if (line ~= "i)(棰嗗彇姣忔棩濂栧姳鎴愬姛|闋樺彇姣忔棩鐛庡嫷鎴愬姛)") {
                    seenDailyRewardSuccess := true
                    WriteLog("鐩ｆ脯鍛戒腑銆庨牁鍙栨瘡鏃ョ崕鍕垫垚鍔熴€? " line)
                }

                if (line ~= "i)(绱㈡媺濂栧姳棰嗗彇澶辫触|绱㈡媺鐛庡嫷闋樺彇澶辨晽|绱㈡媺鐛庡嫷閷勫彇澶辨晽)") {
                    seenSolaraRewardFail := true
                    WriteLog("鐩ｆ脯鍛戒腑銆庣储鎷夌崕鍕甸牁鍙栧け鏁椼€? " line)
                }

                if (seenClickReward && seenNoReward) {
                    delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                    WriteLog("宸插悓鏅傜洠娓埌銆庨粸鎿婇浕鍙颁竴閸甸牁鍙栥€忚垏銆庢矑鏈夌崕鍕佃兘闋樺彇銆忥紝" delaySec " 绉掑緦闁嬪闂滈枆娴佺▼")
                    ShowTip("鉁?鐩ｆ脯鍒颁竴閸甸牁鍙?鐒＄崕鍕碉紝" delaySec "绉掑緦闂滈枆", 2000)
                    Sleep REWARD_SHUTDOWN_DELAY_MS
                    ShutdownGameLrmcOkww()
                    return
                }

                if (seenDailyRewardSuccess && seenNoReward) {
                    delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                    WriteLog("宸插悓鏅傜洠娓埌銆庨牁鍙栨瘡鏃ョ崕鍕垫垚鍔熴€忚垏銆庢矑鏈夌崕鍕佃兘闋樺彇銆忥紝" delaySec " 绉掑緦闁嬪闂滈枆娴佺▼")
                    ShowTip("鉁?鐩ｆ脯鍒版瘡鏃ョ崕鍕垫垚鍔?鐒＄崕鍕碉紝" delaySec "绉掑緦闂滈枆", 2000)
                    Sleep REWARD_SHUTDOWN_DELAY_MS
                    ShutdownGameLrmcOkww()
                    return
                }

                if (seenSolaraRewardFail && seenNoReward) {
                    delaySec := Round(REWARD_SHUTDOWN_DELAY_MS / 1000)
                    WriteLog("宸插悓鏅傜洠娓埌銆庣储鎷夌崕鍕甸牁鍙栧け鏁椼€忚垏銆庢矑鏈夌崕鍕佃兘闋樺彇銆忥紝" delaySec " 绉掑緦闁嬪闂滈枆娴佺▼")
                    ShowTip("鉁?鐩ｆ脯鍒扮储鎷夌崕鍕靛け鏁?鐒＄崕鍕碉紝" delaySec "绉掑緦闂滈枆", 2000)
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
                WriteLog("鏀跺熬鐩ｆ脯鏃ヨ獙璺緫锛堢敱 LRMC 璺緫鎺ㄥ皫锛? " candidate "锛屼締婧?" lrmcResolved)
                return candidate
            }

            WriteLog("鐢?LRMC 璺緫鎺ㄥ皫鐨勬棩瑾屼笉瀛樺湪锛屾敼鐢ㄥ緦鍌欒矾寰? " candidate "锛屼締婧?" lrmcResolved, "WARN")
        }
    }

    cfgFallback := NormalizePath(IniReadSafe(CFG_FILE, "reward_monitor", "fallback_log_file", ""))
    if (cfgFallback = "") {
        cfgFallback := Trim(REWARD_LOG_FILE, ' "')
        if (cfgFallback != "") {
            try IniWrite cfgFallback, CFG_FILE, "reward_monitor", "fallback_log_file"
            WriteLog("宸插垵濮嬪寲寰屽倷鏃ヨ獙璺緫鍒拌ō瀹氭獢: " cfgFallback)
        }
    }

    if (cfgFallback != "") {
        WriteLog("鏀跺熬鐩ｆ脯浣跨敤寰屽倷鏃ヨ獙璺緫: " cfgFallback, "WARN")
        return cfgFallback
    }

    return ""
}

ResolveLrmcPathForLog(pathVal) {
    p := NormalizePath(pathVal)
    if (p = "")
        return ""

    ; 鑻ヨō瀹氱殑鏄嵎寰戯紝鍏堣В鏋愬埌瀵﹂殯鐩绋嬪紡锛岄伩鍏嶇敤鍒伴枊濮嬪姛鑳借〃鐩寗銆?
    if (p ~= "i)\.lnk$") {
        try {
            target := "", outDir := "", outArgs := "", outDesc := "", outIcon := "", outIconNum := 0, outRunState := 0
            FileGetShortcut p, &target, &outDir, &outArgs, &outDesc, &outIcon, &outIconNum, &outRunState
            target := NormalizePath(target)
            if (target != "") {
                WriteLog("LRMC 鎹峰緫宸茶В鏋愶細" p " -> " target)
                return target
            }

            if (outDir != "") {
                candidateExe := NormalizePath(outDir "\\LRMCAI.exe")
                if FileExist(candidateExe) {
                    WriteLog("LRMC 鎹峰緫鐩鐐虹┖锛屾敼鐢ㄦ嵎寰戝伐浣滅洰閷勬帹灏庯細" candidateExe, "WARN")
                    return candidateExe
                }
            }

            WriteLog("LRMC 鎹峰緫瑙ｆ瀽澶辨晽锛屾部鐢ㄥ師璺緫锛? p, "WARN")
            return p
        } catch as e {
            WriteLog("LRMC 鎹峰緫瑙ｆ瀽渚嬪锛屾部鐢ㄥ師璺緫锛? p "锛? e.Message, "WARN")
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

        ; 鏃ヨ獙杓浛鎴栬鎴柗鏅傦紝寰為牠閲嶆柊璁€
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
    UnmuteWutheringAudio("鐩ｆ脯鍒扮祼鏉燂紝闁嬪鏀跺熬")
    WriteLog("闁嬪闂滈枆鏀跺熬鐩绋嬪紡锛氶炒娼€丩RMCAI銆丱KWW")
    ShowTip("馃洃 姝ｅ湪闂滈枆槌存疆/LRMCAI/OKWW...", 1500)

    ; 1) 槌存疆
    try ProcessClose("Client-Win64-Shipping.exe")
    catch
        try Run("taskkill /F /IM Client-Win64-Shipping.exe", , "Hide")
    Sleep 600

    ; 2) LRMCAI
    try ProcessClose("LRMCAI.exe")
    catch
        try Run("taskkill /F /IM LRMCAI.exe", , "Hide")
    Sleep 600

    ; 3) OKWW锛堜富绋嬪紡 + 鏇存柊妾㈡脯锛?
    try ProcessClose("ok-ww.exe")
    catch
        try ProcessClose("OK-WW.exe")
    try Run("taskkill /F /IM ok-ww.exe", , "Hide")
    try Run("taskkill /F /IM OK-WW.exe", , "Hide")
    try Run("taskkill /F /IM pythonw.exe", , "Hide")

    ; 鍋滄鐩ｇ湅瑷堟檪鍣紝閬垮厤寰岀簩娴佺▼鍐嶈Ц鐧?
    try SetTimer(CrashWatcherTick, 0)

    ; 闂滈枆鐩搁棞 AutoHotkey 绠＄悊鑵虫湰锛堜繚鐣欒嚜宸憋紝鏈€寰屽啀 ExitApp锛?
    currentPID := DllCall("GetCurrentProcessId")
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery("Select * from Win32_Process where Name like '%AutoHotkey%'") {
            if (proc.ProcessId = currentPID)
                continue
            try {
                cmdLine := proc.CommandLine
                if (InStr(cmdLine, "闁嬪暉LRMC.ahk") || InStr(cmdLine, "鑷嫊闁嬪暉OKWW.ahk") || InStr(cmdLine, "鑱查鍚堟垚.ahk") || InStr(cmdLine, "鍏ㄨ嚜鍕?ahk"))
                    ProcessClose(proc.ProcessId)
            }
        }
    }

    if MAIL_NOTIFY_ENABLED {
        mailResult := SendShutdownNotifyMail()
        if mailResult.ok
            WriteLog("鏀跺熬閫氱煡淇″凡瀵勫嚭")
        else
            WriteLog("鏀跺熬閫氱煡淇″瘎閫佸け鏁? " mailResult.message, "WARN")
    }

    WriteLog("鏀跺熬闂滈枆娴佺▼宸插畬鎴愶紝鎵€鏈夋祦绋嬪凡鍋滄")
    ShowTip("鉁?宸查棞闁変甫鍋滄鎵€鏈夋祦绋?, 2000)
    Sleep 800
    ExitApp
}

SendShutdownNotifyMail() {
    global CFG_FILE, MAIL_SECTION

    state := ReadCombinedConfigState()
    if state.needSetup {
        WriteLog("鏀跺熬瀵勪俊鍓嶅伒娓埌瑷畾缂烘紡锛岄噸鏂版墦闁嬫暣鍚堣ō瀹氳绐?, "WARN")
        ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, "鏀跺熬瀵勪俊鍓嶅伒娓埌瑷畾鏈夌┖鐧芥垨閷")
        if !ok
            return { ok: false, message: "浣跨敤鑰呭彇娑堟暣鍚堣ō瀹? }

        state := ReadCombinedConfigState()
        if state.needSetup
            return { ok: false, message: "瑷畾浠嶄笉瀹屾暣: " state.errorText }
    }

    cfgPath := Trim(CFG_FILE, " `t`r`n")
    section := Trim(MAIL_SECTION, " `t`r`n")
    if (cfgPath = "")
        return { ok: false, message: "CFG_FILE 鏈ō瀹? }
    if !FileExist(cfgPath)
        return { ok: false, message: "鎵句笉鍒拌ō瀹氭獢: " cfgPath }

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
        return { ok: false, message: "mail_config.ini 娆勪綅涓嶅畬鏁? }
    if !(smtpPort ~= "^\d+$")
        return { ok: false, message: "smtp_port 涓嶆槸鏁稿瓧: " smtpPort }

    nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    subject := subjectPrefix " 闂滈枆瀹屾垚閫氱煡 " nowText
    body := "鍏ㄨ嚜鍕曟敹灏惧凡瀹屾垚銆俙r`n鏅傞枔锛? nowText "`r`n涓绘锛? A_ComputerName "`r`n鑵虫湰锛? A_ScriptFullPath

    return SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl)
}

EnsureMailConfigAtStartup() {
    return EnsureAllConfigAtStartup(false, "閮典欢瑷畾妾㈡煡")
}

EnsureAllConfigAtStartup(force := false, reason := "") {
    global CFG_FILE, MAIL_SECTION

    state := ReadCombinedConfigState()
    if (!force && !state.needSetup)
        return true

    if (reason = "")
        reason := "鍋垫脯鍒拌ō瀹氱己婕忔垨閷"

    WriteLog("鎵撻枊鏁村悎瑷畾瑕栫獥锛? reason, "WARN")
    ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, reason)
    if !ok {
        MsgBox "浣犲凡鍙栨秷瑷畾銆傜偤浜嗙⒑淇濇祦绋嬩竴鑷达紝鏈涓嶅暉鍕曚富娴佺▼銆?, "鏁村悎瑷畾", "Iconx"
        ExitApp
    }

    verify := ReadCombinedConfigState()
    if verify.needSetup {
        msg := "鍎插瓨寰屼粛鏈夋湭瀹屾垚闋呯洰锛歚n" verify.errorText
        MsgBox msg, "鏁村悎瑷畾", "Iconx"
        ExitApp
    }

    WriteLog("鏁村悎瑷畾妾㈡煡瀹屾垚锛岀辜绾屼富娴佺▼")
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
    state.aiSummaryEnabled := ParseBool01(IniReadSafe(CFG_FILE, MAIL_SECTION, "ai_summary_enabled", "0"), 0)
    state.aiApiUrl := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "ai_api_url", "https://api.openai.com/v1/chat/completions"), " `t`r`n")
    state.aiModel := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "ai_model", "gpt-4o-mini"), " `t`r`n")
    state.aiMaxChars := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "ai_max_chars", "12000"), " `t`r`n")
    state.aiApiKeyEnc := Trim(IniReadSafe(CFG_FILE, MAIL_SECTION, "ai_api_key_enc", ""), " `t`r`n")
    state.aiApiKey := DecryptLocalSecret(state.aiApiKeyEnc)
    MAIL_NOTIFY_ENABLED := state.sendEnabled
    state.fallbackLogFile := NormalizePath(IniReadSafe(CFG_FILE, "reward_monitor", "fallback_log_file", ""))
    if (state.fallbackLogFile = "")
        state.fallbackLogFile := Trim(REWARD_LOG_FILE, ' "')

    err := []
    if (state.okwwPath = "")
        err.Push("OKWW 璺緫鐐虹┖")
    else if !FileExist(state.okwwPath)
        err.Push("OKWW 璺緫涓嶅瓨鍦?)

    if (state.lrmcPath = "")
        err.Push("LRMCAI 璺緫鐐虹┖")
    else if !FileExist(state.lrmcPath)
        err.Push("LRMCAI 璺緫涓嶅瓨鍦?)

    if (state.wuPath = "")
        err.Push("槌存疆璺緫鐐虹┖")
    else if !FileExist(state.wuPath)
        err.Push("槌存疆璺緫涓嶅瓨鍦?)

    if MAIL_NOTIFY_ENABLED {
        if (state.smtpHost = "")
            err.Push("smtp_host 鐐虹┖")
        if (state.smtpPort = "")
            err.Push("smtp_port 鐐虹┖")
        else if !(state.smtpPort ~= "^\d+$")
            err.Push("smtp_port 涓嶆槸鏁稿瓧")
        if (state.smtpUser = "")
            err.Push("smtp_user 鐐虹┖")
        if (state.smtpPass = "")
            err.Push("smtp_pass 鐐虹┖")
        if (state.mailFrom = "")
            err.Push("from 鐐虹┖")
        if (state.mailTo = "")
            err.Push("to 鐐虹┖")

        if state.aiSummaryEnabled {
            if (state.aiApiUrl = "")
                err.Push("ai_api_url 鐐虹┖")
            if (state.aiModel = "")
                err.Push("ai_model 鐐虹┖")
            if !(state.aiMaxChars ~= "^\d+$")
                err.Push("ai_max_chars 涓嶆槸鏁稿瓧")
            if (state.aiApiKey = "")
                err.Push("ai_api_key 鏈ō瀹氭垨瑙ｅ瘑澶辨晽")
        }
    }

    state.errors := err
    state.needSetup := (err.Length > 0)
    state.errorText := ""
    for item in err
        state.errorText .= "- " item "`n"

    return state
}

ShowCombinedConfigSetupGui(cfgPath, section, state, reason := "") {
    g := Gui("+AlwaysOnTop +MinSize760x760", "鏁村悎瑷畾锛堢▼寮忚矾寰?+ 閮典欢閫氱煡锛?)
    g.SetFont("s10", "Microsoft JhengHei UI")

    g.AddText("w720", "銆愯Ц鐧煎師鍥犮€? reason)
    g.AddText("w720", "銆愯ō瀹氭獢浣嶇疆銆? cfgPath)
    g.AddText("w720", "銆愯鏄庛€戜互涓嬫瑒浣嶆渻杓夊叆鐩墠瑷畾锛屼綘鍙互涓€娆″叏閮ㄤ慨鏀瑰緦鍎插瓨銆?)
    g.AddText("w720", "銆愯矾寰戣姹傘€戜笁鍊嬬▼寮忚矾寰戦兘蹇呴爤瀛樺湪锛涜嫢涔嬪緦妾㈡脯鍒扮┖鐧芥垨閷锛屾渻鍐嶆璺冲嚭姝よ绐椼€?)

    summary := "鐩墠鍋垫脯鍊硷細`r`n"
    summary .= "OKWW: " state.okwwPath "`r`n"
    summary .= "LRMCAI: " state.lrmcPath "`r`n"
    summary .= "槌存疆: " state.wuPath "`r`n"
    summary .= "smtp_host: " state.smtpHost "`r`n"
    summary .= "smtp_port: " state.smtpPort "`r`n"
    summary .= "smtp_user: " state.smtpUser "`r`n"
    summary .= "from: " state.mailFrom "`r`n"
    summary .= "to: " state.mailTo "`r`n"
    summary .= "send_enabled: " (state.sendEnabled ? "1(鍟熺敤)" : "0(鍋滅敤)") "`r`n"
    summary .= "ai_summary_enabled: " (state.aiSummaryEnabled ? "1(鍟熺敤)" : "0(鍋滅敤)") "`r`n"
    summary .= "ai_api_url: " state.aiApiUrl "`r`n"
    summary .= "ai_model: " state.aiModel "`r`n"
    summary .= "ai_api_key: " (state.aiApiKey != "" ? "宸茶ō瀹? : "鏈ō瀹?) "`r`n"
    summary .= "ai_max_chars: " state.aiMaxChars "`r`n"
    summary .= "fallback_log_file: " state.fallbackLogFile
    g.AddEdit("xm w720 r8 ReadOnly", summary)

    if (state.needSetup)
        g.AddEdit("xm y+8 w720 r4 ReadOnly", "鐩墠闇€淇锛歚r`n" state.errorText)

    g.AddText("xm y+12 w120", "OKWW 璺緫")
    edOkww := g.AddEdit("x+10 w500", state.okwwPath)
    btnOkww := g.AddButton("x+8 w90", "鐎忚...")

    g.AddText("xm y+10 w120", "LRMCAI 璺緫")
    edLrmc := g.AddEdit("x+10 w500", state.lrmcPath)
    btnLrmc := g.AddButton("x+8 w90", "鐎忚...")

    g.AddText("xm y+10 w120", "槌存疆 璺緫")
    edWu := g.AddEdit("x+10 w500", state.wuPath)
    btnWu := g.AddButton("x+8 w90", "鐎忚...")

    g.AddText("xm y+10 w120", "寰屽倷 log 璺緫")
    edFallbackLog := g.AddEdit("x+10 w500", state.fallbackLogFile)
    btnFallbackLog := g.AddButton("x+8 w90", "鐎忚...")
    txtFallbackHint := g.AddText("xm y+4 w720 cE6A700", "")

    g.AddText("xm y+14 w720", "銆愰兊浠惰ō瀹氥€慓mail: smtp.gmail.com / 587 / use_ssl=1锛涘瘑纰艰珛浣跨敤鎳夌敤绋嬪紡瀵嗙⒓")
    cbSendEnabled := g.AddCheckbox("xm y+8", "鍟熺敤鏀跺熬閫氱煡瀵勪俊")
    cbSendEnabled.Value := state.sendEnabled ? 1 : 0
    txtMailHint := g.AddText("x+12 w420", state.sendEnabled ? "鐩墠鍟熺敤瀵勪俊锛氶渶濉 SMTP 娆勪綅" : "鐩墠鍋滅敤瀵勪俊锛氬彲鐣ラ亷 SMTP 娆勪綅")

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

    g.AddText("xm y+14 w720", "銆怉I 鎽樿瑷畾銆戝彲閬搞€傚暉鐢ㄥ緦鏈冩憳瑕佷粖鏃ュ叏鑷嫊 log 鑸?LRMCAI.log锛屽け鏁楁渻鑷嫊鍥為€€鍘熼€氱煡銆?)
    cbAiSummaryEnabled := g.AddCheckbox("xm y+8", "鍟熺敤 AI 鎽樿锛堟敹灏惧瘎淇℃檪闄勫姞锛?)
    cbAiSummaryEnabled.Value := state.aiSummaryEnabled ? 1 : 0
    txtAiHint := g.AddText("x+12 w500", state.aiSummaryEnabled ? "AI 鎽樿宸插暉鐢紝璜嬬⒑瑾?API 瑷畾瀹屾暣" : "AI 鎽樿鍋滅敤锛堜笉褰遍熆鍘熸湰瀵勪俊娴佺▼锛?)

    g.AddText("xm y+10 w120", "ai_api_url")
    edAiApiUrl := g.AddEdit("x+10 w500", state.aiApiUrl)
    g.AddText("xm y+4 w720 c666666", "鏀彺 OpenAI鐩稿 / Gemini / Anthropic / Azure OpenAI銆備緥锛歄penAI https://api.openai.com/v1/chat/completions锛汫emini https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent")

    g.AddText("xm y+10 w120", "ai_model")
    edAiModel := g.AddEdit("x+10 w500", state.aiModel)
    g.AddText("xm y+4 w720 c666666", "妯″瀷绡勪緥锛歄penAI gpt-4o-mini锛汫emini gemini-1.5-flash 鎴?gemini-2.0-flash-exp锛汚nthropic claude-3-5-sonnet-latest銆?)

    g.AddText("xm y+10 w120", "ai_api_key")
    edAiApiKey := g.AddEdit("x+10 w500 Password", "")
    g.AddText("xm y+4 w720 c666666", "渚嗘簮锛欰I 骞冲彴寰屽彴鐢㈢敓鐨?API Key銆傜暀绌猴紳娌跨敤鏃㈡湁锛涙柊杓稿叆鏈冪敤 Windows 甯宠櫉鍔犲瘑鍎插瓨銆?)

    g.AddText("xm y+10 w120", "ai_max_chars")
    edAiMaxChars := g.AddEdit("x+10 w120", state.aiMaxChars)
    g.AddText("x+12 w560 c666666", "姣忎唤 log 鏈€澶氶€佸嚭鐨勫瓧鏁搞€傚缓璀?8000~15000锛岄爯瑷?12000銆?)

    btnSave := g.AddButton("xm y+18 w170 h34 Default", "鍎插瓨鍏ㄩ儴涓︾辜绾?)
    btnCancel := g.AddButton("x+12 w110 h34", "鍙栨秷")

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
        cbAiSummaryEnabled: cbAiSummaryEnabled,
        txtAiHint: txtAiHint,
        edAiApiUrl: edAiApiUrl,
        edAiModel: edAiModel,
        edAiApiKey: edAiApiKey,
        edAiMaxChars: edAiMaxChars,
        aiApiKeyEnc: state.aiApiKeyEnc,
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
    cbAiSummaryEnabled.OnEvent("Click", OnAiSummaryEnabledChanged)
    btnSave.OnEvent("Click", OnCombinedSetupSave)
    btnCancel.OnEvent("Click", OnCombinedSetupCancel)
    g.OnEvent("Close", OnCombinedSetupClose)

    RefreshFallbackLogHint()
    RefreshMailInputsEnabled()
    RefreshAiInputsEnabled()

    g.Show("AutoSize")
    while !__MAIL_SETUP.done
        Sleep 50

    saved := __MAIL_SETUP.saved
    __MAIL_SETUP := ""
    return saved
}

OnCombinedBrowseOkww(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "閬告搰 OKWW 鍙煼琛屾獢鎴栨嵎寰?, "鍙煼琛屾獢鎴栨嵎寰?(*.exe;*.lnk)")
    if (p)
        __MAIL_SETUP.edOkww.Value := p
}

OnCombinedBrowseLrmc(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "閬告搰 LRMCAI 鍙煼琛屾獢鎴栨嵎寰?, "鍙煼琛屾獢鎴栨嵎寰?(*.exe;*.lnk)")
    if (p)
        __MAIL_SETUP.edLrmc.Value := p
}

OnCombinedBrowseWu(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "閬告搰槌存疆鍙煼琛屾獢鎴栨嵎寰?, "鍙煼琛屾獢鎴栨嵎寰?(*.exe;*.lnk)")
    if (p)
        __MAIL_SETUP.edWu.Value := p
}

OnCombinedBrowseFallbackLog(*) {
    global __MAIL_SETUP
    p := FileSelect(, "", "閬告搰寰屽倷 LRMCAI.log", "Log 妾?(*.log)")
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
        __MAIL_SETUP.txtFallbackHint.Value := "鎻愮ず锛氬緦鍌?log 璺緫鐐虹┖锛屾渻鏀圭敤闋愯ō鎴栫敱 LRMC 璺緫鎺ㄥ皫銆?
        return
    }

    if FileExist(p)
        __MAIL_SETUP.txtFallbackHint.Value := "鎻愮ず锛氬緦鍌?log 璺緫瀛樺湪锛屽彲浣滅偤鐩ｆ脯寰屽倷渚嗘簮銆?
    else
        __MAIL_SETUP.txtFallbackHint.Value := "鈿?璀﹀憡锛氬緦鍌?log 妾斾笉瀛樺湪锛屽劜瀛樹粛鍙辜绾岋紝浣嗙洠娓檪鍙兘鎵句笉鍒板緦鍌欐棩瑾屻€?
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
    aiSummaryEnabledVal := st.cbAiSummaryEnabled.Value ? 1 : 0
    aiApiUrlVal := Trim(st.edAiApiUrl.Value, " `t`r`n")
    aiModelVal := Trim(st.edAiModel.Value, " `t`r`n")
    aiApiKeyInputVal := Trim(st.edAiApiKey.Value, " `t`r`n")
    aiMaxCharsVal := Trim(st.edAiMaxChars.Value, " `t`r`n")
    sslVal := st.ddSsl.Text
    sendEnabledVal := st.cbSendEnabled.Value ? 1 : 0

    if (okwwPath = "" || !FileExist(okwwPath)) {
        MsgBox "OKWW 璺緫绌虹櫧鎴栦笉瀛樺湪", "鏁村悎瑷畾", "Iconx"
        return
    }
    if (lrmcPath = "" || !FileExist(lrmcPath)) {
        MsgBox "LRMCAI 璺緫绌虹櫧鎴栦笉瀛樺湪", "鏁村悎瑷畾", "Iconx"
        return
    }
    if (wuPath = "" || !FileExist(wuPath)) {
        MsgBox "槌存疆璺緫绌虹櫧鎴栦笉瀛樺湪", "鏁村悎瑷畾", "Iconx"
        return
    }

    if sendEnabledVal {
        if (hostVal = "" || portVal = "" || userVal = "" || passVal = "" || fromVal = "" || toVal = "") {
            MsgBox "閮典欢娆勪綅涓嶅彲绌虹櫧锛歴mtp_host/smtp_port/smtp_user/smtp_pass/from/to", "鏁村悎瑷畾", "Iconx"
            return
        }
        if !(portVal ~= "^\d+$") {
            MsgBox "smtp_port 蹇呴爤鏄暩瀛?, "鏁村悎瑷畾", "Iconx"
            return
        }

        if aiSummaryEnabledVal {
            if (aiApiUrlVal = "" || aiModelVal = "") {
                MsgBox "鍟熺敤 AI 鎽樿鏅傦紝ai_api_url 鑸?ai_model 涓嶅彲绌虹櫧", "鏁村悎瑷畾", "Iconx"
                return
            }
            if !(InStr(StrLower(aiApiUrlVal), "https://")) {
                MsgBox "ai_api_url 蹇呴爤鏄?https:// 闁嬮牠鐨勫畬鏁?URL", "鏁村悎瑷畾", "Iconx"
                return
            }
            if !(aiMaxCharsVal ~= "^\d+$") {
                MsgBox "ai_max_chars 蹇呴爤鏄暩瀛?, "鏁村悎瑷畾", "Iconx"
                return
            }
            if (Integer(aiMaxCharsVal) < 1000 || Integer(aiMaxCharsVal) > 50000) {
                MsgBox "ai_max_chars 寤鸿浠嬫柤 1000 鍒?50000", "鏁村悎瑷畾", "Iconx"
                return
            }
            if (aiApiKeyInputVal = "" && st.aiApiKeyEnc = "") {
                MsgBox "鍟熺敤 AI 鎽樿鏅傦紝璜嬭几鍏?ai_api_key锛堟垨鍏堝墠宸插劜瀛橀亷锛?, "鏁村悎瑷畾", "Iconx"
                return
            }
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
    IniWrite aiSummaryEnabledVal, st.cfgPath, st.section, "ai_summary_enabled"
    IniWrite (aiApiUrlVal = "" ? "https://api.openai.com/v1/chat/completions" : aiApiUrlVal), st.cfgPath, st.section, "ai_api_url"
    IniWrite (aiModelVal = "" ? "gpt-4o-mini" : aiModelVal), st.cfgPath, st.section, "ai_model"
    IniWrite (aiMaxCharsVal = "" ? "12000" : aiMaxCharsVal), st.cfgPath, st.section, "ai_max_chars"

    encKey := st.aiApiKeyEnc
    if (aiApiKeyInputVal != "") {
        encKey := EncryptLocalSecret(aiApiKeyInputVal)
        if (encKey = "") {
            MsgBox "ai_api_key 鍔犲瘑澶辨晽锛岃珛纰鸿獚鐩墠 Windows 浣跨敤鑰呮瑠闄愭垨閲嶆柊杓稿叆寰屽啀瑭︿竴娆?, "鏁村悎瑷畾", "Iconx"
            return
        }
        decCheck := DecryptLocalSecret(encKey)
        if (decCheck = "") {
            MsgBox "ai_api_key 鍔犲瘑寰岄璀夊け鏁楋紝璜嬮噸鏂拌几鍏ヤ竴娆″啀鍎插瓨", "鏁村悎瑷畾", "Iconx"
            return
        }
    }
    IniWrite encKey, st.cfgPath, st.section, "ai_api_key_enc"
    MAIL_NOTIFY_ENABLED := sendEnabledVal

    __MAIL_SETUP.saved := true
    __MAIL_SETUP.done := true
    st.gui.Destroy()
}

OnSendEnabledChanged(*) {
    RefreshMailInputsEnabled()
    RefreshAiInputsEnabled()
}

OnAiSummaryEnabledChanged(*) {
    RefreshAiInputsEnabled()
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
    __MAIL_SETUP.txtMailHint.Value := enabled ? "鐩墠鍟熺敤瀵勪俊锛氶渶濉 SMTP 娆勪綅" : "鐩墠鍋滅敤瀵勪俊锛氬彲鐣ラ亷 SMTP 娆勪綅"

    __MAIL_SETUP.cbAiSummaryEnabled.Enabled := enabled
    if !enabled
        __MAIL_SETUP.cbAiSummaryEnabled.Value := 0
}

RefreshAiInputsEnabled() {
    global __MAIL_SETUP
    if !IsObject(__MAIL_SETUP)
        return

    sendEnabled := __MAIL_SETUP.cbSendEnabled.Value ? true : false
    aiEnabled := (__MAIL_SETUP.cbAiSummaryEnabled.Value ? true : false) && sendEnabled

    __MAIL_SETUP.edAiApiUrl.Enabled := aiEnabled
    __MAIL_SETUP.edAiModel.Enabled := aiEnabled
    __MAIL_SETUP.edAiApiKey.Enabled := aiEnabled
    __MAIL_SETUP.edAiMaxChars.Enabled := aiEnabled
    __MAIL_SETUP.txtAiHint.Value := aiEnabled ? "AI 鎽樿宸插暉鐢細鏀跺熬瀵勪俊鏈冮檮涓?AI 绺界祼锛堝け鏁楄嚜鍕曞洖閫€鍘熼€氱煡锛? : "AI 鎽樿鍋滅敤锛堜笉褰遍熆鍘熸湰瀵勪俊娴佺▼锛?
}

LoadMailNotifyEnabled() {
    global CFG_FILE, MAIL_SECTION, MAIL_NOTIFY_ENABLED
    MAIL_NOTIFY_ENABLED := ParseBool01(IniReadSafe(CFG_FILE, MAIL_SECTION, "send_enabled", "1"), 1)
    WriteLog("閮典欢閫氱煡闁嬮棞(send_enabled)=" MAIL_NOTIFY_ENABLED)
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
        A_TrayMenu.Delete("闁嬪暉瑷畾 UI")
    }

    A_TrayMenu.Add("闁嬪暉瑷畾 UI", OpenSettingsFromTray)
    A_TrayMenu.Add()
}

OpenSettingsFromTray(*) {
    global CFG_FILE, MAIL_SECTION

    WriteLog("浣跨敤鑰呯敱绯荤当鍖ｉ枊鍟熻ō瀹?UI")
    state := ReadCombinedConfigState()
    ok := ShowCombinedConfigSetupGui(CFG_FILE, MAIL_SECTION, state, "鐢辩郴绲卞專鎵嬪嫊闁嬪暉瑷畾")
    if ok {
        LoadMailNotifyEnabled()
        WriteLog("绯荤当鍖ｈō瀹氬凡鍎插瓨")
        ShowTip("鉁?瑷畾宸插劜瀛?, 1200)
    } else {
        WriteLog("绯荤当鍖ｈō瀹氬凡鍙栨秷", "WARN")
        ShowTip("鈿狅笍 宸插彇娑堣ō瀹?, 1200)
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
        errMsg := "PowerShell SMTP 鍛煎彨澶辨晽锛孍xitCode=" exitCode
    return { ok: false, message: errMsg }
}

PsEsc(text) {
    return StrReplace(text, "'", "''")
}
