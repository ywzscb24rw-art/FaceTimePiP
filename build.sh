#!/bin/zsh
# Builds FaceTime PiP.app next to this script.
#   ./build.sh            build into build/
#   ./build.sh --install  build, then install to /Applications and launch it
set -euo pipefail
cd "${0:A:h}"

APP="build/FaceTime PiP.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"

# Optional custom icons:
#   Icons/AppIcon.png      app icon, square, ideally 1024×1024
#   Icons/MenuBarIcon.png  menu bar icon, black shape on transparent (used as a template)
if [[ -f Icons/AppIcon.png ]]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Icons/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Icons/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi
if [[ -f Icons/MenuBarIcon.png ]]; then
  cp Icons/MenuBarIcon.png "$APP/Contents/Resources/MenuBarIcon.png"
fi

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit -framework CoreMedia \
  -framework CoreAudio -framework ServiceManagement \
  Sources/main.swift -o "$APP/Contents/MacOS/FaceTimePiP"

# Sign with the local certificate when present so the Screen Recording and
# Accessibility permissions survive rebuilds; fall back to ad-hoc (they reset).
IDENTITY="FaceTime PiP Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/FaceTime PiP.app"
  # Quit any running copy (from build/ or /Applications) before replacing it.
  pkill -x FaceTimePiP 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  echo "Installed $DEST"
  open "$DEST"
fi
