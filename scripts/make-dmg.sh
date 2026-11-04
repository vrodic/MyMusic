#!/bin/zsh
# Build the MyMusic Mac app (Release) and package it as build/MyMusic-<version>.dmg,
# with an Applications shortcut so people can drag it over.
#
# The app is signed with your Apple Development certificate, not notarized (that needs a paid
# Developer ID). On another Mac, the first launch is blocked by Gatekeeper; the recipient
# right-clicks the app → Open (or System Settings → Privacy & Security → Open Anyway).
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate >/dev/null
xcodebuild -project MyMusic.xcodeproj -scheme MyMusicServer -configuration Release \
  -derivedDataPath build/dd -allowProvisioningUpdates -quiet build

APP="build/dd/Build/Products/Release/MyMusic.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
OUT="build/MyMusic-$VERSION.dmg"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/Read Me.txt" <<'TXT'
MyMusic for Mac

1. Drag MyMusic onto Applications.
2. First launch: right-click MyMusic → Open (it isn't notarized), then confirm.
3. YouTube downloads need:  brew install yt-dlp ffmpeg deno
   and Full Disk Access for MyMusic (System Settings → Privacy & Security),
   so it can read your browser's YouTube login.
TXT

rm -f "$OUT"
hdiutil create -volname "MyMusic $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT" >/dev/null
codesign --sign "Apple Development" --timestamp=none "$OUT" 2>/dev/null || true
echo "$OUT ($(du -h "$OUT" | cut -f1))"
