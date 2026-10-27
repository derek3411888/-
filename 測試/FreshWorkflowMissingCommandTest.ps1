$ErrorActionPreference='Stop'
# Reproduce MYDESKPC's elevated WMI response with real harmless processes,
# real native image/creation queries, actual launcher admission and mutexes.
foreach($mode in @('current','legacy')) {
    & (Join-Path $PSScriptRoot 'FreshLauncherTakeoverTest.ps1') -Mode $mode -MissingWorkflowImage -MissingWorkflowCommand
    if(!$?) { throw "Native commandless fresh takeover failed: $mode" }
}
& (Join-Path $PSScriptRoot 'FreshLauncherTakeoverTest.ps1') -MissingWorkflowCommand -StaleWorkflowCreation
if(!$?) { throw 'Stale native creation guard failed' }
Write-Output 'PASS commandless native cleanup and stale native identity rejection; shared runtime cases are covered by FreshWorkflowInventoryTest'
