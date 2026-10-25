#Requires AutoHotkey v2.0+
#Include CompletionSynthesis.ahk

FRS_ReadSection(config, section) {
    if !FileExist(config)
        return ""
    for name in StrSplit(IniRead(config),"`n","`r")
        if name = section
            return IniRead(config,section)
    return ""
}

FRS_ArchiveAndReset(config, section, synthesisRoot, historyRoot, drained) {
    ; Called only by the fresh main AFTER preflight cleanup and while it owns
    ; the installation runtime mutex. No credential-bearing config snapshot.
    if !drained.Call()
        throw Error("舊合成／LRMCAI 子程序仍存在或身分尚未確認")
    reward := FRS_ReadSection(config,section)
    statePath := synthesisRoot "\state.txt"
    hadState := !!FileExist(statePath)
    synthesis := hadState ? CS_ReadControlText(statePath) : ""
    if reward = "" && !hadState
        return true
    guid := Buffer(16), text := Buffer(78)
    if DllCall("ole32\CoCreateGuid","ptr",guid,"uint") != 0
        throw Error("無法建立全新循環歷史身分")
    DllCall("ole32\StringFromGUID2","ptr",guid,"ptr",text,"int",39)
    archive := historyRoot "\" A_Now "-" RegExReplace(StrGet(text),"[^A-Za-z0-9-]","")
    DirCreate(archive)
    CS_WriteControlText(archive "\reward-state.ini",reward)
    CS_WriteControlText(archive "\completion-state.txt",synthesis)
    if CS_ReadControlText(archive "\reward-state.ini") != reward
        || CS_ReadControlText(archive "\completion-state.txt") != synthesis
        throw Error("全新循環歷史保存回讀不一致")
    ; Recheck both identity-bearing state and child absence at the destructive
    ; boundary. An archive failure never erases the only copy of old evidence.
    if !drained.Call() || FRS_ReadSection(config,section) != reward
        || !!FileExist(statePath) != hadState
        || (hadState && CS_ReadControlText(statePath) != synthesis)
        throw Error("全新循環重設前舊狀態已變更")
    if reward != ""
        IniDelete(config,section)
    if hadState
        FileDelete(statePath)
    if FRS_ReadSection(config,section) != "" || FileExist(statePath)
        throw Error("全新循環重設回讀未確認")
    CS_WriteControlText(archive "\reset-complete.txt","fresh-launch | " A_Now)
    return true
}
