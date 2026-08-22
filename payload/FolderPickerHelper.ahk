#Requires AutoHotkey v2.0+
#SingleInstance Off
SetWorkingDir A_ScriptDir

; 這支 helper 由桌面 Explorer 啟動，正常情況會使用一般使用者權限，
; 因而能看見與檔案總管相同的映射磁碟。它另外主動列出映射磁碟、
; HKCU 持久映射與「網路位置」，不再依賴標準資料夾視窗的左側欄。

global __FOLDER_PICKER_SOURCE_UI := ""

if PickerHasArg("--probe") {
    probeReply := PickerNormalizePath(PickerArgValue("--reply", ""))
    probeLocations := PickerCollectNetworkLocations()
    PickerWriteReply(probeReply, "probe", "",
        "network_count=" probeLocations.Length, probeLocations.Length, "probe")
    ExitApp(0)
}

PickerRun()
ExitApp(0)

PickerHasArg(name) {
    target := StrLower(name)
    for _, arg in A_Args {
        if (StrLower(arg) = target)
            return true
    }
    return false
}

PickerArgValue(name, defaultValue := "") {
    target := StrLower(name)
    for idx, arg in A_Args {
        if (StrLower(arg) = target && idx < A_Args.Length)
            return A_Args[idx + 1]
    }
    return defaultValue
}

PickerNormalizePath(pathValue) {
    p := Trim(pathValue, ' "`t`r`n')
    if (p = "")
        return ""
    p := StrReplace(p, "/", "\")
    if (StrLen(p) > 3)
        p := RTrim(p, "\")
    return p
}

PickerMappedPathToUnc(pathValue) {
    p := PickerNormalizePath(pathValue)
    if (p = "" || SubStr(p, 1, 2) = "\\")
        return p
    if !RegExMatch(p, "i)^([a-z]:)(\\.*)?$", &m)
        return p

    required := 0
    rc := DllCall("Mpr\WNetGetUniversalNameW", "str", p, "uint", 1,
        "ptr", 0, "uint*", &required, "uint")
    if (rc = 234 && required > A_PtrSize) {
        info := Buffer(required, 0)
        rc := DllCall("Mpr\WNetGetUniversalNameW", "str", p, "uint", 1,
            "ptr", info.Ptr, "uint*", &required, "uint")
        if (rc = 0) {
            uncPtr := NumGet(info, 0, "ptr")
            if (uncPtr)
                return PickerNormalizePath(StrGet(uncPtr, "UTF-16"))
        }
    }

    remoteBuf := Buffer(65536, 0)
    remoteChars := 32768
    rc := DllCall("Mpr\WNetGetConnectionW", "str", m[1], "ptr", remoteBuf.Ptr,
        "uint*", &remoteChars, "uint")
    if (rc = 0) {
        remoteRoot := RTrim(StrGet(remoteBuf.Ptr, "UTF-16"), "\")
        return PickerNormalizePath(remoteRoot m[2])
    }

    try {
        driveLetter := SubStr(m[1], 1, 1)
        remoteRoot := Trim(RegRead("HKCU\Network\" driveLetter, "RemotePath"), ' "`t`r`n')
        if (remoteRoot != "")
            return PickerNormalizePath(RTrim(remoteRoot, "\") m[2])
    }
    return p
}

PickerAddNetworkLocation(locations, seen, label, pathValue) {
    p := PickerMappedPathToUnc(pathValue)
    if (p = "" || SubStr(p, 1, 2) != "\\")
        return false
    key := StrLower(p)
    if seen.Has(key)
        return false
    seen[key] := true
    locations.Push({label: label, path: p})
    return true
}

PickerCollectNetworkLocations() {
    locations := []
    seen := Map()

    ; 目前權杖實際連線中的映射磁碟。
    try {
        driveMask := DllCall("Kernel32\GetLogicalDrives", "uint")
        Loop 26 {
            bit := 1 << (A_Index - 1)
            if !(driveMask & bit)
                continue
            drive := Chr(64 + A_Index) ":"
            if (DllCall("Kernel32\GetDriveTypeW", "str", drive "\", "uint") != 4)
                continue
            unc := PickerMappedPathToUnc(drive "\")
            PickerAddNetworkLocation(locations, seen, drive " 映射磁碟 → " unc, unc)
        }
    }

    ; WScript 會列出目前登入使用者的連線；某些 SMB 提供者只會出現在這裡。
    try {
        network := ComObject("WScript.Network")
        drives := network.EnumNetworkDrives()
        pairCount := Floor(drives.Count / 2)
        Loop pairCount {
            base := (A_Index - 1) * 2
            localName := String(drives.Item(base))
            remoteName := String(drives.Item(base + 1))
            PickerAddNetworkLocation(locations, seen,
                (localName != "" ? localName " 映射磁碟 → " : "網路磁碟 → ") remoteName,
                remoteName)
        }
    }

    ; UAC 分離權杖看不到的持久映射，通常仍可從目前使用者 HKCU 取回。
    try {
        Loop Reg, "HKCU\Network", "K" {
            driveLetter := A_LoopRegName
            remoteName := Trim(RegRead("HKCU\Network\" driveLetter, "RemotePath", ""), ' "`t`r`n')
            if (remoteName != "")
                PickerAddNetworkLocation(locations, seen,
                    StrUpper(driveLetter) ": 持久映射 → " remoteName, remoteName)
        }
    }

    ; 檔案總管「新增網路位置」會把捷徑存放在 Network Shortcuts。
    netHood := EnvGet("APPDATA") "\Microsoft\Windows\Network Shortcuts"
    if DirExist(netHood) {
        try {
            Loop Files, netHood "\*.lnk", "FR" {
                target := ""
                try FileGetShortcut(A_LoopFileFullPath, &target)
                if (target = "")
                    continue
                SplitPath(A_LoopFileDir, &shortcutName)
                PickerAddNetworkLocation(locations, seen,
                    "網路位置 " shortcutName " → " target, target)
            }
        }
    }
    return locations
}

PickerSourceAccept(*) {
    global __FOLDER_PICKER_SOURCE_UI
    if !IsObject(__FOLDER_PICKER_SOURCE_UI)
        return
    idx := __FOLDER_PICKER_SOURCE_UI.dropdown.Value
    if (idx < 1 || idx > __FOLDER_PICKER_SOURCE_UI.items.Length)
        return
    __FOLDER_PICKER_SOURCE_UI.result := __FOLDER_PICKER_SOURCE_UI.items[idx]
    __FOLDER_PICKER_SOURCE_UI.done := true
    try __FOLDER_PICKER_SOURCE_UI.gui.Destroy()
}

PickerSourceCancel(*) {
    global __FOLDER_PICKER_SOURCE_UI
    if !IsObject(__FOLDER_PICKER_SOURCE_UI)
        return
    __FOLDER_PICKER_SOURCE_UI.result := {kind: "cancel", path: "", label: "取消"}
    __FOLDER_PICKER_SOURCE_UI.done := true
    try __FOLDER_PICKER_SOURCE_UI.gui.Destroy()
}

PickerSelectSource(initialPath, locations) {
    global __FOLDER_PICKER_SOURCE_UI

    labels := []
    items := []
    labels.Push("這台電腦：瀏覽本機磁碟與映射磁碟")
    items.Push({kind: "this_pc", path: "", label: "這台電腦"})

    for _, item in locations {
        labels.Push(item.label)
        items.Push({kind: "path", path: item.path, label: item.label})
    }

    labels.Push("網路：瀏覽區域網路上的電腦與共用資料夾")
    items.Push({kind: "network", path: "", label: "網路"})
    labels.Push("直接輸入 UNC：\\電腦名稱\共用資料夾")
    items.Push({kind: "unc", path: "", label: "直接輸入 UNC"})
    if (initialPath != "") {
        labels.Push("目前設定：" initialPath)
        items.Push({kind: "path", path: initialPath, label: "目前設定"})
    }

    g := Gui("+AlwaysOnTop -MinimizeBox", "錄影輸出資料夾")
    g.SetFont("s10", "Microsoft JhengHei UI")
    g.AddText("xm w720", "請選擇要從哪個位置開始瀏覽。映射磁碟會直接列在下方，不必等待檔案總管左側出現『網路』。")
    privilegeText := A_IsAdmin
        ? "目前 helper 仍為管理員權限；非持久映射可能看不到，但可選下方持久映射或直接輸入 UNC。"
        : "目前 helper 為一般使用者權限，應與檔案總管看到相同的映射磁碟。"
    color := A_IsAdmin ? "cB45309" : "c16794A"
    g.AddText("xm y+8 w720 " color, privilegeText)
    g.AddText("xm y+6 w720 c555555", "已偵測到 " locations.Length " 個映射磁碟／網路位置。")
    dropdown := g.AddDropDownList("xm y+10 w720", labels)
    dropdown.Choose(1)
    btnContinue := g.AddButton("xm y+16 w150 h34 Default", "開啟所選位置")
    btnCancel := g.AddButton("x+10 w90 h34", "取消")

    __FOLDER_PICKER_SOURCE_UI := {
        gui: g,
        dropdown: dropdown,
        items: items,
        done: false,
        result: {kind: "cancel", path: "", label: "取消"}
    }
    btnContinue.OnEvent("Click", PickerSourceAccept)
    btnCancel.OnEvent("Click", PickerSourceCancel)
    g.OnEvent("Close", PickerSourceCancel)
    g.Show("AutoSize Center")
    while !__FOLDER_PICKER_SOURCE_UI.done
        Sleep 50

    result := __FOLDER_PICKER_SOURCE_UI.result
    __FOLDER_PICKER_SOURCE_UI := ""
    return result
}

PickerPromptUnc(defaultPath := "") {
    initial := SubStr(defaultPath, 1, 2) = "\\" ? defaultPath : "\\"
    Loop 3 {
        result := InputBox(
            "請輸入共用資料夾 UNC 路徑，例如：`n\\家用電腦\Public\鳴潮錄影`n`n也可貼上 Z:\資料夾，程式會嘗試轉成 UNC。",
            "輸入網路共用路徑", "w650 h190", initial)
        if (result.Result != "OK")
            return ""
        p := PickerMappedPathToUnc(result.Value)
        if (SubStr(p, 1, 2) = "\\" && StrLen(p) > 2)
            return p
        MsgBox("這不是可用的 UNC／映射磁碟路徑：`n" result.Value,
            "網路路徑格式不正確", "Iconx")
        initial := result.Value
    }
    return ""
}

PickerBrowseShellFolder(rootSpec, prompt, fallbackStart := "") {
    try {
        shell := ComObject("Shell.Application")
        ; BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE | BIF_EDITBOX | BIF_SHAREABLE
        folder := shell.BrowseForFolder(0, prompt, 0x8051, rootSpec)
        if !IsObject(folder)
            return ""
        selected := ""
        try selected := folder.Self.Path
        return PickerNormalizePath(selected)
    } catch {
        try return PickerNormalizePath(DirSelect(fallbackStart, 3, prompt))
        catch
            return ""
    }
}

PickerWriteReply(replyPath, status, selectedPath := "", message := "",
    networkCount := 0, source := "") {
    if (replyPath = "")
        return false
    try {
        replyDir := ""
        SplitPath(replyPath, , &replyDir)
        if (replyDir != "" && !DirExist(replyDir))
            DirCreate(replyDir)
        try FileDelete(replyPath)
        IniWrite(status, replyPath, "result", "status")
        IniWrite(selectedPath, replyPath, "result", "path")
        IniWrite(message, replyPath, "result", "message")
        IniWrite(A_IsAdmin ? "1" : "0", replyPath, "result", "helper_was_admin")
        IniWrite(networkCount, replyPath, "result", "network_count")
        IniWrite(source, replyPath, "result", "source")
        return true
    } catch {
        return false
    }
}

PickerRun() {
    replyPath := PickerNormalizePath(PickerArgValue("--reply", ""))
    initialPath := PickerNormalizePath(PickerArgValue("--initial", ""))
    if (replyPath = "")
        return

    try {
        locations := PickerCollectNetworkLocations()
        choice := PickerSelectSource(initialPath, locations)
        if (choice.kind = "cancel") {
            PickerWriteReply(replyPath, "cancel", "", "", locations.Length, "cancel")
            return
        }

        selected := ""
        if (choice.kind = "unc") {
            selected := PickerPromptUnc(initialPath)
        } else if (choice.kind = "network") {
            selected := PickerBrowseShellFolder(18,
                "選擇網路電腦中的共用資料夾", "") ; CSIDL_NETWORK
            if (selected = "") {
                useUnc := MsgBox("沒有選到網路資料夾。要改為直接輸入 \\電腦\共用 嗎？",
                    "網路資料夾", "YesNo Icon?")
                if (useUnc = "Yes")
                    selected := PickerPromptUnc(initialPath)
            }
        } else if (choice.kind = "this_pc") {
            selected := PickerBrowseShellFolder(17,
                "選擇本機、映射磁碟或網路位置", "") ; CSIDL_DRIVES
        } else {
            selected := PickerBrowseShellFolder(choice.path,
                "選擇錄影輸出資料夾", choice.path)
        }

        if (selected = "") {
            PickerWriteReply(replyPath, "cancel", "", "", locations.Length, choice.label)
            return
        }
        resolved := PickerMappedPathToUnc(selected)
        PickerWriteReply(replyPath, "ok", resolved,
            "已偵測 " locations.Length " 個映射磁碟／網路位置",
            locations.Length, choice.label)
    } catch as e {
        PickerWriteReply(replyPath, "error", "", e.Message, 0, "error")
    }
}
