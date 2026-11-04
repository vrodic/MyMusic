#!/bin/zsh
# Build an unsigned .ipa for AltStore / SideStore (they re-sign it with your Apple ID).
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project MyMusic.xcodeproj -scheme MyMusic -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath build/dd CODE_SIGNING_ALLOWED=NO build
rm -rf build/ipa && mkdir -p build/ipa/Payload
cp -R build/dd/Build/Products/Release-iphoneos/MyMusic.app build/ipa/Payload/
(cd build/ipa && zip -qr ../MyMusic.ipa Payload)
echo "build/MyMusic.ipa ready – open it with AltStore/SideStore (My Apps → +)."
