$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$root = Split-Path $PSScriptRoot -Parent
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $root -RunName 'gm-local-ui'
try {
    $source = [IO.File]::ReadAllText((Join-Path $root 'payload\全自動.ahk'))
    $panel = [regex]::Match($source, '(?s)    tabs\.UseTab\(5\).*?(?=    tabs\.UseTab\(\))').Value
    if (-not $panel) { throw 'Missing real maintenance settings panel' }
    $testPath = Join-Path $context.RunRoot 'local-ui.ahk'
    $script = @"
#Requires AutoHotkey v2.0
#Include $root\測試\GameMaintenanceFixtures.ahk
GMTest_Run(TestLocalPanel)
TestLocalPanel() {
    g := Gui("+Resize"), state := {maintenanceEnabled:true}
    g.SetFont("s9","Microsoft JhengHei UI")
    tabs := g.AddTab3("x10 y10 w1040 h400",["1","2","3","4","版本維護"])
$panel
    tabs.UseTab()
    save := g.AddButton("x10 y430 w180 h34","儲存全部並繼續")
    tabs.Value := 5
    g.Show("Hide w1060 h500")
    try {
        btnMaintenanceProbe.GetPos(&px,&py,&pw,&ph)
        save.GetPos(&sx,&sy,&sw,&sh)
        GMTest_Assert(px >= 10 && px + pw < 1060,"maintenance probe within smallest logical width")
        GMTest_Assert(py + ph < sy,"maintenance controls do not overlap fixed save footer")
        GMTest_Assert(cbMaintenanceEnabled.Value = 1,"actual maintenance checkbox uses test config")
        GMTest_Assert(txtMaintenanceProvider.Text != "","actual source status has readable initial explanation")
    } finally g.Destroy()
}
"@
    [IO.File]::WriteAllText($testPath,$script,[Text.UTF8Encoding]::new($true))
    $result = Invoke-GMTestProcess $testPath $context 10
    if ($result.Stdout) { Write-Output $result.Stdout }
    if ($result.Stderr) { Write-Output $result.Stderr }
    Assert-GMEqual $result.ExitCode 0 'Hidden actual AHK maintenance settings panel geometry'
} finally { Complete-ProjectDevelopmentPaths -Context $context }
