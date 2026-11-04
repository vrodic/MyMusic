#!/bin/zsh
# Build MyMusic Server and copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project MyMusic.xcodeproj -scheme MyMusicServer -configuration Release -derivedDataPath build/dd build
rm -rf "/Applications/MyMusic Server.app"
cp -R "build/dd/Build/Products/Release/MyMusic Server.app" /Applications/
echo "Installed /Applications/MyMusic Server.app"
