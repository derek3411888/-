#Requires AutoHotkey v2.0+
#SingleInstance Force

#Include ..\LauncherProcessCleanupPolicy.ahk

AssertLauncherCleanup(condition, message) {
    if !condition
        throw Error(message)
}

AhkWorkerCommand(scriptPath, extraArgs := "") {
    command := '"E:\Downloads\自動鋤地\AutoHotkey64.exe" "' scriptPath '"'
    if (extraArgs != "")
        command .= " " extraArgs
    return command
}

try {
    appDir := "E:\Downloads\自動鋤地\payload"
    finalizePath := appDir "\RecordingFinalizeWorker.ahk"

    decision := LauncherCleanup_ProcessDecision("AutoHotkey64.exe",
        AhkWorkerCommand(finalizePath,
            '--mode finalize --session "E:\Downloads\自動鋤地\操作過程\錄影暫存\session_1"'),
        appDir)
    AssertLauncherCleanup(!decision.stop && decision.role = "recording-worker-finalize",
        "正式 finalize worker 不得被 payload 更新器終止")

    decision := LauncherCleanup_ProcessDecision("AutoHotkey64.exe",
        AhkWorkerCommand(finalizePath,
            '--mode sync --session "E:\Downloads\自動鋤地\操作過程\錄影暫存\session_1"'),
        appDir)
    AssertLauncherCleanup(!decision.stop && decision.role = "recording-worker-sync",
        "正式 sync worker 不得被 payload 更新器終止")

    decision := LauncherCleanup_ProcessDecision("AutoHotkey64.exe",
        AhkWorkerCommand(finalizePath, "--mode finalize --mode sync"), appDir)
    AssertLauncherCleanup(!decision.stop && decision.role = "recording-worker-unknown",
        "參數異常的錄影 worker 也必須 fail-safe 保留")

    ; Launcher 只處理 AutoHotkey parent；SelfHostMediaUpload PowerShell child 即使
    ; 命令列同時含 payload、RecordingFinalizeWorker session，也不得被判為可殺。
    uploadChild := '"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"'
        . ' -File "' appDir '\SelfHostMediaUpload.ps1" -Mode finalize'
        . ' -SessionDir "E:\recording\RecordingFinalizeWorker\payload-session"'
    decision := LauncherCleanup_ProcessDecision("powershell.exe", uploadChild, appDir)
    AssertLauncherCleanup(!decision.stop && decision.role = "non-ahk",
        "錄影 worker 的 PowerShell child 不得被終止")

    for scriptName in ["全自動.ahk", "進程管理器.ahk", "開啟LRMC.ahk",
        "自動開啟OKWW.ahk", "聲骸合成.ahk"] {
        decision := LauncherCleanup_ProcessDecision("AutoHotkey64.exe",
            AhkWorkerCommand(appDir "\" scriptName), appDir)
        AssertLauncherCleanup(decision.stop,
            "精確位於目前 payload 的受管腳本應可清理: " scriptName)
    }

    decision := LauncherCleanup_ProcessDecision("AutoHotkey64.exe",
        AhkWorkerCommand(appDir "\未知工具.ahk",
            '"E:\other\payload" "全自動" "LRMC"'), appDir)
    AssertLauncherCleanup(!decision.stop && decision.role = "unknown-ahk",
        "命令列含 payload／全自動／LRMC 字樣的未知腳本不得被誤殺")

    decision := LauncherCleanup_ProcessDecision("AutoHotkey64.exe",
        AhkWorkerCommand("E:\Downloads\自動鋤地\payload-old\全自動.ahk"), appDir)
    AssertLauncherCleanup(!decision.stop,
        "相似路徑 payload-old 不是目前 APP_DIR，不得以前綴誤殺")

    decision := LauncherCleanup_ProcessDecision("AutoHotkey64.exe",
        '"E:\tools\AutoHotkey64.exe" "E:\tools\payload helper\LRMC測試.ahk"'
            . ' --data "' appDir '"', appDir)
    AssertLauncherCleanup(!decision.stop,
        "外部 AHK 即使命令列含 payload 與 LRMC 也不得被誤殺")

    decision := LauncherCleanup_ProcessDecision("AutoHotkey64.exe", "", appDir)
    AssertLauncherCleanup(!decision.stop && decision.role = "unparseable",
        "讀不到命令列時必須 fail-safe 保留")

    repoRoot := A_ScriptDir "\.."
    launcherSource := FileRead(repoRoot "\打包啟動器.ahk", "UTF-8")
    mainSource := FileRead(repoRoot "\payload\全自動.ahk", "UTF-8")
    workerSource := FileRead(repoRoot "\payload\RecordingFinalizeWorker.ahk", "UTF-8")
    AssertLauncherCleanup(InStr(launcherSource,
        "LauncherCleanup_ProcessDecision(process.Name, cmdLine, APP_DIR)"),
        "Launcher 未使用精確 cleanup policy")
    AssertLauncherCleanup(!InStr(launcherSource, 'InStr(cmdLine, "payload")'),
        "Launcher 不得恢復以 payload 子字串全殺")
    AssertLauncherCleanup(!InStr(StrLower(launcherSource), 'runwait("taskkill'),
        "Launcher 不得用 taskkill 依映像名稱或 /T 終止 parent/child")
    AssertLauncherCleanup(InStr(mainSource, 'Run(cmd, sessionDir, "Hide", &workerPid)'),
        "錄影 worker 工作目錄必須離開 payload")
    AssertLauncherCleanup(InStr(workerSource, 'RunWait(cmd, sessionDir, "Hide")'),
        "錄影上傳 child 工作目錄必須離開 payload")

    FileAppend("launcher-process-cleanup-policy=ok`n", "*")
} catch as e {
    FileAppend("launcher-process-cleanup-policy=failed: " e.Message "`n", "**")
    ExitApp(1)
}

ExitApp(0)
