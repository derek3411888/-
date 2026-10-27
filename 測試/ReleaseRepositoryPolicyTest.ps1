[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
$fixture = Join-Path $project ('.dev-runtime/tests/repository-policy-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
function Git-Test([string[]]$Arguments) {
    $result = @(& git -C $fixture -c core.quotepath=false -c core.autocrlf=false @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "Fixture git failed: $($Arguments[0])" }
    return $result
}
function Assert-Test([bool]$Value, [string]$Message) {
    if (!$Value) { throw "FAIL: $Message" }
}
function Write-Fixture([string]$RelativePath) {
    $file = Join-Path $fixture $RelativePath
    [void][IO.Directory]::CreateDirectory((Split-Path $file -Parent))
    [IO.File]::WriteAllText($file, "fixture only`n", [Text.UTF8Encoding]::new($false))
}
function Assert-Blocked([scriptblock]$Action, [string]$Message) {
    $blocked = $false
    try { & $Action } catch { $blocked = $true }
    Assert-Test $blocked $Message
}
Git-Test @('init','--quiet') | Out-Null
Copy-Item -LiteralPath (Join-Path $project '.gitignore') -Destination (Join-Path $fixture '.gitignore')
$private = @('開發日記.md','AGENTS.md','PROJECT_AI_HANDOFF.md','DEVELOPMENT_ARTIFACTS.md',
    '.agents/skills/example/hosts.json','.vscode/settings.json','.superpowers/work.md',
    '.dev-runtime/diagnostics/private.txt','docs/superpowers/plans/internal.md',
    'docs/archive/private.md','docs/game-maintenance-acceptance.md','docs/game-maintenance-final-review.md',
    '測試/實機伺服器切換50次驗證報告.md','測試/RemoteWorkerCommandTest.ps1',
    '測試/主畫面模板比對/roi_debug.png','測試/主畫面模板比對/test_log.txt')
$public = @('README.md','payload/GameHotfixRecovery.ahk','測試/GameHotfixRecoveryTest.ahk',
    'docs/releases/5.39.md','全自動鋤地.exe','payload.zip','self-hosted-server.zip',
    'remote-control-web.zip','update_manifest.example.json','self-hosted-server/backup/entrypoint.sh')
foreach ($file in ($private + $public)) { Write-Fixture $file }
Git-Test @('add','--','.') | Out-Null
$staged = @(Git-Test @('ls-files'))
foreach ($file in $private) { Assert-Test ($file -notin $staged) "ordinary git add must not stage local-only path: $file" }
foreach ($file in $public) { Assert-Test ($file -in $staged) "required public source/artifact must remain stageable: $file" }
. (Join-Path $project 'ReleaseRepositoryPolicy.ps1')
Assert-ReleaseRepositoryPrivacy -ProjectRoot $fixture
foreach ($file in $private) {
    Git-Test @('add','-f','--',$file) | Out-Null
    Assert-Blocked { Assert-ReleaseRepositoryPrivacy -ProjectRoot $fixture } "forced local file must block release: $file"
    Git-Test @('rm','--cached','--',$file) | Out-Null
    Assert-Test (Test-Path -LiteralPath (Join-Path $fixture $file)) "untracking must keep local file: $file"
    Assert-ReleaseRepositoryPrivacy -ProjectRoot $fixture
}
Git-Test @('add','-f','--','開發日記.md') | Out-Null
Git-Test @('-c','user.name=RepositoryPolicyTest','-c','user.email=fixture@example.invalid','commit','--quiet','-m','fixture private commit') | Out-Null
Assert-Blocked { Assert-ReleaseRepositoryPrivacy -ProjectRoot $fixture -Revision HEAD } 'committed local file must block push'
Git-Test @('rm','--cached','--','開發日記.md') | Out-Null
Assert-ReleaseRepositoryPrivacy -ProjectRoot $fixture
Git-Test @('-c','user.name=RepositoryPolicyTest','-c','user.email=fixture@example.invalid','commit','--quiet','-m','fixture current-tree cleanup') | Out-Null
Assert-ReleaseRepositoryPrivacy -ProjectRoot $fixture -Revision HEAD
Assert-Test (Test-Path -LiteralPath (Join-Path $fixture '開發日記.md')) 'commit cleanup must retain local diary'
Assert-Blocked { Assert-ReleaseRepositoryPrivacy -ProjectRoot $fixture -Revision 'refs/heads/does-not-exist' } 'invalid tree must not pass'
Assert-Blocked { Assert-ReleaseRepositoryPrivacy -ProjectRoot (Join-Path $fixture 'not-a-repository') } 'Git failure must not pass'
Write-Output "PASS: repository privacy ($($private.Count) local-only paths, $($public.Count) public paths, real index and commit checks); fixture=$fixture"
