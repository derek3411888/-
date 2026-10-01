#Requires AutoHotkey v2.0+

; Public integration contract:
;   NativeRuntime_SendMail(host, port, user, pass, from, commaRecipients,
;       subject, body, useSsl) -> {ok: Boolean, message: String}
;   NativeRuntime_SetGameMute(pidCsv, nameCsv, mute) -> Integer
;       0 = changed at least one exact-PID session
;       2 = no exact-PID session
;       any other value = validation, transport, timeout, or Core Audio error
;
; Secrets and message contents travel only through inherited anonymous pipes.
; RuntimeUtilities.exe receives only the operation name on its command line.

NativeRuntime_SendMail(smtpHost, smtpPort, smtpUser, smtpPass, mailFrom,
    mailTo, subject, body, useSsl := "1") {
    try port := Integer(smtpPort)
    catch
        return {ok:false, message:"SMTP port is invalid."}

    sslText := StrLower(Trim(String(useSsl), " `t`r`n"))
    sslJson := (sslText = "1" || sslText = "true") ? "true" : "false"
    request := '{"smtpHost":' NativeRuntime_JsonQuote(smtpHost)
        . ',"smtpPort":' port
        . ',"smtpUser":' NativeRuntime_JsonQuote(smtpUser)
        . ',"smtpPass":' NativeRuntime_JsonQuote(smtpPass)
        . ',"mailFrom":' NativeRuntime_JsonQuote(mailFrom)
        . ',"mailTo":' NativeRuntime_JsonQuote(mailTo)
        . ',"subject":' NativeRuntime_JsonQuote(subject)
        . ',"body":' NativeRuntime_JsonQuote(body)
        . ',"useSsl":' sslJson
        . ',"timeoutMs":30000}'
    result := NativeRuntime_Invoke("mail", request, 35000)
    return {ok:result.ok, message:result.message}
}

NativeRuntime_SetGameMute(pidCsv, nameCsv, mute := true) {
    muteJson := mute ? "true" : "false"
    request := '{"pidCsv":' NativeRuntime_JsonQuote(pidCsv)
        . ',"nameCsv":' NativeRuntime_JsonQuote(nameCsv)
        . ',"mute":' muteJson '}'
    result := NativeRuntime_Invoke("audio", request, 12000)
    return result.exitCode
}

NativeRuntime_Invoke(operation, requestJson, timeoutMs) {
    if (operation != "mail" && operation != "audio")
        return NativeRuntime_Failure(64, "Unknown native utility operation.")
    if (StrLen(requestJson) > 1048576)
        return NativeRuntime_Failure(64, "Native utility request is too large.")

    ; A cancelled overlapped operation may outlive the bounded caller.  Reap a
    ; completed operation first, but never queue another request behind memory
    ; which the kernel may still reference.
    NativeRuntime_ReapPendingIo()
    if NativeRuntime_PendingIoCount()
        return NativeRuntime_Failure(71,
            "A previous native utility I/O operation is still completing.")

    exePath := NativeRuntime_ExecutablePath()
    if !FileExist(exePath)
        return NativeRuntime_Failure(71, "RuntimeUtilities.exe was not found.")

    stdinRead := 0
    stdinWrite := 0
    stdoutRead := 0
    stdoutWrite := 0
    processHandle := 0
    threadHandle := 0
    try {
        securitySize := A_PtrSize = 8 ? 24 : 12
        security := Buffer(securitySize, 0)
        NumPut("UInt", securitySize, security, 0)
        NumPut("Ptr", 0, security, A_PtrSize = 8 ? 8 : 4)
        NumPut("Int", true, security, A_PtrSize = 8 ? 16 : 8)

        if !DllCall("Kernel32\CreatePipe", "Ptr*", &stdoutRead, "Ptr*", &stdoutWrite,
            "Ptr", security, "UInt", 0, "Int")
            return NativeRuntime_Failure(71, "Cannot create native utility output pipe.")
        if !DllCall("Kernel32\SetHandleInformation", "Ptr", stdoutRead,
            "UInt", 1, "UInt", 0, "Int")
            return NativeRuntime_Failure(71, "Cannot secure native utility output pipe.")
        ; The parent side is overlapped so a wrong or stalled child cannot make
        ; the AHK thread block forever while writing a large mail body.
        if !NativeRuntime_CreateInputPipe(&stdinWrite, &stdinRead, security) {
            NativeRuntime_ReapPendingIo()
            return NativeRuntime_Failure(71, "Cannot create native utility input pipe.")
        }

        startupInfo := Buffer(A_PtrSize = 8 ? 104 : 68, 0)
        processInfo := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
        NumPut("UInt", startupInfo.Size, startupInfo, 0)
        flagsOffset := A_PtrSize = 8 ? 60 : 44
        showOffset := A_PtrSize = 8 ? 64 : 48
        stdInputOffset := A_PtrSize = 8 ? 80 : 56
        NumPut("UInt", 0x101, startupInfo, flagsOffset)
        NumPut("UShort", 0, startupInfo, showOffset)
        NumPut("Ptr", stdinRead, startupInfo, stdInputOffset)
        NumPut("Ptr", stdoutWrite, startupInfo, stdInputOffset + A_PtrSize)
        NumPut("Ptr", stdoutWrite, startupInfo, stdInputOffset + (2 * A_PtrSize))

        command := '"' exePath '" ' operation
        commandBuffer := Buffer((StrLen(command) + 1) * 2, 0)
        StrPut(command, commandBuffer, "UTF-16")
        SplitPath exePath, , &workDir
        if !DllCall("Kernel32\CreateProcessW", "Str", exePath, "Ptr", commandBuffer,
            "Ptr", 0, "Ptr", 0, "Int", true, "UInt", 0x08000000,
            "Ptr", 0, "Str", workDir, "Ptr", startupInfo, "Ptr", processInfo, "Int")
            return NativeRuntime_Failure(71, "Cannot start RuntimeUtilities.exe.")

        processHandle := NumGet(processInfo, 0, "Ptr")
        threadHandle := NumGet(processInfo, A_PtrSize, "Ptr")
        DllCall("Kernel32\CloseHandle", "Ptr", threadHandle)
        threadHandle := 0
        DllCall("Kernel32\CloseHandle", "Ptr", stdinRead)
        stdinRead := 0
        DllCall("Kernel32\CloseHandle", "Ptr", stdoutWrite)
        stdoutWrite := 0

        invokeTimeout := Max(500, Integer(timeoutMs))
        invokeDeadline := DllCall("Kernel32\GetTickCount64", "UInt64") + invokeTimeout
        writeResult := NativeRuntime_WriteUtf8Bounded(&stdinWrite, requestJson, invokeTimeout)
        if !writeResult.ok {
            writeExit := writeResult.timedOut ? 124 : 71
            DllCall("Kernel32\TerminateProcess", "Ptr", processHandle, "UInt", writeExit)
            DllCall("Kernel32\WaitForSingleObject", "Ptr", processHandle, "UInt", 5000)
            NativeRuntime_ReapPendingIo()
            return NativeRuntime_Failure(writeExit, writeResult.timedOut
                ? "Native utility timed out while receiving its request."
                : "Cannot send request to native utility.")
        }
        DllCall("Kernel32\CloseHandle", "Ptr", stdinWrite)
        stdinWrite := 0

        now := DllCall("Kernel32\GetTickCount64", "UInt64")
        remaining := invokeDeadline > now ? invokeDeadline - now : 0
        waitResult := DllCall("Kernel32\WaitForSingleObject", "Ptr", processHandle,
            "UInt", Min(remaining, 0xFFFFFFFF), "UInt")
        if (waitResult = 258) {
            DllCall("Kernel32\TerminateProcess", "Ptr", processHandle, "UInt", 124)
            DllCall("Kernel32\WaitForSingleObject", "Ptr", processHandle, "UInt", 5000)
            return NativeRuntime_Failure(124, "Native utility timed out.")
        }
        if (waitResult != 0) {
            DllCall("Kernel32\TerminateProcess", "Ptr", processHandle, "UInt", 71)
            DllCall("Kernel32\WaitForSingleObject", "Ptr", processHandle, "UInt", 5000)
            return NativeRuntime_Failure(71, "Cannot wait for native utility.")
        }

        processExit := 70
        if !DllCall("Kernel32\GetExitCodeProcess", "Ptr", processHandle,
            "UInt*", &processExit, "Int")
            processExit := 70
        responseJson := NativeRuntime_ReadUtf8(stdoutRead)
        return NativeRuntime_ParseResponse(responseJson, processExit)
    } catch {
        if processHandle {
            try DllCall("Kernel32\TerminateProcess", "Ptr", processHandle, "UInt", 71)
            try DllCall("Kernel32\WaitForSingleObject", "Ptr", processHandle, "UInt", 5000)
        }
        NativeRuntime_ReapPendingIo()
        return NativeRuntime_Failure(71, "Native utility transport failed.")
    } finally {
        for handle in [threadHandle, processHandle, stdinRead, stdinWrite, stdoutRead, stdoutWrite] {
            if handle
                try DllCall("Kernel32\CloseHandle", "Ptr", handle)
        }
    }
}

NativeRuntime_ExecutablePath() {
    return A_ScriptDir "\RuntimeUtilities.exe"
}

NativeRuntime_CreateInputPipe(&parentWrite, &childRead, inheritSecurity) {
    parentWrite := 0
    childRead := 0
    guid := Buffer(16, 0)
    guidText := Buffer(80, 0)
    if DllCall("Ole32\CoCreateGuid", "Ptr", guid, "Int") != 0
        return false
    if DllCall("Ole32\StringFromGUID2", "Ptr", guid, "Ptr", guidText,
        "Int", 40, "Int") <= 0
        return false
    token := RegExReplace(StrGet(guidText), "[^A-Fa-f0-9]", "")
    pipeName := "\\.\pipe\Wuthering.RuntimeUtilities."
        . DllCall("Kernel32\GetCurrentProcessId", "UInt") "." token
    parentWrite := DllCall("Kernel32\CreateNamedPipeW", "Str", pipeName,
        "UInt", 0x40080002, "UInt", 0x8, "UInt", 1,
        "UInt", 65536, "UInt", 65536, "UInt", 0, "Ptr", 0, "Ptr")
    if (parentWrite = -1) {
        parentWrite := 0
        return false
    }

    connectEvent := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true,
        "Int", false, "Ptr", 0, "Ptr")
    if !connectEvent {
        DllCall("Kernel32\CloseHandle", "Ptr", parentWrite)
        parentWrite := 0
        return false
    }
    overlapped := NativeRuntime_NewOverlapped(connectEvent)
    pending := false
    success := false
    eventTransferred := false
    try {
        connected := DllCall("Kernel32\ConnectNamedPipe", "Ptr", parentWrite,
            "Ptr", overlapped, "Int")
        if !connected {
            connectError := A_LastError
            if (connectError = 997)
                pending := true
            else if (connectError != 535)
                return false
        }

        childRead := DllCall("Kernel32\CreateFileW", "Str", pipeName,
            "UInt", 0x80000000, "UInt", 0, "Ptr", inheritSecurity,
            "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
        if (childRead = -1) {
            childRead := 0
            return false
        }
        if pending {
            waitResult := DllCall("Kernel32\WaitForSingleObject", "Ptr", connectEvent,
                "UInt", 5000, "UInt")
            connectedBytes := 0
            if (waitResult != 0 || !DllCall("Kernel32\GetOverlappedResult",
                "Ptr", parentWrite, "Ptr", overlapped, "UInt*", &connectedBytes,
                "Int", false, "Int"))
                return false
        }
        success := true
        return true
    } finally {
        if !success {
            if childRead {
                DllCall("Kernel32\CloseHandle", "Ptr", childRead)
                childRead := 0
            }
            if (pending && parentWrite) {
                cancelState := {eventHandle:connectEvent, overlapped:overlapped}
                cancelResult := NativeRuntime_CancelOverlapped(&parentWrite,
                    cancelState)
                eventTransferred := cancelResult.deferred
            }
            if parentWrite {
                DllCall("Kernel32\CloseHandle", "Ptr", parentWrite)
                parentWrite := 0
            }
        }
        if !eventTransferred
            DllCall("Kernel32\CloseHandle", "Ptr", connectEvent)
        if !success {
            parentWrite := 0
        }
    }
}

NativeRuntime_NewOverlapped(eventHandle) {
    overlapped := Buffer(A_PtrSize = 8 ? 32 : 20, 0)
    NumPut("Ptr", eventHandle, overlapped, A_PtrSize = 8 ? 24 : 16)
    return overlapped
}

NativeRuntime_WriteUtf8Bounded(&handle, text, timeoutMs) {
    text .= "`n"
    byteCount := StrPut(text, "UTF-8") - 1
    bytes := Buffer(byteCount + 1, 0)
    StrPut(text, bytes, "UTF-8")
    offset := 0
    deadline := DllCall("Kernel32\GetTickCount64", "UInt64") + timeoutMs
    while (offset < byteCount) {
        eventHandle := DllCall("Kernel32\CreateEventW", "Ptr", 0, "Int", true,
            "Int", false, "Ptr", 0, "Ptr")
        if !eventHandle
            return {ok:false, timedOut:false}
        overlapped := NativeRuntime_NewOverlapped(eventHandle)
        written := 0
        chunkSize := Min(65536, byteCount - offset)
        eventTransferred := false
        try {
            completed := DllCall("Kernel32\WriteFile", "Ptr", handle,
                "Ptr", bytes.Ptr + offset, "UInt", chunkSize,
                "Ptr", 0, "Ptr", overlapped, "Int")
            if !completed {
                writeError := A_LastError
                if (writeError != 997)
                    return {ok:false, timedOut:false}
                now := DllCall("Kernel32\GetTickCount64", "UInt64")
                remaining := deadline > now ? deadline - now : 0
                waitResult := DllCall("Kernel32\WaitForSingleObject", "Ptr", eventHandle,
                    "UInt", Min(remaining, 0xFFFFFFFF), "UInt")
                if (waitResult = 258) {
                    cancelState := {eventHandle:eventHandle,
                        overlapped:overlapped, keepAlive:bytes}
                    cancelResult := NativeRuntime_CancelOverlapped(
                        &handle, cancelState)
                    eventTransferred := cancelResult.deferred
                    return {ok:false, timedOut:true}
                }
                if (waitResult != 0) {
                    cancelState := {eventHandle:eventHandle,
                        overlapped:overlapped, keepAlive:bytes}
                    cancelResult := NativeRuntime_CancelOverlapped(
                        &handle, cancelState)
                    eventTransferred := cancelResult.deferred
                    return {ok:false, timedOut:false}
                }
            }
            if !DllCall("Kernel32\GetOverlappedResult", "Ptr", handle,
                "Ptr", overlapped, "UInt*", &written, "Int", false, "Int")
                return {ok:false, timedOut:false}
            if (written <= 0)
                return {ok:false, timedOut:false}
            offset += written
        } finally {
            if !eventTransferred
                DllCall("Kernel32\CloseHandle", "Ptr", eventHandle)
        }
    }
    return {ok:true, timedOut:false}
}

NativeRuntime_CancelOverlapped(&handle, state, ops := unset) {
    if !handle
        return {terminal:true, deferred:false}
    if !IsSet(ops)
        ops := NativeRuntime_PendingIoOperations()

    try ops.cancel.Call(handle, state.overlapped)
    try ops.wait.Call(state.eventHandle, 2000)
    terminal := false
    try terminal := ops.status.Call(handle, state.overlapped) != 0
    if terminal
        return {terminal:true, deferred:false}

    ; CancelIoEx only requests cancellation.  Keep every address supplied to
    ; the kernel, plus both handles, alive until GetOverlappedResult reports a
    ; terminal status.  The caller relinquishes the file handle to this state.
    state.handle := handle
    state.ops := ops
    handle := 0
    NativeRuntime_RetainPendingIo(state)
    return {terminal:false, deferred:true}
}

NativeRuntime_PendingIoOperations() {
    static operations := {
        cancel:NativeRuntime_RequestOverlappedCancel,
        wait:NativeRuntime_WaitForHandle,
        status:NativeRuntime_OverlappedStatus,
        close:NativeRuntime_CloseNativeHandle}
    return operations
}

NativeRuntime_RequestOverlappedCancel(handle, overlapped) {
    return DllCall("Kernel32\CancelIoEx", "Ptr", handle,
        "Ptr", overlapped, "Int")
}

NativeRuntime_WaitForHandle(handle, timeoutMs) {
    return DllCall("Kernel32\WaitForSingleObject", "Ptr", handle,
        "UInt", timeoutMs, "UInt")
}

NativeRuntime_OverlappedStatus(handle, overlapped) {
    transferred := 0
    if DllCall("Kernel32\GetOverlappedResult", "Ptr", handle,
        "Ptr", overlapped, "UInt*", &transferred, "Int", false, "Int")
        return 1
    ; ERROR_IO_INCOMPLETE is the only nonterminal result for a valid retained
    ; handle.  All other results are final success/failure completion states.
    return A_LastError = 996 ? 0 : 2
}

NativeRuntime_CloseNativeHandle(handle) {
    return DllCall("Kernel32\CloseHandle", "Ptr", handle, "Int")
}

NativeRuntime_PendingIoQueue() {
    static queue := []
    return queue
}

NativeRuntime_PendingIoCount() {
    return NativeRuntime_PendingIoQueue().Length
}

NativeRuntime_RetainPendingIo(state) {
    ; NativeRuntime_Invoke refuses another operation while this queue is not
    ; empty, so production can retain at most one request buffer.
    NativeRuntime_PendingIoQueue().Push(state)
}

NativeRuntime_ReapPendingIo() {
    queue := NativeRuntime_PendingIoQueue()
    index := queue.Length
    while (index >= 1) {
        state := queue[index]
        terminal := false
        try terminal := state.ops.status.Call(
            state.handle, state.overlapped) != 0
        if terminal {
            queue.RemoveAt(index)
            try state.ops.close.Call(state.handle)
            try state.ops.close.Call(state.eventHandle)
            state.handle := 0
            state.eventHandle := 0
            if state.HasOwnProp("keepAlive")
                state.keepAlive := ""
        }
        index -= 1
    }
}

NativeRuntime_ReadUtf8(handle) {
    ; RuntimeUtilities bounds error text, so every response fits in this buffer.
    bytes := Buffer(65536, 0)
    bytesRead := 0
    if !DllCall("Kernel32\ReadFile", "Ptr", handle, "Ptr", bytes,
        "UInt", bytes.Size - 1, "UInt*", &bytesRead, "Ptr", 0, "Int") {
        if (A_LastError != 109)
            return ""
    }
    if (bytesRead <= 0)
        return ""
    return StrGet(bytes, bytesRead, "UTF-8")
}

NativeRuntime_ParseResponse(jsonText, processExit) {
    if !RegExMatch(jsonText, '"ok"\s*:\s*(true|false)', &okMatch)
        return NativeRuntime_Failure(processExit = 0 ? 70 : processExit,
            "Native utility returned an invalid response.")
    ok := StrLower(okMatch[1]) = "true"
    exitCode := NativeRuntime_JsonInteger(jsonText, "exitCode", processExit)
    message := NativeRuntime_JsonString(jsonText, "message", "")
    code := NativeRuntime_JsonString(jsonText, "code", ok ? "ok" : "error")
    if (exitCode != processExit && processExit != 0)
        exitCode := processExit
    return {ok:ok && exitCode = 0, message:message, code:code, exitCode:exitCode}
}

NativeRuntime_Failure(exitCode, message) {
    return {ok:false, message:message, code:"transport_error", exitCode:exitCode}
}

NativeRuntime_JsonQuote(value) {
    text := String(value)
    text := StrReplace(text, "\", "\\")
    text := StrReplace(text, '"', '\"')
    text := StrReplace(text, "`b", "\b")
    text := StrReplace(text, "`f", "\f")
    text := StrReplace(text, "`n", "\n")
    text := StrReplace(text, "`r", "\r")
    text := StrReplace(text, "`t", "\t")
    return '"' text '"'
}

NativeRuntime_JsonString(jsonText, fieldName, defaultValue := "") {
    pattern := '"' fieldName '"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"'
    if !RegExMatch(jsonText, pattern, &match)
        return defaultValue
    return NativeRuntime_JsonUnescape(match[1])
}

NativeRuntime_JsonInteger(jsonText, fieldName, defaultValue := 0) {
    pattern := '"' fieldName '"\s*:\s*(-?\d+)'
    if RegExMatch(jsonText, pattern, &match) {
        try return Integer(match[1])
    }
    return defaultValue
}

NativeRuntime_JsonUnescape(value) {
    result := ""
    index := 1
    length := StrLen(value)
    while (index <= length) {
        char := SubStr(value, index, 1)
        if (char != "\") {
            result .= char
            index += 1
            continue
        }
        index += 1
        if (index > length)
            return ""
        escape := SubStr(value, index, 1)
        if (escape = '"' || escape = "\" || escape = "/")
            result .= escape
        else if (escape = "b")
            result .= "`b"
        else if (escape = "f")
            result .= "`f"
        else if (escape = "n")
            result .= "`n"
        else if (escape = "r")
            result .= "`r"
        else if (escape = "t")
            result .= "`t"
        else if (escape = "u") {
            hex := SubStr(value, index + 1, 4)
            if !RegExMatch(hex, "^[0-9A-Fa-f]{4}$")
                return ""
            codePoint := Integer("0x" hex)
            index += 4
            if (codePoint >= 0xD800 && codePoint <= 0xDBFF
                && SubStr(value, index + 1, 2) = "\u") {
                lowHex := SubStr(value, index + 3, 4)
                if RegExMatch(lowHex, "^[0-9A-Fa-f]{4}$") {
                    low := Integer("0x" lowHex)
                    if (low >= 0xDC00 && low <= 0xDFFF) {
                        codePoint := 0x10000 + ((codePoint - 0xD800) << 10) + (low - 0xDC00)
                        index += 6
                    }
                }
            }
            result .= Chr(codePoint)
        } else
            return ""
        index += 1
    }
    return result
}
