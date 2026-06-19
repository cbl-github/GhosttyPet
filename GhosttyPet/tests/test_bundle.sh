#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP_BINARY="build/GhosttyPet.app/Contents/MacOS/GhosttyPet"
INFO_PLIST="build/GhosttyPet.app/Contents/Info.plist"

test -x "$APP_BINARY"
plutil -lint "$INFO_PLIST" >/dev/null

if otool -L "$APP_BINARY" | grep -E 'WebKit|AVFoundation'; then
  echo "Unexpected heavyweight framework linked" >&2
  exit 1
fi

otool -L "$APP_BINARY" | grep -q 'AppKit.framework'

PET_VIEW_SOURCE="src/PetView.m"
# The ghost is computed by an SDF rasterizer and blitted as one CGImage.
grep -q 'paint_ghost' "$PET_VIEW_SOURCE"
grep -q 'CGImageCreate' "$PET_VIEW_SOURCE"

# Stay asset-free: no bundled image/video/web rendering (CGImage of a computed
# buffer is fine; NSImage/NSBitmapImageRep would imply loaded bitmaps).
if grep -E 'NSImage|NSBitmapImageRep|AVPlayer|WebView' "$PET_VIEW_SOURCE"; then
  echo "PetView should stay vector-native and avoid image/video/web rendering" >&2
  exit 1
fi

grep -q 'mouseDragged' "$PET_VIEW_SOURCE"
grep -q 'rightMouseDown' "$PET_VIEW_SOURCE"
grep -q 'keyDown' "$PET_VIEW_SOURCE"
