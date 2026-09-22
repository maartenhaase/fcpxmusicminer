#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="FCPX Music Miner"
EXECUTABLE="FCPXMusicMiner"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

rm -rf "$DIST" "$ROOT/.build-arm64" "$ROOT/.build-x86_64"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Building arm64…"
swift build -c release --arch arm64 --scratch-path "$ROOT/.build-arm64"
ARM_BIN="$(swift build -c release --arch arm64 --scratch-path "$ROOT/.build-arm64" --show-bin-path)/$EXECUTABLE"

echo "Building x86_64…"
swift build -c release --arch x86_64 --scratch-path "$ROOT/.build-x86_64"
X86_BIN="$(swift build -c release --arch x86_64 --scratch-path "$ROOT/.build-x86_64" --show-bin-path)/$EXECUTABLE"

echo "Creating universal binary…"
lipo -create "$ARM_BIN" "$X86_BIN" -output "$APP/Contents/MacOS/$EXECUTABLE"
chmod +x "$APP/Contents/MacOS/$EXECUTABLE"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>nl</string>
    <key>CFBundleDisplayName</key>
    <string>FCPX Music Miner</string>
    <key>CFBundleExecutable</key>
    <string>FCPXMusicMiner</string>
    <key>CFBundleIdentifier</key>
    <string>nl.maartenhaase.fcpxmusicminer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FCPX Music Miner</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>FCPX Music Miner leest Final Cut Pro libraries en kopieert geselecteerde muziek naar een FCPXMusicMiner-map op dezelfde schijf.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"

cd "$DIST"
ditto -c -k --sequesterRsrc --keepParent "$APP_NAME.app" "FCPXMusicMiner-macOS-universal.zip"

echo
echo "Klaar:"
echo "$APP"
echo "$DIST/FCPXMusicMiner-macOS-universal.zip"
