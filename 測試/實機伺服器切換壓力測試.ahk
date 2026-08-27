#Requires AutoHotkey v2.0+
#SingleInstance Off
#WinActivateForce

#Include ..\payload\plugin\RapidOcr\RapidOcr.ahk
#Include ..\payload\plugin\ImagePut-1.11\ImagePut.ahk
#Include ..\payload\WutheringServerNames.ahk

; 只在鳴潮登入頁執行。每一輪都以正式遊戲畫面 OCR 找列、實際點選、
; 點確認，再以登入頁區服標籤連續兩次驗證；不會點「點擊連接」。

if !A_IsAdmin {
    elevated := '*RunAs "' A_AhkPath '" "' A_ScriptFullPath '"'
    for arg in A_Args
        elevated .= ' "' StrReplace(arg, '"', '""') '"'
    try Run(elevated)
    catch as e {
        FileAppend("live-server-switch=failed | 無法取得管理員權限: " e.Message "`n", "**")
    }
    ExitApp
}

global LIVE_TEST_OCR := RapidOcr()
global LIVE_TEST_ROOT := A_Args.Length >= 2 && Trim(A_Args[2]) != ""
    ? Trim(A_Args[2], ' "')
    : A_Temp "\wuthering_live_server_switch_" A_Now "_" A_TickCount
global LIVE_TEST_LOG := LIVE_TEST_ROOT "\result.log"
global LIVE_TEST_CASES := LIVE_TEST_ROOT "\cases"

caseCount := 50
if (A_Args.Length >= 1 && A_Args[1] ~= "^\d+$")
    caseCount := Integer(A_Args[1])
if (caseCount < 1 || caseCount > 500) {
    try FileAppend("live-server-switch=failed | invalid_case_count=" caseCount "`n", "**")
    LiveHardExit(2)
}

DirCreate(LIVE_TEST_CASES)
if (A_Args.Length >= 3 && A_Args[3] ~= "^\d+$") {
    stalePid := Integer(A_Args[3])
    if (stalePid > 0 && stalePid != DllCall("GetCurrentProcessId")) {
        try ProcessClose(stalePid)
    }
}
LiveLog("START | requested=" caseCount)

hwnd := WinExist("ahk_exe Client-Win64-Shipping.exe")
if !hwnd {
    LiveFail("找不到鳴潮遊戲視窗")
    LiveHardExit(2)
}

try WinGetClientPos(, , &clientW, &clientH, "ahk_id " hwnd)
catch as e {
    LiveFail("無法取得鳴潮客戶區: " e.Message)
    LiveHardExit(2)
}
if (clientW < 1000 || clientH < 600) {
    LiveFail("鳴潮客戶區尺寸異常: " clientW "x" clientH)
    LiveHardExit(2)
}

initial := LiveWaitForLoginServer(hwnd, "", 15000, 2)
if !initial.ok {
    LiveFail("起始登入頁伺服器辨識失敗: " initial.reason " | raw=" initial.raw)
    LiveHardExit(2)
}
originalServer := initial.server
supported := GetSupportedWutheringServers()
startIndex := 0
for index, server in supported {
    if (server = originalServer) {
        startIndex := index
        break
    }
}
if (startIndex = 0) {
    LiveFail("起始伺服器不在正式清單: " originalServer)
    LiveHardExit(2)
}

LiveLog("PRECHECK_OK | original=" originalServer " | client=" clientW "x" clientH)
passed := 0
failed := 0
failureDetail := ""

Loop caseCount {
    caseNo := A_Index
    targetIndex := Mod(startIndex - 1 + caseNo, supported.Length) + 1
    target := supported[targetIndex]
    started := A_TickCount
    try {
        result := LiveSwitchServer(hwnd, target, caseNo)
        if !result.ok
            throw Error(result.reason)
        passed += 1
        elapsed := A_TickCount - started
        LiveLog(Format("CASE_{:02}_PASS | target={} | observed={} | elapsed_ms={} | menu={} | login={}",
            caseNo, target, result.observed, elapsed, result.menuRaw, result.loginRaw))
    } catch as e {
        failed += 1
        failureDetail := "case=" caseNo " target=" target " error=" e.Message
        LiveLog("CASE_FAIL | " failureDetail)
        break
    }
}

; 失敗時也盡力恢復原始伺服器。恢復不列入要求的測試次數。
restored := false
current := LiveWaitForLoginServer(hwnd, "", 5000, 1)
if (current.ok && current.server = originalServer) {
    restored := true
} else {
    try {
        restoreResult := LiveSwitchServer(hwnd, originalServer, caseCount + 1, "restore")
        restored := restoreResult.ok
    } catch as e {
        LiveLog("RESTORE_FAIL | target=" originalServer " | error=" e.Message)
    }
}

successRate := caseCount > 0 ? Round((passed * 100.0) / caseCount, 2) : 0
summary := "live-server-switch=" (failed = 0 && passed = caseCount && restored ? "ok" : "failed")
    . " | requested=" caseCount " | passed=" passed " | failed=" failed
    . " | success_rate=" successRate "% | original=" originalServer
    . " | restored=" (restored ? "1" : "0") " | evidence=" LIVE_TEST_ROOT
if (failureDetail != "")
    summary .= " | " failureDetail
LiveLog("SUMMARY | " summary)
try FileAppend(summary "`n", failed = 0 && passed = caseCount && restored ? "*" : "**")
LiveHardExit(failed = 0 && passed = caseCount && restored ? 0 : 1)

LiveSwitchServer(hwnd, target, caseNo, mode := "case") {
    target := CanonicalizeWutheringServerName(target)
    if (target = "")
        return {ok: false, reason: "invalid_target"}

    before := LiveWaitForLoginServer(hwnd, "", 8000, 2)
    if !before.ok
        return {ok: false, reason: "precheck_failed:" before.reason}
    if (before.server = target)
        return {ok: false, reason: "target_equals_current:" target}

    if !LiveClickClient(hwnd, IsObject(before.center) ? before.center[1] : 640,
        IsObject(before.center) ? before.center[2] : 549)
        return {ok: false, reason: "open_menu_click_failed"}

    menuReady := LiveWaitForMenu(hwnd, 6000)
    if !menuReady.ok
        return {ok: false, reason: "menu_not_ready:" menuReady.reason}

    evidencePrefix := mode "_" Format("{:02}", caseNo) "_" target
    evidencePrefix := StrReplace(StrReplace(StrReplace(evidencePrefix, "(", "_"), ")", "_"), ",", "_")
    try ImagePutFile(hwnd, LIVE_TEST_CASES "\" evidencePrefix "_menu.png")

    menu := LiveReadMenu(hwnd, target)
    clicked := false
    if menu.found
        clicked := LiveClickClient(hwnd, menu.center[1], menu.center[2])

    if !clicked {
        directions := GetServerMenuSearchScrollDirections(target)
        for _, direction in directions {
            if !LiveScrollMenu(hwnd, direction, 8)
                continue
            Sleep 650
            menu := LiveReadMenu(hwnd, target)
            if menu.found && LiveClickClient(hwnd, menu.center[1], menu.center[2]) {
                clicked := true
                break
            }
        }
    }
    if !clicked
        return {ok: false, reason: "target_not_found_after_scroll:" target " | raw=" menu.raw}

    Sleep 250
    if !LiveClickConfirm(hwnd)
        return {ok: false, reason: "confirm_click_failed"}

    verified := LiveWaitForLoginServer(hwnd, target, 8000, 2)
    if !verified.ok
        return {ok: false, reason: "postcheck_failed:" verified.reason " | observed=" verified.server
            " | raw=" verified.raw}

    try ImagePutFile(hwnd, LIVE_TEST_CASES "\" evidencePrefix "_verified.png")
    return {ok: true, observed: verified.server, menuRaw: menu.raw, loginRaw: verified.raw}
}

LiveWaitForMenu(hwnd, timeoutMs) {
    deadline := A_TickCount + timeoutMs
    lastRaw := ""
    while (A_TickCount <= deadline) {
        scan := LiveReadMenu(hwnd, "")
        lastRaw := scan.raw
        if (scan.serverCount >= 3 && scan.confirmFound)
            return {ok: true, reason: "ok", raw: lastRaw}
        Sleep 250
    }
    return {ok: false, reason: "timeout", raw: lastRaw}
}

LiveReadMenu(hwnd, target) {
    result := {found: false, center: "", raw: "", serverCount: 0, confirmFound: false}
    try WinGetClientPos(, , &clientW, &clientH, "ahk_id " hwnd)
    catch
        return result

    minX := clientW * 0.18
    maxX := clientW * 0.82
    minY := clientH * 0.20
    maxY := clientH * 0.68
    tempFile := LIVE_TEST_ROOT "\menu_" A_TickCount ".png"
    try {
        ImagePutFile(hwnd, tempFile)
        blocks := LIVE_TEST_OCR.ocr_from_file(tempFile, , true)
        seen := Map()
        for block in blocks {
            if !block.HasOwnProp("text")
                continue
            text := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
            if (text = "")
                continue
            center := LiveGetOcrBlockCenter(block)
            if !IsObject(center)
                continue
            if (InStr(text, "確認") || InStr(text, "确认") || InStr(text, "確定") || InStr(text, "确定"))
                result.confirmFound := true
            if (center[1] < minX || center[1] > maxX || center[2] < minY || center[2] > maxY)
                continue
            canonical := DetectWutheringServerFromOcrText(text)
            if (canonical = "")
                continue
            if !seen.Has(canonical) {
                seen[canonical] := true
                result.serverCount += 1
            }
            result.raw .= (result.raw = "" ? "" : " | ") text "@" Round(center[1]) "," Round(center[2])
            if (target != "" && IsServerTargetMatch(text, target)) {
                result.found := true
                result.center := center
            }
        }
    } catch as e {
        result.raw := "ocr_error:" e.Message
    } finally {
        try FileDelete(tempFile)
    }
    return result
}

LiveReadLoginServer(hwnd) {
    result := {server: "", center: "", raw: "", reason: "not_found"}
    try WinGetClientPos(, , &clientW, &clientH, "ahk_id " hwnd)
    catch as e {
        result.reason := "client_rect_failed:" e.Message
        return result
    }

    roiX := Max(0, Floor(clientW * 0.25))
    roiY := Max(0, Floor(clientH * 0.68))
    roiW := Min(clientW - roiX, Max(1, Ceil(clientW * 0.50)))
    roiH := Min(clientH - roiY, Max(1, Ceil(clientH * 0.16)))
    zoom := 2
    tempFile := LIVE_TEST_ROOT "\login_" A_TickCount ".png"
    matches := Map()
    try {
        ImagePutFile({Window: hwnd, crop: [roiX, roiY, roiW, roiH],
            scale: [roiW * zoom, roiH * zoom]}, tempFile)
        blocks := LIVE_TEST_OCR.ocr_from_file(tempFile, , true)
        for block in blocks {
            if !block.HasOwnProp("text")
                continue
            text := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
            if (text = "")
                continue
            center := LiveGetOcrBlockCenter(block)
            if !IsObject(center)
                continue
            canonical := DetectWutheringServerFromOcrText(text)
            if (canonical = "")
                continue
            mapped := [roiX + Round(center[1] / zoom), roiY + Round(center[2] / zoom)]
            matches[canonical] := {raw: text, center: mapped}
            result.raw .= (result.raw = "" ? "" : " | ") text
        }
        if (matches.Count = 1) {
            for canonical, match in matches {
                result.server := canonical
                result.center := match.center
                result.raw := match.raw
                result.reason := "ok"
            }
        } else if (matches.Count > 1) {
            result.reason := "ambiguous"
        }
    } catch as e {
        result.reason := "ocr_error:" e.Message
    } finally {
        try FileDelete(tempFile)
    }
    return result
}

LiveWaitForLoginServer(hwnd, expected, timeoutMs, stableNeeded) {
    expected := expected != "" ? CanonicalizeWutheringServerName(expected) : ""
    deadline := A_TickCount + timeoutMs
    stable := 0
    last := {server: "", center: "", raw: "", reason: "timeout"}
    while (A_TickCount <= deadline) {
        last := LiveReadLoginServer(hwnd)
        matched := last.server != "" && (expected = "" || last.server = expected)
        if matched
            stable += 1
        else
            stable := 0
        if (stable >= stableNeeded)
            return {ok: true, server: last.server, center: last.center, raw: last.raw,
                reason: "stable_match"}
        Sleep 250
    }
    return {ok: false, server: last.server, center: last.center, raw: last.raw,
        reason: last.reason}
}

LiveClickConfirm(hwnd) {
    tempFile := LIVE_TEST_ROOT "\confirm_" A_TickCount ".png"
    try {
        ImagePutFile(hwnd, tempFile)
        blocks := LIVE_TEST_OCR.ocr_from_file(tempFile, , true)
        for block in blocks {
            if !block.HasOwnProp("text")
                continue
            text := Trim(StrReplace(StrReplace(block.text, "`r", ""), "`n", ""), " `t")
            if !(InStr(text, "確認") || InStr(text, "确认") || InStr(text, "確定") || InStr(text, "确定"))
                continue
            center := LiveGetOcrBlockCenter(block)
            if IsObject(center) && LiveClickClient(hwnd, center[1], center[2]) {
                Sleep 350
                return true
            }
        }
    } catch {
    } finally {
        try FileDelete(tempFile)
    }
    clicked := LiveClickClient(hwnd, 890, 543)
    if clicked
        Sleep 350
    return clicked
}

LiveClickClient(hwnd, x, y) {
    if !LiveActivate(hwnd)
        return false
    try WinGetClientPos(&screenX, &screenY, &clientW, &clientH, "ahk_id " hwnd)
    catch
        return false
    x := Max(1, Min(clientW - 2, Round(x)))
    y := Max(1, Min(clientH - 2, Round(y)))
    oldMode := A_CoordModeMouse
    try {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&oldX, &oldY)
        MouseMove(screenX + x, screenY + y, 0)
        Click()
        Sleep 80
        MouseMove(oldX, oldY, 0)
    } catch {
        CoordMode("Mouse", oldMode)
        return false
    }
    CoordMode("Mouse", oldMode)
    return true
}

LiveScrollMenu(hwnd, direction, steps) {
    if !LiveActivate(hwnd)
        return false
    try WinGetClientPos(&screenX, &screenY, &clientW, &clientH, "ahk_id " hwnd)
    catch
        return false
    oldMode := A_CoordModeMouse
    try {
        CoordMode("Mouse", "Screen")
        MouseGetPos(&oldX, &oldY)
        MouseMove(screenX + Round(clientW * 0.64), screenY + Round(clientH * 0.46), 0)
        Click(direction = "up" ? "WheelUp" : "WheelDown", steps)
        Sleep 100
        MouseMove(oldX, oldY, 0)
    } catch {
        CoordMode("Mouse", oldMode)
        return false
    }
    CoordMode("Mouse", oldMode)
    return true
}

LiveActivate(hwnd) {
    if !hwnd || !WinExist("ahk_id " hwnd)
        return false
    Loop 8 {
        if WinActive("ahk_id " hwnd)
            return true
        try WinActivate("ahk_id " hwnd)
        Sleep 100
    }
    return WinActive("ahk_id " hwnd) ? true : false
}

LiveGetOcrBlockCenter(block) {
    if (block.HasOwnProp("boxPoint") && IsObject(block.boxPoint)) {
        minX := 2147483647, minY := 2147483647
        maxX := -2147483648, maxY := -2147483648
        found := false
        for _, pt in block.boxPoint {
            if (!IsObject(pt) || !pt.HasOwnProp("x") || !pt.HasOwnProp("y"))
                continue
            minX := Min(minX, pt.x), minY := Min(minY, pt.y)
            maxX := Max(maxX, pt.x), maxY := Max(maxY, pt.y)
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
            minX := Min(minX, pt[1]), minY := Min(minY, pt[2])
            maxX := Max(maxX, pt[1]), maxY := Max(maxY, pt[2])
            found := true
        }
        if found
            return [Round((minX + maxX) / 2), Round((minY + maxY) / 2)]
    }
    return ""
}

LiveLog(line) {
    global LIVE_TEST_LOG
    stamp := FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
    FileAppend(stamp " | " line "`r`n", LIVE_TEST_LOG, "UTF-8")
}

LiveFail(message) {
    LiveLog("FATAL | " message)
    try FileAppend("live-server-switch=failed | " message "`n", "**")
}

LiveHardExit(exitCode) {
    Sleep 50
    DllCall("TerminateProcess", "ptr", -1, "uint", exitCode)
}
