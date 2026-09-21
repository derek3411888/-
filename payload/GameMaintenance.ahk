#Requires AutoHotkey v2.0

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
    GM_RequireEnum(sections["observation"]["phase"], "unknown,not_started,queued,downloading,installing,verifying,update_ready,game_running,login_required,offline,error")
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
