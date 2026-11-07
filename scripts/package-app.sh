#!/bin/bash
# Builds KPTN.SUB.app (Apple Silicon + Intel, macOS 14+), self-signs it and zips it,
# so it can be copied to other Macs that don't have Xcode.
#
#   scripts/package-app.sh [output folder]     (default: ~/Desktop)
#
# Self-signed only: on each Mac, the first launch is blocked until you choose
# System Settings ▸ Privacy & Security ▸ Open Anyway.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$HOME/Desktop}"
NAME="KPTN.SUB"
BUNDLE_ID="com.kptn.sub"
VERSION="0.$(git rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
ARCHS=(--arch arm64 --arch x86_64)

echo "Building $NAME $VERSION ($COMMIT), universal release…"
swift build -c release "${ARCHS[@]}"
BIN_DIR="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

STAGE="$(mktemp -d)"
APP="$STAGE/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Titles" "$APP/Contents/MacOS/$NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$COMMIT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>KPTN.SUB Project</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Owner</string>
      <key>CFBundleTypeExtensions</key><array><string>kptnsub</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST

echo "Self-signing…"
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

mkdir -p "$OUT"
ZIP="$OUT/$NAME-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf "$STAGE"
echo "Done: $ZIP"
lipo -info "$BIN_DIR/Titles" || true
