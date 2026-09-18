#!/usr/bin/env bash
# Builds the demo into a real .app bundle and launches it.
#
# A bare `swift run` executable has no bundle, so macOS gives it no window and
# no microphone permission — the Info.plist below is what makes both work.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/VoiceGlowDemo"

APP="build/VoiceGlowDemo.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VoiceGlowDemo"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VoiceGlowDemo</string>
  <key>CFBundleDisplayName</key><string>VoiceGlowKit</string>
  <key>CFBundleIdentifier</key><string>dev.kuray.voiceglow.demo</string>
  <key>CFBundleExecutable</key><string>VoiceGlowDemo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>The demo listens to your voice so the glow can react to it.</string>
</dict>
</plist>
PLIST

# Ad-hoc signature with the audio-input entitlement, so the mic toggle works.
cat > build/demo.entitlements <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.device.audio-input</key><true/>
</dict>
</plist>
ENT
codesign --force --sign - --entitlements build/demo.entitlements "$APP" >/dev/null 2>&1 || \
  echo "⚠ ad-hoc signing failed — the app will run, but the microphone may not"

echo "✓ $APP"
open "$APP"
