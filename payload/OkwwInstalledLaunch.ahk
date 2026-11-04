; Installed PyAppify launcher: exact button, two stable frames, one click,
; then wait for the existing verified final-window handoff. No OS input here.
OKWW_InstalledLaunchButton(snapshot) {
    if !snapshot.ok || snapshot.kind != "upgrade"
        return 0
    candidates := [], installed := false, pyappify := false
    for block in snapshot.blocks {
        if !IsObject(block) || !block.HasOwnProp("text")
            continue
        label := RegExReplace(block.text,"\s","")
        installed := installed || label = "已安裝" || label = "已安装"
        pyappify := pyappify || RegExMatch(label,"i)^使用PyAppify[\d.]+打包$")
    }
    for block in snapshot.blocks {
        if !IsObject(block) || !block.HasOwnProp("text")
            continue
        text := RegExReplace(block.text, "\s", "")
        if RegExMatch(text, "正在(下載|下载|安裝|安装|更新|啟動|启动)|^(Downloading|Installing|Starting)")
            return 0
        ; 2026-11-04 recorded CLIENT frames: current OCR reads the traditional
        ; green label as this exact string. Never use broad fuzzy/contains matching.
        recordedConfusion := installed && pyappify && text = "動雁用程式"
        if !recordedConfusion && !RegExMatch(text, "^(啟動應用(程式)?|启动应用(程序)?)$")
            continue
        if !block.HasOwnProp("boxPoint") || !(block.boxPoint is Array) || block.boxPoint.Length < 4
            return 0
        x1 := snapshot.w, y1 := snapshot.h, x2 := 0, y2 := 0
        for point in block.boxPoint {
            if !IsNumber(point.x) || !IsNumber(point.y)
                return 0
            x1 := Min(x1,point.x), y1 := Min(y1,point.y)
            x2 := Max(x2,point.x), y2 := Max(y2,point.y)
        }
        if (x1 < 0 || y1 < 0 || x2 >= snapshot.w || y2 >= snapshot.h || x2 <= x1 || y2 <= y1)
            return 0
        if recordedConfusion && (x1 < snapshot.w*0.55 || y2 > snapshot.h*0.30)
            return 0
        candidates.Push({x:Round((x1+x2)/2), y:Round((y1+y2)/2)})
    }
    return candidates.Length = 1 ? candidates[1] : 0
}

OKWW_SameInstalledSnapshot(left, right) {
    if !IsObject(left) || !IsObject(right)
        return false
    for key in ["hwnd","pid","path","started","kind","x","y","w","h"]
        if left.%key% != right.%key%
            return false
    return true
}

OKWW_InstalledAction(snapshot) {
    if !snapshot.ok || snapshot.kind != "upgrade"
        return 0
    message := ""
    for block in snapshot.blocks {
        if !IsObject(block) || !block.HasOwnProp("text")
            continue
        message .= RegExReplace(block.text, "[\s\p{P}]", "")
    }
    ; The instruction is context, never the click target. While it is present,
    ; do not fall through to a Start button visible behind the completion panel.
    if InStr(message, "處理完成請檢視日誌並點選完成") {
        candidates := []
        for block in snapshot.blocks {
            if !IsObject(block) || !block.HasOwnProp("text") || RegExReplace(block.text,"\s","") != "完成"
                continue
            if !block.HasOwnProp("boxPoint") || !(block.boxPoint is Array) || block.boxPoint.Length < 4
                return 0
            x1 := snapshot.w, y1 := snapshot.h, x2 := 0, y2 := 0
            for point in block.boxPoint {
                if !IsObject(point) || !point.HasOwnProp("x") || !point.HasOwnProp("y")
                    || !IsNumber(point.x) || !IsNumber(point.y)
                    return 0
                x1 := Min(x1,point.x), y1 := Min(y1,point.y)
                x2 := Max(x2,point.x), y2 := Max(y2,point.y)
            }
            if x1 < 0 || y1 < 0 || x2 >= snapshot.w || y2 >= snapshot.h || x2 <= x1 || y2 <= y1
                return 0
            candidates.Push({x:Round((x1+x2)/2),y:Round((y1+y2)/2),action:"complete"})
        }
        return candidates.Length = 1 ? candidates[1] : 0
    }
    point := OKWW_InstalledLaunchButton(snapshot)
    if IsObject(point)
        point.action := "start"
    return point
}

OKWW_StartInstalled(capture, click, abort, sleep, maxPolls := 120) {
    previous := 0, previousPoint := 0, clicked := Map()
    Loop maxPolls {
        if abort.Call()
            return "handoff_aborted"
        snapshot := capture.Call()
        if abort.Call()
            return "handoff_aborted"
        if !snapshot.ok {
            if (snapshot.reason = "final_ready" || snapshot.reason = "final_handoff_failed"
                || snapshot.reason = "handoff_aborted")
                return snapshot.reason
            previous := 0
        } else {
            point := OKWW_InstalledAction(snapshot)
            if IsObject(point) && clicked.Has(point.action)
                point := 0
            if IsObject(point) && OKWW_SameInstalledSnapshot(previous, snapshot)
                && point.action = previousPoint.action
                && Abs(point.x-previousPoint.x) <= 3 && Abs(point.y-previousPoint.y) <= 3 {
                if abort.Call()
                    return "handoff_aborted"
                if !click.Call(snapshot,point)
                    return "click_rejected"
                clicked[point.action] := true
            }
            previous := IsObject(point) ? snapshot : 0
            previousPoint := point
        }
        if sleep.Call(500)
            return "handoff_aborted"
    }
    return clicked.Count ? "final_timeout" : "not_found"
}
