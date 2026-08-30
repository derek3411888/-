#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir

#Include ..\測試\TestRuntimePaths.ahk

global RUN_ID := A_Now "@" A_TickCount
global STEP_SEQ := 0
global TOOLTIP_SLOT := 7
global MAIL_TEST_RUNTIME_DIR := TestRuntime_EnsureDir("mail")

ShowTip(msg, duration := 5000) {
    global TOOLTIP_SLOT
    if (duration < 5000)
        duration := 5000
    ToolTip "          " msg, , , TOOLTIP_SLOT
    if (duration > 0)
        SetTimer(() => ToolTip(, , , TOOLTIP_SLOT), -duration)
}

WriteLog(msg, level := "INFO") {
    global RUN_ID, MAIL_TEST_RUNTIME_DIR
    ts := FormatTime(, "yyyy-MM-dd HH:mm:ss")
    line := ts " [" level "] [" RUN_ID "] " msg "`r`n"
    try FileAppend(line, MAIL_TEST_RUNTIME_DIR "\寄送信件測試.log", "UTF-8")
}

JoinArray(items, sep := ",") {
    out := ""
    for idx, v in items {
        if (idx > 1)
            out .= sep
        out .= v
    }
    return out
}

BuildStartupReason() {
    parts := []
    if (A_Args.Length > 0)
        parts.Push("args=" JoinArray(A_Args, "|"))
    else
        parts.Push("args=<none>")
    parts.Push("source=" (A_Args.Length > 0 ? "arg-trigger" : "external-trigger(manual-or-scheduler)"))
    return JoinArray(parts, " | ")
}

LifecycleOnExit(exitReason, exitCode) {
    WriteLog("生命週期停止原因: reason=" exitReason " | exitCode=" exitCode)
}

WriteStep(stepName, detail := "", level := "INFO") {
    global STEP_SEQ
    STEP_SEQ += 1
    msg := "[STEP " Format("{:03}", STEP_SEQ) "] " stepName
    if (detail != "")
        msg .= " | " detail
    WriteLog(msg, level)
    ShowTip("📌 " stepName)
}

cfgPath := A_ScriptDir "\mail_config.ini"
WriteLog("生命週期啟動原因: " BuildStartupReason())
OnExit(LifecycleOnExit)
WriteStep("啟動", "cfgPath=" cfgPath)

if !FileExist(cfgPath) {
    WriteStep("設定檢查失敗", "mail_config.ini 不存在", "ERROR")
    MsgBox "找不到設定檔：" cfgPath "`n請先複製並填寫 mail_config.ini", "寄信測試", "Iconx"
    ExitApp
}

smtpHost := Trim(IniRead(cfgPath, "mail", "smtp_host", ""), " `t`r`n")
smtpPort := Trim(IniRead(cfgPath, "mail", "smtp_port", "587"), " `t`r`n")
smtpUser := Trim(IniRead(cfgPath, "mail", "smtp_user", ""), " `t`r`n")
smtpPass := Trim(IniRead(cfgPath, "mail", "smtp_pass", ""), " `t`r`n")
if (smtpPass = "")
    smtpPass := Trim(IniRead(cfgPath, "mail", "smtp_password", ""), " `t`r`n")
mailFrom := Trim(IniRead(cfgPath, "mail", "from", ""), " `t`r`n")
mailTo := Trim(IniRead(cfgPath, "mail", "to", ""), " `t`r`n")
subjectPrefix := Trim(IniRead(cfgPath, "mail", "subject_prefix", "LRMCAI"), " `t`r`n")
useSsl := Trim(IniRead(cfgPath, "mail", "use_ssl", "1"), " `t`r`n")

missing := []
if (smtpHost = "")
    missing.Push("smtp_host")
if (smtpUser = "")
    missing.Push("smtp_user")
if (smtpPass = "")
    missing.Push("smtp_pass 或 smtp_password")
if (mailFrom = "")
    missing.Push("from")
if (mailTo = "")
    missing.Push("to")

if (missing.Length > 0) {
    WriteStep("設定檢查失敗", "缺少欄位=" JoinByComma(missing), "ERROR")
    MsgBox "mail_config.ini 內容不完整。`n缺少：" JoinByComma(missing), "寄信測試", "Iconx"
    ExitApp
}

if !(smtpPort ~= "^\d+$") {
    WriteStep("設定檢查失敗", "smtp_port 非數字: " smtpPort, "ERROR")
    MsgBox "smtp_port 必須是數字。當前值：" smtpPort, "寄信測試", "Iconx"
    ExitApp
}

WriteStep("設定檢查", "SMTP=" smtpHost ":" smtpPort " SSL=" useSsl)

nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")
subject := subjectPrefix " 測試通知 " nowText
body := "這是一封測試信。`r`n時間：" nowText "`r`n主機：" A_ComputerName

WriteStep("寄信流程", "開始呼叫 PowerShell SMTP")
sendResult := SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl)
if sendResult.ok {
    WriteStep("完成", "測試信寄送成功")
    MsgBox "✅ 測試信寄送成功！", "寄信測試", "Iconi"
} else {
    WriteStep("完成", "測試信寄送失敗: " sendResult.message, "ERROR")
    hint := ""
    if (InStr(smtpHost, "gmail.com")) {
        hint := "`n`nGmail 提示：請使用『應用程式密碼』，不能用一般登入密碼。"
    }
    MsgBox "❌ 測試信寄送失敗。`n`n錯誤訊息：`n" sendResult.message hint, "寄信測試", "Iconx"
}

SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl := "1") {
    psFile := TestRuntime_NewFile("mail", "send_mail", ".ps1")
    errFile := TestRuntime_NewFile("mail", "send_mail_error", ".txt")

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

    WriteLog("PowerShell 腳本已組裝，準備執行 SMTP", "INFO")
    try FileDelete(psFile)
    try FileDelete(errFile)
    FileAppend(script, psFile, "UTF-8")

    cmd := 'powershell -NoProfile -ExecutionPolicy Bypass -File "' psFile '" > "' errFile '" 2>&1'
    WriteLog("執行命令: " cmd)
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
        errMsg := "PowerShell SMTP 呼叫失敗，ExitCode=" exitCode
    return { ok: false, message: errMsg }
}

PsEsc(text) {
    return StrReplace(text, "'", "''")
}

JoinByComma(arr) {
    txt := ""
    for item in arr {
        if (txt != "")
            txt .= ", "
        txt .= item
    }
    return txt
}
