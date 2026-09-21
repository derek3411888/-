#Requires AutoHotkey v2.0

; Pure scheduling policy. No time, process, file, HTTP, global state or input calls.
GM_Value(value, key, fallback := "") {
    if !IsObject(value)
        return fallback
    if value is Map
        return value.Has(key) ? value[key] : fallback
    return value.HasOwnProp(key) ? value.%key% : fallback
}

GM_DefaultState() {
    return {schemaVersion:1, phase:"CHECKING_NOTICE", overlay:"", eventId:"", revision:"", gameVersion:"", sourceUrl:"",
        startsAt:0, expectedOpenAt:0, provider:"unknown", fingerprint:"", runCycle:"", targetServer:"",
        actionId:"", actionStage:"", f11InputAttempted:0, cancelled:0, desiredState:"RUN", remoteGeneration:0,
        elapsedMs:0, lastObserveElapsedMs:0, lastNoticeCheckElapsedMs:-300000, helperRestarts:0, updatedAtUtcMs:0,
        updaterUiActionId:"",updaterUiActionStage:"",notificationKeys:"",notifiedOpenAt:0}
}

GM_CopyState(original) {
    result := GM_DefaultState()
    for key, value in result.OwnProps() {
        if IsObject(original) && original.HasOwnProp(key)
            result.%key% := original.%key%
    }
    return result
}

GM_Decision(state, phase, effect := "none", errorCode := "", detail := "", overlay := "") {
    state.phase := phase, state.overlay := overlay
    return {phase:phase, overlay:overlay, errorCode:errorCode, detail:detail, state:state,
        effect:{type:effect, actionId:effect = "start_update" ? state.eventId ":" state.fingerprint ":update" : "",
            expectedRevision:state.revision, expectedRemoteGeneration:state.remoteGeneration}}
}

GM_Evaluate(previous, input) {
    state := GM_CopyState(previous), now := GM_Value(input,"nowUtcMs",0), elapsed := GM_Value(input,"elapsedMs",0)
    state.desiredState := GM_Value(input,"desiredState","PAUSE"), state.remoteGeneration := GM_Value(input,"remoteGeneration",0)
    state.elapsedMs := elapsed, state.updatedAtUtcMs := now
    if (state.desiredState = "STOP") {
        state.cancelled := true, state.actionStage := "cancelled"
        return GM_Decision(state,"STOPPED","stop","","已取消本腳本後續更新及登入動作")
    }
    if state.cancelled {
        if !GM_Value(input,"newTask",false)
            return GM_Decision(state,"STOPPED","none","","前一任務已取消，等待明確新任務")
        state.cancelled := false, state.actionId := "", state.actionStage := "", state.f11InputAttempted := false
    }
    notice := GM_Value(input,"notice",0), sourceState := GM_Value(input,"noticeState","pending")
    if IsObject(notice) && GM_Value(notice,"eventId","") != "" {
        if (state.eventId != "" && state.eventId != notice.eventId)
            return GM_Decision(state,"WAIT_NOTICE","none","NOTICE_CONFLICT","公告事件與接續任務不一致")
        state.eventId := notice.eventId
        ; A stale source may not shorten an already persisted deadline.
        if GM_Value(notice,"expectedOpenAt",0) >= state.expectedOpenAt {
            state.expectedOpenAt := GM_Value(notice,"expectedOpenAt",0), state.revision := GM_Value(notice,"revision","")
        }
        state.startsAt := GM_Value(notice,"startsAt",state.startsAt)
        state.gameVersion := GM_Value(notice,"gameVersion",state.gameVersion)
        state.sourceUrl := GM_Value(notice,"sourceUrl",state.sourceUrl)
    }
    if (state.desiredState != "RUN")
        return GM_Decision(state,state.phase,"none","","遠端暫停；不操作更新器","PAUSE")
    if !GM_Value(input,"desktopAvailable",false)
        return GM_Decision(state,state.phase,"none","","桌面鎖定；等待解鎖","WAIT_DESKTOP")
    if !GM_Value(input,"clockStable",false) {
        effect := elapsed - state.lastNoticeCheckElapsedMs >= 300000 ? "check_notice" : "none"
        if effect = "check_notice"
            state.lastNoticeCheckElapsedMs := elapsed
        return GM_Decision(state,"WAIT_NOTICE",effect,"CLOCK_CHANGED","系統時間變更，重新確認公告")
    }
    if GM_Value(input,"runCycle",state.runCycle) != state.runCycle
        return GM_Decision(state,state.phase,"reconcile_schedule","","循環日已變更，先核對伺服器排程")
    observation := GM_Value(input,"observation",0), observedPhase := GM_Value(observation,"phase","unknown")
    observationFresh := (now - GM_Value(observation,"observedAt",0) <= 60000 && GM_Value(observation,"observedAt",0) <= now + 5000)
    if !observationFresh
        observedPhase := "unknown"
    if (observedPhase = "maintenance" && GM_Value(observation,"confirmed",false) && GM_Value(observation,"identityVerified",false)) {
        if state.phase != "WAIT_SERVER"
            state.lastObserveElapsedMs := elapsed
        return GM_Decision(state,"WAIT_SERVER","none","","遊戲明確顯示維護，每五分鐘重新確認")
    }
    if (state.phase = "WAIT_SERVER") {
        serverDeadline := state.expectedOpenAt
        if (GM_Value(input,"delayEventId","") = state.eventId && GM_Value(input,"delayUntilUtc",0) > now && GM_Value(input,"delayUntilUtc",0) - now <= 172800000)
            serverDeadline := Max(serverDeadline,GM_Value(input,"delayUntilUtc",0))
        if (state.eventId != "" && GM_Value(input,"skipEventId","") != state.eventId) {
            if now < serverDeadline
                return GM_Decision(state,"WAIT_SERVER","none","","維護畫面已恢復，仍須等公告開服時間")
            if (sourceState != "valid" || !IsObject(notice) || !GM_Value(notice,"freshForRelease",false) || GM_Value(notice,"revision","") != state.revision) {
                effect := elapsed - state.lastNoticeCheckElapsedMs >= 300000 ? "check_notice" : "none"
                if effect = "check_notice"
                    state.lastNoticeCheckElapsedMs := elapsed
                return GM_Decision(state,"WAIT_SERVER",effect,"NOTICE_RECHECK_REQUIRED","仍需最新官方公告確認")
            }
        }
        if (observedPhase = "game_ready" && GM_Value(observation,"identityVerified",false) && GM_Value(observation,"stable",false))
            return GM_Decision(state,"READY","resume_flow","","主畫面已穩定驗證，接續流程")
        if (observedPhase = "login_ready" && state.f11InputAttempted)
            return GM_Decision(state,"NEEDS_ATTENTION","none","LOGIN_RESUME_UNCONFIRMED","已送過 F11；未確認可安全接續，不重送切換快捷鍵")
        if (observedPhase = "login_ready" && !state.f11InputAttempted)
            return GM_Decision(state,"CHECKING_LOGIN","resume_flow","","維護提示已消失，接回既有登入流程")
        if (elapsed - state.lastObserveElapsedMs >= 300000) {
            state.lastObserveElapsedMs := elapsed
            return GM_Decision(state,"WAIT_SERVER","observe")
        }
        return GM_Decision(state,"WAIT_SERVER")
    }
    if (GM_Value(input,"noticeErrorCode","") = "NOTICE_CONFLICT")
        return GM_Decision(state,"WAIT_NOTICE","none","NOTICE_CONFLICT","多份公告時間衝突，等待重新確認")
    if (state.eventId = "") {
        if (sourceState = "valid" || !GM_Value(input,"enabled",true))
            return GM_Decision(state,"NORMAL","resume_flow")
        if (sourceState != "pending" && elapsed >= 20000)
            return GM_Decision(state,"NORMAL","resume_flow","NOTICE_UNAVAILABLE","公告確認失敗；沿用平日流程並保留遊戲內維護備援")
        return GM_Decision(state,"CHECKING_NOTICE")
    }
    deadline := state.expectedOpenAt
    if (GM_Value(input,"delayEventId","") = state.eventId && GM_Value(input,"delayUntilUtc",0) > now && GM_Value(input,"delayUntilUtc",0) - now <= 172800000)
        deadline := Max(deadline,GM_Value(input,"delayUntilUtc",0))
    skip := GM_Value(input,"skipEventId","") = state.eventId
    if (!skip && now < deadline)
        return GM_Decision(state,"WAIT_OPEN","none","","等待官方公告開服時間；不提前更新")
    if (!skip && (sourceState != "valid" || !IsObject(notice) || !GM_Value(notice,"freshForRelease",false) || GM_Value(notice,"revision","") != state.revision)) {
        effect := elapsed - state.lastNoticeCheckElapsedMs >= 300000 ? "check_notice" : "none"
        if effect = "check_notice"
            state.lastNoticeCheckElapsedMs := elapsed
        return GM_Decision(state,"WAIT_NOTICE",effect,"NOTICE_RECHECK_REQUIRED","到達時間，仍需最新官方公告確認")
    }
    install := GM_Value(input,"install",0)
    state.provider := GM_Value(install,"provider","unknown"), state.fingerprint := GM_Value(install,"fingerprint",state.fingerprint)
    if (state.provider != "steam" && state.provider != "kuro")
        return GM_Decision(state,"NEEDS_ATTENTION","none","INSTALL_SOURCE_UNKNOWN","無法確認安裝來源，請檢查鳴潮啟動路徑")
    if (observedPhase = "game_ready" && GM_Value(observation,"identityVerified",false) && GM_Value(observation,"stable",false))
        return GM_Decision(state,"READY","resume_flow")
    if (observedPhase = "error" || observedPhase = "login_required" || observedPhase = "offline" || observedPhase = "paused_download")
        return GM_Decision(state,"NEEDS_ATTENTION","none",GM_Value(observation,"errorCode","UPDATER_" StrUpper(observedPhase)),GM_Value(observation,"detail","更新器需要人工確認"))
    if (observedPhase = "update_ready") {
        if state.actionId = "" && GM_Value(install,"updateAdapterReady",false)
            return GM_Decision(state,"CHECKING_UPDATE","start_update")
        return GM_Decision(state,"CHECKING_UPDATE","observe","","更新器已就緒，仍在等待目標遊戲程序")
    }
    if (observedPhase = "game_running" || observedPhase = "login_ready")
        return GM_Decision(state,"CHECKING_LOGIN","resume_flow","","更新器或程序已就緒；尚未宣告遊戲登入成功")
    if InStr(",downloading,installing,verifying,queued,","," observedPhase ",",true) {
        if GM_Value(input,"noProgressMs",0) >= 1800000
            return GM_Decision(state,"NEEDS_ATTENTION","none","UPDATE_STALLED","三十分鐘沒有可證實的更新進展")
        return GM_Decision(state,"UPDATING","observe")
    }
    if (state.actionId != "" && (state.actionStage = "intent" || state.actionStage = "observed")) {
        if GM_Value(input,"actionElapsedMs",0) >= 180000
            return GM_Decision(state,"NEEDS_ATTENTION","none","UPDATE_ACTIVITY_UNCONFIRMED","已發起更新但三分鐘內無法確認活動；不重複啟動")
        return GM_Decision(state,"CHECKING_UPDATE","observe","","接續上次動作，先核對更新器與遊戲")
    }
    if !GM_Value(install,"updateAdapterReady",false)
        return GM_Decision(state,"NEEDS_ATTENTION","none","UPDATE_ADAPTER_UNVERIFIED","已辨識安裝來源，但更新操作尚未完成實機驗證")
    return GM_Decision(state,"CHECKING_UPDATE","start_update")
}
