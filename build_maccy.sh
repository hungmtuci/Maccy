#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi
export PATH="$HOME/.local/bin:$PROJECT_DIR:$PATH"

APP_NAME="Maccy"
BUNDLE_ID="org.p0deje.Maccy"
VERSION="2.6.0-custom"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
WORKSPACE_APP_BUNDLE="$(dirname "$PROJECT_DIR")/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> [1/5] Đang biên dịch $APP_NAME (Release)..."
swift build --build-system native -c release --product "$APP_NAME"
BIN_PATH="$(swift build --build-system native -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

echo "==> [2/5] Đang tạo AppIcon.icns từ Assets.xcassets..."
ICONSET_DIR="$PROJECT_DIR/.build/AppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

APPICON_SRC="$PROJECT_DIR/Maccy/Assets.xcassets/AppIcon.appiconset"
cp "$APPICON_SRC/AppIcon (Big Sur)-16w.png" "$ICONSET_DIR/icon_16x16.png" 2>/dev/null || true
cp "$APPICON_SRC/AppIcon (Big Sur)-32w.png" "$ICONSET_DIR/icon_16x16@2x.png" 2>/dev/null || true
cp "$APPICON_SRC/AppIcon (Big Sur)-32w-1.png" "$ICONSET_DIR/icon_32x32.png" 2>/dev/null || true
cp "$APPICON_SRC/AppIcon (Big Sur)-64w.png" "$ICONSET_DIR/icon_32x32@2x.png" 2>/dev/null || true
cp "$APPICON_SRC/AppIcon (Big Sur)-128w.png" "$ICONSET_DIR/icon_128x128.png" 2>/dev/null || true
cp "$APPICON_SRC/AppIcon (Big Sur)-256w.png" "$ICONSET_DIR/icon_128x128@2x.png" 2>/dev/null || true
cp "$APPICON_SRC/AppIcon (Big Sur)-256w-1.png" "$ICONSET_DIR/icon_256x256.png" 2>/dev/null || true
cp "$APPICON_SRC/AppIcon (Big Sur)-512w.png" "$ICONSET_DIR/icon_256x256@2x.png" 2>/dev/null || true
cp "$APPICON_SRC/AppIcon (Big Sur)-512w-1.png" "$ICONSET_DIR/icon_512x512.png" 2>/dev/null || true
cp "$APPICON_SRC/AppIcon (Big Sur)-1024w.png" "$ICONSET_DIR/icon_512x512@2x.png" 2>/dev/null || true

echo "==> [3/5] Đang đóng gói $APP_NAME.app và tài nguyên đa ngôn ngữ..."
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns" || true

# Copy SwiftPM resource bundles (e.g. KeyboardShortcuts_KeyboardShortcuts.bundle)
BIN_DIR="$(dirname "$BIN_PATH")"
for bundle in "$BIN_DIR"/*.bundle; do
  if [ -d "$bundle" ]; then
    cp -R "$bundle" "$RESOURCES_DIR/" 2>/dev/null || true
  fi
done

# Copy menu bar images
cp "$PROJECT_DIR/Maccy/Assets.xcassets/StatusBarMenuImage.imageset/DarkMenuBar-16w.png" "$RESOURCES_DIR/StatusBarMenuImage.png" 2>/dev/null || true
cp "$PROJECT_DIR/Maccy/Assets.xcassets/StatusBarMenuImage.imageset/DarkMenuBar-32w.png" "$RESOURCES_DIR/StatusBarMenuImage@2x.png" 2>/dev/null || true
cp "$PROJECT_DIR/Maccy/Assets.xcassets/clipboard.fill.imageset/clipboard.fill.dark_16.png" "$RESOURCES_DIR/clipboard.fill.png" 2>/dev/null || true
cp "$PROJECT_DIR/Maccy/Assets.xcassets/clipboard.fill.imageset/clipboard.fill.dark_32.png" "$RESOURCES_DIR/clipboard.fill@2x.png" 2>/dev/null || true
cp "$PROJECT_DIR/Maccy/Assets.xcassets/scissors.imageset/scissors_dark_16.png" "$RESOURCES_DIR/scissors.png" 2>/dev/null || true
cp "$PROJECT_DIR/Maccy/Assets.xcassets/scissors.imageset/scissors_dark_32.png" "$RESOURCES_DIR/scissors@2x.png" 2>/dev/null || true
cp "$PROJECT_DIR/Maccy/Assets.xcassets/paperclip.imageset/clip.fill.dark_16 1.png" "$RESOURCES_DIR/paperclip.png" 2>/dev/null || true
cp "$PROJECT_DIR/Maccy/Assets.xcassets/paperclip.imageset/clip.fill.dark_32 1.png" "$RESOURCES_DIR/paperclip@2x.png" 2>/dev/null || true

# Copy sounds
if [ -d "$PROJECT_DIR/Maccy/Sounds" ]; then
  cp -R "$PROJECT_DIR/Maccy/Sounds/"* "$RESOURCES_DIR/" 2>/dev/null || true
fi

# Merge all .lproj localization tables into Contents/Resources/<lang>.lproj
for dir in "$PROJECT_DIR/Maccy" "$PROJECT_DIR/Maccy/Settings" "$PROJECT_DIR/Maccy/Views"; do
  if [ -d "$dir" ]; then
    for lproj in "$dir"/*.lproj; do
      if [ -d "$lproj" ]; then
        lang_name="$(basename "$lproj")"
        mkdir -p "$RESOURCES_DIR/$lang_name"
        cp -R "$lproj/"* "$RESOURCES_DIR/$lang_name/" 2>/dev/null || true
      fi
    done
  fi
done

cat > "$CONTENTS_DIR/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>vi</string>
	<key>CFBundleExecutable</key>
	<string>${APP_NAME}</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundleDisplayName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${VERSION}</string>
	<key>CFBundleVersion</key>
	<string>260</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>UTExportedTypeDeclarations</key>
	<array>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>org.p0deje.Maccy.pin-reorder</string>
			<key>UTTypeTagSpecification</key>
			<dict/>
			<key>UTTypeDescription</key>
			<string>Maccy Pin Reorder Type</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.data</string>
			</array>
		</dict>
	</array>
</dict>
</plist>
EOF

echo "==> [4/5] Đang ký số (Ad-hoc Codesign)..."
TMP_SIGN_DIR="/tmp/maccy_sign_$$"
rm -rf "$TMP_SIGN_DIR"
mkdir -p "$TMP_SIGN_DIR"
cp -R "$APP_BUNDLE" "$TMP_SIGN_DIR/$APP_NAME.app"
xattr -cr "$TMP_SIGN_DIR/$APP_NAME.app" 2>/dev/null || true
codesign --force --deep --sign - "$TMP_SIGN_DIR/$APP_NAME.app"
rm -rf "$APP_BUNDLE"
cp -R "$TMP_SIGN_DIR/$APP_NAME.app" "$APP_BUNDLE"
rm -rf "$TMP_SIGN_DIR"

echo "==> [5/5] Đang sao chép sang $WORKSPACE_APP_BUNDLE và /Applications/$APP_NAME.app..."
rm -rf "$WORKSPACE_APP_BUNDLE"
cp -R "$APP_BUNDLE" "$WORKSPACE_APP_BUNDLE"

if [ -w "/Applications" ]; then
  killall "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
fi

echo "==> Hoàn tất đóng gói Maccy.app!"
echo "    - $APP_BUNDLE"
echo "    - $WORKSPACE_APP_BUNDLE"
echo "    - /Applications/$APP_NAME.app"
