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

## Flags
| flag | env | default | |
|---|---|---|---|
| `-music` | `MYMUSIC_ROOT` | (required) | music root; must be the same tree as the Mac's music root |
| `-db` | `MYMUSIC_DB` | `mymusic-web.sqlite` | database file, on a local disk |
| `-listen` | `MYMUSIC_LISTEN` | `:47824` | |
| `-token` | `MYMUSIC_TOKEN` | none | shared secret for the Mac's peer sync |
| `-scan-every` | | `6h` | re-scan interval (`0` = only at start) |

The browser endpoints have no login, like the Mac's iPhone sync server: it's meant for your home network.

## Develop
```sh
cd web && go run . -music /Volumes/root/mnt/picko/stuff/mp3 -db /tmp/web.sqlite -listen 127.0.0.1:47824
```
The UI is plain HTML/CSS/JS in `static/`, embedded into the binary.
