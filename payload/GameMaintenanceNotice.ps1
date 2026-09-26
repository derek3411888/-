# Read-only official information. No launcher, game, account or input side effects.
Set-StrictMode -Version 2

function Get-GMNoticeValue($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}

function Test-GMNoticeUrl([string]$Url) {
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne 'https' -or $uri.Port -ne 443 -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) { return $false }
    if ($uri.Host -eq 'hw-media-cdn-mingchao.kurogame.com') {
        return $uri.AbsolutePath -cmatch '^/akiwebsite/website2\.0/json/G152/zh-tw/(?:MainMenu\.json|article/\d+\.json)$'
    }
    return $uri.Host -eq 'wutheringwaves.kurogames.com' -and $uri.AbsolutePath -cmatch '^/zh-tw/(?:main/)?news/detail/\d+$'
}

function Get-GMNoticeHash([string]$Text) {
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $hasher.Dispose() }
}

function ConvertFrom-GMNoticeJson([string]$Text) {
    # PS 7.5+ otherwise converts ISO strings into localized DateTime values.
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) {
        return (ConvertFrom-Json -InputObject $Text -DateKind String -ErrorAction Stop)
    }
    return (ConvertFrom-Json -InputObject $Text -ErrorAction Stop)
}

function ConvertFrom-GMNotice {
    param($Article, [string]$SourceUrl, [DateTimeOffset]$FetchedAt)
    $invalid = { param($reason) [pscustomobject]@{valid=$false;reason=$reason;notice=$null} }
    if (-not (Test-GMNoticeUrl $SourceUrl)) { return (& $invalid 'UNTRUSTED_SOURCE') }
    $title = [string](Get-GMNoticeValue $Article 'articleTitle' '')
    $raw = [string](Get-GMNoticeValue $Article 'articleContent' '')
    $gameId = [string](Get-GMNoticeValue $Article 'gameId' 'G152-tw')
    $id = [string](Get-GMNoticeValue $Article 'articleId' '')
    if ($gameId -ne 'G152-tw' -or $title -match '國服|国服|中國大陸|中国大陆') { return (& $invalid 'WRONG_SCOPE') }
    if ($id -notmatch '^\d+$' -or $raw.Length -eq 0 -or [Text.Encoding]::UTF8.GetByteCount($raw) -gt 2097152) { return (& $invalid 'INVALID_ARTICLE') }
    if ($title -match '預下載|预下载|前瞻' -or $title -notmatch '(?<version>\d+(?:\.\d+){1,3})\s*版本.*(?:更新|維護|维护)') {
        return (& $invalid 'NOT_VERSION_MAINTENANCE')
    }
    $version = $Matches.version
    $plain = [regex]::Replace($raw, '(?is)<(script|style)\b[^>]*>.*?</\1\s*>', '')
    $plain = [regex]::Replace($plain, '(?i)<br\s*/?>|</(?:p|div|li|h[1-6])\s*>', "`n")
    $plain = [Net.WebUtility]::HtmlDecode([regex]::Replace($plain, '<[^>]*>', ''))
    if ($plain -notmatch '(?:維護|维护).{0,40}(?:無法|无法|不能).{0,12}(?:登入|登錄|登录)|停機|停机') { return (& $invalid 'NO_LOGIN_OUTAGE') }
    $date = '(?<Y>\d{4})\s*(?:年|[-/])\s*(?<M>\d{1,2})\s*(?:月|[-/])\s*(?<D>\d{1,2})\s*日?\s*(?<H>\d{1,2}):(?<N>\d{2})'
    $range = [regex]::Match($plain, '(?s)(?:更新維護時間|更新维护时间|維護時間|维护时间)\s*[:：]?\s*(?<start>' + $date + ')\s*(?:~|～|至|—|–|-)\s*(?<end>' + $date + ')\s*[（(]?\s*UTC\s*(?<offset>[+\-]\d{1,2}(?::\d{2})?)\s*[)）]?')
    if (-not $range.Success) { return (& $invalid 'INCOMPLETE_TIME_RANGE') }
    try {
        $offsetMatch = [regex]::Match($range.Groups['offset'].Value, '^([+\-])(\d{1,2})(?::(\d{2}))?$')
        $hours = [int]$offsetMatch.Groups[2].Value
        $minutes = if ($offsetMatch.Groups[3].Success) { [int]$offsetMatch.Groups[3].Value } else { 0 }
        if ($hours -gt 14 -or $minutes -gt 59 -or ($hours -eq 14 -and $minutes -ne 0)) { throw 'Offset out of range' }
        $signedMinutes = ($hours * 60 + $minutes) * $(if ($offsetMatch.Groups[1].Value -eq '-') { -1 } else { 1 })
        $offset = [TimeSpan]::FromMinutes($signedMinutes)
        $times = @()
        foreach ($name in @('start','end')) {
            $parts = [regex]::Match($range.Groups[$name].Value, $date)
            $formatted = '{0}-{1}-{2} {3}:{4}' -f $parts.Groups['Y'].Value,$parts.Groups['M'].Value,$parts.Groups['D'].Value,$parts.Groups['H'].Value,$parts.Groups['N'].Value
            $local = [datetime]::MinValue
            if (-not [datetime]::TryParseExact($formatted, 'yyyy-M-d H:mm', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$local)) { throw 'Invalid date' }
            $times += [DateTimeOffset]::new([DateTime]::SpecifyKind($local,[DateTimeKind]::Unspecified),$offset)
        }
        if ($times[1] -le $times[0] -or ($times[1] - $times[0]).TotalHours -gt 48) { throw 'Invalid span' }
    } catch { return (& $invalid 'INVALID_TIME_RANGE') }
    $startUtc = $times[0].UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $openUtc = $times[1].UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
    $bodyHash = Get-GMNoticeHash $plain
    $notice = [pscustomobject]@{
        schemaVersion=1;eventId="wuthering-global-$version-$($times[0].ToUnixTimeSeconds())";articleId=[long]$id
        gameVersion=$version;scope='global-pc';startsAtUtc=$startUtc;expectedOpenAtUtc=$openUtc
        publishedAt=[string](Get-GMNoticeValue $Article 'startTime' '')
        fetchedAtUtc=$FetchedAt.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ');sourceUrl=$SourceUrl
        bodySha256=$bodyHash;revisionHash=(Get-GMNoticeHash "$id|$bodyHash|$openUtc");sourceState='verified'
    }
    return [pscustomobject]@{valid=$true;reason='';notice=$notice}
}

function Test-GMSavedNotice($Notice) {
    try {
        if ((Get-GMNoticeValue $Notice 'schemaVersion') -ne 1 -or (Get-GMNoticeValue $Notice 'scope') -ne 'global-pc') { return $false }
        if (-not (Test-GMNoticeUrl ([string]$Notice.sourceUrl))) { return $false }
        $start = [DateTimeOffset]::ParseExact([string]$Notice.startsAtUtc,'yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        $end = [DateTimeOffset]::ParseExact([string]$Notice.expectedOpenAtUtc,'yyyy-MM-ddTHH:mm:ssZ',[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal)
        return $end -gt $start -and ($end-$start).TotalHours -le 48 -and
            $Notice.gameVersion -match '^\d+(?:\.\d+){1,3}$' -and
            $Notice.eventId -ceq "wuthering-global-$($Notice.gameVersion)-$($start.ToUnixTimeSeconds())" -and
            $Notice.revisionHash -match '^[0-9a-f]{64}$' -and $Notice.bodySha256 -match '^[0-9a-f]{64}$'
    } catch { return $false }
}

function Select-GMNotice {
    param([AllowEmptyCollection()][object[]]$Notices, [DateTimeOffset]$Now, $Previous = $null)
    $today = $Now.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd')
    $usable = @($Notices | Where-Object { Test-GMSavedNotice $_ })
    $previousValid = $null -ne $Previous -and (Test-GMSavedNotice $Previous)
    if ($previousValid) {
        $previousStart=[DateTimeOffset]$Previous.startsAtUtc
        $previousEnd=[DateTimeOffset]$Previous.expectedOpenAtUtc
        $previousDay=$previousStart.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd')
        $conflicting=@($usable | Where-Object {
            $start=[DateTimeOffset]$_.startsAtUtc; $end=[DateTimeOffset]$_.expectedOpenAtUtc
            $_.eventId -ne $Previous.eventId -and (
                $start.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd') -eq $previousDay -or
                ($start -le $previousEnd -and $end -ge $previousStart) -or
                ($_.gameVersion -eq $Previous.gameVersion -and $end -ge $Now -and $start -le $previousStart.AddDays(2)))
        })
        if ($conflicting.Count) { return [pscustomobject]@{notice=$Previous;sourceState='conflict';requiresReview=$true;reconfirmed=$false} }
        $currentMatches = @($usable | Where-Object { $_.eventId -eq $Previous.eventId })
        $same = $currentMatches + @($Previous)
        $chosen = $same | Sort-Object {[DateTimeOffset]$_.expectedOpenAtUtc} -Descending | Select-Object -First 1
        return [pscustomobject]@{notice=$chosen;sourceState='known';requiresReview=$false;reconfirmed=($currentMatches.Count -gt 0)}
    }
    $todayNotices = @($usable | Where-Object { ([DateTimeOffset]$_.startsAtUtc).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd') -eq $today })
    $events = @($todayNotices | Group-Object eventId)
    if ($events.Count -gt 1) { return [pscustomobject]@{notice=$null;sourceState='conflict';requiresReview=$true} }
    $ordered = @($todayNotices | Sort-Object {[DateTimeOffset]$_.expectedOpenAtUtc} -Descending)
    $chosen = $null
    if ($ordered.Count -gt 0) { $chosen = $ordered[0] }
    return [pscustomobject]@{notice=$chosen;sourceState='verified';requiresReview=$false}
}

function Select-GMUpcomingNotice {
    param([AllowEmptyCollection()][object[]]$Notices, [DateTimeOffset]$Now)
    # Display-only evidence. Never feed this preview into the active-day gate.
    $today = $Now.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd')
    $upcoming = @($Notices | Where-Object {
        (Test-GMSavedNotice $_) -and ([DateTimeOffset]$_.startsAtUtc) -le $Now.AddDays(14) -and
        ([DateTimeOffset]$_.startsAtUtc).ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd') -gt $today
    } | Sort-Object @{Expression={[DateTimeOffset]$_.startsAtUtc}}, @{Expression={[DateTimeOffset]$_.expectedOpenAtUtc};Descending=$true})
    if ($upcoming.Count) { return $upcoming[0] }
    return $null
}

function Read-GMNoticeCache([string]$Directory) {
    foreach ($name in @('notice-cache.json','notice-cache.json.bak')) {
        try {
            $path = Join-Path $Directory $name
            if (-not [IO.File]::Exists($path) -or ([IO.FileInfo]$path).Length -gt 262144) { continue }
            $cache = ConvertFrom-GMNoticeJson ([IO.File]::ReadAllText($path,[Text.Encoding]::UTF8))
            if ($cache.schemaVersion -ne 1 -or @($cache.notices).Count -gt 3) { continue }
            [void][DateTimeOffset]::Parse($cache.checkedAtUtc)
            if (@($cache.notices | Where-Object { -not (Test-GMSavedNotice $_) }).Count) { continue }
            return $cache
        } catch { continue }
    }
    return $null
}

function Write-GMNoticeCache([string]$Directory, $Cache) {
    [void][IO.Directory]::CreateDirectory($Directory)
    $path = Join-Path $Directory 'notice-cache.json'
    $temporary = Join-Path $Directory ('notice-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $text = $Cache | ConvertTo-Json -Depth 6 -Compress
    if ([Text.Encoding]::UTF8.GetByteCount($text) -gt 262144) { throw 'GM_INVALID: cache too large' }
    try {
        [IO.File]::WriteAllText($temporary,$text,[Text.UTF8Encoding]::new($false))
        $readback = ConvertFrom-GMNoticeJson ([IO.File]::ReadAllText($temporary))
        if ($readback.schemaVersion -ne 1 -or @($readback.notices | Where-Object { -not (Test-GMSavedNotice $_) }).Count) { throw 'GM_INVALID: cache readback failed' }
        if ([IO.File]::Exists($path)) { [IO.File]::Replace($temporary,$path,$path+'.bak') }
        else { [IO.File]::Move($temporary,$path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Invoke-GMNoticeHttp([string]$Url, [int]$TimeoutMs, [int]$MaxBytes) {
    if (-not (Test-GMNoticeUrl $Url)) { throw 'GM_INVALID: URL not allowed' }
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.AllowAutoRedirect = $false
    $request.Timeout = [Math]::Max(1,[Math]::Min(10000,$TimeoutMs))
    $request.ReadWriteTimeout = $request.Timeout
    $request.UserAgent = 'WutheringMaintenance/1.0'
    $response = $null; $stream = $null; $memory = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = $request.GetResponse()
        if ([int]$response.StatusCode -ne 200) { throw 'GM_INVALID: redirects and non-200 responses are not accepted' }
        if ($response.ContentLength -gt $MaxBytes) { throw 'GM_INVALID: response too large' }
        $stream = $response.GetResponseStream(); $memory = [IO.MemoryStream]::new()
        $chunk = New-Object byte[] 8192
        while ($true) {
            $remaining = $TimeoutMs - [int]$clock.ElapsedMilliseconds
            if ($remaining -le 0) { throw 'HTTP response time budget exhausted' }
            if ($stream.CanTimeout) { $stream.ReadTimeout = [Math]::Max(1,$remaining) }
            $count = $stream.Read($chunk,0,$chunk.Length)
            if ($count -eq 0) { break }
            if ($memory.Length + $count -gt $MaxBytes) { throw 'GM_INVALID: response too large' }
            $memory.Write($chunk,0,$count)
        }
        return [Text.UTF8Encoding]::new($false,$true).GetString($memory.ToArray())
    } finally {
        if ($memory) { $memory.Dispose() }; if ($stream) { $stream.Dispose() }; if ($response) { $response.Dispose() }
        $request.Abort()
    }
}

function Get-GMOfficialNotice {
    param([string]$CacheDirectory, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow, [bool]$Force = $false,
        [scriptblock]$HttpGetter = {param($uri,$timeoutMs,$maxBytes) Invoke-GMNoticeHttp $uri $timeoutMs $maxBytes},
        $Previous = $null, [ValidateRange(1,20000)][int]$BudgetMilliseconds = 20000)
    $cache = Read-GMNoticeCache $CacheDirectory
    $cachedNotices = if ($null -ne $cache) { @($cache.notices) } else { @() }
    $selected = Select-GMNotice $cachedNotices $Now $Previous
    $lastChecked = if ($cache) { [DateTimeOffset]$cache.checkedAtUtc } else { [DateTimeOffset]::MinValue }
    $dateKey = $Now.ToOffset([TimeSpan]::FromHours(8)).ToString('yyyy-MM-dd')
    $ttl = if ($selected.notice) { 300 } else { 21600 }
    $age = ($Now - $lastChecked).TotalSeconds
    if (-not $Force -and $cache -and $cache.dateKey -eq $dateKey -and $age -ge 0 -and $age -lt $ttl -and -not $selected.requiresReview) {
        return [pscustomobject]@{outcome='ok';notice=$selected.notice;upcomingNotice=(Select-GMUpcomingNotice $cachedNotices $Now);checkedAt=$cache.checkedAtUtc;errorCode='';errorDetail='';fromCache=$true}
    }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $fetch = {
        param([string]$uri)
        if (-not (Test-GMNoticeUrl $uri)) { throw 'GM_INVALID: URL not allowed' }
        $remaining = $BudgetMilliseconds - [int]$watch.ElapsedMilliseconds
        if ($remaining -le 0) { throw 'Official notice time budget exhausted' }
        $json = & $HttpGetter $uri ([Math]::Min(10000,$remaining)) 2097152
        if ($watch.ElapsedMilliseconds -gt $BudgetMilliseconds) { throw 'Official notice time budget exhausted' }
        if ($json -isnot [string] -or [Text.Encoding]::UTF8.GetByteCount($json) -gt 2097152) { throw 'GM_INVALID: oversized or invalid response' }
        try { return (ConvertFrom-GMNoticeJson $json) } catch { throw 'GM_INVALID: malformed JSON' }
    }
    try {
        $base = 'https://hw-media-cdn-mingchao.kurogame.com/akiwebsite/website2.0/json/G152/zh-tw/'
        $menu = & $fetch ($base+'MainMenu.json')
        if ($null -eq $menu -or $null -eq $menu.PSObject.Properties['article'] -or $menu.article -isnot [array]) { throw 'GM_INVALID: menu schema changed' }
        $candidates = @($menu.article | Where-Object {
            ([string](Get-GMNoticeValue $_ 'articleId' '')) -match '^\d+$' -and
            ([string](Get-GMNoticeValue $_ 'articleTitle' '')) -match '\d+(?:\.\d+)+\s*版本.*(?:維護|维护)' -and
            ([string](Get-GMNoticeValue $_ 'articleTitle' '')) -notmatch '預下載|预下载|前瞻'
        } | Group-Object articleId | ForEach-Object { $_.Group[0] } | Sort-Object {[string](Get-GMNoticeValue $_ 'startTime' '')} -Descending | Select-Object -First 12)
        $notices = @()
        foreach ($candidate in $candidates) {
            $id = [string]$candidate.articleId
            $article = & $fetch ($base+"article/$id.json")
            if ([string](Get-GMNoticeValue $article 'articleId' '') -ne $id) { throw 'GM_INVALID: article identity mismatch' }
            $parsed = ConvertFrom-GMNotice $article ("https://wutheringwaves.kurogames.com/zh-tw/main/news/detail/$id") $Now
            if (-not $parsed.valid) { throw ('GM_INVALID: announcement '+$parsed.reason) }
            $notices += $parsed.notice
        }
        $selectedFresh = Select-GMNotice $notices $Now $selected.notice
        if ($selectedFresh.requiresReview) { throw 'GM_CONFLICT: conflicting maintenance events' }
        if ($selected.notice -and -not (Get-GMNoticeValue $selectedFresh 'reconfirmed' $false)) {
            throw 'GM_UNCONFIRMED: known event missing from current official notices'
        }
        $merged = @($notices | Group-Object eventId | ForEach-Object {
            $_.Group | Sort-Object {[DateTimeOffset]$_.expectedOpenAtUtc} -Descending | Select-Object -First 1
        })
        $kept = @($merged | Where-Object {
            ([DateTimeOffset]$_.startsAtUtc) -le $Now.AddDays(14) -and ([DateTimeOffset]$_.expectedOpenAtUtc) -ge $Now.AddDays(-2)
        } | Sort-Object {[Math]::Abs((([DateTimeOffset]$_.startsAtUtc)-$Now).TotalSeconds)} | Select-Object -First 3)
        if ($selectedFresh.notice) {
            # Persist the merged deadline, not a stale article of the same event.
            $kept = @($selectedFresh.notice) + @($kept | Where-Object { $_.eventId -ne $selectedFresh.notice.eventId } | Select-Object -First 2)
        }
        $checkedAt = $Now.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
        Write-GMNoticeCache $CacheDirectory ([pscustomobject]@{schemaVersion=1;checkedAtUtc=$checkedAt;dateKey=$dateKey;notices=$kept})
        return [pscustomobject]@{outcome='ok';notice=$selectedFresh.notice;upcomingNotice=(Select-GMUpcomingNotice $kept $Now);checkedAt=$checkedAt;errorCode='';errorDetail='';fromCache=$false}
    } catch {
        $conflict = $_.Exception.Message.StartsWith('GM_CONFLICT:')
        $unconfirmed = $_.Exception.Message.StartsWith('GM_UNCONFIRMED:')
        $invalid = $conflict -or $_.Exception.Message.StartsWith('GM_INVALID:')
        return [pscustomobject]@{outcome=$(if ($invalid) {'invalid'} else {'unavailable'});notice=$selected.notice;upcomingNotice=(Select-GMUpcomingNotice $cachedNotices $Now)
            checkedAt=$(if ($cache) {$cache.checkedAtUtc} else {''});errorCode=$(if ($conflict) {'NOTICE_CONFLICT'} elseif ($unconfirmed) {'NOTICE_EVENT_NOT_RECONFIRMED'} elseif ($invalid) {'NOTICE_INVALID'} else {'NOTICE_UNAVAILABLE'})
            errorDetail=([regex]::Replace($_.Exception.Message,'[\r\n\x00-\x1f]',' ')).Substring(0,[Math]::Min(500,$_.Exception.Message.Length));fromCache=$false}
    }
}
