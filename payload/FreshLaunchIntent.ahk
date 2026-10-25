#Requires AutoHotkey v2.0+

FLI_Canonical(path) {
    pathBuffer := Buffer(65536)
    length := DllCall("GetFullPathNameW","str",path,"uint",32768,"ptr",pathBuffer,"ptr",0,"uint")
    if !length || length >= 32768
        throw Error("無法確認全新啟動安裝路徑")
    return StrLower(RTrim(StrGet(pathBuffer,length,"UTF-16"),"\"))
}

FLI_CommandGeneration(config) {
    cursor := IniRead(config,"remote_control","last_nonce","0")
    desired := IniRead(config ".remote_desired_state.ini","desired_state","nonce","0")
    for value in [cursor,desired]
        if !RegExMatch(value,"^\d{1,10}$") || Integer(value) > 2147483647
            throw Error("無法確認目前遠端命令世代")
    return Max(Integer(cursor),Integer(desired))
}

FLI_Capture(root) {
    ; Relocation is a child of this same launch, not fresh user authority.
    ; Preserve the first generation, even when a newer STOP arrived meanwhile.
    canonical := FLI_Canonical(root)
    inheritedRoot := EnvGet("PACK_FRESH_INSTALL")
    inheritedNonce := EnvGet("PACK_FRESH_COMMAND_NONCE")
    if inheritedRoot != "" || inheritedNonce != "" {
        if inheritedRoot = "" || FLI_Canonical(inheritedRoot) != canonical
            || !RegExMatch(inheritedNonce,"^\d{1,10}$") || Integer(inheritedNonce) > 2147483647
            throw Error("繼承的全新啟動意圖無效；不重新授權")
        return
    }
    ; Inherited by this launcher's child only, not a global environment edit.
    EnvSet("PACK_FRESH_INSTALL",canonical)
    EnvSet("PACK_FRESH_COMMAND_NONCE",String(FLI_CommandGeneration(root "\config\config.ini")))
}

FLI_Clear() {
    EnvSet("PACK_FRESH_INSTALL","")
    EnvSet("PACK_FRESH_COMMAND_NONCE","")
}

FLI_AllowsFresh(config) {
    root := EnvGet("PACK_FRESH_INSTALL")
    if root = ""
        return true ; direct manual main launch: no earlier takeover interval
    SplitPath(config,,&configDir)
    SplitPath(configDir,,&installDir)
    baseline := EnvGet("PACK_FRESH_COMMAND_NONCE")
    if FLI_Canonical(root) != FLI_Canonical(installDir)
        || !RegExMatch(baseline,"^\d{1,10}$") || Integer(baseline) > 2147483647
        return false
    return FLI_CommandGeneration(config) <= Integer(baseline)
}
