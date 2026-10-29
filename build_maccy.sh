#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$PROJECT_DIR"

if [ -d "/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk" ]; then
  export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
fi
export PATH="$HOME/.local/bin:$PROJECT_DIR:$PATH"
export COPYFILE_DISABLE=1

APP_NAME="Maccy"
BUNDLE_ID="org.p0deje.Maccy"
VERSION="3.1.0-custom"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
WORKSPACE_APP_BUNDLE="$(dirname "$PROJECT_DIR")/$APP_NAME.app"

STAGE_DIR="/tmp/maccy_stage_$$"
STAGE_APP="$STAGE_DIR/$APP_NAME.app"
CONTENTS_DIR="$STAGE_APP/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> [1/5] Đang biên dịch $APP_NAME Universal (arm64 + x86_64, SwiftBuild Release)..."
find "$PROJECT_DIR" -not -path '*/.git/*' -not -path '*/.build/*' -name '* 2*' -delete 2>/dev/null || true

# IMPORTANT: Never pass `--build-system native`! The legacy build system hardcodes local `.build` paths
# into `Bundle.module` (`resource_bundle_accessor.swift`) instead of checking `Bundle.main.resourceURL`,
# which causes an immediate fatalError crash when launching the `.app` on any other Mac!
SWIFTC_COMPAT_FLAGS=(
  -Xswiftc -runtime-compatibility-version -Xswiftc none
  -Xswiftc -disable-autolinking-runtime-compatibility
  -Xswiftc -disable-autolinking-runtime-compatibility-concurrency
  -Xswiftc -disable-autolinking-runtime-compatibility-dynamic-replacements
)

if swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME" "${SWIFTC_COMPAT_FLAGS[@]}"; then
  BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --product "$APP_NAME" "${SWIFTC_COMPAT_FLAGS[@]}" --show-bin-path)"
else
  echo "    (Fallback biên dịch kiến trúc gốc arm64...)"
  swift build -c release --product "$APP_NAME"
  BIN_DIR="$(swift build -c release --product "$APP_NAME" --show-bin-path)"
fi
BIN_PATH="$BIN_DIR/$APP_NAME"

echo "==> [2/5] Đang tạo AppIcon.icns từ Assets.xcassets..."
ICONSET_DIR="/tmp/maccy_iconset_$$.iconset"
rm -rf "$ICONSET_DIR" "$STAGE_DIR"
mkdir -p "$ICONSET_DIR" "$MACOS_DIR" "$RESOURCES_DIR"

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

echo "==> [3/5] Đang đóng gói $APP_NAME.app chuẩn macOS trong /tmp (tránh FinderInfo xattr)..."
cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns" || true
rm -rf "$ICONSET_DIR"

# Copy SwiftBuild resource bundles (Contents/Info.plist format) into Contents/Resources/
for bundle in "$BIN_DIR"/*.bundle; do
  if [ -d "$bundle" ]; then
    ditto --norsrc "$bundle" "$RESOURCES_DIR/$(basename "$bundle")"
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
	<string>310</string>
	<key>NSHumanReadableCopyright</key>
	<string>Copyright © Alexey Rodionov • Custom Edition by Hung Le Xuan</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>Maccy sử dụng quyền Automation để nhập trực tiếp bộ gõ tắt từ Typinator và chạy AppleScript/JXA trong Snippets.</string>
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

echo "==> [4/5] Đang làm sạch xattr, ký số chuẩn Strict Codesign & đóng gói Zip phát hành..."
chmod -R u+w "$STAGE_APP" 2>/dev/null || true
xattr -cr "$STAGE_APP" 2>/dev/null || true
find "$STAGE_APP" -name '._*' -delete 2>/dev/null || true

for nested_bundle in "$RESOURCES_DIR"/*.bundle; do
  if [ -d "$nested_bundle" ]; then
    codesign --force --sign - "$nested_bundle"
  fi
done
codesign --force --deep --sign - "$STAGE_APP"
codesign --verify --deep --strict -vvvv "$STAGE_APP"

DIST_ZIP="/tmp/${APP_NAME}-v${VERSION}.zip"
rm -f "$DIST_ZIP"
ditto -c -k --norsrc --keepParent "$STAGE_APP" "$DIST_ZIP"

echo "==> [5/5] Đang cài đặt sang /Applications/$APP_NAME.app và $WORKSPACE_APP_BUNDLE..."
rm -rf "$APP_BUNDLE" "$WORKSPACE_APP_BUNDLE"
ditto --norsrc "$STAGE_APP" "$APP_BUNDLE"
ditto --norsrc "$STAGE_APP" "$WORKSPACE_APP_BUNDLE"

if [ -w "/Applications" ]; then
  killall "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  ditto --norsrc "$STAGE_APP" "/Applications/$APP_NAME.app"
fi

rm -rf "$STAGE_DIR"

echo "==> Hoàn tất đóng gói Maccy.app ($VERSION)!"
echo "    - /Applications/$APP_NAME.app"
echo "    - Gói cài đặt sạch cho máy khác: $DIST_ZIP"
