#!/bin/bash
# Builds .build/Brahma.app from the SwiftPM products. Usage: scripts/make-app.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
C="${1:-release}"

swift build -c "$C" --product brahma
swift build -c "$C" --product BrahmaApp
BIN="$(swift build -c "$C" --show-bin-path)"

APP=.build/Brahma.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/BrahmaApp" "$APP/Contents/MacOS/Brahma"
cp "$BIN/brahma" "$APP/Contents/Helpers/brahma"
for b in "$BIN"/*.bundle; do
  [ -e "$b" ] || continue
  case "$b" in *Tests.bundle) continue ;; esac
  cp -R "$b" "$APP/Contents/Resources/"
done

printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.brahma.app</string>
  <key>CFBundleName</key><string>Brahma</string>
  <key>CFBundleDisplayName</key><string>Brahma</string>
  <key>CFBundleExecutable</key><string>Brahma</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP/Contents/Helpers/brahma"
codesign --force --sign - --identifier dev.brahma.app "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
