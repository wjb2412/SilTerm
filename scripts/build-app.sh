#!/bin/bash
# SilTerm 打包脚本：构建可执行文件 → 组装 .app → ad-hoc 签名 → 注册到 LaunchServices
# 用法：bash scripts/build-app.sh [--universal]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="release"
BUILD_ARGS=(-c "$CONFIG" --package-path "$ROOT")

if [[ "${1:-}" == "--universal" ]]; then
    BUILD_ARGS+=(--arch arm64 --arch x86_64)
fi

echo "==> 编译 SilTerm ($CONFIG)"
swift build "${BUILD_ARGS[@]}"

BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
BIN="$BIN_DIR/SilTerm"
APP="$ROOT/build/SilTerm.app"

if [[ ! -x "$BIN" ]]; then
    echo "构建产物不存在：$BIN" >&2
    exit 1
fi

echo "==> 组装 $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SilTerm"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 架构：$(lipo -archs "$APP/Contents/MacOS/SilTerm")"

echo "==> ad-hoc 签名"
codesign --force --timestamp=none --sign - --identifier com.silterm.app "$APP"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    echo "==> 注册 LaunchServices（刷新服务菜单 / Dock 拖拽）"
    "$LSREGISTER" -f "$APP"
fi

echo "==> 完成：$APP"
echo "    首次运行请执行：open \"$APP\""
