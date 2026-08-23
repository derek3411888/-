#Requires AutoHotkey v2.0+

; 所有執行期間產生的圖片集中到程式根目錄，避免散落在 payload、
; %TEMP% 或 %LOCALAPPDATA%，也避免 payload 更新時一併刪除診斷證據。
RuntimeFiles_ProgramRoot() {
    root := Trim(EnvGet("PACK_APP_DIR"), ' "`t`r`n')
    if (root = "")
        root := A_ScriptDir

    root := StrReplace(root, "/", "\")
    root := RTrim(root, "\")
    if RegExMatch(root, "i)\\payload$")
        root := RegExReplace(root, "i)\\payload$", "")

    buf := Buffer(32768 * 2, 0)
    len := DllCall("Kernel32\GetFullPathNameW", "str", root, "uint", 32768,
        "ptr", buf, "ptr", 0, "uint")
    if (len > 0 && len < 32768)
        return RTrim(StrGet(buf, len, "UTF-16"), "\")
    return root
}

RuntimeFiles_DiagnosticsDir() {
    configured := Trim(EnvGet("WUTHERING_DIAGNOSTICS_DIR"), ' "`t`r`n')
    if (configured != "")
        return RTrim(StrReplace(configured, "/", "\"), "\")

    dir := RuntimeFiles_ProgramRoot() "\診斷快照"
    EnvSet("WUTHERING_DIAGNOSTICS_DIR", dir)
    return dir
}

RuntimeFiles_EnsureDir(subdir := "") {
    dir := RuntimeFiles_DiagnosticsDir()
    cleanSubdir := Trim(StrReplace(subdir, "/", "\"), " \")
    if (cleanSubdir != "")
        dir .= "\" cleanSubdir
    if !DirExist(dir)
        DirCreate(dir)
    return dir
}

RuntimeFiles_NewImagePath(prefix, extension := ".png", subdir := "暫存") {
    safePrefix := RegExReplace(Trim(prefix), "[^0-9A-Za-z_-]", "_")
    if (safePrefix = "")
        safePrefix := "image"
    ext := Trim(extension)
    if (ext = "")
        ext := ".png"
    if (SubStr(ext, 1, 1) != ".")
        ext := "." ext
    token := DllCall("GetCurrentProcessId") "_" A_TickCount
    return RuntimeFiles_EnsureDir(subdir) "\" safePrefix "_" token ext
}

RuntimeFiles_PruneDiagnosticImages(keepCount := 30) {
    keep := Max(1, Integer(keepCount))
    dir := RuntimeFiles_EnsureDir()
    files := []
    for pattern in ["error_*.jpg", "error_*.jpeg", "error_*.png"] {
        Loop Files, dir "\" pattern, "F"
            files.Push({path: A_LoopFileFullPath, modified: A_LoopFileTimeModified})
    }

    i := 1
    while (i < files.Length) {
        j := i + 1
        while (j <= files.Length) {
            if (files[i].modified < files[j].modified) {
                tmp := files[i]
                files[i] := files[j]
                files[j] := tmp
            }
            j += 1
        }
        i += 1
    }
    deleted := 0
    while (files.Length > keep) {
        item := files.Pop()
        try {
            FileDelete(item.path)
            deleted += 1
        }
    }
    return deleted
}

RuntimeFiles_DeleteStaleTempImages(maxAgeHours := 24) {
    dir := RuntimeFiles_EnsureDir("暫存")
    cutoff := DateAdd(A_Now, -Max(1, Integer(maxAgeHours)), "Hours")
    deleted := 0
    Loop Files, dir "\*.*", "F" {
        if (A_LoopFileTimeModified >= cutoff)
            continue
        try {
            FileDelete(A_LoopFileFullPath)
            deleted += 1
        }
    }
    return deleted
}

RuntimeFiles_CopyVerifiedAndRemove(source, destination) {
    try {
        sourceSize := FileGetSize(source)
        SplitPath(destination, , &parentDir)
        if !DirExist(parentDir)
            DirCreate(parentDir)
        FileCopy(source, destination, 1)
        if (!FileExist(destination) || FileGetSize(destination) != sourceSize)
            return false
        FileDelete(source)
        return true
    }
    return false
}

RuntimeFiles_MigrateLegacyDiagnosticImages() {
    localBase := Trim(EnvGet("LOCALAPPDATA"), ' "`t`r`n')
    if (localBase = "")
        return 0

    legacyDir := RTrim(StrReplace(localBase, "/", "\"), "\") "\WutheringAuto\diagnostics"
    targetDir := RuntimeFiles_EnsureDir()
    if !DirExist(legacyDir)
        return 0

    moved := 0
    for pattern in ["latest.jpg", "error_*.jpg", "error_*.jpeg", "error_*.png"] {
        Loop Files, legacyDir "\" pattern, "F" {
            destination := targetDir "\" A_LoopFileName
            if FileExist(destination) {
                SplitPath(A_LoopFileName, , , &ext, &nameNoExt)
                destination := targetDir "\" nameNoExt "_legacy_" A_LoopFileTimeModified "." ext
            }
            ; 舊資料通常在 C:，程式可能在 D:/E:；以驗證過的複製取代跨磁碟移動。
            if RuntimeFiles_CopyVerifiedAndRemove(A_LoopFileFullPath, destination)
                moved += 1
        }
    }
    return moved
}

RuntimeFiles_MigrateLegacyPayloadImages() {
    payloadDir := RTrim(StrReplace(A_ScriptDir, "/", "\"), "\")
    targetDir := RuntimeFiles_EnsureDir()
    tempDir := RuntimeFiles_EnsureDir("暫存")
    moved := 0

    Loop Files, payloadDir "\debug_lrmc_ocr_nomatch_*.png", "F" {
        destination := targetDir "\error_legacy_" A_LoopFileName
        if RuntimeFiles_CopyVerifiedAndRemove(A_LoopFileFullPath, destination)
            moved += 1
    }

    for pattern in ["temp.png", "temp_lrmc_*.png", "temp_synthesis_*.png", "ue4crash_*.png", "temp_update_*.png"] {
        Loop Files, payloadDir "\" pattern, "F" {
            destination := tempDir "\legacy_" A_LoopFileName
            if RuntimeFiles_CopyVerifiedAndRemove(A_LoopFileFullPath, destination)
                moved += 1
        }
    }
    return moved
}
