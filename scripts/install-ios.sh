#!/bin/zsh
# Build and install MyMusic on a connected iPhone (paid or free Apple ID set as DEVELOPMENT_TEAM).
# Reinstalling over the top keeps all app data. Usage: scripts/install-ios.sh <TEAM_ID>
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM=${1:?usage: install-ios.sh TEAM_ID}
xcodegen generate
xcodebuild -project MyMusic.xcodeproj -scheme MyMusic -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/dd DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates build
# Pick a physical iPhone/iPad (never a simulator). Prefer one that's connected right now.
# Override with: install-ios.sh TEAM_ID <device UDID>
DEVICE=${2:-}
if [[ -z "$DEVICE" ]]; then
  JSON=$(mktemp)
  xcrun devicectl list devices --json-output "$JSON" >/dev/null
  DEVICE=$(python3 -I -c '
import json, sys
devs = [d for d in json.load(open(sys.argv[1]))["result"]["devices"]
        if d.get("hardwareProperties", {}).get("reality") == "physical"
        and d.get("hardwareProperties", {}).get("platform") in ("iOS", "iPadOS")]
devs.sort(key=lambda d: d.get("connectionProperties", {}).get("tunnelState") != "connected")
print(devs[0]["hardwareProperties"]["udid"] if devs else "")' "$JSON")
  rm -f "$JSON"
fi
[[ -n "$DEVICE" ]] || { echo "No physical iPhone found. Plug it in (or enable Wi-Fi debugging) and unlock it."; exit 1; }
echo "Installing on device $DEVICE"
xcrun devicectl device install app --device "$DEVICE" build/dd/Build/Products/Release-iphoneos/MyMusic.app
xcrun devicectl device process launch --device "$DEVICE" com.vrodic.mymusic >/dev/null && echo "Launched." || true
echo "Installed. Profile expiry: 7 days (free Apple ID) or 1 year (paid)."
