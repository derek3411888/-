#Requires AutoHotkey v2.0
#Include GameMaintenancePolicy.ahk

; UTF-8 protocol, deliberately not IniRead (Windows INI decoding is not UTF-8).
GM_SnapshotSchema() {
    return Map("meta", "schemaVersion,marker,requestId,sequence,generation,observedAtUtcMs",
        "notice", "outcome,present,eventId,revision,gameVersion,startsAtUtcMs,expectedOpenAtUtcMs,checkedAtUtcMs,sourceUrl,sourceState,freshForRelease,errorCode,detail",
        "install", "provider,appId,gameRoot,launcherPath,fingerprint,updateAdapterReady,evidence,checkedAtUtcMs",
        "observation", "phase,bytesDone,bytesTotal,progressPercent,lastProgressAtUtcMs,detail,errorCode,gamePid,gamePath")
}

GM_ContainedPath(path, root) {
    fullPath := GM_FullPath(path), fullRoot := RTrim(GM_FullPath(root), "\")
    if (StrLower(SubStr(fullPath, 1, StrLen(fullRoot) + 1)) != StrLower(fullRoot "\"))
        throw Error("Maintenance path outside session")
    checkPath := fullPath
    loop {
        attributes := DllCall("GetFileAttributesW", "Str", checkPath, "UInt")
        if (attributes != 0xFFFFFFFF && (attributes & 0x400))
            throw Error("Maintenance reparse path rejected")
        SplitPath(checkPath, , &parent)
        if (parent = "" || parent = checkPath)
            break
        checkPath := parent
    }
    return fullPath
}

GM_FullPath(path) {
    if (path = "" || RegExMatch(path, "[\x00-\x1F]"))
        throw Error("Invalid maintenance path")
    pathBuffer := Buffer(65536, 0)
    length := DllCall("GetFullPathNameW", "Str", path, "UInt", 32768, "Ptr", pathBuffer.Ptr, "Ptr", 0, "UInt")
    if (!length || length >= 32768)
        throw Error("Cannot canonicalize maintenance path")
    return StrGet(pathBuffer)
}

GM_ReadWorkerSnapshot(path, requestId, previousSequence, nowMs, sessionRoot) {
    path := GM_ContainedPath(path, sessionRoot)
    if (FileGetSize(path) > 65536)
        throw Error("Maintenance snapshot too large")
    content := FileRead(path, "UTF-8")
    schema := GM_SnapshotSchema(), sections := Map(), current := ""
    for raw in StrSplit(content, "`n") {
        line := RTrim(raw, "`r")
        if (line = "")
            continue
        if RegExMatch(line, "[\x00-\x1F]")
            throw Error("Maintenance control character rejected")
        if RegExMatch(line, "^\[([a-z]+)\]$", &match) {
            current := match[1]
            if (!schema.Has(current) || sections.Has(current))
                throw Error("Unknown or duplicate maintenance section")
            sections[current] := Map()
            continue
        }
        if (!sections.Has(current) || !RegExMatch(line, "^([a-zA-Z][a-zA-Z0-9]*)=(.*)$", &match))
            throw Error("Malformed maintenance field")
        key := match[1], value := match[2]
        if (!InStr("," schema[current] ",", "," key ",", true) || sections[current].Has(key) || StrLen(value) > 2048)
            throw Error("Unknown, duplicate or oversized maintenance field")
        sections[current][key] := value
    }
    for section, fields in schema {
        if !sections.Has(section)
            throw Error("Missing maintenance section")
        for key in StrSplit(fields, ",") {
            if !sections[section].Has(key)
                sections[section][key] := ""
        }
    }
    meta := sections["meta"]
    if (meta["schemaVersion"] != "1" || meta["marker"] != "WUTHERING_GAME_MAINTENANCE_WORKER_V1" || meta["requestId"] != requestId)
        throw Error("Maintenance worker identity mismatch")
    for key in ["sequence", "generation", "observedAtUtcMs"] {
        if !RegExMatch(meta[key], "^\d{1,15}$")
            throw Error("Invalid maintenance metadata number")
        meta[key] := Integer(meta[key])
    }
    if (meta["sequence"] <= previousSequence || nowMs - meta["observedAtUtcMs"] > 60000 || meta["observedAtUtcMs"] - nowMs > 5000)
        throw Error("Stale or future maintenance snapshot")
    GM_RequireEnum(sections["notice"]["outcome"], "ok,invalid,unavailable,pending")
    GM_RequireEnum(sections["notice"]["present"], "0,1")
    GM_RequireEnum(sections["install"]["provider"], "unknown,ambiguous,steam,kuro")
    GM_RequireEnum(sections["observation"]["phase"], "unknown,not_started,queued,downloading,installing,verifying,update_ready,game_running,paused_download,login_required,offline,error")
    for section, keys in Map("notice", "startsAtUtcMs,expectedOpenAtUtcMs,checkedAtUtcMs,freshForRelease", "install", "appId,checkedAtUtcMs,updateAdapterReady", "observation", "bytesDone,bytesTotal,lastProgressAtUtcMs,gamePid") {
        for key in StrSplit(keys, ",") {
            value := sections[section][key]
            if (value != "" && !RegExMatch(value, "^\d{1,16}$"))
                throw Error("Invalid maintenance numeric field")
        }
    }
    progress := sections["observation"]["progressPercent"]
    if (progress != "" && (!RegExMatch(progress, "^\d{1,3}(\.\d{1,2})?$") || Number(progress) > 100))
        throw Error("Invalid maintenance progress")
    notice := sections["notice"]
    if (notice["present"] = "1") {
        for key in ["eventId", "revision", "gameVersion", "startsAtUtcMs", "expectedOpenAtUtcMs", "checkedAtUtcMs", "sourceUrl", "sourceState", "freshForRelease"] {
            if (notice[key] = "")
                throw Error("Incomplete maintenance notice")
        }
        if (Number(notice["expectedOpenAtUtcMs"]) <= Number(notice["startsAtUtcMs"]) || Number(notice["expectedOpenAtUtcMs"]) - Number(notice["startsAtUtcMs"]) > 172800000)
            throw Error("Invalid maintenance span")
        GM_RequireEnum(notice["freshForRelease"], "0,1")
    }
    return sections
}

GM_RequireEnum(value, allowed) {
    if !InStr("," allowed ",", "," value ",", true)
        throw Error("Invalid maintenance protocol enum")
}

GM_IsValidGameLaunchEntry(path) {
    if RegExMatch(path,"i)^steam://(?:run|rungameid)/3513350/?$")
        return true
    if RegExMatch(path,"i)^steam:")
        return false
    if path = "" || !FileExist(path)
        return false
    if RegExMatch(path,"i)\.url$") {
        target := "", section := "", found := 0
        try {
            if FileGetSize(path) > 65536
                return false
            for line in StrSplit(FileRead(path,"UTF-8"),"`n","`r") {
                line := Trim(line)
                if RegExMatch(line,"^\[([^\]]+)\]$",&match)
                    section := StrLower(match[1])
                else if section = "internetshortcut" && RegExMatch(line,"i)^URL=(.*)$",&match)
                    target := Trim(match[1]), found += 1
            }
        } catch
            return false
        if found != 1
            return false
        return !!RegExMatch(target,"i)^steam://(?:run|rungameid)/3513350/?$")
    }
    return !!RegExMatch(path,"i)\.(?:exe|lnk)$")
}

GM_JournalFields() {
    return "schemaVersion,phase,overlay,eventId,revision,gameVersion,sourceUrl,startsAt,expectedOpenAt,provider,fingerprint,runCycle,targetServer,actionId,actionStage,f11InputAttempted,cancelled,desiredState,remoteGeneration,elapsedMs,lastObserveElapsedMs,lastNoticeCheckElapsedMs,helperRestarts,updatedAtUtcMs,updaterUiActionId,updaterUiActionStage"
}

GM_TextChecksum(text) {
    encoded := Buffer(StrPut(text,"UTF-8"),0)
    count := StrPut(text,encoded,"UTF-8") - 1
    return Format("{:08X}",DllCall("ntdll\RtlComputeCrc32","UInt",0,"Ptr",encoded.Ptr,"UInt",count,"UInt"))
}

GM_ParseJournal(text) {
    if (StrLen(text) > 16384 || !RegExMatch(text,"s)^\[state\]`n(.*)checksum=([A-F0-9]{8})`n$",&parts))
        throw Error("Malformed maintenance journal")
    if GM_TextChecksum(parts[1]) != parts[2]
        throw Error("Maintenance journal checksum mismatch")
    data := Map(), state := GM_DefaultState()
    for line in StrSplit(parts[1],"`n") {
        if line = ""
            continue
        if !RegExMatch(line,"^([a-zA-Z][a-zA-Z0-9]*)=(.*)$",&field)
            throw Error("Malformed journal field")
        if (!InStr("," GM_JournalFields() ",","," field[1] ",",true) || data.Has(field[1]) || RegExMatch(field[2],"[\x00-\x1F]") || StrLen(field[2]) > 2048)
            throw Error("Unsafe journal field")
        data[field[1]] := field[2]
    }
    numeric := ",schemaVersion,startsAt,expectedOpenAt,f11InputAttempted,cancelled,remoteGeneration,elapsedMs,lastObserveElapsedMs,lastNoticeCheckElapsedMs,helperRestarts,updatedAtUtcMs,"
    for key in StrSplit(GM_JournalFields(),",") {
        if !data.Has(key)
            throw Error("Incomplete maintenance journal")
        if InStr(numeric,"," key ",",true) {
            if !RegExMatch(data[key],"^-?\d{1,16}$")
                throw Error("Invalid journal number")
            state.%key% := Integer(data[key])
        } else
            state.%key% := data[key]
    }
    if state.schemaVersion != 1
        throw Error("Unsupported maintenance journal")
    GM_RequireEnum(state.phase,"CHECKING_NOTICE,NORMAL,WAIT_OPEN,WAIT_NOTICE,CHECKING_UPDATE,UPDATING,CHECKING_LOGIN,WAIT_SERVER,READY,NEEDS_ATTENTION,STOPPED")
    GM_RequireEnum(state.desiredState,"RUN,PAUSE,STOP")
    GM_RequireEnum(state.actionStage,",intent,observed,cancelled")
    GM_RequireEnum(state.updaterUiActionStage,",intent,observed,cancelled")
    GM_RequireEnum(state.provider,"unknown,ambiguous,steam,kuro")
    GM_RequireEnum(state.overlay,",PAUSE,WAIT_DESKTOP")
    if (state.cancelled != 0 && state.cancelled != 1) || (state.f11InputAttempted != 0 && state.f11InputAttempted != 1)
        throw Error("Invalid journal flag")
    return state
}

GM_LoadJournal(path) {
    SplitPath(path,,&root)
    path := GM_ContainedPath(path,root)
    exists := false
    for candidate in [path,path ".bak"] {
        if !FileExist(candidate)
            continue
        exists := true
        try {
            GM_ContainedPath(candidate,root)
            if FileGetSize(candidate) > 32768
                throw Error("Journal too large")
            return GM_ParseJournal(FileRead(candidate,"UTF-8"))
        }
    }
    if exists
        throw Error("Maintenance journal and backup invalid")
    return GM_DefaultState()
}

GM_AtomicText(path,text) {
    SplitPath(path,,&root)
    path := GM_ContainedPath(path,root)
    DirCreate(root)
    temporary := path "." DllCall("GetCurrentProcessId") "_" A_TickCount "_" Random(1,2147483647) ".tmp"
    try {
        journalFile := FileOpen(temporary,"w","UTF-8-RAW")
        if !IsObject(journalFile)
            throw Error("Cannot create atomic maintenance file")
        try {
            journalFile.Write(text)
            if !DllCall("FlushFileBuffers","Ptr",journalFile.Handle)
                throw OSError(A_LastError,"Flush maintenance file")
        } finally
            journalFile.Close()
        if !DllCall("MoveFileExW","Str",temporary,"Str",path,"UInt",0x9)
            throw OSError(A_LastError,"Atomic maintenance replace")
    } finally {
        if FileExist(temporary)
            FileDelete(temporary)
    }
}

GM_SaveJournal(path,original) {
    state := GM_CopyState(original), body := ""
    for key in StrSplit(GM_JournalFields(),",") {
        value := state.%key%
        if IsObject(value) || RegExMatch(value,"[\x00-\x1F]") || StrLen(value) > 2048
            throw Error("Unsafe maintenance state")
        body .= key "=" value "`n"
    }
    text := "[state]`n" body "checksum=" GM_TextChecksum(body) "`n"
    GM_ParseJournal(text)
    if FileExist(path) {
        previous := ""
        try {
            if FileGetSize(path) <= 32768 {
                candidate := FileRead(path,"UTF-8")
                GM_ParseJournal(candidate)
                previous := candidate
            }
        }
        if previous != ""
            GM_AtomicText(path ".bak",previous)
    }
    GM_AtomicText(path,text)
}

GM_HasActiveContinuation(stateOrCfg,nowMs := 0) {
    if IsObject(stateOrCfg)
        state := stateOrCfg
    else {
        SplitPath(stateOrCfg,,&cfgRoot)
        try state := GM_LoadJournal(cfgRoot "\game-maintenance\state.ini")
        catch
            return true ; A damaged journal must not silently clear persisted PAUSE.
    }
    if (GM_Value(state,"cancelled",false) || InStr(",NORMAL,READY,STOPPED,","," state.phase ",",true))
        return false
    if (state.eventId = "" && state.phase != "WAIT_SERVER")
        return false
    if (nowMs > 0 && GM_Value(state,"expectedOpenAt",0) > 0 && state.actionId = "" && nowMs - state.expectedOpenAt > 172800000)
        return false
    return true
}

GM_CommitEffect(original,decision,getCurrentInput,journalPath,applyEffect,writeJournal := GM_SaveJournal) {
    if decision.effect.type = "none"
        return {committed:false,errorCode:"",state:decision.state}
    ; Re-evaluate from current intent, not only from the loop's earlier snapshot.
    fresh := GM_Evaluate(original,getCurrentInput.Call())
    if (fresh.effect.type != decision.effect.type || fresh.effect.expectedRevision != decision.effect.expectedRevision
        || fresh.effect.expectedRemoteGeneration != decision.effect.expectedRemoteGeneration || fresh.effect.actionId != decision.effect.actionId)
        return {committed:false,errorCode:"INTENT_CHANGED",state:fresh.state}
    next := fresh.state
    durable := (fresh.effect.type = "start_update" || fresh.effect.type = "stop")
    if fresh.effect.type = "start_update"
        next.actionId := fresh.effect.actionId, next.actionStage := "intent"
    if durable {
        try writeJournal.Call(journalPath,next)
        catch
            return {committed:false,errorCode:"JOURNAL_WRITE_FAILED",state:original}
        again := GM_Evaluate(original,getCurrentInput.Call())
        if (again.effect.type != fresh.effect.type || again.effect.expectedRevision != fresh.effect.expectedRevision
            || again.effect.expectedRemoteGeneration != fresh.effect.expectedRemoteGeneration || again.effect.actionId != fresh.effect.actionId)
            return {committed:false,errorCode:"INTENT_CHANGED_AFTER_JOURNAL",state:next}
    }
    try result := applyEffect.Call(fresh.effect)
    catch as err
        return {committed:false,errorCode:"EFFECT_FAILED",detail:err.Message,state:next}
    if (fresh.effect.type = "start_update") {
        ; An attempt is not an accepted update or successful login.
        next.actionStage := "observed"
        try writeJournal.Call(journalPath,next)
        catch
            return {committed:true,errorCode:"JOURNAL_OBSERVATION_FAILED",state:next}
    }
    return {committed:true,errorCode:"",state:next,result:result}
}

; The controller owns scheduling; host hooks own existing application behavior.
; Tests exercise this exact controller, without loading the game auto-execute body.
GM_CreateController(journalPath,context,hooks) {
    loadError := ""
    try state := GM_LoadJournal(journalPath)
    catch as err {
        state := GM_DefaultState(), state.phase := "NEEDS_ATTENTION", loadError := err.Message
    }
    if (!GM_HasActiveContinuation(state) && (GM_Value(context,"newTask",false) || state.phase = "NORMAL" || state.phase = "READY"))
        state := GM_DefaultState()
    if state.runCycle = ""
        state.runCycle := GM_Value(context,"runCycle","")
    if state.targetServer = ""
        state.targetServer := GM_Value(context,"targetServer","")
    return {state:state,hooks:hooks,journalPath:journalPath,worker:0,readCount:0,lastDecision:0,
        active:true,managed:state.eventId != "",stopRecordingDone:false,loadError:loadError,
        lastSavedAt:0,lastSavedKey:"",lastPublishedKey:"",workerFailure:""}
}

GM_ControllerSave(c,force := false) {
    state := c.state
    key := state.phase "|" state.overlay "|" state.eventId "|" state.revision "|" state.expectedOpenAt "|"
        . state.actionId "|" state.actionStage "|" state.desiredState "|" state.remoteGeneration "|"
        . state.cancelled "|" state.runCycle "|" state.targetServer "|" state.f11InputAttempted "|" state.helperRestarts
    if force || key != c.lastSavedKey || state.updatedAtUtcMs - c.lastSavedAt >= 30000 {
        GM_SaveJournal(c.journalPath,state)
        c.lastSavedAt := state.updatedAtUtcMs, c.lastSavedKey := key
    }
}

GM_ControllerRemoteIntent(c,desired,command := 0) {
    if !IsObject(c) || !c.active
        return {handled:false}
    if desired = "SWITCH_SERVER" {
        if !GM_Value(command,"validated",false)
            return {handled:false}
        c.state.targetServer := GM_Value(command,"serverName",c.state.targetServer)
    } else if (desired = "RUN" || desired = "PAUSE" || desired = "STOP") {
        c.state.desiredState := desired
        if desired = "STOP"
            c.state.cancelled := true, c.state.phase := "STOPPED", c.state.actionStage := "cancelled"
        c.state.overlay := desired = "PAUSE" ? "PAUSE" : ""
    } else
        return {handled:false}
    c.state.remoteGeneration := Max(c.state.remoteGeneration,GM_Value(command,"remoteNonce",0))
    try GM_ControllerSave(c,true)
    catch
        return {handled:true,code:"CONFIG_WRITE_FAILED",detail:"維護意圖未能持久保存；不執行遊戲操作"}
    return {handled:true,code:desired = "SWITCH_SERVER" ? "SWITCH_SCHEDULED" : "APPLIED",
        detail:desired = "SWITCH_SERVER" ? "已保存目標，等待開服／更新；尚未完成實際切服" : "已保存維護期間意圖，不發送遊戲快捷鍵"}
}

GM_ControllerScheduleChanged(c) {
    schedule := c.hooks.ReconcileSchedule.Call(c.state)
    c.state.runCycle := schedule.runCycle, c.state.targetServer := schedule.targetServer
    if GM_Value(schedule,"allCompleted",false)
        c.state.cancelled := true, c.state.phase := "STOPPED", c.state.desiredState := "STOP"
    GM_ControllerSave(c,true)
    return schedule
}

GM_ControllerTick(c,allowStart := false) {
    if c.state.cancelled {
        c.lastDecision := GM_Decision(c.state,"STOPPED","stop")
        return c.lastDecision
    }
    if c.loadError != "" {
        c.lastDecision := GM_Decision(c.state,"NEEDS_ATTENTION","none","MAINTENANCE_JOURNAL_INVALID",c.loadError)
        return c.lastDecision
    }
    if IsObject(c.worker) && !c.hooks.WorkerAlive.Call(c.worker) {
        try c.hooks.WorkerStop.Call(c.worker)
        c.worker := 0
        if c.state.helperRestarts >= 1 {
            c.workerFailure := "背景維護查詢重建一次後仍失敗，等待人工確認"
        } else
            c.state.helperRestarts += 1
    }
    if !IsObject(c.worker) && c.workerFailure = "" {
        try c.worker := c.hooks.WorkerStart.Call(c)
        catch as err {
            if c.state.helperRestarts >= 1
                c.workerFailure := err.Message
            else
                c.state.helperRestarts += 1
        }
    }
    c.readCount += 1
    input := c.hooks.ReadInput.Call(c)
    if c.workerFailure != "" && input.desiredState != "STOP"
        decision := GM_Decision(c.state,"NEEDS_ATTENTION","none","MAINTENANCE_WORKER_FAILED",c.workerFailure)
    else
        decision := GM_Evaluate(c.state,input)
    c.managed := c.managed || decision.state.eventId != "" || decision.phase = "WAIT_SERVER"
    if InStr(",WAIT_OPEN,WAIT_NOTICE,WAIT_SERVER,NEEDS_ATTENTION,","," decision.phase ",",true) && !c.stopRecordingDone {
        c.hooks.StopRecording.Call()
        c.stopRecordingDone := true
    }
    if (decision.effect.type = "reconcile_schedule") {
        c.state := decision.state
        GM_ControllerScheduleChanged(c)
        decision.state := c.state
    } else if (decision.effect.type != "none" && decision.effect.type != "resume_flow" && (allowStart || decision.effect.type != "start_update")) {
        committed := GM_CommitEffect(c.state,decision,(*) => c.hooks.ReadInput.Call(c),c.journalPath,c.hooks.ApplyEffect)
        decision.state := committed.state
        if committed.errorCode != "" && committed.errorCode != "INTENT_CHANGED" {
            decision := GM_Decision(committed.state,"NEEDS_ATTENTION","none",committed.errorCode,"動作尚未安全完成；保留現場，不一般重啟")
        }
    }
    c.state := decision.state, c.lastDecision := decision
    try GM_ControllerSave(c)
    catch {
        c.loadError := "維護狀態保存失敗；停止後續操作"
        return GM_Decision(c.state,"NEEDS_ATTENTION","none","JOURNAL_WRITE_FAILED",c.loadError)
    }
    key := decision.phase "|" decision.overlay "|" decision.errorCode "|" decision.detail "|" c.state.targetServer "|" c.state.expectedOpenAt
    if key != c.lastPublishedKey {
        c.hooks.Publish.Call(decision)
        c.lastPublishedKey := key
    }
    return decision
}
