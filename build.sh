#!/bin/zsh
# Builds FaceTime PiP.app next to this script.
set -euo pipefail
cd "${0:A:h}"

APP="build/FaceTime PiP.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"

swiftc -O -swift-version 5 \
  -target "$(uname -m)-apple-macosx14.0" \
  -framework AppKit -framework AVKit -framework ScreenCaptureKit -framework CoreMedia \
  Sources/main.swift -o "$APP/Contents/MacOS/FaceTimePiP"

# Sign with the local certificate when present so the Screen Recording permission
# survives rebuilds; fall back to ad-hoc (permission resets each build).
IDENTITY="FaceTime PiP Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
  codesign --force --sign "$IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built $APP"
