#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP=GreenKeyLab.app; rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx26.0 Keyer/GreenKeyer.swift App/Renderer.swift App/Benchmark.swift App/main.swift -o "$APP/Contents/MacOS/GreenKeyLab"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleName</key><string>GreenKeyLab</string><key>CFBundleIdentifier</key><string>local.greenkeylab</string><key>CFBundleExecutable</key><string>GreenKeyLab</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>0.3</string><key>LSMinimumSystemVersion</key><string>26.0</string><key>NSHighResolutionCapable</key><true/></dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $PWD/$APP"
