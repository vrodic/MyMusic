# MyMusic — Architecture

Two native SwiftUI apps that share one source folder (`Shared/`):

| Target | Platform | Role |
|---|---|---|
| **MyMusic for Mac** (`Mac/`) | macOS 14+ | Indexes the music root into SQLite, downloads YouTube "Liked music" with `yt-dlp`, plays music, shows library stats, serves the library over the LAN. |
| **MyMusic** (`iOS/`) | iOS 17+ | Discovers the Mac via Bonjour, mirrors the selected folders (keeping folder structure), plays music offline, tracks favorites / play counts, exposes files to other apps. |

```
            ┌──────────────── Mac ────────────────┐
 ~/Music ─▶ │ Indexer ─▶ library.sqlite ◀─ Stats  │
 root/yt ◀─ │ YouTubeManager (yt-dlp, 1 at a time)│
            │ HTTPServer (NWListener, Bonjour)    │──── _mymusic._tcp ────┐
            └─────────────────────────────────────┘                       │
                                                                          ▼
            ┌──────────────── iPhone ─────────────┐   GET /api/library
            │ ServerBrowser (NWBrowser)           │   GET /api/file?path=…
            │ SyncManager ─▶ Documents/Music/<relPath>  POST /api/stats
            │ library.sqlite (favorites, plays)   │   GET /api/stats/device?id=…
            └─────────────────────────────────────┘
```

## Shared code (`Shared/`)
* `SQLite.swift` – tiny dependency‑free wrapper over the system `sqlite3`.
* `Models.swift` – `Track`, `LibraryManifest`, `StatsUpload`, service constants.
* `LibraryDB.swift` – the `tracks` table used by both apps (metadata + play stats).
* `AudioScanner.swift` – walks a folder, reads tags via AVFoundation (title, artist, album, track #, year, duration, artwork), incremental by size+mtime.
* `PlayerEngine.swift` – AVPlayer based queue, shuffle/repeat, Now Playing + remote commands (lock screen on iOS, media keys on macOS), play counting (counts after 50% or 4 min, skip counted if < 10 s).
* `FolderTree.swift` – builds the folder hierarchy from relative paths (used for browsing and for sync-folder selection).

## Mac app
* **Music root** – picked once (`NSOpenPanel`). Whole root is indexed (stats cover the whole collection). The app is not sandboxed (it must run `/opt/homebrew/bin/yt-dlp`).
* **Synced folders** – a checkbox tree in *Sync* view; only tracks under checked folders are published to iOS.
* **YouTube** – `yt-dlp --flat-playlist -J --cookies-from-browser <browser> https://music.youtube.com/playlist?list=LM` indexes the liked playlist into `yt_items`. A single worker downloads items one by one (`-x --audio-format m4a --embed-metadata --embed-thumbnail`) into `<root>/yt/`. Each item has a qBittorrent‑style priority: **Do not download / Normal / High / Maximum**; the worker always picks the highest priority pending item (ties → playlist order). Re-index runs on demand and every N hours.
* **Server** – minimal HTTP/1.1 on `NWListener` (port 47823), advertised as `_mymusic._tcp`. Only indexed tracks can be served (no path traversal). Supports `Range` so downloads can resume.
* **Stats** – totals, format/source breakdown (Swift Charts), top tracks/artists (Mac plays + all device plays), recently added, YouTube queue status, devices + last sync.

## iOS app
* Files live in `Documents/Music/<relPath>` → the folder structure from the Mac is preserved. `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` expose them in the **Files** app, so any other app can open/import them, and songs you drop in there (or import with the in‑app importer, which copies whole folders recursively) are indexed as local tracks.
* Browsing: Folders, Songs, Artists, Albums, Favorites, Most played, Recently played, Recently added, search.
* Player: background audio, lock screen controls, queue, shuffle, repeat, Up Next.
* Sync: picks a discovered Mac (or a manually entered `host:port`), uploads stats, downloads new/changed files, optionally removes files deleted on the Mac (only files that came from the Mac – never your local imports).

## Data safety
See [CERTIFICATES.md](CERTIFICATES.md). Short version: every sync backs up the iPhone's play counts and favorites to the Mac database; after a reinstall *Settings → Restore stats from Mac* puts them back and the music re-syncs.

## Peer sync (users, play counts, favorites, playlists, YouTube queue)
Every device — each Mac, each iPhone, the web player — keeps a full copy and works offline; when two
meet they swap only what changed since last time (`GET/POST /api/v2/changes`, delta by each device's
own sequence number, gossiped onward). `Shared/SyncStore.swift` (Swift) and `web/sync.go` (Go) hold the
same tables and merge rules, all conflict-free:

| data | rule |
|---|---|
| play / skip counts | one counter cell per (user, song, device); a device only raises its own; merge = max per cell; total = sum |
| favorites, users, playlists, per-user settings | newest change wins (ties: device id) |
| removed duplicates | alias old → kept song; stats follow it everywhere |
| YouTube queue (Macs + web relay) | user fields and download fields newest-wins separately; "downloaded" sticks; download claims (newest wins) so two Macs don't fetch one song |

Songs are keyed by their path in Unicode NFC (Macs see decomposed names over SMB, Linux composed).
Macs find each other over Bonjour (`_mymusic._tcp`) and exchange every minute and soon after changes;
the web player relays between Macs that are never on together; iPhones exchange with their Mac on
every sync. Each device has a current user (Mac: toolbar; iPhone: Settings; web: header); an iPhone
gets that user's ticked folders, favorites (if chosen) and playlist songs. The `tracks` table keeps a
copy of the current user's totals so lists stay simple and fast.

Each Mac also uploads a copy of its library to its own slot on the web player every 30 minutes (or
**Back Up Now**); a new Mac picks one to start from, or none and just syncs with the peers.
