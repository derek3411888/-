[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'GameMaintenanceTestHelpers.ps1')
$module = Join-Path $PSScriptRoot '..\payload\GameMaintenanceNotice.ps1'
Assert-GMTrue (Test-Path -LiteralPath $module) 'Official maintenance module is missing'
. $module
$ctx = Initialize-ProjectDevelopmentPaths -ProjectRoot (Split-Path $PSScriptRoot -Parent) -RunName 'gm-notice-test'
try {
    $now = [DateTimeOffset]'2026-08-20T02:00:00Z'
    $url = 'https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/1'
    function New-Article([string]$Time = '2026年8月20日04:00 ~ 2026年8月20日11:00（UTC+8）') {
        [pscustomobject]@{articleId=1;articleTitle='《鳴潮》9.9版本更新維護預告（測試資料）';gameId='G152-tw';
            startTime='2026-08-13 11:00:01';articleContent="<p>維護期間無法登入遊戲。</p><p>更新維護時間：<strong>$Time</strong></p>"}
    }
    $original = ConvertFrom-GMNotice -Article (New-Article) -SourceUrl $url -FetchedAt $now
    Assert-GMTrue $original.valid 'Full official-scoped maintenance notice accepted'
    Assert-GMEqual $original.notice.startsAtUtc '2026-08-19T20:00:00Z' 'Start from body, not publication'
    Assert-GMEqual $original.notice.expectedOpenAtUtc '2026-08-20T03:00:00Z' 'Expected open converted to UTC'
    foreach ($time in @('2026年8月20日04:00 ~ 2026年8月20日11:00','8月20日04:00 ~ 8月20日11:00（UTC+8）',
        '2026年8月20日11:00 ~ 2026年8月20日04:00（UTC+8）','2026年8月20日04:00 ~ 2026年8月23日11:00（UTC+8）',
        '2026年2月30日04:00 ~ 2026年2月30日11:00（UTC+8）')) {
        Assert-GMEqual (ConvertFrom-GMNotice (New-Article $time) $url $now).valid $false 'Incomplete/invalid maintenance range rejected'
    }
    $cross = ConvertFrom-GMNotice (New-Article '2026年8月19日23:00 ~ 2026年8月20日06:00（UTC-4）') $url $now
    Assert-GMEqual $cross.notice.startsAtUtc '2026-08-20T03:00:00Z' 'Negative UTC offset'
    foreach ($title in @('《鳴潮》9.9版本預下載公告','《鳴潮》9.9版本前瞻','《鳴潮》商城維護公告','國服9.9版本更新維護')) {
        $bad = New-Article; $bad.articleTitle = $title
        Assert-GMEqual (ConvertFrom-GMNotice $bad $url $now).valid $false 'Unrelated notices rejected'
    }
    $bad = New-Article; $bad.gameId='G152-cn'
    Assert-GMEqual (ConvertFrom-GMNotice $bad $url $now).valid $false 'Wrong regional feed rejected'
    Assert-GMEqual (ConvertFrom-GMNotice (New-Article) 'https://example.org/news/1' $now).valid $false 'Unofficial source rejected'
    $late = ConvertFrom-GMNotice (New-Article '2026年8月20日04:00 ~ 2026年8月20日13:00（UTC+8）') $url $now
    Assert-GMEqual $late.notice.eventId $original.notice.eventId 'Extension retains event identity'
    $selection = Select-GMNotice @($original.notice,$late.notice,$original.notice) $now $original.notice
    Assert-GMEqual $selection.notice.expectedOpenAtUtc '2026-08-20T05:00:00Z' 'Latest deadline never shortens'
    Assert-GMEqual (Select-GMNotice @($original.notice) ([DateTimeOffset]'2026-08-19T02:00:00Z') $null).notice $null 'Tomorrow does not block today'
    Assert-GMEqual (Select-GMNotice @($original.notice) ([DateTimeOffset]'2026-08-21T04:00:00Z') $null).notice $null 'Historic event does not block cold start'
    Assert-GMTrue ($null -ne (Select-GMNotice @($original.notice) ([DateTimeOffset]'2026-08-20T09:00:00Z') $null).notice) 'Late start updates today'
    Assert-GMTrue ($null -ne (Select-GMNotice @() ([DateTimeOffset]'2026-08-21T04:00:00Z') $original.notice).notice) 'Persisted active event survives day boundary'

    $script:requests = [Collections.Generic.List[string]]::new()
    $getter = { param($uri,$timeoutMs,$maxBytes)
        $script:requests.Add([string]$uri)
        if ([string]$uri -like '*MainMenu.json') {
            return ([pscustomobject]@{article=@((New-Article),(New-Article))} | ConvertTo-Json -Depth 5 -Compress)
        }
        return (New-Article | ConvertTo-Json -Depth 5 -Compress)
    }
    $cache = Join-Path $ctx.RunRoot 'cache'
    $result = Get-GMOfficialNotice -CacheDirectory $cache -Now $now -HttpGetter $getter
    Assert-GMEqual $result.outcome 'ok' 'Source success'
    Assert-GMEqual $script:requests.Count 2 'Deduplicate list entries before detail fetch'
    [void](Get-GMOfficialNotice -CacheDirectory $cache -Now $now.AddMinutes(1) -HttpGetter $getter)
    Assert-GMEqual $script:requests.Count 2 'Active notice uses five minute cache'
    $unavailable = Get-GMOfficialNotice -CacheDirectory $cache -Now $now.AddHours(1) -Force $true -HttpGetter { throw 'HTTP 500' }
    Assert-GMEqual $unavailable.outcome 'unavailable' 'Network error remains unavailable'
    Assert-GMEqual $unavailable.notice.eventId $original.notice.eventId 'Known maintenance retained through outage'
    $unknown = Get-GMOfficialNotice -CacheDirectory (Join-Path $ctx.RunRoot 'unknown') -Now $now -HttpGetter { throw 'timeout' }
    Assert-GMEqual $unknown.outcome 'unavailable' 'No cache failure is not no-maintenance success'
    Assert-GMEqual $unknown.notice $null 'Unknown remains unknown'
    $malformed = Get-GMOfficialNotice -CacheDirectory $cache -Now $now.AddHours(1) -Force $true -HttpGetter { '{broken' }
    Assert-GMEqual $malformed.outcome 'invalid' 'Malformed JSON not accepted'
    Assert-GMTrue ($malformed.errorDetail -match 'malformed JSON') 'Source rejection has an inspectable reason'
    Assert-GMTrue ($null -ne $malformed.notice) 'Malformed source retains prior evidence'
    $oversized = Get-GMOfficialNotice -CacheDirectory $cache -Now $now.AddHours(1) -Force $true -HttpGetter { 'x' * 2097153 }
    Assert-GMEqual $oversized.outcome 'invalid' 'Oversized body rejected with injected getter too'
    $wrongShape = Get-GMOfficialNotice -CacheDirectory $cache -Now $now.AddHours(1) -Force $true -HttpGetter { '{"items":[]}' }
    Assert-GMEqual $wrongShape.outcome 'invalid' 'Changed menu schema not treated as empty feed'
    $negativeCache = Join-Path $ctx.RunRoot 'negative'
    $script:emptyCalls=0
    $emptyGetter={ param($uri,$timeoutMs,$maxBytes) $script:emptyCalls++; '{"article":[]}' }
    $noEventResult=Get-GMOfficialNotice $negativeCache $now $false $emptyGetter
    Assert-GMEqual ($noEventResult | ConvertTo-Json -Depth 5 -Compress | ConvertFrom-Json).notice $null 'No event serializes as JSON null, not an empty object'
    [void](Get-GMOfficialNotice $negativeCache $now.AddHours(5) $false $emptyGetter)
    Assert-GMEqual $script:emptyCalls 1 'Negative cache six hour TTL'
    [void](Get-GMOfficialNotice $negativeCache $now.AddHours(7) $false $emptyGetter)
    Assert-GMEqual $script:emptyCalls 2 'Expired negative cache refreshes'
    $result = Get-GMOfficialNotice -CacheDirectory $cache -Now $now.AddMinutes(1) -Force $true -HttpGetter $getter
    $cachePath=Join-Path $cache 'notice-cache.json'
    [IO.File]::WriteAllText($cachePath,'{truncated',[Text.UTF8Encoding]::new($false))
    $recovered = Get-GMOfficialNotice -CacheDirectory $cache -Now $now.AddHours(1) -Force $true -HttpGetter { throw 'offline' }
    Assert-GMTrue ($null -ne $recovered.notice) 'Validated backup survives truncated primary'
    $extensionCache = Join-Path $ctx.RunRoot 'extension'
    $extensionGetter = { param($uri,$timeoutMs,$maxBytes)
        $extendedArticle=New-Article '2026年8月20日04:00 ~ 2026年8月20日13:00（UTC+8）'
        if ([string]$uri -like '*MainMenu.json') { return ([pscustomobject]@{article=@($extendedArticle)} | ConvertTo-Json -Depth 5 -Compress) }
        return ($extendedArticle | ConvertTo-Json -Depth 5 -Compress)
    }
    [void](Get-GMOfficialNotice $extensionCache $now $true $extensionGetter)
    [void](Get-GMOfficialNotice $extensionCache $now $true $getter)
    $afterStale = Get-GMOfficialNotice $extensionCache $now.AddMinutes(1) $false { throw 'should use cache' }
    Assert-GMEqual $afterStale.notice.expectedOpenAtUtc '2026-08-20T05:00:00Z' 'Stale response cannot shorten persisted extension'
    $script:limitedCalls=0
    $capGetter={ param($uri,$timeoutMs,$maxBytes)
        $script:limitedCalls++
        Assert-GMTrue ($timeoutMs -le 10000) 'HTTP call timeout bounded'
        if ([string]$uri -like '*MainMenu.json') {
            $items=@(1..20 | ForEach-Object { $entry=New-Article; $entry.articleId=$_; $entry })
            return ([pscustomobject]@{article=$items} | ConvertTo-Json -Depth 5 -Compress)
        }
        $entry=New-Article; $entry.articleId=[int]([regex]::Match([string]$uri,'/(\d+)\.json$').Groups[1].Value)
        return ($entry | ConvertTo-Json -Depth 5 -Compress)
    }
    [void](Get-GMOfficialNotice (Join-Path $ctx.RunRoot 'cap') $now $true $capGetter)
    Assert-GMEqual $script:limitedCalls 13 'At most twelve unique detail requests'
    $script:chosenIds=@()
    $orderedGetter={ param($uri,$timeoutMs,$maxBytes)
        if ([string]$uri -like '*MainMenu.json') {
            $items=@(1..20 | ForEach-Object { $entry=New-Article; $entry.articleId=$_; $entry.startTime=('2026-08-{0:00} 00:00:00' -f $_); $entry })
            return ([pscustomobject]@{article=$items} | ConvertTo-Json -Depth 5 -Compress)
        }
        $id=[int]([regex]::Match([string]$uri,'/(\d+)\.json$').Groups[1].Value)
        $script:chosenIds += $id
        $entry=New-Article; $entry.articleId=$id
        return ($entry | ConvertTo-Json -Depth 5 -Compress)
    }
    [void](Get-GMOfficialNotice (Join-Path $ctx.RunRoot 'ordering') $now $true $orderedGetter)
    Assert-GMEqual $script:chosenIds[0] 20 'Newest candidate fetched first after deduplication'
    Assert-GMEqual $script:chosenIds[-1] 9 'Old history cannot displace the newest twelve candidates'
    $futureGetter = { param($uri,$timeoutMs,$maxBytes)
        if ([string]$uri -like '*MainMenu.json') {
            $entries=@(1..5 | ForEach-Object {$item=New-Article; $item.articleId=$_; $item})
            return ([pscustomobject]@{article=$entries} | ConvertTo-Json -Depth 5 -Compress)
        }
        $id=[int]([regex]::Match([string]$uri,'/(\d+)\.json$').Groups[1].Value)
        $day=20+$id
        $item=New-Article ("2026年8月${day}日04:00 ~ 2026年8月${day}日11:00（UTC+8）")
        $item.articleId=$id; $item.articleTitle="《鳴潮》9.$id 版本更新維護預告"
        return ($item | ConvertTo-Json -Depth 5 -Compress)
    }
    $futureCache=Join-Path $ctx.RunRoot 'future-cache'
    $futureResult=Get-GMOfficialNotice $futureCache $now $true $futureGetter
    Assert-GMEqual $futureResult.notice $null 'Upcoming announcement cannot block normal farming today'
    $upcoming=Get-GMNoticeValue $futureResult 'upcomingNotice'
    Assert-GMEqual (Get-GMNoticeValue $upcoming 'gameVersion') '9.1' 'Nearest future announcement is exposed separately for the website'
    $cachedFuture=Get-GMOfficialNotice $futureCache $now.AddMinutes(1) $false { throw 'cached future should not fetch' }
    Assert-GMTrue $cachedFuture.fromCache 'Upcoming announcement uses existing six-hour cache'
    Assert-GMEqual $cachedFuture.upcomingNotice.expectedOpenAtUtc '2026-08-21T03:00:00Z' 'Cache hit retains future display deadline'
    $offlineFuture=Get-GMOfficialNotice $futureCache $now.AddMinutes(2) $true { throw 'offline' }
    Assert-GMEqual $offlineFuture.outcome 'unavailable' 'Future cache does not disguise network failure'
    Assert-GMEqual $offlineFuture.upcomingNotice.gameVersion '9.1' 'Last known upcoming announcement survives outage'
    Assert-GMEqual $offlineFuture.checkedAt $futureResult.checkedAt 'Failed refresh cannot claim a new confirmation time'
    $onMaintenanceDay=Get-GMOfficialNotice $futureCache ([DateTimeOffset]'2026-08-20T20:00:00Z') $false { throw 'offline' }
    Assert-GMEqual $onMaintenanceDay.notice.gameVersion '9.1' 'Known future event becomes an active gate on its Taipei date even offline'
    Assert-GMEqual $onMaintenanceDay.upcomingNotice.gameVersion '9.2' 'Preview does not duplicate the current maintenance event'
    $saved=Read-GMNoticeCache $futureCache
    Assert-GMEqual @($saved.notices).Count 3 'Cache stores at most three event summaries'
    Assert-GMEqual $saved.notices[0].gameVersion '9.1' 'Nearest upcoming event retained first'
    $conflictGetter={ param($uri,$timeoutMs,$maxBytes)
        if ([string]$uri -like '*MainMenu.json') {
            $items=@(1,2 | ForEach-Object {$item=New-Article; $item.articleId=$_; $item})
            return ([pscustomobject]@{article=$items} | ConvertTo-Json -Depth 5 -Compress)
        }
        $id=[int]([regex]::Match([string]$uri,'/(\d+)\.json$').Groups[1].Value)
        $item=New-Article; $item.articleId=$id; $item.articleTitle="《鳴潮》9.$id 版本更新維護預告"
        return ($item | ConvertTo-Json -Depth 5 -Compress)
    }
    $conflict=Get-GMOfficialNotice (Join-Path $ctx.RunRoot 'conflict') $now $true $conflictGetter
    Assert-GMEqual $conflict.errorCode 'NOTICE_CONFLICT' 'Two applicable events require review rather than ordinary network degradation'
    $replacementGetter={ param($uri,$timeoutMs,$maxBytes)
        $item=New-Article '2026年8月20日05:00 ~ 2026年8月20日13:00（UTC+8）'
        if ([string]$uri -like '*MainMenu.json') { return ([pscustomobject]@{article=@($item)} | ConvertTo-Json -Depth 5 -Compress) }
        return ($item | ConvertTo-Json -Depth 5 -Compress)
    }
    $replacement=Get-GMOfficialNotice -CacheDirectory (Join-Path $ctx.RunRoot 'replacement') -Now $now.AddHours(2) -Force $true -HttpGetter $replacementGetter -Previous $original.notice
    Assert-GMEqual $replacement.errorCode 'NOTICE_CONFLICT' 'Pinned previous cannot hide replacement with changed start/end'
    Assert-GMTrue ($replacement.checkedAt -ne $now.AddHours(2).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')) 'Unconfirmed retained notice never gets fresh checkedAt'
    $removed=Get-GMOfficialNotice -CacheDirectory (Join-Path $ctx.RunRoot 'removed') -Now $now.AddHours(2) -Force $true -HttpGetter $emptyGetter -Previous $original.notice
    Assert-GMEqual $removed.errorCode 'NOTICE_EVENT_NOT_RECONFIRMED' 'Removed pinned notice remains known but not freshly confirmed'
    Assert-GMEqual $removed.notice.eventId $original.notice.eventId 'Removal does not erase prior deadline'
    $budgetResult=Get-GMOfficialNotice -CacheDirectory (Join-Path $ctx.RunRoot 'budget') -Now $now -BudgetMilliseconds 1 -HttpGetter { Start-Sleep -Milliseconds 20; '{"article":[]}' }
    Assert-GMEqual $budgetResult.outcome 'unavailable' 'Total request budget enforced'
    [void](Get-GMOfficialNotice $negativeCache ([DateTimeOffset]'2026-08-20T15:59:00Z') $true $emptyGetter)
    $callsBeforeMidnight=$script:emptyCalls
    [void](Get-GMOfficialNotice $negativeCache ([DateTimeOffset]'2026-08-20T16:01:00Z') $false $emptyGetter)
    Assert-GMEqual $script:emptyCalls ($callsBeforeMidnight+1) 'Taipei midnight invalidates negative cache'
    foreach ($hostile in @('http://wutheringwaves.kurogames.com/zh-tw/main/news/detail/1', 'https://user@wutheringwaves.kurogames.com/zh-tw/main/news/detail/1','https://wutheringwaves.kurogames.com.evil.test/zh-tw/main/news/detail/1','https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/1?next=evil')) {
        Assert-GMEqual (Test-GMNoticeUrl $hostile) $false 'Unsafe URL rejected'
    }
    Write-Output 'PASS: notice parsing, scope, time, extensions, TTL, cache recovery and network degradation'
} finally { Complete-ProjectDevelopmentPaths -Context $ctx }
