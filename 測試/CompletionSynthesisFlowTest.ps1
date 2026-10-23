[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$run = Join-Path $root '.dev-runtime\diagnostics\game-maintenance\20261023-restart-synthesis'
[void][IO.Directory]::CreateDirectory($run)
$source = [IO.File]::ReadAllText((Join-Path $root 'payload\聲骸合成.ahk'))
$match = [regex]::Match($source, '(?s)\r?\nRunSynthesisLoop\(\) \{.*?(?=\r?\n; ==================== 各步驟函數)')
if (-not $match.Success) { throw 'Cannot isolate actual production synthesis flow' }
$harness = @'
#Requires AutoHotkey v2.0
global logger := FakeLogger(), firstTime := false, failedStep := "", mergeCount := 0
try {
    for step in ["ClickBatchMerge", "ClickBottomStandardMerge", "ClickStep5Icon", "SelectDiscardedAndConfirm", "ClickSelectAll", "ClickMergeBatchButton", "ReturnToStep4"] {
        failedStep := step, mergeCount := 1
        if RunSynthesisLoop()
            throw Error("inner flow failure reported success: " step)
    }
    failedStep := "", mergeCount := -1
    if RunSynthesisLoop()
        throw Error("unknown OCR merge count reported success")
    mergeCount := 0
    if !RunSynthesisLoop()
        throw Error("verified exhausted-material path must succeed")
    FileAppend("PASS: actual synthesis flow rejects seven failed steps and unknown OCR; valid zero succeeds`n", "*")
    ExitApp(0)
} catch as err {
    FileAppend("FAIL: " err.Message "`n", "**")
    ExitApp(1)
}
class FakeLogger {
    log(args*) {
    }
}
WriteStep(args*) {
}
Sleep(ms) {
}
ShowTip(args*) {
}
HandleMonthlyCardRewardIfPresent() => true
OpenMainMenu() => true
ClickDataWarehouse() => true
ClickStep3Icon() => true
VerifyBackpackPanel() => true
ClickBatchMerge() => Allowed("ClickBatchMerge")
ClickBottomStandardMerge() => Allowed("ClickBottomStandardMerge")
ClickStep5Icon() => Allowed("ClickStep5Icon")
SelectDiscardedAndConfirm() => Allowed("SelectDiscardedAndConfirm")
ClickSelectAll() => Allowed("ClickSelectAll")
ClickMergeBatchButton() => Allowed("ClickMergeBatchButton")
ReturnToStep4() => Allowed("ReturnToStep4")
HandleFirstTimePrompt() => true
CheckMergeCount() {
    global mergeCount
    return mergeCount
}
Allowed(step) {
    global failedStep
    return failedStep != step
}
ClickRelative(args*) => true
ActivateGame() => true
SynthesisSendEsc() => true
SynthesisVerifyFinishedMenu() => true
Send(args*) {
}
'@
$path = Join-Path $run 'SynthesisFlowHarness.ahk'
[IO.File]::WriteAllText($path, $harness + "`r`n" + $match.Value, [Text.UTF8Encoding]::new($true))
& (Join-Path $root 'AutoHotkey64.exe') /ErrorStdOut=UTF-8 $path 2>&1 | ForEach-Object { $_ }
if ($LASTEXITCODE -ne 0) { throw 'Actual synthesis flow failed safety assertions' }
