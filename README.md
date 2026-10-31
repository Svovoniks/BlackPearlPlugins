# BlackPearlPlugins

Acquisition plugins for [Watchroom](https://github.com/Svovoniks/WatchRoom). They
follow Watchroom's [plugin protocol](https://github.com/Svovoniks/WatchRoom/blob/master/PLUGINS.md)
and use its interactive picker, so they need a Watchroom release that includes
the acquisition picker.

## Sparrow acquisition providers

Ports of all four providers in [Sparrow](https://github.com/Svovoniks/sparrow):

| Plugin | Content | Source behavior |
| --- | --- | --- |
| SubsPlease | Anime | Show catalog, show ID, episode API and resolution selection |
| EZTV | Shows | JSON API by IMDb ID (from Watchroom, or an IMDb title lookup) |
| TokyoToshokan | Anime | Anime RSS search for the title, its AniList romaji title and each missing episode |
| TheRARBG | Shows, movies | Encoded search, paginated releases and detail-page magnets |

These are Windows PowerShell 5.1 plugins with no additional dependencies. They
use Watchroom's existing Acquire action and retain release filenames. Sparrow's
interactive prompts are replaced by the acquisition request and optional settings.
Sparrow's source tree and configuration are not modified or required at runtime.

## Choose options in Watchroom

**Acquire** now opens a native picker for these providers. It searches straight
away (or opens the provider page saved for the title), picks the provider title
that is this show or film, preferring one with its year, and ticks the best
release of each missing episode. Check the ticks and choose **Download**; nothing
downloads before that. To change any step:

1. Choose another provider, or edit the search title and choose **Search**.
2. For SubsPlease or EZTV, click a provider title to list its releases. When no
   title clearly matches, the picker leaves the titles for you to choose from.
   TokyoToshokan and TheRARBG show release results directly.
3. Use the options beside the list to choose a quality, set a provider page, build
   a filter from a selected release, or adjust anime numbering. The release list
   reloads on its own when an option changes.
4. Click releases to tick them, or use **Select best matches** to tick the best
   release of each requested episode; those releases are listed first. Only
   releases of requested episodes in the chosen quality are downloadable; choose
   one version per episode.
5. Choose **Download**. Browsing and option changes never download.

Release lists exclude unrelated titles and, for movies, different release years.
Matching releases appear first, ordered by how many distinct search words their
titles contain. For example, searching `Hazbin Hotel megusta` puts MeGusta releases
above other groups of the requested episodes and quality. Partial words also
help rank results; capitalization and punctuation do not matter. Ranking does not
change which releases are eligible to download. Other qualities of the same title remain visible
so you can change the quality setting; their rows explain the difference. If the
provider only returns other titles, the picker reports no releases found.

**Remember choices for this title** saves the selected provider, title, source URL,
quality, filter and numbering for that title and season in Watchroom's profile.
It does not save a download selection: every run asks you to confirm releases.
Watchroom already knows the missing episodes from your library, so you do not
need to tell it the last episode you have.

Use **Settings** in the picker or beside a plugin under **Folders > Acquisition
plugins** to choose a downloader, default quality, Web UI credentials or mirror.
These settings update the plugin's local configuration while preserving existing
title bindings. Existing command-only plugins still work as before.

## Install

From a checkout of this repository:

```powershell
./install.ps1
```

This installs four plugin folders plus `sparrow-runtime` under
`%LOCALAPPDATA%\Watchroom\plugins`, or `WATCHROOM_PLUGINS` when set. Use
`-Destination <folder>` for another installation. Reload under **Folders >
Acquisition plugins**, or restart Watchroom. Reinstalling updates shipped files
and preserves each provider's `settings.json`. To copy manually, copy all five
`sparrow-*` folders together. Keep `sparrow-runtime` beside the four providers.

## Downloads

By default, matching magnets open in the registered torrent client, just as in
Sparrow. **Choose the library destination in that client's dialog.** Magnet URI
handlers do not provide a standard way to set the download folder.

For automatic destinations, enable qBittorrent's Web UI and set **Download with**
to **qbittorrent** in the provider's in-app Settings. You can also create
`settings.json` inside each provider's folder (not inside `sparrow-runtime`):

```json
{
  "downloader": "qbittorrent",
  "resolution": 1080,
  "qbittorrent": {
    "url": "http://localhost:8080",
    "username": "your-web-ui-user",
    "password": "your-web-ui-password"
  }
}
```

These credentials are local configuration; do not commit them. qBittorrent must
have access to the same destination paths as Watchroom. Remote Web UIs require
HTTPS. The plugin sends each torrent's `savepath` and disables automatic torrent
management for it. Season requests use `seasonDirectory` when supplied, otherwise
`Season NN` (or `Specials`) beneath the requested show directory. Upcoming episodes
are skipped. Unmatched aired episodes are listed in the result; a season with
some matching episodes queues those releases and reports the remainder. Repeating
Acquire hands the same hashes to the client, which manages duplicate torrents.

## Title, quality and numbering settings

The default resolution is exactly 1080p. Set `resolution` to 720, 480, 2160 or
`0` to accept any resolution. If multiple releases qualify, the first by title
and URL is selected. A title binding can override the resolution and restrict a
release group with a Sparrow filter. No fuzzy title match or season pack is
downloaded automatically.

Catalog providers require one exact title after punctuation/case normalization,
using the Watchroom title or original title. Set a provider-specific title or
show page URL when names differ or catalog matches are ambiguous:

```json
{
  "titles": {
    "The title in Watchroom": {
      "title": "Provider title",
      "url": "https://subsplease.org/shows/provider-title/",
      "season": 2,
      "resolution": 720
    }
  }
}
```

`url` is optional and must be a show page for SubsPlease, an IMDb title page
(`https://www.imdb.com/title/tt…/`) for EZTV, an `rss.php` or search page for
TokyoToshokan, or a search page for TheRARBG. Omit `season` for ordinary season-and-episode releases.
Anime releases numbered without a season use the request's `absoluteEpisode`
when present, otherwise episode numbers for season 1 only. For a separate
season-2 listing numbered from 1, set `season: 2`. For a continuous listing with
season 2 episode 1 numbered 13, use `episodeOffset: 12` instead. A binding applies
to this Watchroom title; keep its URL/title and numbering consistent. Specials
without explicit season codes need an explicit numbering binding.

Releases of the title without an episode number, such as season packs, batches and
OVAs, are listed but never ticked or matched automatically. Tick one on its own to
download it to the request's folder. A typed search title may be the start of the
provider's name for the show; a release filter replaces the exact-title check.

`filter` supports Sparrow's literal templates: `<<variable>>`, `<<fix:d:2>>`,
`<<max:s:8>>` and `<<max0:d:3>>`. Its `<<episode_number>>` placeholder works for
EZTV too. SubsPlease uses resolution and episode API fields instead of filenames,
so leave `filter` unset there. These plugins deliberately avoid Sparrow's closest
title guess and DHT filename lookup; ambiguous or absent matches return a useful
failure. Movie matches require an exact title prefix and the requested year.

Optional `baseUrl` selects an HTTPS mirror. `limit` (default 200, maximum 1000)
and `maxPages` (default 10, maximum 20) bound SubsPlease and TheRARBG searches.
EZTV reads up to 2000 releases of the show; TokyoToshokan's feed returns about
150 per search, plus up to 12 per-episode searches. EZTV's show list and
TokyoToshokan's search page are blocked by Cloudflare, so those are not used. Each provider
request times out after 20 seconds and Cloudflare 52x and gateway errors are
retried twice; Watchroom stops the overall run after five
minutes. Blocking, missing pages and changed site layouts report failure. The
plugins do not bypass challenges. Live source availability is independent of
the offline parser tests.

`plugins/sparrow-runtime/settings.example.json` shows available fields; copy only the
fields you need into a provider's `settings.json`.

## Verification

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/run.ps1
```

The checks use saved response shapes for every Sparrow provider, exercise request
matching and downloader handoff without opening magnets or downloading videos,
and run all four installed commands through the real JSON process protocol.
