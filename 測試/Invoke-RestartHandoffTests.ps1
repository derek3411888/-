[CmdletBinding()]
param([string]$Scenario = '')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $projectRoot 'ProjectDevelopmentPaths.ps1')
$context = Initialize-ProjectDevelopmentPaths -ProjectRoot $projectRoot -RunName 'restart-handoff-tests'
$runtime = Join-Path $projectRoot 'AutoHotkey64.exe'
$passed = 0
try {
    # Use unchanged handoff/worker code in a contained fixture installation.
    # Only the process-inventory boundary is namespaced to this test's files.
    # Unreadable unrelated elevated AHK processes must block the real product,
    # but must not determine the outcome of synthetic protocol tests.
    $harnessRoot = Join-Path $context.RunRoot 'harness'
    $harnessPayload = Join-Path $harnessRoot 'payload'
    $harnessTests = Join-Path $harnessRoot '測試'
    $harnessFixtures = Join-Path $harnessTests 'fixtures'
    foreach ($dir in @($harnessPayload,$harnessFixtures)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    foreach ($file in @('ScriptRestartHandoff.ahk','ScriptRestartWorker.ahk')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot ('payload\'+$file)) -Destination (Join-Path $harnessPayload $file)
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ScriptRestartHandoffTest.ahk') -Destination $harnessTests
    $mainSource=Get-Content -LiteralPath (Join-Path $projectRoot 'payload\全自動.ahk') -Raw -Encoding UTF8
    $mainDirective=[regex]::Match($mainSource,'(?m)^#SingleInstance[^\r\n]*').Value
    $mainGate=[regex]::Match($mainSource,'(?s); BEGIN MAIN INSTANCE OWNERSHIP.*?; END MAIN INSTANCE OWNERSHIP').Value
    if($mainDirective -ne '#SingleInstance Off' -or !$mainGate){throw 'Production main ownership prologue is missing'}
    $mainGate=$mainGate.Replace('#Include InstallStartupLock.ahk','#Include ..\..\payload\InstallStartupLock.ahk')
    $successorSource=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\RestartHandoffFixture.ahk') -Raw -Encoding UTF8
    $successorSource=$successorSource.Replace('#SingleInstance Off',$mainDirective+"`n"+$mainGate)
    [IO.File]::WriteAllText((Join-Path $harnessFixtures 'RestartHandoffFixture.ahk'),$successorSource,[Text.UTF8Encoding]::new($false))
    $inventorySource = Get-Content -LiteralPath (Join-Path $projectRoot 'payload\InstallStartupLock.ahk') -Raw -Encoding UTF8
    $fixtureInventory = @'
InstallStartupLock_QueryProcesses() {
    ownedRecords := []
    for record in ComObjGet("winmgmts:").ExecQuery("Select ProcessId, CommandLine from Win32_Process where Name like '%AutoHotkey%'") {
        if record.CommandLine && InStr(record.CommandLine, "__HARNESS_ROOT__")
            ownedRecords.Push(record)
    }
    return ownedRecords
}
'@
    $inventorySource = [regex]::Replace($inventorySource,'(?ms)^InstallStartupLock_QueryProcesses\(\) \{.*?^\}',
        [Text.RegularExpressions.MatchEvaluator]{ param($match) $fixtureInventory.Replace('__HARNESS_ROOT__',$harnessRoot) })
    [IO.File]::WriteAllText((Join-Path $harnessPayload 'InstallStartupLock.ahk'),$inventorySource,[Text.UTF8Encoding]::new($false))
    $testFile = Join-Path $harnessTests 'ScriptRestartHandoffTest.ahk'
    $workerPath = Join-Path $harnessPayload 'ScriptRestartWorker.ahk'
    $launcherFixture = Join-Path $context.RunRoot 'launcher-fixture.exe'
    $compiler = Join-Path $env:ProgramFiles 'AutoHotkey\Compiler\Ahk2Exe.exe'
    $compileArgs = '/in "{0}" /out "{1}" /base "{2}" /silent verbose' -f `
        (Join-Path $PSScriptRoot 'fixtures\RestartLauncherFixture.ahk'), $launcherFixture, $runtime
    $compileProcess = Start-Process -FilePath $compiler -ArgumentList $compileArgs -WindowStyle Hidden -PassThru
    [void]$compileProcess.Handle
    if (-not $compileProcess.WaitForExit(30000)) { $compileProcess.Kill(); throw 'Fixture compile timed out' }
    if ($compileProcess.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $launcherFixture)) { throw 'Fixture compile failed' }
    $compileProcess.Dispose()
    $recorderFixture = Join-Path $context.RunRoot 'ffmpeg.exe'
    & (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:exe `
        ('/out:' + $recorderFixture) (Join-Path $PSScriptRoot 'fixtures\HandoffRecorderFixture.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Recorder fixture compile failed' }
    foreach ($case in @(
        @{ Mode='nextserver'; Scenario='slow'; Expected='accepted' },
        @{ Mode='nextserver remote'; Scenario='slow'; Expected='accepted' },
        @{ Mode='restart'; Scenario='slow'; Expected='accepted' },
        @{ Mode='restart resume'; Scenario='slow'; Expected='accepted' },
        @{ Mode='nextserver'; Scenario='duplicate'; Expected='accepted' },
        @{ Mode='nextserver'; Scenario='cancel'; Expected='cancelled' },
        @{ Mode='nextserver'; Scenario='timeout'; Expected='failed' },
        @{ Mode='nextserver'; Scenario='noack'; Expected='failed' },
        @{ Mode='nextserver'; Scenario='noack-recording'; Expected='failed' },
        @{ Mode='nextserver'; Scenario='timeout-recording'; Expected='failed' },
        @{ Mode='nextserver'; Scenario='boundary-recording'; Expected='failed' },
        @{ Mode='nextserver'; Scenario='accepted-recording'; Expected='accepted' },
        @{ Mode='nextserver'; Scenario='cancel-write-blocked'; Expected='cancelled' },
        @{ Mode='restart resume'; Scenario='wrong-mode'; Expected='failed' },
        @{ Mode='restart'; Scenario='launcher'; Expected='accepted' },
        @{ Mode='restart resume'; Scenario='launcher'; Expected='accepted' },
        @{ Mode='restart resume'; Scenario='missing-launcher'; Expected='accepted' },
        @{ Mode='nextserver'; Scenario='late-duplicate'; Expected='accepted' },
        @{ Mode='nextserver'; Scenario='invalid'; Expected='invalid' }
    )) {
        if ($Scenario -and $case.Scenario -ne $Scenario) { continue }
        $caseRoot = Join-Path $context.RunRoot ([Guid]::NewGuid().ToString('N'))
        [void](New-Item -ItemType Directory -Path $caseRoot)
        $stdout = Join-Path $caseRoot 'stdout.log'
        $stderr = Join-Path $caseRoot 'stderr.log'
        $arguments = '/ErrorStdOut=UTF-8 "{0}" "{1}" "{2}" "{3}"' -f $testFile,$caseRoot,$case.Mode,$case.Scenario
        $caseLauncher = if ($case.Scenario -in @('launcher','wrong-mode')) { $launcherFixture } elseif ($case.Scenario -eq 'missing-launcher') { Join-Path $caseRoot 'missing.exe' } else { '' }
        $arguments += ' "' + $caseLauncher + '" "' + $recorderFixture + '"'
        $process = Start-Process -FilePath $runtime -ArgumentList $arguments -WorkingDirectory $projectRoot `
            -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
        [void]$process.Handle
        if (-not $process.WaitForExit(20000)) {
            # Exact owned process object, never a process-name kill.
            $process.Kill()
            throw "Test parent timed out: $($case.Scenario)"
        }
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) {
            throw "Handoff test failed: $(Get-Content -LiteralPath $stdout -Raw) $(Get-Content -LiteralPath $stderr -Raw)"
        }
        if ((Get-Content -LiteralPath $stdout -Raw) -match '==> Warning:' -or (Get-Content -LiteralPath $stderr -Raw) -match '==> Warning:') {
            throw 'Handoff tests must not emit AHK diagnostics'
        }
        $process.Dispose()
        if ($case.Expected -ne 'invalid') {
            $request = (Get-Content -LiteralPath (Join-Path $caseRoot 'request-path.txt') -Raw).Trim()
            $resultPath = Join-Path (Split-Path $request -Parent) 'result.ini'
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            do {
                $resultText = if (Test-Path -LiteralPath $resultPath) { Get-Content -LiteralPath $resultPath -Raw } else { '' }
                if ($resultText -match '(?m)^state=(accepted|cancelled|failed)\s*$') { break }
                Start-Sleep -Milliseconds 100
            } while ([DateTime]::UtcNow -lt $deadline)
            if ($resultText -notmatch ('(?m)^state=' + $case.Expected + '\s*$')) { throw "Wrong handoff result: $resultText" }
            if ($resultText -notmatch ('(?m)^working_directory=' + [regex]::Escape((Split-Path $request -Parent)) + '\s*$')) {
                throw 'Handoff worker must not hold the payload working directory during an update'
            }
            $childPath = Join-Path $caseRoot 'child-starts.txt'
            if ($case.Scenario -eq 'late-duplicate') {
                $duplicate = Start-Process -FilePath $runtime -ArgumentList ('/ErrorStdOut=UTF-8 "{0}" "{1}"' -f `
                    $workerPath, $request) -WindowStyle Hidden -PassThru
                [void]$duplicate.Handle
                if (-not $duplicate.WaitForExit(5000)) { $duplicate.Kill(); throw 'Late duplicate worker did not exit' }
                if ($duplicate.ExitCode -ne 0) { throw 'Late duplicate worker failed' }
                $duplicate.Dispose()
            }
            if ($case.Expected -eq 'accepted' -or $case.Scenario -like 'noack*' -or $case.Scenario -eq 'wrong-mode') {
                # The deliberately short 400-ms no-ACK deadline can finish
                # before a busy machine schedules the inert successor. Wait
                # for its independent evidence, without changing product timeouts.
                $startDeadline = [DateTime]::UtcNow.AddSeconds(5)
                while (-not (Test-Path -LiteralPath $childPath) -and [DateTime]::UtcNow -lt $startDeadline) {
                    Start-Sleep -Milliseconds 50
                }
                $starts = @(Get-Content -LiteralPath $childPath | Where-Object { $_ })
                if ($starts.Count -ne 1 -or ($case.Scenario -ne 'wrong-mode' -and $starts[0] -cne $case.Mode)) { throw 'Successor mode changed or launched more than once' }
                $exitPath = Join-Path $caseRoot 'child-exit.ini'
                $exitDeadline = [DateTime]::UtcNow.AddSeconds(5)
                while (-not (Test-Path -LiteralPath $exitPath) -and [DateTime]::UtcNow -lt $exitDeadline) {
                    Start-Sleep -Milliseconds 50
                }
                if (-not (Test-Path -LiteralPath $exitPath)) { throw 'Synthetic successor did not exit; an error dialog may be blocking it' }
                $exitText = Get-Content -LiteralPath $exitPath -Raw
                if ($exitText -notmatch '(?m)^pid=(\d+)\s*$') { throw 'Successor exit report has no process identity' }
                $childProcess = Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue
                if ($childProcess) {
                    try {
                        if (-not $childProcess.WaitForExit(2000)) { throw 'Synthetic successor is still running after its exit report' }
                    } finally { $childProcess.Dispose() }
                }
                $expectedExit = if ($case.Scenario -eq 'wrong-mode') { 1 } else { 0 }
                if ($exitText -notmatch ('(?m)^code=' + $expectedExit + '\s*$')) { throw "Unexpected successor exit: $exitText" }
                $childErrorPath = Join-Path $caseRoot 'child-error.txt'
                if ($case.Scenario -eq 'wrong-mode') {
                    if (-not (Test-Path -LiteralPath $childErrorPath) -or (Get-Content -LiteralPath $childErrorPath -Raw).Trim() -cne 'Restart handoff mode mismatch; refusing a fresh or different task') {
                        throw 'Wrong-mode child did not durably report the expected rejection'
                    }
                } elseif (Test-Path -LiteralPath $childErrorPath) { throw 'Synthetic successor reported an unexpected error' }
            } elseif (Test-Path -LiteralPath $childPath) { throw 'Cancelled/timed-out handoff launched a successor' }
            if ($case.Scenario -eq 'launcher') {
                $launcherStarts = @(Get-Content -LiteralPath (Join-Path $caseRoot 'launcher-starts.txt'))
                $expectedFlag = if ($case.Mode -eq 'restart resume') { '--resume-current-task' } else { '--restart-current-task' }
                if ($launcherStarts.Count -ne 1 -or $launcherStarts[0] -cne $expectedFlag) { throw 'Updater mode changed or started more than once' }
            }
            if ($case.Scenario -like '*recording') {
                $sealDeadline = [DateTime]::UtcNow.AddSeconds(5)
                do {
                    $sealed = (Get-Content -LiteralPath (Join-Path $caseRoot 'recorder-state.txt') -Raw) -eq 'sealed'
                    if (-not $sealed) { Start-Sleep -Milliseconds 50 }
                } while (-not $sealed -and [DateTime]::UtcNow -lt $sealDeadline)
                if (-not $sealed) {
                    throw 'Failed restart left the inherited recorder running without graceful finalization'
                }
                if ($case.Scenario -eq 'accepted-recording' -and -not (Test-Path -LiteralPath (Join-Path $caseRoot 'recorder-adopted.txt'))) {
                    throw 'Recorder was not preserved and explicitly adopted by successor'
                }
            }
        }
        $passed++
        Write-Host "PASS $($case.Mode) / $($case.Scenario)"
    }
    Write-Host "Restart handoff integration tests: $passed passed"
} finally {
    # Only this suite's compiled synthetic console recorder, never real FFmpeg.
    Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" | Where-Object {
        $_.ExecutablePath -eq $recorderFixture
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -ErrorAction SilentlyContinue }
    # Keep acceptance evidence inside the project, including failures.
    Complete-ProjectDevelopmentPaths -Context $context
}
