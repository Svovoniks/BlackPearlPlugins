param([string]$OutputDirectory = (Join-Path $PSScriptRoot '../artifacts/sparrow-checks'))
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
. (Join-Path $repo 'plugins/sparrow-runtime/acquire.ps1') -LibraryOnly
# The real page fetcher, kept before the fixture replaces it.
$realGetPage = ${function:Get-Page}
$script:checks = 0
function Check([bool]$Condition, [string]$Name) {
    if (!$Condition) { throw "FAIL: $Name" }
    $script:checks++; Write-Output "PASS: $Name"
}
function Fails([scriptblock]$Action, [string]$Pattern, [string]$Name) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_.Exception.Message }
    Check ($null -ne $caught -and $caught -match $Pattern) $Name
}
function Json([string]$Value) { ConvertFrom-Json $Value }
$episode = Json '{"season":1,"episode":2,"upcoming":false,"absoluteEpisode":null}'
$request = Json '{"version":1,"scope":"episode","contentType":"anime","title":"Test & Show","originalTitle":null,"name":"Test Show S01E02","year":2024,"targetDirectory":"D:\\Anime\\Test Show\\Season 01","seasonDirectory":null,"episodes":[]}'
$request.episodes = @($episode)
$empty = Json '{}'
$hash = '0123456789abcdef0123456789abcdef01234567'
$magnet = 'magnet:?xt=urn:btih:' + $hash + '&dn=Test%20Show'
$htmlMagnet = $magnet.Replace('&', '&amp;')
$script:pages = @{}
$script:visited = New-Object Collections.Generic.List[string]
function Get-Page([string]$Url) {
    $script:visited.Add($Url)
    if (!$script:pages.ContainsKey($Url)) { throw "Unexpected fixture URL: $Url" }
    return $script:pages[$Url]
}
$script:ProviderSession = New-Object Microsoft.PowerShell.Commands.WebRequestSession
# AniList's romaji titles, offline.
$script:anilist = @{}
function Get-AlternativeTitles($Request) { $value = $script:anilist[[string]$Request.title]; if ($value) { return , $value }; return @() }

# Captured markup structures from Sparrow, with synthetic titles and hashes.
$script:pages['https://subsplease.org/shows/'] = '<div class="all-shows-link"><a href="test/" title="Test &amp; Show">Test &amp; Show</a></div>'
$script:pages['https://subsplease.org/shows/test/'] = '<div id="show-release-table" sid="42"></div>'
$script:pages['https://subsplease.org/api/?f=show&tz=UTC&sid=42'] = '{"episode":{"Test & Show - 02":{"downloads":[{"res":"1080","magnet":"' + $magnet + '"},{"res":"720","magnet":"' + $magnet + '"}]},"Test & Show - 02.5":{"downloads":[{"res":"1080","magnet":"' + $magnet + '"}]}}}'
$subs = @(Get-Releases 'SubsPlease' $request $empty $null)
Check ($subs.Count -eq 3 -and $subs[0].Url -eq $magnet) 'SubsPlease resolves the catalog, relative show link, SID and API downloads'
Check ((Test-Release $subs[0] $request $episode $null 'SubsPlease') -and !(Test-Release $subs[2] $request $episode $null 'SubsPlease')) 'SubsPlease matches regular episode numbers without treating fractional specials as episodes'
Check ((Get-Resolution $subs[0]) -eq 1080) 'SubsPlease retains the selected API resolution'
Check ($subs[0].Episode -eq '02' -and $subs[2].Episode -eq '02.5' -and $subs[0].Title -eq 'Test & Show - 02') 'SubsPlease extracts episode numbers from the current full-title API keys'

$tvRequest = Json '{"version":1,"scope":"episode","contentType":"show","title":"Test Show","originalTitle":null,"name":"Test Show S01E02","year":2024,"targetDirectory":"D:\\Shows\\Test Show\\Season 01","episodes":[]}'
$tvRequest.episodes = @($episode)
# EZTV's HTML pages are behind Cloudflare; its JSON API takes the IMDb ID as digits only.
$tvRequest | Add-Member -NotePropertyName providerIds -NotePropertyValue (Json '{"imdb":"tt0001234"}')
$eztvApi = 'https://eztvx.to/api/get-torrents?imdb_id=0001234&limit=100&page='
$script:pages[$eztvApi + '1'] = '{"imdb_id":"0001234","torrents_count":2,"page":1,"torrents":[{"title":"Test Show S01E02 1080p WEB EZTV","magnet_url":"' + $magnet + '"},{"title":"Test Show 2024 S01E03 1080p WEB EZTV","magnet_url":"' + $magnet.Replace($hash, ('c' * 40)) + '"}]}'
$eztv = @(Get-Releases 'EZTV' $tvRequest $empty $null)
Check ($eztv.Count -eq 2 -and $eztv[0].Title -eq 'Test Show S01E02 1080p WEB' -and $eztv[0].Url -eq $magnet -and $eztv[0].Identified) 'EZTV reads the API by numeric IMDb ID and strips the EZTV title suffix'
Check ((Test-Release $eztv[1] $tvRequest (Json '{"season":1,"episode":3}') $null 'EZTV')) 'EZTV releases identified by IMDb ID match despite a year in the release name'
$script:pages[$eztvApi + '1'] = '{"torrents_count":1097972,"page":1,"torrents":[{"title":"Other Show S01E02 EZTV","magnet_url":"' + $magnet + '"}]}'
Fails { Get-Releases 'EZTV' $tvRequest $empty $null } 'did not return results' 'An EZTV response for another show (the unfiltered feed) is rejected'
$noIds = $tvRequest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$noIds.providerIds = $null
$script:pages['https://v3.sg.media-imdb.com/suggestion/x/Test%20Show.json'] = '{"d":[{"id":"tt0001234","l":"Test Show","qid":"tvSeries","y":2024},{"id":"tt0009999","l":"Test Show","qid":"tvSeries","y":1990},{"id":"tt0005555","l":"Test Show","qid":"movie","y":2024}]}'
Check ((Get-ImdbNumber $noIds $null) -eq '0001234') 'Without an IMDb ID, EZTV finds the series on IMDb by exact title and year'
$noIds.year = $null
Fails { Get-ImdbNumber $noIds $null } 'IMDb ID' 'Ambiguous IMDb series titles require a year, binding or search'
Check ((Get-ImdbNumber $noIds (Json '{"url":"https://www.imdb.com/title/tt0009999/"}')) -eq '0009999') 'A chosen IMDb show takes precedence over the request'
$script:pages[$eztvApi + '1'] = '{"imdb_id":"0001234","torrents_count":1,"page":1,"torrents":[{"title":"Test Show S01E02 1080p WEB EZTV","magnet_url":"' + $magnet + '"}]}'
$eztv = @(Get-Releases 'EZTV' $tvRequest $empty $null)

# TokyoToshokan's search.php is behind Cloudflare; its RSS feed is not, but holds only recent
# results, so each missing episode is searched too.
$tokyo = 'https://www.tokyotosho.info/rss.php?filter=1&terms=Test%20%26%20Show'
function Feed([string[]]$Items) { '<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>t</title>' + ($Items -join '') + '</channel></rss>' }
function FeedItem([string]$Title, [string]$Link) { "<item><category>Anime</category><title>$Title</title><description><![CDATA[<a href=`"https://files.invalid/a.torrent`">Torrent Link</a><br />`n<a href=`"$($Link.Replace('&', '&amp;'))`">Magnet Link</a><br />]]></description></item>" }
$item2 = FeedItem '[Group] Test &amp; Show - 02 (1080p) [ABCDEF12].mkv' $magnet
$item3 = FeedItem '[Group] Test &amp; Show - 03 (1080p) [ABCDEF12].mkv' $magnet.Replace($hash, ('a' * 40))
$script:pages[$tokyo] = Feed @($item3)
$script:pages[$tokyo + '%2002'] = Feed @($item2, $item3)
$releases = @(Get-Releases 'TokyoToshokan' $request $empty $null)
Check ($releases.Count -eq 2 -and $script:visited.Contains($tokyo + '%2002')) 'TokyoToshokan encodes queries, searches each missing episode and removes duplicates'
$releases = @($releases | Sort-Object Title)
Check ($releases[0].Title.Contains('Test & Show') -and $releases[0].Url -eq $magnet -and (Test-Release $releases[0] $request $episode $null 'TokyoToshokan')) 'TokyoToshokan decodes titles and CDATA magnets and matches anime absolute release numbers'
Check (!(Test-Release $releases[1] $request $episode $null 'TokyoToshokan')) 'Anime matching excludes a different episode'

# Most anime releases use the romaji title; season packs and OVAs have no episode number.
$english = Json '{"version":1,"scope":"episode","contentType":"anime","title":"English Name: Part!","originalTitle":null,"name":"English Name Part! S02E13","year":2020,"season":2,"targetDirectory":"D:\\Anime\\English\\Season 02","episodes":[{"season":2,"episode":13,"upcoming":false,"absoluteEpisode":null}]}'
$script:anilist['English Name: Part!'] = 'Romaji no Namae shiteshimatta' + [char]0x2026
$feedEnglish = 'https://www.tokyotosho.info/rss.php?filter=1&terms=English%20Name%3A%20Part!'
$feedRomaji = 'https://www.tokyotosho.info/rss.php?filter=1&terms=Romaji%20no%20Namae%20shiteshimatta'
$script:pages[$feedEnglish] = Feed @((FeedItem '[Packs] English Name - Part! [Season 1 + 2] [BD 1080p]' $magnet.Replace($hash, ('d' * 40))))
$script:pages[$feedRomaji] = Feed @(
    (FeedItem '[Group] Romaji no Namae shiteshimatta... X - OVA [1080p][ABCDEF12].mkv' $magnet.Replace($hash, ('e' * 40)))
    (FeedItem '[Other] Romaji no Namae Shiteshimatta X 01 [1080p][ABCDEF12].mkv' $magnet.Replace($hash, ('f' * 40)))
    (FeedItem '[Group] Romaji no Namae shiteshimatta - 05 [1080p][ABCDEF12].mkv' $magnet.Replace($hash, ('1' * 40)))
    (FeedItem '[Group] Unrelated Show - OVA [1080p][ABCDEF12].mkv' $magnet.Replace($hash, ('2' * 40))))
# Searches without results return only closing tags.
foreach ($term in @('English%20Name%3A%20Part!%20S02E13', 'Romaji%20no%20Namae%20shiteshimatta%20S02E13')) { $script:pages['https://www.tokyotosho.info/rss.php?filter=1&terms=' + $term] = "</channel>`n</rss>" }
$browsed = Invoke-Browse 'TokyoToshokan' ($english | ConvertTo-Json -Depth 8 | ConvertFrom-Json | Add-Member -NotePropertyName action -NotePropertyValue 'releases' -PassThru) $empty
$assignable = @($browsed.choices | Where-Object { $_.assignable })
Check ($script:visited.Contains($feedRomaji) -and $browsed.choices.Count -eq 3) 'TokyoToshokan also searches the romaji title, lists its releases and tolerates empty feeds'
Check ($assignable.Count -eq 2 -and @($assignable | Where-Object { $_.title -match 'OVA' -and $_.detail -match '^Special' }).Count -eq 1 -and !@($browsed.choices | Where-Object { $_.matches }).Count) 'Season packs and OVAs of the title are offered for an explicit tick, never as matches'
Check (!@($browsed.choices | Where-Object { $_.title -match 'X 01|Unrelated' }).Count) 'Single episodes named without a dash and other titles are not offered as packs'
$packRequest = $english | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$packRequest | Add-Member -NotePropertyName action -NotePropertyValue 'acquire'
$packRequest | Add-Member -NotePropertyName selectedReleases -NotePropertyValue @($magnet.Replace($hash, ('e' * 40)))
$script:packJobs = $null
$realSend = ${function:Send-Torrents}
${function:Send-Torrents} = { param($Jobs, $Settings) $script:packJobs = @($Jobs); return 'Fixture handoff.' }
$result = Invoke-Acquisition 'TokyoToshokan' $packRequest $empty
Check ($result.success -and $script:packJobs.Count -eq 1 -and $script:packJobs[0].Directory -eq $english.targetDirectory -and $script:packJobs[0].Magnet -match ('e' * 40)) 'A ticked OVA downloads on its own to the request''s folder'
$packRequest.selectedReleases = @($magnet.Replace($hash, ('e' * 40)), $magnet.Replace($hash, ('d' * 40)))
$result = Invoke-Acquisition 'TokyoToshokan' $packRequest $empty
Check ($result.success -and $script:packJobs.Count -eq 2 -and @($script:packJobs | Where-Object { $_.Directory -eq $english.targetDirectory }).Count -eq 2) 'Several ticked packs and specials download together'
$packRequest.selectedReleases = @($magnet.Replace($hash, ('e' * 40)), $magnet.Replace($hash, ('1' * 40)))
Fails { Invoke-Acquisition 'TokyoToshokan' $packRequest $empty } 'no longer matches' 'A pack does not make a ticked release of another episode downloadable'
# A season pack ticked together with a release of a requested episode downloads both.
$script:pages[$tokyo + '%2002'] = Feed @($item2, $item3, (FeedItem '[Group] Test &amp; Show [Batch 01-12] (1080p)' $magnet.Replace($hash, ('c' * 40))))
$mixed = $request | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$mixed | Add-Member -NotePropertyName action -NotePropertyValue 'acquire'
$mixed | Add-Member -NotePropertyName selectedReleases -NotePropertyValue @($magnet, $magnet.Replace($hash, ('c' * 40)))
$result = Invoke-Acquisition 'TokyoToshokan' $mixed $empty
Check ($result.success -and $script:packJobs.Count -eq 2 -and $script:packJobs[0].Magnet -match ('c' * 40) -and $script:packJobs[1].Magnet -match $hash) 'A season pack downloads together with a ticked episode release'
$script:pages[$tokyo + '%2002'] = Feed @($item2, $item3)
${function:Send-Torrents} = $realSend
$script:anilist.Clear()
$script:pages['https://therarbg.com/get-posts/keywords:Test%20%26%20Show:category:Movies:category:TV/'] ='<tr class="list-entry"><td><a href="/post/a/">A</a></td></tr><tr class="list-entry"><td><a href="/post/b/">B</a></td></tr>'
$bounded = @(Get-Releases 'TheRARBG' $request (Json '{"limit":1}') $null)
Check ($bounded.Count -eq 1) 'Search results honor the configured limit'

$rarbg = 'https://therarbg.com/get-posts/keywords:Test%20Show:category:Movies:category:TV/'
$script:pages[$rarbg] = '<table><tr class="list-entry odd"><td><a href="/post/test/" title="Detail">Test.Show.S01E02.1080p.WEB</a></td><td class="sizeCell">1.2 GB</td></tr></table>'
$script:pages['https://therarbg.com/post/test/'] = '<button onclick="copy(''' + $htmlMagnet + ''',''#copy_magnet'')">Copy</button>'
$rar = @(Get-Releases 'TheRARBG' $tvRequest $empty $null)
Check ($rar.Count -eq 1 -and $rar[0].Url -eq 'https://therarbg.com/post/test/') 'TheRARBG resolves search entries to detail pages'
Check ((Get-Magnet $rar[0] 'TheRARBG') -eq $magnet) 'TheRARBG extracts and unescapes the copy-button magnet'
Check ((Get-Magnet $eztv[0] 'EZTV') -eq $magnet) 'Direct provider magnets pass validation'
Fails { Get-Magnet (New-Release 'Bad' 'https://bad.invalid/') 'EZTV' } 'invalid.*magnet' 'Non-magnet handoffs are rejected'

Check ((Test-Release $eztv[0] $tvRequest $episode $null 'EZTV')) 'TV releases match exact title, season and episode'
foreach ($title in @('Other.Show.S01E02.1080p', 'Test.Show.S02E02.1080p', 'Test.Show.S01E03.1080p', 'Test.Show.S01E020.1080p', 'Test.Show.S01E02E03.1080p', 'Test.Show.S01E02-03.1080p')) {
    Check (!(Test-Release (New-Release $title $magnet) $tvRequest $episode $null 'EZTV')) "TV matching excludes $title"
}
$second = Json '{"season":2,"episode":2,"upcoming":false,"absoluteEpisode":null}'
Check (!(Test-Release $releases[0] $request $second $null 'TokyoToshokan')) 'Later anime seasons do not guess unqualified episode numbers'
Check ((Test-Release $releases[0] $request $second (Json '{"season":2}') 'TokyoToshokan')) 'Explicit season binding enables restarted anime numbering'
Check (!(Test-Release $releases[0] $request $episode (Json '{"season":2}') 'TokyoToshokan')) 'A season binding excludes requests for another season'
Check ((Test-Release $releases[1] $request $second (Json '{"episodeOffset":1}') 'TokyoToshokan')) 'Anime episode offsets map continuous numbering'
$second.absoluteEpisode = 3
Check ((Test-Release $releases[1] $request $second $null 'TokyoToshokan')) 'Watchroom absoluteEpisode takes precedence over season-relative numbering'
$binding = Json '{"filter":"[Group] Test & Show - <<fix:d:2>> (1080p) [<<checksum>>].mkv"}'
Check ((Test-Release $releases[0] $request $episode $binding 'TokyoToshokan')) 'Sparrow fixed-digit and variable filters retain release-group restrictions'
Check (!(Test-Release (New-Release $releases[0].Title.Replace('[Group]', '[Other]') $magnet) $request $episode $binding 'TokyoToshokan')) 'Release filters exclude other groups'
Check ([regex]::IsMatch('A-123', (Convert-SparrowFilter 'A-<<max:d:3>>')) -and ![regex]::IsMatch('A-1234', (Convert-SparrowFilter 'A-<<max:d:3>>'))) 'Sparrow bounded placeholders keep their length limits'
Check ([regex]::IsMatch('A-', (Convert-SparrowFilter 'A-<<max0:d:3>>'))) 'Sparrow max0 placeholders permit empty values'

$movie = Json '{"version":1,"scope":"movie","contentType":"movie","title":"Test Movie","originalTitle":null,"year":2024,"name":"Test Movie (2024)","targetDirectory":"D:\\Movies","episodes":[]}'
Check ((Test-Release (New-Release 'Test.Movie.2024.1080p.WEB' $magnet) $movie $null $null 'TheRARBG')) 'Movies require the requested title and year'
Check (!(Test-Release (New-Release 'Test.Movie.2023.1080p.WEB' $magnet) $movie $null $null 'TheRARBG')) 'Movie remakes from a different year are excluded'
Fails { Get-CatalogShow @([pscustomobject]@{Title='Unknown';Url='https://invalid/'}) $request $null } 'exact title' 'Catalog misses do not silently choose a similar show'
Fails { Get-CatalogShow @([pscustomobject]@{Title='Test Show';Url='https://invalid/1'},[pscustomobject]@{Title='Test Show';Url='https://invalid/2'}) $tvRequest $null } 'exact title' 'Ambiguous catalog matches require a binding'

# Exercise the real qBittorrent handoff with an HTTP transport stub.
$script:calls = New-Object Collections.Generic.List[object]
$script:reply = 'Ok.'
function Invoke-WebRequest { param($Uri, $Method, $Body, $WebSession, $Headers, $TimeoutSec, [switch]$UseBasicParsing)
    $script:calls.Add([pscustomobject]@{ Uri=$Uri; Body=$Body; Session=$WebSession; Headers=$Headers })
    return [pscustomobject]@{ Content=$script:reply }
}
$settings = Json '{"downloader":"qbittorrent","qbittorrent":{"url":"http://localhost:8080","username":"test","password":"test"}}'
$target = Join-Path $OutputDirectory 'destination'
Send-Torrents @([pscustomobject]@{Magnet=$magnet;Directory=$target}) $settings | Out-Null
Check ($script:calls.Count -eq 2 -and $script:calls[0].Uri.EndsWith('/auth/login') -and $script:calls[1].Body.savepath -eq $target -and $script:calls[1].Body.autoTMM -eq 'false') 'qBittorrent authenticates and receives the exact destination with automatic management disabled'
Check ([object]::ReferenceEquals($script:calls[0].Session, $script:calls[1].Session) -and $script:calls[1].Headers.Origin -eq 'http://localhost:8080') 'qBittorrent retains authentication cookies and sends origin headers'
$script:reply = 'Fails.'
Fails { Send-Torrents @([pscustomobject]@{Magnet=$magnet;Directory=$target}) $settings } 'login failed' 'Rejected qBittorrent authentication reports failure'
$script:calls.Clear()
Fails { Send-Torrents @() (Json '{"downloader":"qbittorrent","qbittorrent":{"url":"http://remote.invalid:8080"}}') } 'HTTPS' 'Remote qBittorrent credentials require HTTPS'
Check ($script:calls.Count -eq 0) 'Insecure remote downloader is rejected before any HTTP request'

# Test request orchestration without opening a torrent client.
$script:jobs = @()
function Send-Torrents($Jobs, $Settings) { $script:jobs = @($Jobs); return 'Fixture handoff.' }
$result = Invoke-Acquisition 'SubsPlease' $request $empty
Check ($result.success -and $script:jobs.Count -eq 1 -and $script:jobs[0].Directory -eq $request.targetDirectory) 'Episode acquisition queues one release at the preferred resolution'
$request.scope = 'season'; $request.targetDirectory = Join-Path $OutputDirectory 'show'
$request.episodes = @($episode, (Json '{"season":1,"episode":3,"upcoming":false}'), (Json '{"season":1,"episode":4,"upcoming":true}'))
$result = Invoke-Acquisition 'SubsPlease' $request $empty
Check ($result.success -and $result.message -match 'Not found: S01E03' -and $result.message -match 'Skipped 1 upcoming' -and $script:jobs[0].Directory -eq (Join-Path $request.targetDirectory 'Season 01')) 'Season acquisition uses the season destination and reports missing and upcoming episodes'
$request.seasonDirectory = Join-Path $OutputDirectory 'flat-show'
Invoke-Acquisition 'SubsPlease' $request $empty | Out-Null
Check ($script:jobs[0].Directory -eq $request.seasonDirectory) 'Existing flat season directories are preserved'
$request.episodes = @((Json '{"season":1,"episode":4,"upcoming":true}'))
Fails { Invoke-Acquisition 'SubsPlease' $request $empty } 'No aired' 'Upcoming-only requests perform no provider lookup'
$script:pages['https://therarbg.com/get-posts/keywords:Test%20Movie:category:Movies:category:TV/'] = '<tr class="list-entry"><td><a href="/post/movie/">Test.Movie.2024.1080p.WEB</a></td><td class="sizeCell">1 GB</td></tr>'
$script:pages['https://therarbg.com/post/movie/'] = '<a href="' + $htmlMagnet + '">Magnet</a>'
$result = Invoke-Acquisition 'TheRARBG' $movie $empty
Check ($result.success -and $script:jobs.Count -eq 1 -and $script:jobs[0].Directory -eq $movie.targetDirectory) 'Movie acquisition queues a matching release in the movie library'

# Interactive browsing is read-only. Selections are revalidated before handoff.
$interactive = $request | ConvertTo-Json -Depth 10 | ConvertFrom-Json
$interactive.scope = 'episode'; $interactive.title = 'Test & Show'; $interactive.episodes = @($episode)
$interactive | Add-Member -NotePropertyName action -NotePropertyValue 'search'
$interactive | Add-Member -NotePropertyName options -NotePropertyValue (Json '{"query":"Test","resolution":1080,"filter":""}')
$interactive | Add-Member -NotePropertyName selectedReleases -NotePropertyValue @()
$oldJobs = $script:jobs
$browsed = Invoke-Browse 'SubsPlease' $interactive $empty
Check ($browsed.stage -eq 'shows' -and $browsed.choices.Count -eq 1 -and $browsed.choices[0].id -eq 'https://subsplease.org/shows/test/') 'Interactive catalog search offers partial title matches for the user to choose'
Check ([object]::ReferenceEquals($oldJobs, $script:jobs)) 'Catalog browsing performs no downloader handoff'
$interactive.action = 'releases'; $interactive.options = Json '{"query":"Test & Show","sourceUrl":"https://subsplease.org/shows/test/","resolution":1080,"filter":""}'
$browsed = Invoke-Browse 'SubsPlease' $interactive $empty
Check ($browsed.stage -eq 'releases' -and $browsed.choices.Count -eq 3 -and @($browsed.choices | Where-Object { $_.matches }).Count -eq 1) 'Release browsing labels only the requested episode at the selected resolution as matching'
Check ([object]::ReferenceEquals($oldJobs, $script:jobs)) 'Release previews perform no downloader handoff'
$interactive.action = 'search'; $interactive.options = Json '{"query":"Test & Show","resolution":1080,"filter":""}'
$browsed = Invoke-Browse 'TokyoToshokan' $interactive $empty
Check ($browsed.stage -eq 'releases' -and $browsed.choices.Count -eq 2 -and $browsed.choices[0].suggestedFilter -match '<<episode_number>>' -and $browsed.choices[0].suggestedFilter -match '<<checksum>>') 'Non-catalog providers offer release choices and an editable Sparrow filter template'
$interactive.options = Json '{"query":"Test & Show","resolution":1080,"filter":"[Other] <<anything>>"}'
$browsed = Invoke-Browse 'TokyoToshokan' $interactive $empty
Check (@($browsed.choices | Where-Object { $_.matches }).Count -eq 0) 'Release previews apply the chosen release-group filter'
$interactive.action = 'acquire'; $interactive.options = Json '{"query":"Test & Show","resolution":1080,"filter":""}'
Fails { Invoke-Acquisition 'TokyoToshokan' $interactive $empty } 'Select at least one' 'Interactive acquisition requires an explicit release selection'
$interactive.selectedReleases = @($releases[0].Url)
$result = Invoke-Acquisition 'TokyoToshokan' $interactive $empty
Check ($result.success -and $script:jobs.Count -eq 1 -and $script:jobs[0].Magnet -eq $releases[0].Url) 'Confirmation queues only the selected matching release'
$interactive.selectedReleases = @($releases[1].Url)
Fails { Invoke-Acquisition 'TokyoToshokan' $interactive $empty } 'no longer matches' 'A release for another episode cannot bypass matching by being explicitly selected'
$interactive.selectedReleases = @('magnet:?xt=urn:btih:' + ('b' * 40))
Fails { Invoke-Acquisition 'TokyoToshokan' $interactive $empty } 'no longer matches' 'Stale release selections fail before any handoff'
$interactive.options = Json '{"query":"New title","sourceUrl":null,"episodeOffset":null,"providerSeason":null}'
$bound = Get-Binding $interactive (Json '{"titles":{"Test & Show":{"title":"Old title","url":"https://old.invalid/","season":2,"episodeOffset":12,"filter":"saved"}}}')
Check ($bound.title -eq 'New title' -and !$bound.url -and $null -eq $bound.season -and $null -eq $bound.episodeOffset -and $bound.filter -eq 'saved') 'Interactive source and numbering changes override saved bindings without discarding unrelated settings'

# Broad provider results must not fill a movie picker with other franchise entries.
$spider = Json '{"version":1,"scope":"movie","contentType":"movie","title":"Spider-Man: No Way Home","originalTitle":null,"year":2021,"name":"Spider-Man No Way Home (2021)","targetDirectory":"D:\\Movies","episodes":[],"action":"releases","options":{"query":"Spider-Man","sourceUrl":"https://therarbg.com/fixture-movie-search/","resolution":1080,"filter":""}}'
$script:pages['https://therarbg.com/fixture-movie-search/'] = @(
    '<tr class="list-entry"><td><a href="/post/wrong-film/">Spider-Man: Brand New Day 2026 1080p web YTS</a></td></tr>'
    '<tr class="list-entry"><td><a href="/post/correct-film/">Spider.Man.No.Way.Home.2021.1080p.WEB</a></td></tr>'
    '<tr class="list-entry"><td><a href="/post/other-quality/">Spider.Man.No.Way.Home.2021.720p.WEB</a></td></tr>'
    '<tr class="list-entry"><td><a href="/post/wrong-year/">Spider.Man.No.Way.Home.2026.1080p.WEB</a></td></tr>'
) -join "`n"
$browsed = Invoke-Browse 'TheRARBG' $spider $empty
Check ($browsed.choices.Count -eq 2 -and @($browsed.choices | Where-Object { $_.title -match 'Brand New Day|2026' }).Count -eq 0) 'Movie browsing excludes different franchise titles and release years before displaying choices'
Check ($browsed.choices[0].matches -and $browsed.choices[0].id.EndsWith('/correct-film/')) 'The requested movie remains identifiable when the search query is shortened and matching releases appear first'
Check (!$browsed.choices[1].matches -and $browsed.choices[1].detail -match 'Different quality' -and $browsed.choices[1].detail -notmatch 'episode') 'Alternate qualities of the correct movie remain visible with a specific explanation'
$script:pages['https://therarbg.com/fixture-movie-search/'] = '<tr class="list-entry"><td><a href="/post/wrong-film/">Spider-Man: Brand New Day 2026 1080p web YTS</a></td></tr>'
$browsed = Invoke-Browse 'TheRARBG' $spider $empty
Check ($browsed.success -and $browsed.choices.Count -eq 0 -and $browsed.message -match 'No releases found for Spider-Man No Way Home') 'A provider with only unrelated movies gives an empty result instead of unrelated choices'
$numericMovie = Json '{"scope":"movie","title":"2001: A Space Odyssey","originalTitle":null,"year":1968}'
Check ((Test-Release (New-Release '2001.A.Space.Odyssey.1968.1080p' $magnet) $numericMovie $null $null 'TheRARBG')) 'A year in a movie title is not confused with its release year'
$tvBrowse = $tvRequest | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$tvBrowse | Add-Member -NotePropertyName action -NotePropertyValue 'releases'
$tvBrowse | Add-Member -NotePropertyName options -NotePropertyValue (Json '{"sourceUrl":"https://therarbg.com/fixture-show-search/","resolution":1080}')
$script:pages['https://therarbg.com/fixture-show-search/'] = @(
    '<tr class="list-entry"><td><a href="/post/other-show/">Other.Show.S01E02.1080p</a></td></tr>'
    '<tr class="list-entry"><td><a href="/post/requested-episode/">Test.Show.S01E02.1080p</a></td></tr>'
    '<tr class="list-entry"><td><a href="/post/same-show/">Test.Show.S01E03.1080p</a></td></tr>'
) -join "`n"
$browsed = Invoke-Browse 'TheRARBG' $tvBrowse $empty
Check ($browsed.choices.Count -eq 2 -and @($browsed.choices | Where-Object { $_.title -match '^Other' }).Count -eq 0) 'Episode browsing also removes unrelated series while retaining the requested series for filter previews'
$script:pages['https://therarbg.com/fixture-show-search/'] = @(
    '<tr class="list-entry"><td><a href="/post/later/">Test.Show.S01E03.1080p</a></td></tr>'
    '<tr class="list-entry"><td><a href="/post/other-quality/">Test.Show.S01E02.720p</a></td></tr>'
    '<tr class="list-entry"><td><a href="/post/requested-episode/">Test.Show.S01E02.1080p</a></td></tr>'
) -join "`n"
$browsed = Invoke-Browse 'TheRARBG' $tvBrowse $empty
Check (($browsed.choices | ForEach-Object { $_.title }) -join ',' -eq 'Test.Show.S01E02.1080p,Test.Show.S01E02.720p,Test.Show.S01E03.1080p') 'Requested episodes in another quality follow the downloadable releases and come before other episodes'
Check ($browsed.choices[1].episode -eq 'S01E02' -and !$browsed.choices[1].matches -and $browsed.choices[1].detail -match 'S01E02 in another quality' -and !$browsed.choices[2].episode) 'A requested episode in another quality names its episode without becoming downloadable'
Check ($browsed.choices[2].detail -match '^Not one of the missing episodes') 'A release of an episode that was not requested says so'

# Rate limiting, with the real page fetcher over a scripted HTTP transport and a clock-free sleep.
class FixtureHttpResponse : System.Net.WebResponse {
    [int]$StatusCode
    FixtureHttpResponse([int]$Code) { $this.StatusCode = $Code }
}
& {
    $script:replies = New-Object Collections.Generic.Queue[int]
    $script:requests = New-Object Collections.Generic.List[string]
    $script:sleeps = New-Object Collections.Generic.List[double]
    function Invoke-WebRequest { param($Uri, $WebSession, $TimeoutSec, $UserAgent, [switch]$UseBasicParsing)
        $script:requests.Add($Uri)
        $code = if ($script:replies.Count) { $script:replies.Dequeue() } else { 200 }
        if ($code -ne 200) { throw (New-Object Net.WebException('fixture', $null, [Net.WebExceptionStatus]::ProtocolError, [FixtureHttpResponse]::new($code))) }
        return [pscustomobject]@{ Content = "page $Uri" }
    }
    function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) $script:sleeps.Add([Math]::Round($Seconds + $Milliseconds / 1000.0)) }
    function Reset([int[]]$Codes) { $script:replies.Clear(); foreach ($code in $Codes) { $script:replies.Enqueue($code) }; $script:requests.Clear(); $script:sleeps.Clear() }
    $search = 'https://therarbg.com/get-posts/keywords:Test:category:Movies:category:TV/'
    $script:RateLimitedHosts = @{}

    Reset @(429, 429)
    $page = & $realGetPage $search
    Check ($page -eq "page $search" -and $script:requests.Count -eq 3 -and ($script:sleeps -join ',') -eq '3,6') 'HTTP 429 is retried after growing delays'
    Reset @()
    & $realGetPage ($search + '?page=2') | Out-Null
    Check (($script:sleeps -join ',') -eq '3') 'Later requests to a rate-limited host are spaced out'
    Reset @()
    & $realGetPage 'https://subsplease.org/shows/' | Out-Null
    Check ($script:sleeps.Count -eq 0) 'Other hosts are not slowed down by another host''s rate limit'

    $script:RateLimitedHosts = @{}
    Reset @(429, 429, 429, 429, 429)
    Fails { & $realGetPage $search } 'limiting how often.*HTTP 429' 'A persistent HTTP 429 gives up with a rate-limit message'
    Check ($script:requests.Count -eq 5 -and ($script:sleeps -join ',') -eq '3,6,9,12') 'A persistent HTTP 429 stops after five attempts'

    $script:RateLimitedHosts = @{}
    Reset @(404)
    Fails { & $realGetPage $search } 'fixture' 'Other HTTP errors are not retried'
    Check ($script:requests.Count -eq 1 -and $script:sleeps.Count -eq 0 -and !$script:RateLimitedHosts.Count) 'Other HTTP errors do not mark the host as rate-limited'
}

# Plugins that share a support folder update together, so BlackPearl shows them as one group; each must name it.
foreach ($manifestFile in Get-ChildItem (Join-Path $repo 'plugins') -Filter plugin.json -Recurse) {
    $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
    if ($manifest.command -like '../sparrow-runtime/*') { Check ($manifest.group -ceq 'Sparrow') "$($manifestFile.Directory.Name) is in the Sparrow group with the other plugins that share sparrow-runtime" }
}

# Install and run each actual manifest command in Windows PowerShell, with UTF-8 JSON pipes.
$install = Join-Path $OutputDirectory 'plugins'
& (Join-Path $repo 'install.ps1') -Destination $install | Out-Null
$settingsFile = Join-Path $install 'sparrow-subsplease/settings.json'
Set-Content -LiteralPath $settingsFile -Value '{"resolution":720}' -Encoding UTF8
& (Join-Path $repo 'install.ps1') -Destination $install | Out-Null
Check ((Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json).resolution -eq 720) 'Reinstallation preserves local provider settings'
foreach ($folder in @('sparrow-subsplease','sparrow-eztv','sparrow-tokyotoshokan','sparrow-therarbg')) {
    $pluginDirectory = Join-Path $install $folder
    $manifest = Get-Content -LiteralPath (Join-Path $pluginDirectory 'plugin.json') -Raw | ConvertFrom-Json
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = 'powershell.exe'
    $command = [IO.Path]::GetFullPath((Join-Path $pluginDirectory $manifest.command))
    $start.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $command + '" -Provider ' + $manifest.arguments[1]
    $start.WorkingDirectory = $pluginDirectory
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
    $start.EnvironmentVariables['WATCHROOM_PLUGIN_DIR'] = $pluginDirectory
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        $process.Start() | Out-Null
        $request.contentType = $manifest.contentTypes[0]
        $request.title = [char]0x65e5 + [string][char]0x672c
        $bytes = [Text.Encoding]::UTF8.GetBytes(($request | ConvertTo-Json -Depth 8 -Compress))
        $process.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length); $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit(15000)) { $process.Kill(); throw "$folder process timed out" }
        $response = $stdout.Result.Trim() | ConvertFrom-Json
        Check ($process.ExitCode -eq 1 -and $response.success -eq $false -and $response.message -match 'No aired' -and !$stderr.Result) "$folder executes through the installed manifest and returns structured JSON"
    } finally { $process.Dispose() }
}
Write-Output "$script:checks Sparrow provider checks passed."
