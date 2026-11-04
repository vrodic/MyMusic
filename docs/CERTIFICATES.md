# Keeping the iOS app signed (and not losing data)

## How data loss actually happens
* **Certificate / profile expiry does NOT delete data.** The app just refuses to launch. Re-signing and installing the *same bundle ID* from the *same team* over the top keeps the app container (database + `Documents/Music`).
* Data is lost only when the app is **deleted**, or when it is reinstalled under a **different bundle ID / team** (a new, empty container). So: never delete the app to "fix" an expired signature — refresh it.

## Options (best first for a single-person, always-on-Mac setup)

### 1. Paid Apple Developer account (≈ €99/yr) + Xcode — most convenient
* Development provisioning profiles last **1 year**. Install with Xcode or `scripts/install-ios.sh` (uses `xcodebuild` + `devicectl`).
* Put a yearly reminder; reinstalling over the top keeps all data.
* The same account also unlocks option 3 if you ever want zero expiry.

### 2. Free Apple ID + AltStore Classic / SideStore — free, needs refreshing every 7 days
* Run **AltServer** on this Mac (it's on the same Wi‑Fi anyway). AltStore on the phone auto-refreshes in the background when the Mac is reachable; SideStore can refresh on‑device with a WireGuard/LocalDevVPN pairing file.
* Limits: 3 sideloaded apps, 10 App IDs per week. AltStore appends your team ID to the bundle ID — that's fine as long as you keep using the **same Apple ID**.
* If it lapses, open AltStore → *Refresh All*; data stays.
* Build an `.ipa` with `scripts/build-ipa.sh` and open it in AltStore.

### 3. AltStore PAL (EU) — no expiry, but heavyweight
AltStore PAL installs *notarized* apps from a developer-hosted *source*. To use it for your own app you need: a paid developer account, Apple's approval for alternative (Web/Marketplace) distribution in the EU, App Store Connect notarization for each build, and a hosted source JSON + ipa. Apps installed this way don't expire. Worth it only if you want to share the app with others; for personal use option 1 is simpler.

## Built-in safety nets
1. **Music** – the Mac is the source of truth; a fresh install re-syncs everything.
2. **Stats & favorites** – each sync `POST /api/stats` uploads the phone's per-track play counts, skips, last played and favorites into `device_stats` on the Mac. *iOS → Settings → Restore stats from Mac* lists backups per device and merges them back (max of counts, OR of favorites).
3. **Local-only imports** (songs added via Files) – those exist only on the phone. Keep a copy on the Mac or in iCloud Drive; the Files app can see them under *On My iPhone → MyMusic*.
4. Keep the bundle ID (`com.vrodic.mymusic` in `project.yml`) stable forever.
