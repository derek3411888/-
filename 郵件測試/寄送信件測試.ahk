#Requires AutoHotkey v2.0+
#SingleInstance Force
SetWorkingDir A_ScriptDir

cfgPath := A_ScriptDir "\mail_config.ini"

if !FileExist(cfgPath) {
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
    MsgBox "mail_config.ini 內容不完整。`n缺少：" JoinByComma(missing), "寄信測試", "Iconx"
    ExitApp
}

if !(smtpPort ~= "^\d+$") {
    MsgBox "smtp_port 必須是數字。當前值：" smtpPort, "寄信測試", "Iconx"
    ExitApp
}

nowText := FormatTime(, "yyyy-MM-dd HH:mm:ss")
subject := subjectPrefix " 測試通知 " nowText
body := "這是一封測試信。`r`n時間：" nowText "`r`n主機：" A_ComputerName

sendResult := SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl)
if sendResult.ok {
    MsgBox "✅ 測試信寄送成功！", "寄信測試", "Iconi"
} else {
    hint := ""
    if (InStr(smtpHost, "gmail.com")) {
        hint := "`n`nGmail 提示：請使用『應用程式密碼』，不能用一般登入密碼。"
    }
    MsgBox "❌ 測試信寄送失敗。`n`n錯誤訊息：`n" sendResult.message hint, "寄信測試", "Iconx"
}

SendMailByPowerShell(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom, mailTo, subject, body, useSsl := "1") {
    psFile := A_Temp "\send_mail_test_" A_TickCount ".ps1"
    errFile := A_Temp "\send_mail_test_err_" A_TickCount ".txt"

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

    try FileDelete(psFile)
    try FileDelete(errFile)
    FileAppend(script, psFile, "UTF-8")

    cmd := 'powershell -NoProfile -ExecutionPolicy Bypass -File "' psFile '" > "' errFile '" 2>&1'
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
