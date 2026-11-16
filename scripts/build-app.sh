#!/bin/bash
# Builds DockLite.app into ./build. Usage: scripts/build-app.sh [--install]
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/DockLite.app
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DockLite "$APP/Contents/MacOS/DockLite"

# App icon (optional; skipped if rendering fails)
ICONSET=$(mktemp -d)/AppIcon.iconset
if swift scripts/make-icon.swift "$ICONSET" 2>/dev/null && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
  echo "Icon generated"
else
  echo "Icon generation skipped"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>DockLite</string>
  <key>CFBundleDisplayName</key><string>DockLite</string>
  <key>CFBundleIdentifier</key><string>local.docklite.app</string>
  <key>CFBundleExecutable</key><string>DockLite</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/DockLite.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/DockLite.app"
fi
