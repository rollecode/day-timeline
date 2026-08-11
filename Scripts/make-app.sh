#!/usr/bin/env bash
# Builds dist/Day timeline.app: release binary, resource bundle, and an
# AppIcon.icns rendered by the binary itself so code and icon never drift.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dist="$root/dist"
app="$dist/Day timeline.app"
binary="$root/.build/release/day-timeline"
version="$(sed -n 's/^### \([0-9.]*\):.*/\1/p' "$root/CHANGELOG.md" | head -1)"

swift build -c release --package-path "$root"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

cp "$binary" "$app/Contents/MacOS/day-timeline"
cp -R "$root/.build/release/day-timeline_day-timeline.bundle" "$app/Contents/Resources/"

iconset="$dist/AppIcon.iconset"
rm -rf "$iconset"
"$binary" --export-icon "$iconset"
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Day timeline</string>
    <key>CFBundleDisplayName</key>
    <string>Day timeline</string>
    <key>CFBundleExecutable</key>
    <string>day-timeline</string>
    <key>CFBundleIdentifier</key>
    <string>fi.dude.day-timeline</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${version}</string>
    <key>CFBundleVersion</key>
    <string>${version}</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$app" >/dev/null 2>&1 || true
touch "$app"

echo "Built $app"
echo "Install with: cp -R \"$app\" ~/Applications/"
