#!/bin/bash
set -e

VERSION=${1:-"1.0.0"}
APP_NAME="LockIn"
BUNDLE_ID="com.hamzaammar.lockin"
DIST_DIR="dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"

echo "🔨 Building LockIn v$VERSION..."

# ── 1. Compile ──
swift build -c release
BINARY=".build/release/$APP_NAME"

if [ ! -f "$BINARY" ]; then
  echo "❌ Build failed — binary not found at $BINARY"
  exit 1
fi

echo "✅ Build complete"

# ── 2. Create .app bundle structure ──
rm -rf "$DIST_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

# ── 3. Write Info.plist ──
cat > "$APP_DIR/Contents/Info.plist" << EOF
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
    <string>LockIn</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHumanReadableDescription</key>
    <string>Monitors your screen activity and notifies you when you're procrastinating.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>LockIn uses AppleScript to send notifications.</string>
</dict>
</plist>
EOF

echo "✅ App bundle created"

# ── 4. App icon ──
if [ -f "icon.png" ]; then
  echo "🎨 Generating iconset..."
  ICONSET="$APP_DIR/Contents/Resources/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 64 128 256 512; do
    sips -z $size $size icon.png --out "$ICONSET/icon_${size}x${size}.png" > /dev/null 2>&1
    double=$((size * 2))
    sips -z $double $double icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null 2>&1
  done
  iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null && \
    rm -rf "$ICONSET" && echo "✅ Icon generated" || echo "⚠️  Icon generation failed (skipping)"
fi

# ── 5. Ad-hoc code sign ──
echo "🔏 Signing..."
codesign --force --deep --sign - \
  --options runtime \
  "$APP_DIR"
echo "✅ Signed (ad-hoc)"

# ── 6. Zip for Homebrew ──
echo "📦 Creating zip..."
ZIP_PATH="$DIST_DIR/$APP_NAME-$VERSION.zip"
cd "$DIST_DIR"
zip -qr "$APP_NAME-$VERSION.zip" "$APP_NAME.app"
cd ..
echo "✅ Done!"
echo "📦 Zip: $ZIP_PATH"
