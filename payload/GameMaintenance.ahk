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
    return "schemaVersion,phase,overlay,eventId,revision,gameVersion,sourceUrl,startsAt,expectedOpenAt,provider,fingerprint,runCycle,targetServer,actionId,actionStage,f11InputAttempted,cancelled,desiredState,remoteGeneration,elapsedMs,lastObserveElapsedMs,lastNoticeCheckElapsedMs,helperRestarts,updatedAtUtcMs,updaterUiActionId,updaterUiActionStage,notificationKeys,notifiedOpenAt"
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
    numeric := ",schemaVersion,startsAt,expectedOpenAt,f11InputAttempted,cancelled,remoteGeneration,elapsedMs,lastObserveElapsedMs,lastNoticeCheckElapsedMs,helperRestarts,updatedAtUtcMs,notifiedOpenAt,"
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

GM_PublicQuote(value,maxChars := 400) {
    value := SubStr(RegExReplace(String(value),"[\x00-\x1f\x7f]"," "),1,maxChars)
    return '"' StrReplace(StrReplace(value,"\","\\"),'"','\"') '"'
}

GM_BuildPublicJson(state,decision,input,nowMs) {
    observation := GM_Value(input,"observation",0)
    percent := GM_Value(observation,"progressPercent","")
    percentJson := IsNumber(percent) && percent != "" && Number(percent) >= 0 && Number(percent) <= 100 ? Number(percent) : "null"
    source := state.sourceUrl
    if !RegExMatch(source,"^https://wutheringwaves\.kurogames\.com/zh-tw/main/news/detail/\d+$")
        source := ""
    detail := RegExReplace(GM_Value(decision,"detail",""),"(?:[A-Za-z]:\\|\\\\)[^\s|]*","[本機路徑]")
    result := '{"schemaVersion":1,"capabilityVersion":1'
    fields := {phase:GM_Value(decision,"phase",state.phase),overlay:GM_Value(decision,"overlay",state.overlay),
        provider:state.provider,gameVersion:state.gameVersion,eventId:state.eventId,sourceUrl:source,
        sourceState:GM_Value(input,"noticeState","pending"),progressStage:GM_Value(observation,"phase","unknown"),
        errorCode:GM_Value(decision,"errorCode",""),detail:detail,targetServer:state.targetServer}
    for key, value in fields.OwnProps()
        result .= ',' GM_PublicQuote(key) ':' GM_PublicQuote(value,key = "detail" ? 400 : key = "sourceUrl" ? 180 : 180)
    result .= ',"expectedOpenAt":' state.expectedOpenAt ',"checkedAt":' GM_Value(input,"noticeCheckedAt",0)
    ; Current controller status is observed for every existing heartbeat. Notice
    ; freshness remains independently exposed as checkedAt; no HTTP read here.
    result .= ',"observedAt":' nowMs ',"observedUtcNow":' nowMs ',"progressPercent":' percentJson '}'
    return StrPut(result,"UTF-8") <= 4097 ? result : "null"
}

GM_MaintenanceSettingKeys() {
    return Map("maintenanceEnabled","enabled","maintenanceOverrideEventId","override_event_id",
        "maintenanceDelayUntilUtc","delay_until_utc","maintenanceSkipEventId","skip_event_id","maintenanceRefreshRequestId","refresh_request_id")
}

GM_InstallSummary(install) {
    provider := GM_Value(install,"provider","unknown")
    label := provider = "steam" ? "Steam（自動判定）" : provider = "kuro" ? "官方啟動器（自動判定）"
        : provider = "ambiguous" ? "來源有衝突，請確認所選入口" : "來源尚未確認"
    return label "`n" SubStr(GM_Value(install,"evidence","尚未完成只讀偵測"),1,500)
}

GM_ReadMaintenanceSettings(cfgPath) {
    result := {}
    for key, iniKey in GM_MaintenanceSettingKeys() {
        fallback := key = "maintenanceEnabled" ? "1" : key = "maintenanceDelayUntilUtc" ? "0" : ""
        value := fallback
        try value := IniRead(cfgPath,"game_maintenance",iniKey,fallback)
        result.%key% := key = "maintenanceEnabled" ? (value = "1" ? 1 : 0)
            : key = "maintenanceDelayUntilUtc" ? (RegExMatch(value,"^\d{1,13}$") ? Integer(value) : 0) : value
    }
    return result
}

GM_ValidateMaintenanceSettings(values,previous,state,nowMs) {
    result := {}, changed := Map()
    for key, iniKey in GM_MaintenanceSettingKeys() {
        result.%key% := previous.%key%
        if !values.HasOwnProp(key)
            continue
        value := values.%key%
        if key = "maintenanceEnabled" {
            if !(value is Integer) || (value != 0 && value != 1)
                throw Error("維護開關必須是布林值")
        } else if key = "maintenanceDelayUntilUtc" {
            if !(value is Integer) || value < 0 || value > 9999999999999
                throw Error("維護延後時間格式錯誤")
        } else if !(value is String) || StrLen(value) > 180 || (value != "" && !RegExMatch(value,"^[A-Za-z0-9._:@-]+$"))
            throw Error("維護事件格式錯誤")
        if value != previous.%key%
            changed[key] := true
        result.%key% := value
    }
    if (changed.Has("maintenanceOverrideEventId") || changed.Has("maintenanceDelayUntilUtc"))
        && (result.maintenanceOverrideEventId != "" || result.maintenanceDelayUntilUtc > 0) {
        if state.eventId = "" || result.maintenanceOverrideEventId != state.eventId
            || result.maintenanceDelayUntilUtc <= nowMs || result.maintenanceDelayUntilUtc > nowMs + 172800000
            throw Error("延後僅可針對目前維護事件，且在現在至 48 小時內")
    }
    if changed.Has("maintenanceSkipEventId") && result.maintenanceSkipEventId != "" && result.maintenanceSkipEventId != state.eventId
        throw Error("略過事件已過期，請重新讀取裝置狀態")
    return result
}

GM_WriteMaintenanceSettings(cfgPath,values) {
    ; The caller supplies its existing atomic configuration staging file.
    for key, iniKey in GM_MaintenanceSettingKeys() {
        IniWrite(values.%key%,cfgPath,"game_maintenance",iniKey)
        if IniRead(cfgPath,"game_maintenance",iniKey,"!missing") != String(values.%key%)
            throw Error("維護設定暫存讀回驗證失敗")
    }
}

GM_MaintenanceFirestoreFields(values,prefix := "effective") {
    result := ""
    for key, iniKey in GM_MaintenanceSettingKeys() {
        fieldName := prefix StrUpper(SubStr(key,1,1)) SubStr(key,2)
        item := key = "maintenanceEnabled" ? '{"booleanValue":' (values.%key% ? "true" : "false") '}'
            : key = "maintenanceDelayUntilUtc" ? '{"integerValue":' GM_PublicQuote(values.%key%) '}'
            : '{"stringValue":' GM_PublicQuote(values.%key%,180) '}'
        result .= GM_PublicQuote(fieldName) ':' item ','
    }
    return result
}

GM_MaintenanceFirestoreMask(prefix := "effective",maskType := "updateMask") {
    result := ""
    for key, iniKey in GM_MaintenanceSettingKeys()
        result .= "&" maskType ".fieldPaths=" prefix StrUpper(SubStr(key,1,1)) SubStr(key,2)
    return result
}

GM_ReadMaintenanceDesired(json) {
    result := {}
    for key, iniKey in GM_MaintenanceSettingKeys() {
        name := "desired" StrUpper(SubStr(key,1,1)) SubStr(key,2)
        if !RegExMatch(json,'"' name '"\s*:\s*\{([^}]*)\}',&field)
            continue
        value := "!invalid"
        if key = "maintenanceEnabled" {
            if RegExMatch(field[1],'^\s*"booleanValue"\s*:\s*(true|false)\s*$',&item)
                value := item[1] = "true" ? 1 : 0
        } else if key = "maintenanceDelayUntilUtc" {
            if RegExMatch(field[1],'^\s*"integerValue"\s*:\s*"?(\d{1,13})"?\s*$',&item)
                value := Integer(item[1])
        } else if RegExMatch(field[1],'^\s*"stringValue"\s*:\s*"([A-Za-z0-9._:@-]{0,180})"\s*$',&item)
            value := item[1]
        result.%key% := value
    }
    return result
}

GM_NotifyStage(state,journalPath,decision,sendMail) {
    if state.eventId = ""
        return false
    stage := decision.phase = "WAIT_OPEN" || decision.phase = "WAIT_SERVER" ? "waiting"
        : decision.phase = "UPDATING" ? "updating" : decision.phase = "READY" ? "ready"
        : decision.phase = "NEEDS_ATTENTION" ? "attention" : ""
    if state.notifiedOpenAt > 0 && state.expectedOpenAt > state.notifiedOpenAt
        stage := "extended"
    if stage = ""
        return false
    key := GM_TextChecksum(state.eventId "|" stage "|" state.revision)
    if InStr("|" state.notificationKeys "|","|" key "|")
        return false
    previousKeys := state.notificationKeys, previousOpen := state.notifiedOpenAt
    state.notificationKeys := SubStr(state.notificationKeys "|" key,-1800)
    state.notifiedOpenAt := Max(state.notifiedOpenAt,state.expectedOpenAt)
    try GM_SaveJournal(journalPath,state)
    catch as err {
        state.notificationKeys := previousKeys, state.notifiedOpenAt := previousOpen
        throw err
    }
    return sendMail.Call(stage,decision.detail)
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
