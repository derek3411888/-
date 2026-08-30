#Requires AutoHotkey v2.0+

; 所有由執行端產生、且應由使用者管理的檔案，都集中到程式根目錄。
; 只有 Windows 保護的憑證、Docker named volume 與使用者明確指定的外部
; 錄影目的地不受這個模組管理。
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

RuntimeFiles_EnsureProgramSubdir(relativePath) {
    clean := Trim(StrReplace(relativePath, "/", "\"), " \")
    dir := RuntimeFiles_ProgramRoot()
    if (clean != "")
        dir .= "\" clean
    if !DirExist(dir)
        DirCreate(dir)
    return dir
}

RuntimeFiles_ConfigDir() {
    ; PACK_DATA_DIR 曾有 %TEMP% 後備，導致同一台電腦可能存在兩份設定。
    ; 新版的唯一正式位置固定為 <程式根目錄>\config。
    dir := RuntimeFiles_EnsureProgramSubdir("config")
    EnvSet("PACK_DATA_DIR", dir)
    return dir
}

RuntimeFiles_LogDir(scriptName := "") {
    dir := RuntimeFiles_EnsureProgramSubdir("log")
    safeName := Trim(String(scriptName), " `t`r`n\")
    if (safeName != "") {
        safeName := RegExReplace(safeName, '[<>:"/\\|?*]', "_")
        dir .= "\" safeName
        if !DirExist(dir)
            DirCreate(dir)
    }
    return dir
}

RuntimeFiles_LogFallbackPath(scriptName) {
    safeName := RegExReplace(Trim(String(scriptName), " `t`r`n\"), '[<>:"/\\|?*]', "_")
    if (safeName = "")
        safeName := "runtime"
    return RuntimeFiles_LogDir(safeName) "\" safeName "_fallback.log"
}

RuntimeFiles_RuntimeDir(category := "") {
    dir := RuntimeFiles_EnsureProgramSubdir("執行暫存")
    safeCategory := Trim(String(category), " `t`r`n\")
    if (safeCategory != "") {
        safeCategory := RegExReplace(safeCategory, '[<>:"/\\|?*]', "_")
        dir .= "\" safeCategory
        if !DirExist(dir)
            DirCreate(dir)
    }
    return dir
}

RuntimeFiles_NewTempPath(prefix, extension := ".tmp", category := "一般") {
    safePrefix := RegExReplace(Trim(String(prefix)), "[^0-9A-Za-z_-]", "_")
    if (safePrefix = "")
        safePrefix := "runtime"
    ext := Trim(String(extension))
    if (ext = "")
        ext := ".tmp"
    if (SubStr(ext, 1, 1) != ".")
        ext := "." ext
    token := DllCall("GetCurrentProcessId") "_" A_TickCount
    return RuntimeFiles_RuntimeDir(category) "\" safePrefix "_" token ext
}

RuntimeFiles_RecordingsDir() {
    return RuntimeFiles_EnsureProgramSubdir("操作過程")
}

RuntimeFiles_RecordingStagingDir() {
    return RuntimeFiles_EnsureProgramSubdir("操作過程\錄影暫存")
}

RuntimeFiles_LegacyRecordingStagingDir() {
    localBase := Trim(EnvGet("LOCALAPPDATA"), ' "`t`r`n')
    if (localBase = "")
        return ""
    return RTrim(StrReplace(localBase, "/", "\"), "\") "\WutheringAuto\recording_staging"
}

RuntimeFiles_DiagnosticsDir() {
    expected := RuntimeFiles_ProgramRoot() "\診斷快照"
    configured := Trim(EnvGet("WUTHERING_DIAGNOSTICS_DIR"), ' "`t`r`n')
    configured := RTrim(StrReplace(configured, "/", "\"), "\")
    if (configured != "" && StrLower(configured) = StrLower(expected))
        return configured

    EnvSet("WUTHERING_DIAGNOSTICS_DIR", expected)
    return expected
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

RuntimeFiles_DeleteStaleRuntimeFiles(maxAgeHours := 24) {
    root := RuntimeFiles_RuntimeDir()
    cutoff := DateAdd(A_Now, -Max(1, Integer(maxAgeHours)), "Hours")
    deleted := 0
    Loop Files, root "\*.*", "FR" {
        if (A_LoopFileTimeModified >= cutoff)
            continue
        try {
            FileDelete(A_LoopFileFullPath)
            deleted += 1
        }
    }
    return deleted
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

RuntimeFiles_UniqueLegacyDestination(targetDir, fileName, legacyLabel := "legacy") {
    destination := targetDir "\" fileName
    if !FileExist(destination)
        return destination

    SplitPath(fileName, , , &ext, &nameNoExt)
    stamp := FormatTime(, "yyyyMMdd_HHmmss") "_" A_TickCount
    suffix := ext != "" ? "." ext : ""
    return targetDir "\" nameNoExt "_" legacyLabel "_" stamp suffix
}

RuntimeFiles_MigrateLegacyConfig(legacyDirOverride := "") {
    legacyDir := Trim(String(legacyDirOverride), ' "`t`r`n')
    if (legacyDir = "")
        legacyDir := RTrim(StrReplace(A_Temp, "/", "\"), "\") "\okww_runtime\config"
    else
        legacyDir := RTrim(StrReplace(legacyDir, "/", "\"), "\")
    targetDir := RuntimeFiles_ConfigDir()
    if !DirExist(legacyDir)
        return 0

    moved := 0
    Loop Files, legacyDir "\*", "F" {
        destination := RuntimeFiles_UniqueLegacyDestination(targetDir, A_LoopFileName, "legacy")
        if RuntimeFiles_CopyVerifiedAndRemove(A_LoopFileFullPath, destination)
            moved += 1
    }
    try DirDelete(legacyDir)
    SplitPath(legacyDir, , &legacyParent)
    if (legacyParent != "")
        try DirDelete(legacyParent)
    return moved
}

RuntimeFiles_MigrateLegacyRecordingMetadata(legacyDirOverride := "") {
    legacyDir := Trim(String(legacyDirOverride), ' "`t`r`n')
    if (legacyDir = "")
        legacyDir := RuntimeFiles_LegacyRecordingStagingDir()
    else
        legacyDir := RTrim(StrReplace(legacyDir, "/", "\"), "\")
    targetDir := RuntimeFiles_RecordingStagingDir()
    if (legacyDir = "" || !DirExist(legacyDir)
        || StrLower(legacyDir) = StrLower(targetDir))
        return {moved: 0, deferredSessions: 0}

    ; 未完成工作階段可能仍由 FFmpeg／收尾 worker 使用，不能在執行中跨磁碟
    ; 強搬。主程式會繼續掃描舊根目錄；待工作階段清空後再搬狀態與 Log。
    deferred := 0
    Loop Files, legacyDir "\wuthering_auto_recording_*", "D"
        deferred += 1
    if RuntimeFiles_IsRecordingRootInUse(legacyDir)
        deferred := Max(1, deferred)
    if (deferred > 0)
        return {moved: 0, deferredSessions: deferred}

    moved := 0
    Loop Files, legacyDir "\*", "F" {
        destination := RuntimeFiles_UniqueLegacyDestination(targetDir, A_LoopFileName, "legacy")
        if RuntimeFiles_CopyVerifiedAndRemove(A_LoopFileFullPath, destination)
            moved += 1
    }
    try DirDelete(legacyDir)
    return {moved: moved, deferredSessions: 0}
}

RuntimeFiles_IsRecordingRootInUse(rootPath) {
    needle := StrLower(RTrim(StrReplace(rootPath, "/", "\"), "\"))
    if (needle = "")
        return false
    try {
        for proc in ComObjGet("winmgmts:").ExecQuery(
            "Select Name,CommandLine from Win32_Process where Name='ffmpeg.exe' or Name like 'AutoHotkey%'") {
            commandLine := ""
            try commandLine := String(proc.CommandLine)
            if (commandLine != "" && InStr(StrLower(commandLine), needle))
                return true
        }
        return false
    } catch {
        ; 無法驗證程序使用狀態時採安全失敗：保留舊錄影資料，下一次再遷移。
        return true
    }
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
