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
# Generate DMG background with Python
BACKGROUND_DIR="$BACKGROUND_DIR" python3 - << 'PYEOF2'
import struct, zlib, os

W, H = 540, 380

# --- minimal PNG writer ---
def make_png(pixels):  # pixels: list of (r,g,b) rows
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    rows = b"".join(b"\x00" + b"".join(struct.pack("BBB", *px) for px in row) for row in pixels)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows, 9))
            + chunk(b"IEND", b""))

# --- draw a pixel ---
bg = [[(247, 247, 247)] * W for _ in range(H)]

def set_px(x, y, rgb):
    if 0 <= x < W and 0 <= y < H:
        bg[y][x] = rgb

GRAY = (150, 150, 150)
DARK = (60, 60, 60)

# --- draw horizontal arrow line from x=235 to x=295, y=185 ---
for x in range(235, 300):
    set_px(x, 185, GRAY)

# arrowhead at x=300
for i in range(8):
    for j in range(-i, i+1):
        set_px(300 + i, 185 + j, GRAY)

# --- bitmap font: 5x7 digits/letters for "Drag to Applications to install" ---
# Use a simple dot-matrix approach for the label
FONT5 = {
    "D": [0x1E,0x11,0x11,0x11,0x1E], "r": [0x00,0x16,0x19,0x10,0x10],
    "a": [0x00,0x0E,0x09,0x0F,0x0B], "g": [0x00,0x0F,0x11,0x0F,0x01],
    " ": [0x00,0x00,0x00,0x00,0x00], "t": [0x08,0x1C,0x08,0x08,0x07],
    "o": [0x00,0x0E,0x11,0x11,0x0E], "A": [0x0E,0x11,0x1F,0x11,0x11],
    "p": [0x00,0x1E,0x11,0x1E,0x10], "l": [0x18,0x08,0x08,0x08,0x1C],
    "i": [0x08,0x00,0x18,0x08,0x1C], "c": [0x00,0x0E,0x10,0x10,0x0E],
    "n": [0x00,0x16,0x19,0x11,0x11], "s": [0x00,0x0F,0x18,0x06,0x1F],
    "I": [0x1C,0x08,0x08,0x08,0x1C], "h": [0x10,0x1E,0x11,0x11,0x11],
    "e": [0x00,0x0E,0x1F,0x10,0x0E], "f": [0x06,0x08,0x1C,0x08,0x08],
}

def draw_text(text, x0, y0, color=DARK, scale=1):
    x = x0
    for ch in text:
        cols = FONT5.get(ch, FONT5[" "])
        for ci, col in enumerate(cols):
            for row in range(7):
                if col & (1 << (6 - row)):
                    for sx in range(scale):
                        for sy in range(scale):
                            set_px(x + ci*scale + sx, y0 + row*scale + sy, color)
        x += (len(cols) + 1) * scale

label = "Drag to Applications to install"
text_w = len(label) * 6 * 1
text_x = (W - text_w) // 2
draw_text(label, text_x, 218, DARK, 1)

out = os.environ["BACKGROUND_DIR"] + "/bg.png"
with open(out, "wb") as f:
    f.write(make_png(bg))
print("Background generated")
PYEOF2
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
