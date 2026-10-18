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
echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/GitDeck" "$APP/Contents/MacOS/$PRODUCT_NAME"
cp -R "$BIN/GitDeck_GitDeck.bundle" "$APP/Contents/Resources/"
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
  <key>CFBundleVersion</key><string>$VERSION</string>
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
