#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP=CompShot.app; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 Keyer/GreenKeyer.swift App/Renderer.swift App/Benchmark.swift App/Background.swift App/Exporter.swift App/UI.swift App/ControlServer.swift App/main.swift -o "$APP/Contents/MacOS/CompShot"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleName</key><string>CompShot</string><key>CFBundleIdentifier</key><string>local.compshot</string><key>CFBundleExecutable</key><string>CompShot</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.7</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
# Icon: AppIcon.png (1024 x 1024, drawn by Tools/make-icon-concepts.swift) -> every size macOS needs -> .icns
if [ -f AppIcon.png ]; then
  iconset="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$iconset"
  for size in 16 32 128 256 512; do
    sips -z $size $size AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$iconset")"
fi
codesign --force --sign - "$APP" >/dev/null 2>&1
touch "$APP"   # nudges Finder and the Dock to pick up the new icon
# MCP helper (0.7): the small program AI apps start to drive CompShot. It lives in
# ~/Library/Application Support/CompShot so its path never changes, wherever you keep the app.
SUPPORT="$HOME/Library/Application Support/CompShot"
mkdir -p "$SUPPORT" .build
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 MCP/main.swift -o .build/compshot-mcp
rm -f "$SUPPORT/compshot-mcp"          # remove first, so a copy an AI app is running isn't overwritten in place
cp .build/compshot-mcp "$SUPPORT/compshot-mcp"
codesign --force --sign - "$SUPPORT/compshot-mcp" >/dev/null 2>&1 || true
echo "$PWD/$APP" > "$SUPPORT/app-path"
"$SUPPORT/compshot-mcp" --install
echo "Built $PWD/$APP"
echo "MCP server: $SUPPORT/compshot-mcp"
