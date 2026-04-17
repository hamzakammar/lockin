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

# Copy binary
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

# ── 4. App icon (if icon.png exists in repo root) ──
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
else
  echo "⚠️  No icon.png found — app will use default icon. Add a 512x512 icon.png to the repo root."
fi

# ── 5. Ad-hoc code sign ──
echo "🔏 Signing..."
codesign --force --deep --sign - \
  --options runtime \
  "$APP_DIR"
echo "✅ Signed (ad-hoc)"

# ── 6. Create DMG ──
echo "📦 Creating DMG..."

DMG_STAGING="$DIST_DIR/dmg_staging"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
DMG_TMP="$DIST_DIR/$APP_NAME-$VERSION-tmp.dmg"
BACKGROUND_DIR="$DMG_STAGING/.background"

mkdir -p "$DMG_STAGING"
mkdir -p "$BACKGROUND_DIR"

# Generate a clean background image (dark gradient)
# Generate DMG background using osascript + Cocoa
osascript << 'APPLESCRIPT_BG'
use framework "AppKit"
use framework "Foundation"
use scripting additions

set W to 540
set H to 380
set outPath to (system attribute "BACKGROUND_DIR") & "/bg.png"

-- Create bitmap
set bmp to current application's NSBitmapImageRep's alloc()'s initWithBitmapDataPlanes:(missing value) pixelsWide:W pixelsHigh:H bitsPerSample:8 samplesPerPixel:4 hasAlpha:true isPlanar:false colorSpaceName:(current application's NSCalibratedRGBColorSpace) bytesPerRow:0 bitsPerPixel:0

set ctx to current application's NSGraphicsContext's graphicsContextWithBitmapImageRep:bmp
current application's NSGraphicsContext's setCurrentContext:ctx

-- White background
set bgColor to current application's NSColor's colorWithRed:0.97 green:0.97 blue:0.97 alpha:1.0
bgColor's setFill()
current application's NSRectFill({x:0, y:0, |width|:W, |height|:H})

-- Drag arrow (→) between app icon and Applications folder
-- App icon center: x=160, Applications center: x=380, y=195 from bottom
set arrowColor to current application's NSColor's colorWithRed:0.5 green:0.5 blue:0.5 alpha:0.8
arrowColor's set()
set arrowFont to current application's NSFont's systemFontOfSize:40
set arrowAttrs to current application's NSDictionary's dictionaryWithObjects:{arrowFont, arrowColor} forKeys:{current application's NSFontAttributeName, current application's NSForegroundColorAttributeName}
set arrowStr to current application's NSAttributedString's alloc()'s initWithString:"→" attributes:arrowAttrs
set arrowSize to arrowStr's |size|()
set arrowX to (W / 2) - ((arrowSize's |width|()) / 2)
set arrowY to 175
arrowStr's drawAtPoint:{arrowX, arrowY}

-- Label: "Drag to install"
set labelColor to current application's NSColor's colorWithRed:0.4 green:0.4 blue:0.4 alpha:1.0
set labelFont to current application's NSFont's systemFontOfSize:12
set labelAttrs to current application's NSDictionary's dictionaryWithObjects:{labelFont, labelColor} forKeys:{current application's NSFontAttributeName, current application's NSForegroundColorAttributeName}
set labelStr to current application's NSAttributedString's alloc()'s initWithString:"Drag to Applications to install" attributes:labelAttrs
set labelSize to labelStr's |size|()
set labelX to (W / 2) - ((labelSize's |width|()) / 2)
labelStr's drawAtPoint:{labelX, 140}

ctx's flushGraphics()

-- Save as PNG
set pngData to bmp's representationUsingType:(current application's NSBitmapImageFileTypePNG) |properties|:(missing value)
pngData's writeToFile:(outPath) atomically:true
APPLESCRIPT_BG
echo "Background generated" 

# Create a writable DMG, set layout with AppleScript, then convert to compressed
hdiutil create -size 80m -fs HFS+ -volname "$APP_NAME" "$DMG_TMP" -quiet
MOUNT_OUTPUT=$(hdiutil attach "$DMG_TMP" -readwrite -noverify -noautoopen)
DEVICE=$(echo "$MOUNT_OUTPUT" | grep "Apple_HFS" | awk '{print $1}')
VOLUME="/Volumes/$APP_NAME"

# Copy files
cp -r "$APP_DIR" "$VOLUME/"
ln -sf /Applications "$VOLUME/Applications"
mkdir -p "$VOLUME/.background"
cp "$BACKGROUND_DIR/bg.png" "$VOLUME/.background/bg.png"

# AppleScript to set window size, icon positions, background, hide toolbar
osascript << APPLESCRIPT
tell application "Finder"
  tell disk "$APP_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 200, 740, 580}
    set theViewOptions to the icon view options of container window
    set arrangement of theViewOptions to not arranged
    set icon size of theViewOptions to 96
    set background picture of theViewOptions to file ".background:bg.png"
    set position of item "$APP_NAME.app" to {160, 185}
    set position of item "Applications" to {380, 185}
    close
    open
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

# Bless and detach
chmod -Rf go-w "$VOLUME/.background"
hdiutil detach "$DEVICE" -quiet

# Convert to compressed, read-only
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" -quiet
rm -f "$DMG_TMP"
rm -rf "$DMG_STAGING"

echo ""
echo "✅ Done!"
echo "📦 DMG: $DMG_PATH"
echo ""
echo "To install: open $DMG_PATH, drag LockIn to Applications."
echo "First launch: right-click → Open (Gatekeeper bypass, one-time only)."
