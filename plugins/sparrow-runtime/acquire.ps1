param(
    [ValidateSet('SubsPlease', 'EZTV', 'TokyoToshokan', 'TheRARBG')][string]$Provider,
    [switch]$LibraryOnly
)

# Sparrow provider algorithms adapted to Watchroom's request/result protocol.
# Windows PowerShell 5.1 and .NET only; no Python, clipboard, or DHT dependency.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:AlternativeTitles = @()
# Hosts that answered HTTP 429 during this run, with the earliest time to send them the next request.
$script:RateLimitedHosts = @{}
$script:RateLimitGapSeconds = 3

function Get-Option($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
function Get-Text([string]$Html) {
    return [Net.WebUtility]::HtmlDecode(([regex]::Replace($Html, '<[^>]*>', ''))).Trim()
}
function Get-Key([string]$Text) {
    return [regex]::Replace($Text.Normalize([Text.NormalizationForm]::FormD).ToLowerInvariant(), '[^\p{L}\p{N}]', '')
}
function Get-Attribute([string]$Tag, [string]$Name) {
    $match = [regex]::Match($Tag, ('(?is)(?:^|\s)' + [regex]::Escape($Name) + '\s*=\s*(["''])(.*?)\1'))
    if ($match.Success) { return [Net.WebUtility]::HtmlDecode($match.Groups[2].Value) }
    return ''
}
function Get-Links([string]$Html) {
    foreach ($match in [regex]::Matches($Html, '(?is)<a\b([^>]*)>(.*?)</a>')) {
        [pscustomobject]@{ Url = Get-Attribute $match.Groups[1].Value 'href'; Title = Get-Text $match.Groups[2].Value; Attributes = $match.Groups[1].Value }
    }
}
function Join-Url([string]$Base, [string]$Relative) { return ([uri]::new([uri]$Base, $Relative)).AbsoluteUri }
function Get-Page([string]$Url) {
    if (([uri]$Url).Scheme -ne 'https') { throw 'Provider URLs must use HTTPS.' }
    # Preserve Sparrow's browser user agent: some provider frontends reject generic clients.
    $agent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36'
    $hostName = ([uri]$Url).Host
    for ($attempt = 1; ; $attempt++) {
        # A host that has rate-limited this run gets its requests spaced out (TheRARBG allows about one search every few seconds).
        if ($script:RateLimitedHosts.ContainsKey($hostName)) {
            $wait = ($script:RateLimitedHosts[$hostName] - [DateTime]::UtcNow).TotalMilliseconds
            if ($wait -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($wait)) }
        }
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 20 -WebSession $script:ProviderSession -UserAgent $agent
            if ($script:RateLimitedHosts.ContainsKey($hostName)) { $script:RateLimitedHosts[$hostName] = [DateTime]::UtcNow.AddSeconds($script:RateLimitGapSeconds) }
            break
        }
        catch [Net.WebException] {
            $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($status -eq 429) {
                if ($attempt -ge 5) { throw 'The provider is limiting how often it can be searched (HTTP 429). Wait a minute and try again.' }
                $delay = 3 * $attempt
                $retryAfter = 0
                try { [void][int]::TryParse([string]$_.Exception.Response.Headers['Retry-After'], [ref]$retryAfter) } catch { }
                if ($retryAfter -gt $delay) { $delay = [Math]::Min(30, $retryAfter) }
                $script:RateLimitedHosts[$hostName] = [DateTime]::UtcNow.AddSeconds($delay)
                continue
            }
            if ($script:RateLimitedHosts.ContainsKey($hostName)) { $script:RateLimitedHosts[$hostName] = [DateTime]::UtcNow.AddSeconds($script:RateLimitGapSeconds) }
            # Cloudflare 52x and gateway errors are usually brief origin outages (TokyoToshokan often).
            if ($attempt -ge 3 -or $status -notin @(502, 503, 504, 520, 521, 522, 523, 524)) { throw }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
    if ($response.Content -match '(?i)cf-chl-|just a moment\.\.\.|verify you are human') { throw 'The provider requires browser verification. Try another provider or configure a working mirror.' }
    return [string]$response.Content
}
function New-Release([string]$Title, [string]$Url, [string]$Resolution = '', [string]$Episode = '', [switch]$Identified) {
    # Identified: the provider already matched the release to the title (EZTV by IMDb ID).
    [pscustomobject]@{ Title = $Title; Url = $Url; Resolution = $Resolution; Episode = $Episode; Identified = [bool]$Identified }
}
function Find-ImdbSeries([string]$Query) {
    # IMDb's public suggestion endpoint; EZTV's own show list and search are behind Cloudflare.
    $key = Get-Key $Query
    if (!$key) { return }
    $data = Get-Page ('https://v3.sg.media-imdb.com/suggestion/x/' + [uri]::EscapeDataString($Query.Trim()) + '.json') | ConvertFrom-Json
    foreach ($entry in @($data.d)) {
        if ($entry.id -match '^tt\d+$' -and $entry.qid -in @('tvSeries', 'tvMiniSeries')) {
            [pscustomobject]@{ Title = $(if ($entry.y) { "$($entry.l) ($($entry.y))" } else { $entry.l }); Name = $entry.l; Year = $entry.y; Url = "https://www.imdb.com/title/$($entry.id)/" }
        }
    }
}
function Get-ImdbNumber($Request, $Binding) {
    foreach ($value in @((Get-Option $Binding 'url'), (Get-Option (Get-Option $Request 'providerIds') 'imdb'))) {
        $match = [regex]::Match([string]$value, '(?i)(?:^|\btt|/title/tt)(\d{5,})\b')
        if ($match.Success) { return $match.Groups[1].Value }
    }
    $names = @((Get-Option $Binding 'title' $Request.title), $Request.originalTitle) | Where-Object { $_ } | Select-Object -Unique
    foreach ($name in $names) {
        $found = @(Find-ImdbSeries $name | Where-Object { (Get-Key $_.Name) -eq (Get-Key $name) })
        if ($Request.year -and $found.Count -gt 1) { $found = @($found | Where-Object { [int]$_.Year -eq [int]$Request.year }) }
        if ($found.Count -eq 1) { return [regex]::Match($found[0].Url, 'tt(\d+)').Groups[1].Value }
    }
    throw 'Could not find this show''s IMDb ID. Search for the title, or set its IMDb url in this plugin''s settings.json titles entry.'
}
function Get-AlternativeTitles($Request) {
    # Anime releases mostly use the romaji title, while Watchroom may only know the English one. AniList (public,
    # no key) gives the romaji title of the entry whose English or romaji title is this one. Optional: on any
    # failure the search uses Watchroom's titles alone.
    $names = @(@($Request.title, $Request.originalTitle) | Where-Object { $_ })
    $keys = @($names | ForEach-Object { Get-Key $_ })
    try {
        $body = @{ query = 'query($s:String){Page(perPage:8){media(search:$s,type:ANIME){title{romaji english} seasonYear}}}'; variables = @{ s = [string]$names[0] } } | ConvertTo-Json -Compress -Depth 5
        $response = Invoke-WebRequest -Uri 'https://graphql.anilist.co' -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($body)) -ContentType 'application/json' -Headers @{ Accept = 'application/json' } -UseBasicParsing -TimeoutSec 15
        $found = @(($response.Content | ConvertFrom-Json).data.Page.media | Where-Object { (Get-Key $_.title.english) -in $keys -or (Get-Key $_.title.romaji) -in $keys })
        if ($Request.year -and $found.Count -gt 1) { $found = @($found | Where-Object { [int]$_.seasonYear -eq [int]$Request.year }) }
        if ($found.Count -eq 1 -and $found[0].title.romaji -and (Get-Key $found[0].title.romaji) -notin $keys) { return , [string]$found[0].title.romaji }
    } catch { }
    return @()
}
function Get-SearchTerm([string]$Name) {
    # Provider searches match words: punctuation such as "..." or ":" would only narrow them.
    return ([regex]::Replace($Name, '[^\p{L}\p{N}]+', ' ')).Trim()
}
function Get-CatalogShow($Entries, $Request, $Binding) {
    $names = @((Get-Option $Binding 'title' $Request.title), $Request.originalTitle) | Where-Object { $_ }
    $keys = @($names | ForEach-Object { Get-Key $_ })
    $found = @($Entries | Where-Object { (Get-Key $_.Title) -in $keys } | Sort-Object Url -Unique)
    if ($found.Count -ne 1) { throw 'No unique exact title in the provider catalog. Set a title or url in this plugin''s settings.json titles entry.' }
    return $found[0].Url
}
function Get-ProviderBase([string]$ProviderName, $Settings) {
    return Get-Option $Settings 'baseUrl' (@{ SubsPlease = 'https://subsplease.org/'; EZTV = 'https://eztvx.to/'; TokyoToshokan = 'https://www.tokyotosho.info/'; TheRARBG = 'https://therarbg.com/' }[$ProviderName])
}
function Get-CatalogEntries([string]$ProviderName, $Settings) {
    $base = Get-ProviderBase $ProviderName $Settings
    if ($ProviderName -eq 'SubsPlease') {
        $catalog = Get-Page (Join-Url $base 'shows/')
        foreach ($block in [regex]::Matches($catalog, '(?is)<div\b[^>]*class=["'']all-shows-link["''][^>]*>(.*?)</div>')) {
            foreach ($link in Get-Links $block.Groups[1].Value) {
                [pscustomobject]@{ Title = (Get-Attribute $link.Attributes 'title'); Url = Join-Url (Join-Url $base 'shows/') $link.Url }
            }
        }
    }
}
function Get-Binding($Request, $Settings) {
    $binding = [pscustomobject]@{}
    $titles = Get-Option $Settings 'titles'
    if ($titles) {
        $property = $titles.PSObject.Properties | Where-Object { $_.Name -eq $Request.title } | Select-Object -First 1
        if ($property) { $binding = $property.Value | ConvertTo-Json -Depth 15 | ConvertFrom-Json }
    }
    $options = Get-Option $Request 'options'
    foreach ($pair in @(@('query','title'), @('sourceUrl','url'), @('resolution','resolution'), @('filter','filter'), @('episodeOffset','episodeOffset'), @('providerSeason','season'))) {
        $value = Get-Option $options $pair[0]
        if ($null -ne $value) { $binding | Add-Member -NotePropertyName $pair[1] -NotePropertyValue $value -Force }
    }
    # Interactive numbering controls override an old saved title binding as a unit.
    if ($options) {
        if (!(Get-Option $options 'sourceUrl') -or (Get-Option $Request 'action') -eq 'search') { $binding.PSObject.Properties.Remove('url') }
        if ($null -eq (Get-Option $options 'episodeOffset')) { $binding.PSObject.Properties.Remove('episodeOffset') }
        if ($null -eq (Get-Option $options 'providerSeason')) { $binding.PSObject.Properties.Remove('season') }
    }
    return $binding
}
function Get-Releases([string]$ProviderName, $Request, $Settings, $Binding) {
    $base = Get-ProviderBase $ProviderName $Settings
    $query = Get-Option $Binding 'title' $Request.title
    $url = Get-Option $Binding 'url'
    $limit = [Math]::Min(1000, [Math]::Max(1, [int](Get-Option $Settings 'limit' 200)))
    $maxPages = [Math]::Min(20, [Math]::Max(1, [int](Get-Option $Settings 'maxPages' 10)))
    switch ($ProviderName) {
        'SubsPlease' {
            if (!$url) {
                $entries = @(Get-CatalogEntries $ProviderName $Settings)
                $url = Get-CatalogShow $entries $Request $Binding
            }
            $page = Get-Page $url
            $sid = [regex]::Match($page, 'sid\s*=\s*["''](\d+)["'']')
            if (!$sid.Success) { throw 'SubsPlease show ID is missing; the provider page format may have changed.' }
            $data = Get-Page (Join-Url $base ('api/?f=show&tz=UTC&sid=' + $sid.Groups[1].Value)) | ConvertFrom-Json
            if (!$data.episode) { throw 'SubsPlease returned no episode data.' }
            foreach ($entry in $data.episode.PSObject.Properties) {
                # Current API keys are release titles ("Sousou no Frieren - 01");
                # some archived responses use just "01". Keep the fractional-special marker.
                $episode = $entry.Name
                $number = [regex]::Match($entry.Name, '(?i)(?:^|\s+-\s+)(\d+(?:\.\d+)?(?:v\d+)?)(?:\s*\([^)]*\))?$')
                if ($number.Success) { $episode = $number.Groups[1].Value }
                $releaseTitle = if ($entry.Name -match '^\d+(?:\.\d+)?(?:v\d+)?$') { "$query - $($entry.Name)" } else { $entry.Name }
                foreach ($download in $entry.Value.downloads) {
                    New-Release $releaseTitle $download.magnet ([string]$download.res) $episode
                }
            }
            return
        }
        'EZTV' {
            # The HTML show pages are blocked by Cloudflare; the JSON API is not.
            # imdb_id must be digits only: with a "tt" prefix the API ignores it and lists every show.
            $imdb = Get-ImdbNumber $Request $Binding
            # Results are newest first and only for this show, so the release limit would hide
            # older seasons; read every page (up to 2000 releases) instead.
            for ($pageNumber = 1; $pageNumber -le 20; $pageNumber++) {
                $data = Get-Page (Join-Url $base ('api/get-torrents?imdb_id=' + $imdb + '&limit=100&page=' + $pageNumber)) | ConvertFrom-Json
                if ([string]$data.imdb_id -ne $imdb) { throw 'EZTV did not return results for this show.' }
                $torrents = @($data.torrents)
                foreach ($torrent in $torrents) {
                    if ($torrent.magnet_url) { New-Release ([regex]::Replace([string]$torrent.title, '\s+EZTV$', '')) $torrent.magnet_url -Identified }
                }
                if ($torrents.Count -lt 100) { break }
            }
            return
        }
        'TokyoToshokan' {
            # search.php is blocked by Cloudflare; rss.php is not. A feed holds only the newest
            # ~150 matches, so each missing episode also gets its own search.
            $terms = @()
            if ($url) {
                $old = [regex]::Match($url, '(?i)[?&]terms=([^&]*)')
                if ($url -match '(?i)/rss\.php') { $terms += , $url }
                elseif ($old.Success) { $query = [uri]::UnescapeDataString($old.Groups[1].Value.Replace('+', ' ')) }
                else { throw 'TokyoToshokan url must be a search or rss.php address.' }
            }
            if (!$terms.Count) {
                # Also search the romaji title, which most anime releases use.
                $script:AlternativeTitles = @(Get-AlternativeTitles $Request)
                $names = @(@($query) + @($script:AlternativeTitles | ForEach-Object { Get-SearchTerm $_ }) | Where-Object { $_ } | Select-Object -Unique)
                $terms += $names
                $extra = 0
                foreach ($episode in @($Request.episodes | Where-Object { !$_.upcoming })) {
                    foreach ($name in $names) {
                        if ($extra -ge 12) { break }
                        $number = Get-AbsoluteNumber $episode $Binding
                        if ($null -ne $number) { $terms += , ('{0} {1:00}' -f $name, $number); $extra++ }
                        if ([int]$episode.season -gt 1) { $terms += , ('{0} S{1:00}E{2:00}' -f $name, [int]$episode.season, [int]$episode.episode); $extra++ }
                    }
                }
            }
            # No release limit: it would drop the per-episode searches that follow the title search.
            $seen = @{}
            foreach ($term in $terms) {
                $feed = if ($term -match '^https://') { $term } else { Join-Url $base ('rss.php?filter=1&terms=' + [uri]::EscapeDataString($term)) }
                $page = Get-Page $feed
                # A search without results returns only the closing tags.
                if ($page -notmatch '<rss\b') { continue }
                [xml]$xml = $page
                foreach ($entry in @($xml.rss.channel.SelectNodes('item'))) {
                    # Elements holding CDATA sections are XmlElements, not strings.
                    $magnet = [regex]::Match($entry.SelectSingleNode('description').InnerText, '(?i)href="(magnet:\?[^"]+)"')
                    if (!$magnet.Success) { continue }
                    $link = [Net.WebUtility]::HtmlDecode($magnet.Groups[1].Value)
                    if ($seen.ContainsKey($link)) { continue }
                    $seen[$link] = $true
                    New-Release $entry.SelectSingleNode('title').InnerText.Trim() $link
                }
            }
            return
        }
        'TheRARBG' {
            if (!$url) { $url = Join-Url $base ('get-posts/keywords:' + [uri]::EscapeDataString($query) + ':category:Movies:category:TV/') }
        }
    }
    $count = 0
    $seen = @{}
    for ($pageNumber = 1; $pageNumber -le $maxPages -and $count -lt $limit; $pageNumber++) {
        $pageUrl = $url
        if ($pageNumber -gt 1) {
            $separator = if ($url.Contains('?')) { '&' } else { '?' }
            $pageUrl = $url + $separator + 'page=' + $pageNumber
        }
        $page = Get-Page $pageUrl
        $found = 0
        foreach ($row in [regex]::Matches($page, '(?is)<tr\b[^>]*>(.*?)</tr>')) {
            $body = $row.Groups[1].Value
            $links = @(Get-Links $body)
            $magnet = $links | Where-Object { $_.Url.StartsWith('magnet:') } | Select-Object -First 1
            $item = $null
            switch ($ProviderName) {
                'TheRARBG' {
                    if ($row.Value -match 'class=["'']list-entry') {
                        $info = $links | Where-Object { $_.Title -and $_.Url -and !$_.Url.StartsWith('magnet:') } | Select-Object -First 1
                        if ($info) { $item = New-Release $info.Title (Join-Url $base $info.Url) }
                    }
                }
            }
            if ($null -ne $item -and !$seen.ContainsKey($item.Url)) {
                $seen[$item.Url] = $true; $found++; $count++; $item
                if ($count -ge $limit) { break }
            }
        }
        if (!$found -or $page -notmatch '(?i)(?:[?&]|&amp;)page=\d+') { break }
    }
}
function Convert-SparrowFilter([string]$Filter) {
    # Sparrow literal filters with <<variable>>, <<fix:d:2>>, <<max:s:8>>, etc.
    $result = ''; $position = 0
    foreach ($match in [regex]::Matches($Filter, '<<.*?>>')) {
        $result += [regex]::Escape($Filter.Substring($position, $match.Index - $position))
        $special = [regex]::Match($match.Value, '^<<(fix|max|max0):(s|d):(\d+)>>$')
        if ($special.Success) {
            $prefix = if ($special.Groups[2].Value -eq 'd') { '\d' } else { '.' }
            $number = [int]$special.Groups[3].Value
            if ($number -gt 1000) { throw 'Filter counts must be at most 1000.' }
            $quantifier = switch ($special.Groups[1].Value) { 'fix' { "$number" }; 'max' { "1,$number" }; 'max0' { "0,$number" } }
            $result += $prefix + '{' + $quantifier + '}'
        } else { $result += '.*' }
        $position = $match.Index + $match.Length
    }
    return '^' + $result + [regex]::Escape($Filter.Substring($position)) + '$'
}
function Test-ReleaseIdentity($Release, $Request, $Binding, [string]$ProviderName) {
    # Provider keyword searches can return a different film in the same franchise.
    # Check identity separately from quality/filter/episode options so irrelevant
    # titles never enter the picker, while useful alternate versions still do.
    if (($ProviderName -eq 'SubsPlease' -or $Release.Identified) -and $Request.scope -ne 'movie') { return $true }
    $title = [regex]::Replace($Release.Title, '^\s*(?:\[[^\]]+\]\s*)+', '')
    $keys = Get-TitleKeys $Request $Binding
    if ($Request.scope -eq 'movie') {
        if (!$Request.year -or $title -match '(?i)\bS\d+E\d+') { return $false }
        foreach ($year in [regex]::Matches($title, '(?<!\d)(?:19|20)\d{2}(?!\d)')) {
            if ([int]$year.Value -eq [int]$Request.year -and (Get-Key $title.Substring(0, $year.Index)) -in $keys) { return $true }
        }
        return $false
    }
    # A search title the user typed may be the start of the provider's name for the show, such as a shortened
    # romaji title; its releases are listed, though only exact titles (or a release filter) make them match.
    $typed = Get-Key ([string](Get-Option $Binding 'title'))
    $code = [regex]::Match($title, '(?i)(?<![a-z0-9])(?:S\d{1,2}E\d{1,3}|\d{1,2}x\d{1,3})(?!\d)')
    $absolute = [regex]::Match($title, '^(.+?)\s+-\s+\d{1,4}(?:v\d+)?(?=\s|\[|\(|$)')
    $prefix = if ($code.Success) { $title.Substring(0, $code.Index) } elseif ($Request.contentType -eq 'anime' -and $absolute.Success) { $absolute.Groups[1].Value } else { $null }
    if ($null -ne $prefix) { $prefix = Get-Key $prefix; return $prefix -in $keys -or ($typed -and $prefix.StartsWith($typed)) }
    return Test-Unnumbered $Release $Request $Binding $ProviderName
}
function Get-TitleKeys($Request, $Binding) {
    # The title, its original title, the search title and names found elsewhere (such as AniList's romaji).
    return @(@($Request.title, $Request.originalTitle, (Get-Option $Binding 'title')) + $script:AlternativeTitles | Where-Object { $_ } | ForEach-Object { Get-Key $_ } | Where-Object { $_ } | Select-Object -Unique)
}
function Test-Unnumbered($Release, $Request, $Binding, [string]$ProviderName) {
    # A release of this title without an episode number, such as a season pack or an OVA. Nothing can tell which
    # episodes it holds, so it is only downloaded when the user ticks it.
    if ($Request.scope -eq 'movie' -or $ProviderName -eq 'SubsPlease') { return $false }
    $title = [regex]::Replace($Release.Title, '^\s*(?:\[[^\]]+\]\s*)+', '')
    if ($title -match '(?i)(?<![a-z0-9])(?:S\d{1,2}E\d{1,3}|\d{1,2}x\d{1,3})(?!\d)' -or $title -match '^.+?\s+-\s+\d{1,4}(?:v\d+)?(?=\s|\[|\(|$)') { return $false }
    # "Title 05 [1080p].mkv": a single episode named without a dash. Ranges such as "01-12" are packs.
    $name = [regex]::Match($title, '^[^\[\(]*').Value
    if ($name -match '(?<![\d-])\s\d{1,4}(?:v\d+)?\s*$') { return $false }
    if ($Release.Identified) { return $true }
    $name = Get-Key $name
    if (!$name) { return $false }
    foreach ($key in Get-TitleKeys $Request $Binding) { if ($name.StartsWith($key)) { return $true } }
    return $false
}
function Test-Release($Release, $Request, $Episode, $Binding, [string]$ProviderName) {
    $filter = Get-Option $Binding 'filter'
    if ($filter -and ![regex]::IsMatch($Release.Title, (Convert-SparrowFilter $filter), [Text.RegularExpressions.RegexOptions]::IgnoreCase, [timespan]::FromSeconds(1))) { return $false }
    # A release filter the user wrote names the releases they want, so it stands in for the exact title.
    $filtered = [bool]$filter
    if ($ProviderName -eq 'SubsPlease') {
        $number = Get-AbsoluteNumber $Episode $Binding
        # Special episodes and fractional releases must not be mistaken for regular episodes.
        return $null -ne $number -and $Release.Episode -match '^\d+(?:v\d+)?$' -and [int]($Release.Episode -replace 'v\d+$', '') -eq $number
    }
    $title = [regex]::Replace($Release.Title, '^\s*(?:\[[^\]]+\]\s*)+', '')
    $keys = Get-TitleKeys $Request $Binding
    if ($Request.scope -eq 'movie') {
        return Test-ReleaseIdentity $Release $Request $Binding $ProviderName
    }
    $code = [regex]::Match($title, '(?i)(?<![a-z0-9])(?:S(\d{1,2})E(\d{1,3})|(\d{1,2})x(\d{1,3}))(?!\d)')
    if ($code.Success) {
        $s = if ($code.Groups[1].Success) { [int]$code.Groups[1].Value } else { [int]$code.Groups[3].Value }
        $e = if ($code.Groups[2].Success) { [int]$code.Groups[2].Value } else { [int]$code.Groups[4].Value }
        $prefix = $title.Substring(0, $code.Index)
        # EZTV names may add a year or country ("Fargo 2014", "The Office US"); its IMDb match is enough.
        $matchesTitle = $Release.Identified -or $filtered -or (Get-Key $prefix) -in $keys
        # Reject combined releases: they may contain episodes the request did not ask for.
        $suffix = $title.Substring($code.Index + $code.Length)
        return $matchesTitle -and $s -eq [int]$Episode.season -and $e -eq [int]$Episode.episode -and $suffix -notmatch '^(?i)(?:E\d|[-+]\s*(?:E)?\d)'
    }
    if ($Request.contentType -ne 'anime') { return $false }
    $absolute = [regex]::Match($title, '^(.+?)\s+-\s+(\d{1,4})(?:v\d+)?(?=\s|\[|\(|$)')
    $number = Get-AbsoluteNumber $Episode $Binding
    return $absolute.Success -and $null -ne $number -and [int]$absolute.Groups[2].Value -eq $number -and ($filtered -or (Get-Key $absolute.Groups[1].Value) -in $keys)
}
function Get-AbsoluteNumber($Episode, $Binding) {
    if ($null -ne (Get-Option $Binding 'episodeOffset')) { return [int]$Episode.episode + [int]$Binding.episodeOffset }
    if ($null -ne (Get-Option $Binding 'season')) {
        if ([int]$Binding.season -eq [int]$Episode.season) { return [int]$Episode.episode }
        return $null
    }
    if ($null -ne $Episode.absoluteEpisode) { return [int]$Episode.absoluteEpisode }
    if ([int]$Episode.season -eq 1) { return [int]$Episode.episode }
    return $null
}
function Get-Resolution($Release) {
    if ($Release.Resolution) { return [int]($Release.Resolution -replace '[^\d]', '') }
    $match = [regex]::Match($Release.Title, '(?i)(?<!\d)(2160|1080|720|480)p?\b')
    if ($match.Success) { return [int]$match.Groups[1].Value }
    return 0
}
function Get-Magnet($Release, [string]$ProviderName) {
    $magnet = $Release.Url
    if ($ProviderName -eq 'TheRARBG') {
        $page = Get-Page $Release.Url
        $link = Get-Links $page | Where-Object { $_.Url.StartsWith('magnet:') } | Select-Object -First 1
        if ($link) { $magnet = $link.Url }
        else {
            $match = [regex]::Match($page, '(?is)copy\(''(magnet:[^'']+)''\s*,\s*''#copy_magnet''\)')
            if (!$match.Success) { throw 'TheRARBG release page contains no magnet link.' }
            $magnet = [Net.WebUtility]::HtmlDecode($match.Groups[1].Value)
        }
    }
    if ($magnet -notmatch '^magnet:\?[^\r\n]*\bxt=urn:btih:(?:[0-9a-fA-F]{40}|[a-zA-Z2-7]{32})(?:&|$)') { throw 'The provider returned an invalid BitTorrent magnet.' }
    return $magnet
}
function Send-Torrents($Jobs, $Settings) {
    $mode = Get-Option $Settings 'downloader' 'magnet'
    if ($mode -eq 'magnet') {
        foreach ($job in $Jobs) { Start-Process -FilePath $job.Magnet | Out-Null }
        return 'Opened in your default torrent client; select the requested library folders in its download dialog.'
    }
    if ($mode -ne 'qbittorrent') { throw 'downloader must be magnet or qbittorrent.' }
    $config = Get-Option $Settings 'qbittorrent'
    $base = ([string](Get-Option $config 'url' 'http://localhost:8080')).TrimEnd('/')
    $uri = [uri]$base
    if ($uri.Scheme -notin @('http', 'https')) { throw 'Invalid qBittorrent URL.' }
    if (!$uri.IsLoopback -and $uri.Scheme -ne 'https') { throw 'Use HTTPS for a remote qBittorrent server.' }
    $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $headers = @{ Referer = $base + '/'; Origin = $uri.GetLeftPart([UriPartial]::Authority) }
    if (Get-Option $config 'username') {
        $reply = Invoke-WebRequest -UseBasicParsing -Uri ($base + '/api/v2/auth/login') -Method Post -Body @{ username = $config.username; password = (Get-Option $config 'password' '') } -WebSession $session -Headers $headers -TimeoutSec 15
        if ($reply.Content.Trim() -ne 'Ok.') { throw 'qBittorrent login failed. Check this plugin''s settings.json.' }
    }
    foreach ($job in $Jobs) {
        New-Item -ItemType Directory -Force -Path $job.Directory | Out-Null
        $body = @{ urls = $job.Magnet; savepath = $job.Directory; autoTMM = 'false' }
        # The original release name is retained for reliable library identification.
        $reply = Invoke-WebRequest -UseBasicParsing -Uri ($base + '/api/v2/torrents/add') -Method Post -Body $body -WebSession $session -Headers $headers -TimeoutSec 20
        if ($reply.Content.Trim() -ne 'Ok.') { throw 'qBittorrent did not accept the torrent.' }
    }
    return 'Queued in qBittorrent with the requested library folders.'
}
function Invoke-Acquisition([string]$ProviderName, $Request, $Settings) {
    if ($Request.version -ne 1 -or $Request.scope -notin @('movie', 'episode', 'season')) { throw 'Unsupported Watchroom acquisition request.' }
    $supported = @{ SubsPlease = @('anime'); EZTV = @('show'); TokyoToshokan = @('anime'); TheRARBG = @('show', 'movie') }
    if ($Request.contentType -notin $supported[$ProviderName] -or !$Request.title -or !$Request.targetDirectory) { throw 'The request has no supported content type, title or destination.' }
    $binding = Get-Binding $Request $Settings
    $episodes = @($Request.episodes | Where-Object { !($_.upcoming) })
    if ($Request.scope -ne 'movie' -and !$episodes.Count) { throw 'No aired missing episodes to acquire. Try again after the air date.' }
    $script:ProviderSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $releases = @(Get-Releases $ProviderName $Request $Settings $binding)
    if (!$releases.Count) { throw 'No releases found. The provider may be unavailable or its page format may have changed.' }
    $quality = [int](Get-Option $binding 'resolution' (Get-Option $Settings 'resolution' 1080))
    $jobs = @(); $missing = @(); $used = @{}; $usedIds = @{}
    $selected = @(Get-Option $Request 'selectedReleases' @() | Where-Object { $_ })
    if ((Get-Option $Request 'action') -eq 'acquire' -and !$selected.Count) { throw 'Select at least one release before downloading.' }
    # Season packs and specials the user ticked, alone or with episode releases: they go where the request's files belong.
    $packs = @(); $packTitles = @()
    foreach ($pack in @($releases | Where-Object { $_.Url -in $selected -and (Test-Unnumbered $_ $Request $binding $ProviderName) })) {
        if ($usedIds.ContainsKey($pack.Url)) { continue }
        $usedIds[$pack.Url] = $true; $packs += $pack.Url
        $magnet = Get-Magnet $pack $ProviderName
        $hash = [regex]::Match($magnet, '(?i)xt=urn:btih:([^&]+)').Groups[1].Value.ToLowerInvariant()
        if ($used.ContainsKey($hash)) { continue }
        $used[$hash] = $true; $packTitles += $pack.Title
        $destination = $Request.targetDirectory
        if ($Request.scope -eq 'season') {
            $destination = $Request.seasonDirectory
            if (!$destination) { $destination = Join-Path $Request.targetDirectory $(if ([int]$Request.season -eq 0) { 'Specials' } else { 'Season {0:00}' -f [int]$Request.season }) }
        }
        $jobs += [pscustomobject]@{ Magnet = $magnet; Directory = $destination }
    }
    if ($packs.Count -and $packs.Count -eq $selected.Count) {
        $message = Send-Torrents $jobs $Settings
        return @{ success = $true; message = "$($packTitles -join ', ') for $($Request.name). $message" }
    }
    $wanted = @($null)
    if ($Request.scope -ne 'movie') { $wanted = $episodes }
    foreach ($episode in $wanted) {
        $matches = @($releases | Where-Object { (!$selected.Count -or ($_.Url -in $selected -and $_.Url -notin $packs)) -and (Test-Release $_ $Request $episode $binding $ProviderName) -and ($quality -eq 0 -or (Get-Resolution $_) -eq $quality) } | Sort-Object Title, Url)
        if (!$matches.Count) { $missing += $(if ($null -eq $episode) { $Request.name } else { 'S{0:00}E{1:00}' -f [int]$episode.season, [int]$episode.episode }); continue }
        $magnet = Get-Magnet $matches[0] $ProviderName
        $usedIds[$matches[0].Url] = $true
        $hash = [regex]::Match($magnet, '(?i)xt=urn:btih:([^&]+)').Groups[1].Value.ToLowerInvariant()
        if ($used.ContainsKey($hash)) { continue }
        $used[$hash] = $true
        $destination = $Request.targetDirectory
        if ($Request.scope -eq 'season') {
            $destination = $Request.seasonDirectory
            if (!$destination) { $destination = Join-Path $Request.targetDirectory $(if ([int]$episode.season -eq 0) { 'Specials' } else { 'Season {0:00}' -f [int]$episode.season }) }
        }
        $jobs += [pscustomobject]@{ Magnet = $magnet; Directory = $destination }
    }
    if ($selected.Count -and @($selected | Where-Object { !$usedIds.ContainsKey($_) }).Count) { throw 'A selected release no longer matches these episodes or options. Refresh the list and select again.' }
    if (!$jobs.Count) { throw "No matching releases at the configured resolution ($quality). Check title, season/absolute numbering, and filter in settings.json." }
    $message = Send-Torrents $jobs $Settings
    $message = "$($jobs.Count) release(s) for $($Request.name). $message"
    if ($missing.Count) { $message += $(if ($selected.Count) { ' Not selected: ' } else { ' Not found: ' }) + ($missing -join ', ') + '.' }
    $upcoming = @($Request.episodes | Where-Object { $_.upcoming }).Count
    if ($upcoming) { $message += " Skipped $upcoming upcoming episode(s)." }
    return @{ success = $true; message = $message }
}
function Get-SuggestedFilter([string]$Title) {
    $value = [regex]::Replace($Title, '(?i)\[[a-f0-9]{8}\]', '[<<checksum>>]')
    $value = [regex]::Replace($value, '(?i)S\d{1,2}E\d{1,3}|\d{1,2}x\d{1,3}', '<<episode_number>>')
    $value = [regex]::Replace($value, '(?<= - )\d{1,4}(?:v\d+)?(?=\s|\[|\(|$)', '<<episode_number>>')
    return $value
}
function Invoke-Browse([string]$ProviderName, $Request, $Settings) {
    $script:ProviderSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $binding = Get-Binding $Request $Settings
    if ($Request.action -eq 'search' -and $ProviderName -in @('SubsPlease','EZTV')) {
        $text = [string](Get-Option $binding 'title' $Request.title)
        $query = Get-Key $text
        if (!$query) { throw 'Enter a title to search for.' }
        if ($ProviderName -eq 'EZTV') {
            # IMDb's ranking is kept: EZTV looks shows up by IMDb ID.
            $entries = @(Find-ImdbSeries $text | Select-Object -First 100)
            $choices = @($entries | ForEach-Object { @{ id=$_.Url; title=$_.Title; detail='EZTV via IMDb'; matches=$true } })
            return @{ success=$true; stage='shows'; choices=$choices; message="Choose a show ($($choices.Count) found)." }
        }
        $entries = @(Get-CatalogEntries $ProviderName $Settings | Where-Object { (Get-Key $_.Title).Contains($query) } | Sort-Object @{Expression={ if ((Get-Key $_.Title) -eq $query) { 0 } else { 1 } }},Title | Select-Object -First 100)
        $choices = @($entries | ForEach-Object { @{ id=$_.Url; title=$_.Title; detail=$ProviderName; matches=$true } })
        return @{ success=$true; stage='shows'; choices=$choices; message="Choose a provider title ($($choices.Count) found)." }
    }
    $releases = @(Get-Releases $ProviderName $Request $Settings $binding | Where-Object { Test-ReleaseIdentity $_ $Request $binding $ProviderName })
    $quality = [int](Get-Option $binding 'resolution' (Get-Option $Settings 'resolution' 1080))
    # Without the filter, to name the requested episode a release provides even when it isn't downloadable as is.
    $loose = $binding | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    $loose.PSObject.Properties.Remove('filter')
    $choices = @(
        foreach ($release in $releases) {
            $wanted = @($null)
            if ($Request.scope -ne 'movie') { $wanted = @($Request.episodes | Where-Object { !$_.upcoming }) }
            $episodeName = $null; $match = $false
            foreach ($episode in $wanted) {
                if ((Test-Release $release $Request $episode $binding $ProviderName) -and ($quality -eq 0 -or (Get-Resolution $release) -eq $quality)) {
                    $match=$true; $episodeName=if ($null -eq $episode) { 'Movie' } else { 'S{0:00}E{1:00}' -f [int]$episode.season,[int]$episode.episode }; break
                }
            }
            if (!$match -and $Request.scope -ne 'movie') {
                foreach ($episode in $wanted) {
                    if (Test-Release $release $Request $episode $loose $ProviderName) { $episodeName = 'S{0:00}E{1:00}' -f [int]$episode.season,[int]$episode.episode; break }
                }
            }
            $resolution = Get-Resolution $release
            $assignable = !$match -and !$episodeName -and (Test-Unnumbered $release $Request $binding $ProviderName)
            $detail = if ($match) { "Requested: $episodeName" }
                elseif ($assignable) { $(if ($release.Title -match '(?i)\b(?:OVA|OAD|ONA|Special|SP)\b') { 'Special' } else { 'Season pack or batch' }) + ' with no episode number: tick it to download it' }
                elseif ($episodeName -and $quality -ne 0 -and $resolution -ne $quality) { "$episodeName in another quality (selected ${quality}p)" }
                elseif ($episodeName) { "$episodeName, left out by the release filter" }
                elseif ($Request.scope -ne 'movie' -and $release.Title -match '(?i)(?<![a-z0-9])(?:S\d{1,2}E\d{1,3}|\d{1,2}x\d{1,3})(?!\d)') { 'Not one of the missing episodes' }
                elseif ($quality -ne 0 -and $resolution -ne $quality) { "Different quality (selected ${quality}p)" }
                elseif ($Request.scope -eq 'movie') { 'Does not match the release filter' }
                else { 'Different episode or release filter' }
            if ($resolution) { $detail += " | ${resolution}p" }
            $title = if ($ProviderName -eq 'SubsPlease') { "$($release.Title) (${resolution}p)" } else { $release.Title }
            @{id=$release.Url; title=$title; detail=$detail; matches=$match; assignable=$assignable; episode=$episodeName; resolution=$resolution; suggestedFilter=$(if ($ProviderName -ne 'SubsPlease') { Get-SuggestedFilter $release.Title } else { '' })}
        }
    )
    $choices = @($choices | Sort-Object @{Expression={$_.matches};Descending=$true}, @{Expression={[bool]$_.episode};Descending=$true}, @{Expression={$_.episode}}, @{Expression={$_.title}})
    $message = if ($choices.Count) { "Select releases to download ($(@($choices | Where-Object { $_.matches }).Count) match)." }
        else { "No releases found for $($Request.name). Try another search title or provider." }
    return @{ success=$true; stage='releases'; choices=$choices; message=$message }
}

if (!$LibraryOnly) {
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
    [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
    try {
        if (!$Provider) { throw 'A provider argument is required.' }
        $request = [Console]::In.ReadToEnd().TrimStart([char]0xfeff) | ConvertFrom-Json
        $settingsPath = Join-Path $env:WATCHROOM_PLUGIN_DIR 'settings.json'
        $settings = if (Test-Path -LiteralPath $settingsPath) { Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { [pscustomobject]@{} }
        $action = Get-Option $request 'action' 'acquire'
        if ($action -in @('search','releases')) { Invoke-Browse $Provider $request $settings | ConvertTo-Json -Compress -Depth 8 }
        elseif (!$action -or $action -eq 'acquire') { Invoke-Acquisition $Provider $request $settings | ConvertTo-Json -Compress -Depth 5 }
        else { throw 'Unknown plugin action.' }
        exit 0
    } catch {
        # Do not echo request URLs or HTTP bodies: a configured downloader can contain credentials.
        $message = if ($_.Exception -is [Net.WebException]) { 'Provider or downloader HTTP request failed. Check availability and downloader settings.' } else { $_.Exception.Message }
        @{ success = $false; message = $message } | ConvertTo-Json -Compress
        exit 1
    }
}
