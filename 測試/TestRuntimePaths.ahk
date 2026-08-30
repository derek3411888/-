#Requires AutoHotkey v2.0+

; 開發與測試產物只能寫到 repo\.dev-runtime。這個模組不依賴
; Windows Temp/AppData，也不接受專案外的輸出路徑。
TestRuntime_CanonicalPath(path) {
    path := RTrim(StrReplace(Trim(String(path), ' "`t`r`n'), "/", "\"), "\")
    if (path = "")
        return ""
    pathBuf := Buffer(32768 * 2, 0)
    length := DllCall("Kernel32\GetFullPathNameW", "str", path, "uint", 32768,
        "ptr", pathBuf, "ptr", 0, "uint")
    if (length > 0 && length < 32768)
        return RTrim(StrGet(pathBuf, length, "UTF-16"), "\")
    return path
}

TestRuntime_RepoRoot() {
    static cached := ""
    if (cached != "")
        return cached
    current := TestRuntime_CanonicalPath(A_ScriptDir)
    parent := ""
    Loop 10 {
        if ((DirExist(current "\.git") || FileExist(current "\.git"))
            && FileExist(current "\payload\RuntimeFilePaths.ahk")
            && FileExist(current "\打包更新.ps1")) {
            cached := current
            return cached
        }
        SplitPath(current, , &parent)
        if (parent = "" || StrLower(parent) = StrLower(current))
            break
        current := parent
    }
    throw Error("找不到專案根目錄，拒絕在專案外建立測試檔案")
}

TestRuntime_IsWithinRepo(path) {
    repo := StrLower(TestRuntime_CanonicalPath(TestRuntime_RepoRoot()))
    candidate := StrLower(TestRuntime_CanonicalPath(path))
    return candidate = repo || InStr(candidate, repo "\") = 1
}

TestRuntime_DevelopmentRoot() {
    return TestRuntime_RepoRoot() "\.dev-runtime"
}

TestRuntime_IsWithinDevelopmentRoot(path) {
    root := StrLower(TestRuntime_CanonicalPath(TestRuntime_DevelopmentRoot()))
    candidate := StrLower(TestRuntime_CanonicalPath(path))
    return candidate = root || InStr(candidate, root "\") = 1
}

TestRuntime_AssertNoReparsePoints(path) {
    root := TestRuntime_CanonicalPath(TestRuntime_DevelopmentRoot())
    candidate := TestRuntime_CanonicalPath(path)
    rootLower := StrLower(root)
    candidateLower := StrLower(candidate)
    if (candidateLower != rootLower && InStr(candidateLower, rootLower "\") != 1)
        throw Error("測試路徑不在 .dev-runtime 內: " candidate)

    relative := candidateLower = rootLower ? "" : SubStr(candidate, StrLen(root) + 2)
    current := root
    parts := relative = "" ? [] : StrSplit(relative, "\")
    ; 拒絕 .dev-runtime 與通往目標的任何現存 junction/symlink，
    ; 避免字串前綴檢查通過、實際卻寫到 repo 外。
    candidates := [root]
    for part in parts {
        current .= "\" part
        candidates.Push(current)
    }
    for existingPath in candidates {
        if (!DirExist(existingPath) && !FileExist(existingPath))
            continue
        attributes := ""
        try attributes := FileGetAttrib(existingPath)
        catch as e
            throw Error("無法驗證測試路徑屬性: " existingPath " | " e.Message)
        if InStr(attributes, "L")
            throw Error("測試路徑不得經過 junction/symlink: " existingPath)
    }
}

TestRuntime_EnsureDir(category := "一般") {
    safeCategory := RegExReplace(Trim(String(category)), '[<>:"/\\|?*]', "_")
    if (safeCategory = "")
        safeCategory := "一般"
    testsRoot := TestRuntime_CanonicalPath(TestRuntime_DevelopmentRoot() "\tests")
    dir := TestRuntime_CanonicalPath(testsRoot "\" safeCategory)
    if (InStr(StrLower(dir), StrLower(testsRoot) "\") != 1)
        throw Error("測試類別不得離開 .dev-runtime\tests: " safeCategory)
    TestRuntime_AssertNoReparsePoints(dir)
    if !DirExist(dir)
        DirCreate(dir)
    TestRuntime_AssertNoReparsePoints(dir)
    return dir
}

TestRuntime_NewCaseDir(category := "一般", prefix := "case") {
    safePrefix := RegExReplace(Trim(String(prefix)), "[^0-9A-Za-z_-]", "_")
    if (safePrefix = "")
        safePrefix := "case"
    dir := TestRuntime_EnsureDir(category) "\" safePrefix "_"
        . DllCall("GetCurrentProcessId") "_" A_TickCount
    if !TestRuntime_IsWithinDevelopmentRoot(dir)
        throw Error("測試 case 目錄不在 .dev-runtime 內: " dir)
    TestRuntime_AssertNoReparsePoints(dir)
    if !DirExist(dir)
        DirCreate(dir)
    TestRuntime_AssertNoReparsePoints(dir)
    return dir
}

TestRuntime_NewFile(category, prefix, extension := ".tmp") {
    extName := RegExReplace(Trim(String(extension)), "^\.+", "")
    extName := RegExReplace(extName, "[^0-9A-Za-z_-]", "_")
    if (extName = "")
        extName := "tmp"
    ext := "." SubStr(extName, 1, 32)
    safePrefix := RegExReplace(Trim(String(prefix)), "[^0-9A-Za-z_-]", "_")
    if (safePrefix = "")
        safePrefix := "test"
    result := TestRuntime_CanonicalPath(TestRuntime_EnsureDir(category) "\" safePrefix "_"
        . DllCall("GetCurrentProcessId") "_" A_TickCount ext)
    if !TestRuntime_IsWithinDevelopmentRoot(result)
        throw Error("測試檔案路徑不在 .dev-runtime 內: " result)
    parent := ""
    SplitPath(result, , &parent)
    TestRuntime_AssertNoReparsePoints(parent)
    return result
}

TestRuntime_ResolveOutputPath(requestedPath, category, defaultName) {
    requested := Trim(String(requestedPath), ' "`t`r`n')
    if (requested = "")
        requested := TestRuntime_EnsureDir(category) "\" defaultName
    resolved := TestRuntime_CanonicalPath(requested)
    if !TestRuntime_IsWithinDevelopmentRoot(resolved)
        throw Error("測試輸出路徑不在 .dev-runtime 內: " resolved)
    TestRuntime_AssertNoReparsePoints(resolved)
    parent := ""
    SplitPath(resolved, , &parent)
    TestRuntime_AssertNoReparsePoints(parent)
    if !DirExist(parent)
        DirCreate(parent)
    TestRuntime_AssertNoReparsePoints(parent)
    TestRuntime_AssertNoReparsePoints(resolved)
    return resolved
}

TestRuntime_ResolveOutputDir(requestedPath, category) {
    requested := Trim(String(requestedPath), ' "`t`r`n')
    resolved := requested = "" ? TestRuntime_NewCaseDir(category) : TestRuntime_CanonicalPath(requested)
    if !TestRuntime_IsWithinDevelopmentRoot(resolved)
        throw Error("測試輸出目錄不在 .dev-runtime 內: " resolved)
    TestRuntime_AssertNoReparsePoints(resolved)
    if !DirExist(resolved)
        DirCreate(resolved)
    TestRuntime_AssertNoReparsePoints(resolved)
    return resolved
}

TestRuntime_DeleteCaseDir(path) {
    resolved := TestRuntime_CanonicalPath(path)
    testsRoot := TestRuntime_CanonicalPath(TestRuntime_DevelopmentRoot() "\tests")
    ; 只允許刪除 .dev-runtime\tests 的子目錄，不可刪 tests 本身。
    if (!TestRuntime_IsWithinDevelopmentRoot(resolved)
        || InStr(StrLower(resolved), StrLower(testsRoot) "\") != 1)
        throw Error("拒絕刪除非 .dev-runtime 測試目錄: " resolved)
    TestRuntime_AssertNoReparsePoints(resolved)
    if DirExist(resolved)
        DirDelete(resolved, true)
}
