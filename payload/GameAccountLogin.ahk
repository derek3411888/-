#Requires AutoHotkey v2.0

; Account-provider login is not the server's "click to connect" page.
GL_IsAccountDialog(blocks) {
    brand := false, account := false
    if blocks is Array {
        for block in blocks {
            if !block.HasOwnProp("text")
                continue
            text := RegExReplace(block.text,"\s","")
            if InStr(StrUpper(text),"KUROGAMES")
                brand := true
            if RegExMatch(text,"^(登录|登入|登錄)$|其他登|验证码|驗證碼|人机验证|人機驗證|密码|密碼|(?i:captcha|password)")
                account := true
        }
    }
    return brand && account
}

GL_Classify(blocks,width,height) {
    if !(blocks is Array) || width < 500 || height < 280
        return 0
    brand := false, buttons := []
    for block in blocks {
        if !block.HasOwnProp("text")
            continue
        text := RegExReplace(block.text,"\s","")
        if RegExMatch(text,"验证码|驗證碼|人机验证|人機驗證|密码|密碼|維護|维护|(?i:captcha|password|maintenance)")
            return 0
        if InStr(StrUpper(text),"KUROGAMES")
            brand := true
        if !RegExMatch(text,"^(登录|登入|登錄)$") || !block.HasOwnProp("boxPoint")
            continue
        try {
            p := block.boxPoint
            x := (p[1].x+p[3].x)/2, y := (p[1].y+p[3].y)/2
            if p[1].x >= 0 && p[1].y >= 0 && p[3].x <= width && p[3].y <= height
                && p[3].x > p[1].x && p[3].y > p[1].y
                && x >= width*0.2 && x <= width*0.8 && y >= height*0.3 && y <= height*0.85
                buttons.Push({x:Round(x),y:Round(y),label:text})
        }
    }
    return brand && buttons.Length = 1 ? buttons[1] : 0
}

GL_Attempt(io,obs) {
    if io.Intent() != "RUN" || io.Alive() != true
        return "unverified"
    age := io.Now()-obs.capturedAt
    if age < 0 || age > 5000 || !IsObject(obs.candidate)
        return "waiting"
    if io.attempts >= 3
        return "limit"
    if io.attempts && io.Now()-io.lastAttempt < 15000
        return "waiting"
    io.lastAttempt := io.Now(), io.attempts++
    return io.Confirm(obs) ? "clicked" : "waiting"
}
