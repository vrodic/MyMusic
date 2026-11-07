# mymusic-web

A browser music player that runs on the machine holding the music (e.g. the SMB server at
`192.168.100.7`) and works as a **peer** of the MyMusic Mac app:

* **The Mac stays the main app.** Each side keeps its own SQLite database on its **own local disk**.
  (Never put a live SQLite database on the SMB share: network-file locking is unreliable and
  WAL mode doesn't work over a network filesystem.)
* **When both are up**, the Mac syncs every ~5 minutes (and soon after rescans, YouTube
  downloads, iPhone syncs and favorite changes):
  1. it pulls the web player's own plays and favorite changes (`GET /api/peer/stats`) and stores
     them like an iPhone's stats, so they count in the Mac's totals; favorites merge newest-change-wins;
  2. it pushes its library (`POST /api/peer/library`) with Mac-side play totals (Mac + iPhones,
     *not* the web player's own plays, so nothing is counted twice) and the merged favorites.
* **When the Mac is off**, the web player keeps working from its last copy. It also scans its own
  disk (at start and every 6 h) so new files show up even before the Mac has seen them.

## Features
Songs, folders, artists, albums, favorites, most/recently played, recently added and YouTube likes;
accent-insensitive search (same rules as the apps) that also finds folders at any depth; queue,
shuffle, repeat, seeking, embedded cover art, lock-screen/media-key controls (Media Session API),
favorite one song or a whole list (♥ header), play counts. Works on phones too.

**Duplicates** (sidebar → Tools): finds byte-identical files and the same song stored twice, right on
the server's disk (≈0.3 s for 3,400 songs). Extra copies are moved to a hidden `.duplicates` folder in
the music root (not deleted), and their plays and favorites move to the copy you keep. On its next sync
the Mac folds each removal into its own library (its counts, iPhone backups, YouTube links) *before*
pushing, and passes a merge list on, so iPhones move their own counts to the kept copy before deleting
the file. Empty `.duplicates` yourself once you're sure.

## Install on the music server (Linux)

```sh
# on the Mac
scripts/build-web.sh                     # → build/web/mymusic-web-linux-{amd64,arm64}
scp build/web/mymusic-web-linux-amd64 love@192.168.100.7:/tmp/mymusic-web     # pick the right arch (uname -m)
scp web/deploy/mymusic-web.service love@192.168.100.7:/tmp/

# on the server
sudo install -m 755 /tmp/mymusic-web /usr/local/bin/mymusic-web
sudo install -m 644 /tmp/mymusic-web.service /etc/systemd/system/   # edit -music if your path differs
# Runs as an unprivileged throwaway user (DynamicUser=yes). If the music isn't world-readable,
# uncomment SupplementaryGroups= in the service and set it to the music folder's group.
sudo systemctl daemon-reload
sudo systemctl enable --now mymusic-web
journalctl -u mymusic-web -f             # watch the first scan
```

Then open `http://192.168.100.7:47824`, and on the Mac set **Sync & Devices → Web player** to that
address. If you set `MYMUSIC_TOKEN` in the service, enter the same token there.

## Found on the network

The web player announces itself over Bonjour (`_mymusic-web._tcp`):
* **iPhone** → Library tab → *On \<server\> → Not on iPhone*: songs on the server that aren't on the
  phone, by folder, with search. Tap to stream; swipe / long-press to download (one song, a folder,
  or everything listed). Downloads stay on the phone even if they're not in the Mac's sync selection.
  Plays and favorites of streamed songs are recorded here and reach the Mac on its next sync.
* **A new Mac**: the first-run screen offers *Set Up from \<server\>*. It mounts the music share
  (`MYMUSIC_SMB_URL`; macOS asks for the username and password) and restores the main Mac's library
  — play counts, favorites, iPhone backups, YouTube queue and sync settings — from the copy the main
  Mac uploads here every 30 minutes (`mac-library-backup.sqlite`, next to the database).

## Streaming to a Mac (no share, no scan)

A Mac can use the web player as its library, using the song list the server already has
(`GET /api/tracks`) and the files from `GET /api/stream`:
* **First run**: *Stream from \<server\>* on the welcome screen. It stays on the server until you pick a
  music folder in Settings.
* **Music folder not mounted**: a Mac with a web player address carries on from the server by itself,
  and goes back to the folder (with a rescan) when it's mounted again.

Plays, favorites and playlists sync as usual. While streaming the Mac never pushes its library here.
iPhones can still sync from a streaming Mac: it sends them here for the files. Deleting songs,
finding duplicates and YouTube downloads need the folder.

## Flags
| flag | env | default | |
|---|---|---|---|
| `-music` | `MYMUSIC_ROOT` | (required) | music root; must be the same tree as the Mac's music root |
| `-db` | `MYMUSIC_DB` | `mymusic-web.sqlite` | database file, on a local disk |
| `-listen` | `MYMUSIC_LISTEN` | `:47824` | |
| `-token` | `MYMUSIC_TOKEN` | none | shared secret for the Mac's peer sync |
| `-scan-every` | | `6h` | re-scan interval (`0` = only at start) |
| `-smb` | `MYMUSIC_SMB_URL` | none | how Macs reach the music over SMB: `smb://host/share/path/to/music` (for new-Mac setup) |

The browser endpoints have no login, like the Mac's iPhone sync server: it's meant for your home network.

## Develop
```sh
cd web && go run . -music /Volumes/root/mnt/picko/stuff/mp3 -db /tmp/web.sqlite -listen 127.0.0.1:47824
```
The UI is plain HTML/CSS/JS in `static/`, embedded into the binary.
