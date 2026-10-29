#!/usr/bin/env bash
# 构建 mac 端并组装为 .app（arm64，macOS 15+）。
#
# 用法：scripts/build-mac-app.sh [debug|release]（默认 debug）
# 产物：build/<CONFIG>/GitDeck.app
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/product.env"

# 本机使用 Xcode-beta，不改动系统级 xcode-select（见 docs/DECISIONS.md）。
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app ]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

"$ROOT/scripts/build-core-mac.sh" "$CONFIG"

echo "==> swift build ($CONFIG)"
PKG="$ROOT/apps/mac"
swift build --package-path "$PKG" -c "$CONFIG" --arch arm64
BIN="$(swift build --package-path "$PKG" -c "$CONFIG" --arch arm64 --show-bin-path)"

APP="$ROOT/build/$CONFIG/$PRODUCT_NAME.app"
# Debug 构建使用独立的 Bundle ID：设置、钥匙串项与最近项目和正式版互不影响。
if [ "$CONFIG" = "debug" ]; then
  BUNDLE_ID="$BUNDLE_ID.debug"
fi
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GitDeck" "$APP/Contents/MacOS/$PRODUCT_NAME"
cp -R "$BIN/GitDeck_GitDeck.bundle" "$APP/Contents/Resources/"
# 文案：SwiftPM 只有在工具链带有 xcstringstool 时才会把 Localizable.xcstrings 编译为各语言的 .lproj，
# 否则资源包里只有原始的 .xcstrings，界面显示的全是键名（GitHub Actions 的 Xcode 正式版即是如此）。
RES_BUNDLE="$APP/Contents/Resources/GitDeck_GitDeck.bundle"
if ! ls "$RES_BUNDLE"/*.lproj/Localizable.strings >/dev/null 2>&1; then
  XCSTRINGS="$PKG/Sources/GitDeck/Resources/Localizable.xcstrings"
  echo "==> 编译文案：${XCSTRINGS}"
  if ! xcrun xcstringstool compile "$XCSTRINGS" --output-directory "$RES_BUNDLE" 2>/dev/null      || ! ls "$RES_BUNDLE"/*.lproj/Localizable.strings >/dev/null 2>&1; then
    python3 "$ROOT/scripts/xcstrings-to-strings.py" "$XCSTRINGS" "$RES_BUNDLE"
  fi
  rm -f "$RES_BUNDLE/Localizable.xcstrings"
fi
# 主包声明支持的语言，系统“设置 > 语言与地区 > App”中才会列出本应用。
for lang in en zh-Hans; do
  mkdir -p "$APP/Contents/Resources/$lang.lproj"
  printf '"CFBundleName" = "%s";\n' "$PRODUCT_NAME" > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
done

# 应用图标：由 assets/icon/GitDeck-1024.png（scripts/make-icon.swift 生成）缩放出各尺寸并打包为 .icns。
ICON_SRC="$ROOT/assets/icon/GitDeck-1024.png"
if [ -f "$ICON_SRC" ]; then
  ICONSET="$ROOT/build/$CONFIG/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

VERSION="$(grep -m1 '^version' "$ROOT/Cargo.toml" | sed -E 's/.*"(.*)".*/\1/')"
# CFBundleVersion 只能是数字：预发布版本（如 0.2.0-beta）取数字部分，显示的版本仍为完整版本号。
BUILD_VERSION="${VERSION%%[-+]*}"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$PRODUCT_NAME</string>
  <key>CFBundleDisplayName</key><string>$PRODUCT_NAME</string>
  <key>CFBundleExecutable</key><string>$PRODUCT_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hans</string></array>
  <key>LSMinimumSystemVersion</key><string>$MACOS_MIN</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"

# 本地开发使用 ad-hoc 签名；发布签名与公证在打包阶段处理。
codesign --force --deep --sign - "$APP" >/dev/null
echo "==> 完成：$APP"
