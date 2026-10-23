#Requires AutoHotkey v2.0+
#Include RemoteRestartDrain.ahk

global REMOTE_UPDATE_RESTART_NONCE := 0
global REMOTE_UPDATE_RESTART_MODE := ""

RemoteUpdateRestartReceiptPath() {
    return RuntimeFiles_RuntimeDir("遠端重啟") "\request.ini"
}

PrepareRemoteUpdateRestart(command) {
    global REMOTE_UPDATE_RESTART_NONCE, REMOTE_UPDATE_RESTART_MODE
    global REMOTE_STOP_IN_PROGRESS, EXITING_FROM_TRAY, __RESTART_IN_PROGRESS
    global REMOTE_SERVER_SWITCH_PENDING, RC_REMOTE_DESIRED_STATE
    nonce := IsObject(command) && command.HasOwnProp("remoteNonce") ? command.remoteNonce : 0
    if nonce <= 0
        return {code:"INVALID_COMMAND",detail:"重啟命令缺少有效識別碼"}
    receipt := RemoteUpdateRestartReceiptPath()
    savedNonce := Integer(IniRead(receipt,"request","nonce","0"))
    savedStage := IniRead(receipt,"request","stage","")
    ; Recovery of an already accepted action only repairs its ACK. A new main
    ; must never replay the previous main's shutdown and create a restart loop.
    if savedNonce = nonce && savedStage != "prepared"
        return {code:"ACCEPTED",detail:"重啟要求已接收；請以新心跳、版本及任務進度確認結果"}
    if savedNonce > nonce
        return {code:"STALE_COMMAND",detail:"已有較新的重啟要求，未重複執行"}
    if REMOTE_STOP_IN_PROGRESS || EXITING_FROM_TRAY || __RESTART_IN_PROGRESS || REMOTE_SERVER_SWITCH_PENDING || REMOTE_UPDATE_RESTART_NONCE
        return {code:"BUSY",detail:"目前正在停止或交接；未排入第二次重啟"}
    launcher := ResolvePersistentToolsRoot() "\全自動鋤地.exe"
    if !FileExist(launcher)
        return {code:"LAUNCHER_MISSING",detail:"找不到正式啟動器；未關閉現有流程"}
    mode := IsLrmcRunResumeReady() ? "restart resume" : "restart"
    try {
        RestartHandoff_WriteIni(receipt,"request",Map("nonce",nonce,"stage","prepared","mode",mode))
        if !RC_SavePersistedDesiredState("RUN",nonce,"web-restart-update")
            return {code:"CONFIG_WRITE_FAILED",detail:"無法保存重啟後 RUN；未關閉現有流程"}
        RestartHandoff_WriteIni(receipt,"request",Map("nonce",nonce,"stage","accepted","mode",mode))
    } catch as e {
        return {code:"CONFIG_WRITE_FAILED",detail:"無法保存重啟要求：" e.Message}
    }
    RC_REMOTE_DESIRED_STATE := "RUN"
    RC_SetPausedFlag(false)
    SetSoftPauseClockState(false)
    REMOTE_UPDATE_RESTART_NONCE := nonce
    REMOTE_UPDATE_RESTART_MODE := mode
    SetTimer(RemoteUpdateRestartCommitTick,-250)
    return {code:"ACCEPTED",detail:"已排程完整關閉並由啟動器檢查更新；保留原伺服器與任務進度。尚未確認重啟完成"}
}

RemoteUpdateRestartCommitTick() {
    global REMOTE_UPDATE_RESTART_NONCE, REMOTE_UPDATE_RESTART_MODE
    global RC_COMMAND_APPLY_IN_PROGRESS, RC_PENDING_COMMAND_CLAIM
    global REMOTE_STOP_IN_PROGRESS, EXITING_FROM_TRAY, __RESTART_IN_PROGRESS, __NEXTSERVER_RESTART
    nonce := REMOTE_UPDATE_RESTART_NONCE
    if !nonce
        return
    ; Never exit the command callback before the accepted ACK is durably staged
    ; and the claim cleared. Network retries may continue on the successor.
    if RC_COMMAND_APPLY_IN_PROGRESS || (IsObject(RC_PENDING_COMMAND_CLAIM) && RC_PENDING_COMMAND_CLAIM.nonce = nonce) {
        SetTimer(RemoteUpdateRestartCommitTick,-1000)
        return
    }
    if REMOTE_STOP_IN_PROGRESS || EXITING_FROM_TRAY || RC_IsPaused() || !RC_IsDesiredStateGenerationCurrent("RUN",nonce) {
        REMOTE_UPDATE_RESTART_NONCE := 0
        WriteLog("較新的停止／暫停／命令已取消排隊中的網頁重啟", "WARN")
        return
    }
    try RestartHandoff_WriteIni(RemoteUpdateRestartReceiptPath(),"request",
        Map("nonce",nonce,"stage","closing","mode",REMOTE_UPDATE_RESTART_MODE))
    catch as e {
        REMOTE_UPDATE_RESTART_NONCE := 0
        WriteStep("網頁重啟失敗","無法保存關閉階段；未關閉現有流程 | " e.Message,"ERROR")
        return
    }
    ; Receipt replacement can yield. Serialize the final generation check and
    ; admission boundary with both in-process callbacks and persisted intents.
    previousCritical := Critical("On"), intentMutex := 0
    try {
        intentMutex := RC_AcquirePersistedDesiredStateMutex()
        if !intentMutex || REMOTE_STOP_IN_PROGRESS || EXITING_FROM_TRAY || RC_IsPaused()
            || !RC_IsDesiredStateGenerationCurrent("RUN",nonce) {
            REMOTE_UPDATE_RESTART_NONCE := 0
            WriteLog("網頁重啟提交前意圖已變更或無法鎖定；保留目前流程", "WARN")
            return
        }
        REMOTE_UPDATE_RESTART_NONCE := 0
        __RESTART_IN_PROGRESS := true
        __NEXTSERVER_RESTART := false
    } finally {
        if intentMutex
            RC_ReleasePersistedDesiredStateMutex(intentMutex)
        Critical(previousCritical)
    }
    WriteStep("網頁重新啟動","完整關閉、錄影封口後經啟動器檢查更新；保留原任務")
    ShutdownGameLrmcOkww(true,"WEB_RESTART_UPDATE",REMOTE_UPDATE_RESTART_MODE)
}
