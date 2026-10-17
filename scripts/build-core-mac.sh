#!/usr/bin/env bash
# 构建 Rust 核心并为 mac 端生成 Swift 绑定与 XCFramework。
#
# 产物（均在 apps/mac/Generated/，已加入 .gitignore）：
#   GitDeckCoreFFI.xcframework   静态库 + C 头文件 + modulemap
#   GitDeckCore/gitdeck_core.swift  UniFFI 生成的 Swift API
#
# 用法：scripts/build-core-mac.sh [debug|release]（默认 debug）
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="aarch64-apple-darwin"
OUT="$ROOT/apps/mac/Generated"
STAGE="$ROOT/build/mac-core"

# shellcheck disable=SC1091
[ -f "$HOME/.cargo/env" ] && source "$HOME/.cargo/env"

# 与应用最低系统版本保持一致（见 docs/DECISIONS.md）。
export MACOSX_DEPLOYMENT_TARGET=15.0

CARGO_FLAGS=(--target "$TARGET" -p gitdeck-core)
[ "$CONFIG" = "release" ] && CARGO_FLAGS+=(--release)

echo "==> cargo build ($CONFIG, $TARGET)"
cargo build --manifest-path "$ROOT/Cargo.toml" "${CARGO_FLAGS[@]}"
LIB_DIR="$ROOT/target/$TARGET/$CONFIG"

echo "==> 生成 Swift 绑定"
rm -rf "$STAGE"
mkdir -p "$STAGE/bindings" "$STAGE/headers"
cargo run -q --manifest-path "$ROOT/Cargo.toml" -p uniffi-bindgen -- \
  generate --library "$LIB_DIR/libgitdeck_core.dylib" \
  --language swift --out-dir "$STAGE/bindings"

cp "$STAGE/bindings/gitdeck_coreFFI.h" "$STAGE/headers/"
cp "$STAGE/bindings/gitdeck_coreFFI.modulemap" "$STAGE/headers/module.modulemap"

echo "==> 打包 XCFramework"
rm -rf "$OUT"
mkdir -p "$OUT/GitDeckCore"
xcodebuild -create-xcframework \
  -library "$LIB_DIR/libgitdeck_core.a" \
  -headers "$STAGE/headers" \
  -output "$OUT/GitDeckCoreFFI.xcframework" >/dev/null
cp "$STAGE/bindings/gitdeck_core.swift" "$OUT/GitDeckCore/"

echo "==> 完成：$OUT"
