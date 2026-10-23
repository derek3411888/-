#Requires AutoHotkey v2.0

; A standalone digit has no count semantics. Accept a unique complete label +
; count (or one aligned split label/value pair), entirely within the known ROI.
SC_ParseCount(blocks,width,height) {
    if !(blocks is Array) || width < 100 || height < 100
        return -1
    texts := []
    for block in blocks {
        if !IsObject(block) || !block.HasOwnProp("text") || !block.HasOwnProp("boxPoint")
            continue
        p := block.boxPoint
        if !(p is Array) || p.Length < 3
            continue
        try {
            x1 := p[1].x*1280/width, y1 := p[1].y*720/height
            x2 := p[3].x*1280/width, y2 := p[3].y*720/height
            if x2 < 936 || x1 > 1075 || y2 < 603 || y1 > 633
                continue
            if x1 < 936 || x2 > 1075 || y1 < 603 || y2 > 633 || x2 <= x1 || y2 <= y1
                return -1
            text := RegExReplace(block.text,"\s+","")
            if text != ""
                texts.Push({text:text,x1:x1,x2:x2,y:(y1+y2)/2})
        } catch {
            return -1
        }
    }
    if texts.Length = 1 {
        if RegExMatch(texts[1].text,"^(?:融合)?(?:次数|次數)[：:]?(0|[1-9][0-9]{0,3})$",&m)
            return Integer(m[1])
    } else if texts.Length = 2 {
        label := texts[1], value := texts[2]
        if label.x1 > value.x1
            label := texts[2], value := texts[1]
        if RegExMatch(label.text,"^(?:融合)?(?:次数|次數)[：:]?$")
            && RegExMatch(value.text,"^(0|[1-9][0-9]{0,3})$",&m)
            && label.x2 <= value.x1 && value.x1-label.x2 <= 35 && Abs(label.y-value.y) <= 6
            return Integer(m[1])
    }
    return -1
}

SC_ReadStableCount(io) {
    previous := 0
    Loop 4 {
        obs := io.Sample(), now := io.Now()
        if IsObject(obs) && obs.HasOwnProp("interrupted") && obs.interrupted {
            previous := 0
            continue
        }
        if !IsObject(obs) || now-obs.capturedAt < 0 || now-obs.capturedAt > 5000
            return -1
        count := SC_ParseCount(obs.blocks,obs.width,obs.height)
        if count < 0
            return -1
        if IsObject(previous) {
            if obs.key != previous.key || obs.frame = previous.frame
                return -1
            if obs.pausedMs = previous.pausedMs {
                if count != previous.count || obs.capturedAt-previous.capturedAt < 300
                    return -1
                return count
            }
            ; PAUSE invalidates old stability evidence, not the entire attempt.
        }
        previous := {key:obs.key,frame:obs.frame,count:count,capturedAt:obs.capturedAt,pausedMs:obs.pausedMs}
        io.Wait(350)
    }
    return -1
}
