#Requires AutoHotkey v2.0+
#SingleInstance Force

#Include TestRuntimePaths.ahk
#Include ..\payload\plugin\ImagePut-1.11\ImagePut.ahk

AssertGeneratedPathPolicy(condition, message) {
    if !condition
        throw Error(message)
}

repoRoot := TestRuntime_RepoRoot()

try {
    ; A_Temp 只可出現在舊版違留路徑的讀取/驗證邏輯，不得成為寫入位置。
    ; 只掃描本專案可管理的原始碼目錄，不遞迴 .git、npm cache
    ; 或其他大型開發產物，避免路徑政策本身卡住打包。
    sourceRoots := [repoRoot "\payload", repoRoot "\測試",
        repoRoot "\文字識別", repoRoot "\郵件測試"]
    sourceFiles := [repoRoot "\打包啟動器.ahk"]
    for sourceRoot in sourceRoots {
        if !DirExist(sourceRoot)
            continue
        Loop Files, sourceRoot "\*.ahk", "FR"
            sourceFiles.Push(A_LoopFileFullPath)
    }
    for path in sourceFiles {
        relative := SubStr(path, StrLen(repoRoot) + 2)
        if (relative = "測試\AhkGeneratedPathPolicyTest.ahk")
            continue
        lineNo := 0
        Loop Read, path {
            lineNo += 1
            if RegExMatch(A_LoopReadLine, 'i)EnvGet\("(?:TEMP|TMP)"\)')
                throw Error("禁止從 Windows Temp 建立開發產物: " relative ":" lineNo)
            if RegExMatch(A_LoopReadLine, 'i)[A-Z]:\\Users\\[^\\]+\\AppData\\')
                throw Error("禁止硬編碼 AppData 開發路徑: " relative ":" lineNo)
            if (RegExMatch(A_LoopReadLine,
                    "i)\b(?:FileAppend|FileCopy|FileMove|IniWrite|DirCreate|ImagePutFile|Download)\b")
                && RegExMatch(A_LoopReadLine, "i)[`"'](?:[A-Z]:\\|\\\\)"))
                throw Error("禁止將開發產物寫入硬編碼的外部磁碟: " relative ":" lineNo)
            if !InStr(A_LoopReadLine, "A_Temp")
                continue
            allowedLegacyRead := (relative = "payload\RuntimeFilePaths.ahk"
                    && InStr(A_LoopReadLine, "legacyDir :="))
                || (relative = "payload\全自動.ahk"
                    && InStr(A_LoopReadLine, "tempRoot :="))
            AssertGeneratedPathPolicy(allowedLegacyRead,
                "禁止的 A_Temp 參考: " relative ":" lineNo)
        }
    }

    imagePutPath := repoRoot "\payload\plugin\ImagePut-1.11\ImagePut.ahk"
    imagePutText := FileRead(imagePutPath, "UTF-8")
    AssertGeneratedPathPolicy(!InStr(imagePutText, 'filepath := A_Temp'),
        "ImagePut 仍把 clipboard 檔案寫到 Windows Temp")
    expectedImagePutRoot := repoRoot "\.dev-runtime\runtime\執行暫存\ImagePut"
    TestRuntime_AssertNoReparsePoints(expectedImagePutRoot)
    imagePutDir := ImagePutRuntimeTempDir()
    TestRuntime_AssertNoReparsePoints(imagePutDir)
    AssertGeneratedPathPolicy(
        StrLower(TestRuntime_CanonicalPath(imagePutDir))
            = StrLower(TestRuntime_CanonicalPath(expectedImagePutRoot)),
        "ImagePut 開發暫存位置錯誤: " imagePutDir)

    runtimeText := FileRead(repoRoot "\payload\RuntimeFilePaths.ahk", "UTF-8")
    AssertGeneratedPathPolicy(InStr(runtimeText, 'return repoRoot "\.dev-runtime\runtime"'),
        "Payload 原始碼執行未導向 .dev-runtime")
    launcherText := FileRead(repoRoot "\打包啟動器.ahk", "UTF-8")
    AssertGeneratedPathPolicy(InStr(launcherText, 'return dir "\.dev-runtime\launcher-app"'),
        "Launcher 原始碼執行未導向 .dev-runtime")
    AssertGeneratedPathPolicy(InStr(launcherText, '"--resume-current-task"'),
        "Launcher 缺少中斷任務接續旗標")
    AssertGeneratedPathPolicy(InStr(launcherText, 'payloadArgs := LauncherHasArg'),
        "Launcher 未將接續旗標轉成 Payload restart resume")

    requiredTestRuntimeUsers := [
        "測試\RuntimeFilePaths測試.ahk",
        "測試\SelfHostCredentialReuseTest.ahk",
        "測試\SelfHostFreshDeviceDefaultTest.ahk",
        "測試\SupportLogContextTest.ahk",
        "測試\OCR模型冒煙測試.ahk",
        "測試\伺服器登入標籤OCR影像測試.ahk",
        "測試\實機伺服器切換壓力測試.ahk",
        "測試\錄影收尾狀態測試.ahk",
        "測試\主畫面模板比對\主畫面模板比對測試.ahk",
        "文字識別\文字識別測試.ahk",
        "郵件測試\寄送信件測試.ahk"
    ]
    for relative in requiredTestRuntimeUsers {
        content := FileRead(repoRoot "\" relative, "UTF-8")
        AssertGeneratedPathPolicy(InStr(content, "#Include")
                && RegExMatch(content,
                    "i)TestRuntime_(?:EnsureDir|NewCaseDir|NewFile|ResolveOutput(?:Path|Dir))\s*\("),
            "開發測試未使用 .dev-runtime: " relative)
    }

    FileAppend("ahk-generated-path-policy=ok`n", "*")
} catch as e {
    FileAppend("ahk-generated-path-policy=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)
