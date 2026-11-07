#!/usr/bin/env bash
# Build ClaudeUsage.app into app/build/ (install.sh copies it to ~/Applications).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/ClaudeUsage.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
# Prefer Xcode's toolchain: some Command Line Tools releases ship a duplicate SwiftBridging module map
# ("redefinition of module 'SwiftBridging'") that breaks every Swift build.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
xcrun swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14" \
  ClaudeUsage.swift -o "$APP/Contents/MacOS/ClaudeUsage" 2> build/swiftc.log || {
  grep -q "redefinition of module 'SwiftBridging'" build/swiftc.log &&
    echo "Your Command Line Tools have a known broken Swift module map. Install Xcode, or update the tools" \
         "(softwareupdate --list), then re-run." >&2
  grep -m5 'error:' build/swiftc.log >&2; exit 1; }
cat > "$APP/Contents/Info.plist" <<'PL'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ClaudeUsage</string>
  <key>CFBundleDisplayName</key><string>Claude Usage</string>
  <key>CFBundleIdentifier</key><string>local.claude-accounts.usage</string>
  <key>CFBundleExecutable</key><string>ClaudeUsage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PL
codesign --force --sign - "$APP" 2>/dev/null
echo "built $PWD/$APP"
