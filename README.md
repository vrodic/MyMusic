# MyMusic

Personal music player: **MyMusic Server** (macOS) indexes your collection and downloads your YouTube *Liked music*;
**MyMusic** (iOS) syncs chosen folders over Wi‑Fi and plays them offline.

* Architecture: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
* Signing / cert renewal / not losing data: [docs/CERTIFICATES.md](docs/CERTIFICATES.md)

## Requirements
```
brew install xcodegen yt-dlp ffmpeg deno
```
(`deno` is the JS runtime yt-dlp needs for YouTube.)

## Build
```
xcodegen generate          # creates MyMusic.xcodeproj (not committed)
scripts/build-mac.sh       # → /Applications/MyMusic Server.app
scripts/install-ios.sh <TEAM_ID>   # direct install to a connected iPhone
scripts/build-ipa.sh       # → build/MyMusic.ipa for AltStore / SideStore
```

## First run
1. Open **MyMusic Server** → *Choose Music Root…*. The whole root is indexed into
   `~/Library/Application Support/MyMusic/library.sqlite`; all top-level folders are initially marked for sync.
2. *Settings (⌘,) → YouTube*: choose the browser you're signed in to YouTube with (cookies). Then *YouTube Liked → Refresh Liked*.
   Songs download one at a time into `<root>/yt/`. Change priority per song (or multi-select → right click):
   Do not download / Normal / High / Maximum.
3. *Sync & Devices*: tick the folders the iPhone should get.
4. On the iPhone: *Sync* tab → the Mac appears automatically → *Sync Now*. Allow Local Network access when asked.

## Notes
* Formats: mp3, m4a/aac/alac, flac, wav, aiff, caf. (ogg/opus aren't indexed — iOS can't play them natively; YouTube downloads are m4a.)
* The server has no authentication — it only serves indexed tracks from synced folders, on your LAN.
* Play counts: a play counts after 50 % of the track (or 4 min); skipping earlier counts as a skip.
