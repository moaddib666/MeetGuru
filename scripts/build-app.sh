#!/usr/bin/env bash
# Builds dist/MeetingGuru.app (arm64, ad-hoc signed) from the Swift package.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:-2.0.0}"
BUILD="${BUILD:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
APP="$ROOT/dist/MeetingGuru.app"

swift build --package-path "$ROOT" -c release --arch arm64
BIN="$(swift build --package-path "$ROOT" -c release --arch arm64 --show-bin-path)/MeetingGuru"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MeetingGuru"
cp "$ROOT/Resources/mascot.png" "$ROOT/Resources/alert.mp3" "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp -R "$ROOT/Resources/Backgrounds" "$APP/Contents/Resources/Backgrounds"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>MeetingGuru</string>
    <key>CFBundleExecutable</key><string>MeetingGuru</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>com.meetingguru.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>MeetingGuru</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MeetingGuru by moaddib. MIT License.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "Built $APP"
