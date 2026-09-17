#!/usr/bin/env bash
# Build a double-clickable MidiToMp3.app — no Xcode required.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MidiToMp3"
BUNDLE_ID="com.parithoshvarma.miditomp3"

swift build -c release --product MidiToMp3

rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS" "$APP_NAME.app/Contents/Resources"
cp ".build/release/MidiToMp3" "$APP_NAME.app/Contents/MacOS/$APP_NAME"
cp "Icon.icns" "$APP_NAME.app/Contents/Resources/Icon.icns"

cat > "$APP_NAME.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>MIDI to Audio</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>Icon</string>
    <key>CFBundleIconName</key>
    <string>Icon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.music</string>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP_NAME.app/Contents/PkgInfo"
codesign --force --deep -s - "$APP_NAME.app"
codesign -v "$APP_NAME.app" && echo "signed OK: $APP_NAME.app"
