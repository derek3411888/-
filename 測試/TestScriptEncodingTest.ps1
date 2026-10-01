[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot (Split-Path $PSScriptRoot -Parent) -RunName 'test-script-encoding'
try {
    # ParseFile uses Windows PowerShell's actual file-decoding rules. ParseInput
    # receives explicitly decoded UTF-8 as the independent reference. Neither
    # path executes the inspected scripts or changes execution policy.
    $probe = @'
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$failures = @()
$files = @(Get-ChildItem -LiteralPath '__TEST_ROOT__' -Filter '*.ps1' -File)
foreach ($file in $files) {
    $referenceTokens = $null; $referenceErrors = $null
    $fileTokens = $null; $fileErrors = $null
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $source = [IO.File]::ReadAllText($file.FullName, $utf8)
    [void][Management.Automation.Language.Parser]::ParseInput($source, [ref]$referenceTokens, [ref]$referenceErrors)
    [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$fileTokens, [ref]$fileErrors)
    $reference = @($referenceTokens | ForEach-Object { $_.Kind.ToString() + ':' + $_.Text }) -join [char]0
    $actual = @($fileTokens | ForEach-Object { $_.Kind.ToString() + ':' + $_.Text }) -join [char]0
    if ($reference -cne $actual) { $failures += ($file.Name + ': file decoding changes tokens/fixtures') }
    if (@($referenceErrors).Count -or @($fileErrors).Count) { $failures += ($file.Name + ': Windows PowerShell parse errors') }
}
[pscustomobject]@{ version=$PSVersionTable.PSVersion.ToString(); codePage=[Text.Encoding]::Default.CodePage;
    files=$files.Count; failures=@($failures) } | ConvertTo-Json -Compress
'@
    $probe = $probe.Replace('__TEST_ROOT__', $PSScriptRoot.Replace("'", "''"))
    $stdout = Join-Path $context.RunRoot 'parser.stdout.json'
    $stderr = Join-Path $context.RunRoot 'parser.stderr.log'
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $windowsPowerShell)) { throw 'Windows PowerShell parser is required for encoding regression' }
    # The fixed probe contains single quotes only; no encoded commands or policy overrides.
    if ($probe.Contains('"')) { throw 'Unexpected command quote in read-only parser probe' }
    $process = Start-Process -FilePath $windowsPowerShell -ArgumentList ('-NoProfile -NonInteractive -Command "' + $probe + '"') `
        -WorkingDirectory $context.ProjectRoot -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    try {
        [void]$process.Handle
        if (-not $process.WaitForExit(30000)) {
            $process.Kill() # Exact retained process object: only this read-only parser probe.
            [void]$process.WaitForExit(5000)
            throw 'Read-only Windows PowerShell parser probe timed out'
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw ('Parser probe failed: ' + (Read-GMTestOutput $stderr)) }
    } finally { $process.Dispose() }
    $result = (Read-GMTestOutput $stdout) | ConvertFrom-Json
    $failures = @($result.failures)
    # Prevent recurrence even on hosts whose ANSI code page happens to be UTF-8.
    foreach ($file in (Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File)) {
        $bytes = [IO.File]::ReadAllBytes($file.FullName)
        [void]([Text.UTF8Encoding]::new($false, $true).GetString($bytes))
        $nonAscii = $false
        foreach ($value in $bytes) { if ($value -gt 127) { $nonAscii = $true; break } }
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191
        if ($nonAscii -and -not $hasBom) { $failures += ($file.Name + ': non-ASCII PowerShell requires UTF-8 BOM') }
    }
    if ($failures.Count) { throw ($failures -join "`n") }
    Write-Output ('PASS: ' + $result.files + ' PowerShell test files preserve tokens/fixtures in Windows PowerShell ' +
        $result.version + ' (ANSI ' + $result.codePage + '); UTF-8 BOM storage contract')
} finally { Complete-ProjectDevelopmentPaths -Context $context }
