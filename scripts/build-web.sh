#!/bin/zsh
# Build the Go web player for Linux (amd64 + arm64) into build/web/.
set -euo pipefail
cd "$(dirname "$0")/../web"
mkdir -p ../build/web
for arch in amd64 arm64; do
  CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -trimpath -ldflags "-s -w" -o ../build/web/mymusic-web-linux-$arch .
done
go build -o ../build/web/mymusic-web-darwin .
ls -lh ../build/web
