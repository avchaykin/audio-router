#!/bin/zsh
# Builds "Audio Router.app" (with the virtual-device driver embedded) into ./build.nosync
# (".nosync" keeps iCloud Drive from syncing build output).
set -euo pipefail
cd "$(dirname "$0")"
CONFIG=${1:-release}
OUT=build.nosync

# --- Virtual device driver (AudioServerPlugIn) ---
DRV="$OUT/AudioRouterDriver.driver"
rm -rf "$DRV"
mkdir -p "$DRV/Contents/MacOS"
clang -bundle -O2 -Wall -Wextra -arch arm64 -arch x86_64 -mmacosx-version-min=12.0 \
    -framework CoreAudio -framework CoreFoundation \
    -o "$DRV/Contents/MacOS/AudioRouterDriver" Driver/AudioRouterDriver.c
cp Driver/Info.plist "$DRV/Contents/Info.plist"
codesign --force --sign - "$DRV"

# --- App ---
swift build -c "$CONFIG" --scratch-path .build.nosync
BIN="$(swift build -c "$CONFIG" --scratch-path .build.nosync --show-bin-path)/AudioRouter"
APP="$OUT/Audio Router.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AudioRouter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R "$DRV" "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built: $PWD/$APP"
