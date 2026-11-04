#!/bin/zsh
# Build the MyMusic Mac app and copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project MyMusic.xcodeproj -scheme MyMusicServer -configuration Release -derivedDataPath build/dd build
rm -rf "/Applications/MyMusic.app" "/Applications/MyMusic Server.app"   # old name too
cp -R "build/dd/Build/Products/Release/MyMusic.app" /Applications/
echo "Installed /Applications/MyMusic.app"
