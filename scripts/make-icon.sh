#!/bin/bash
# 由一张方形插画生成 SilTerm 应用图标（去水印 → mac 圆角规范 → AppIcon.icns）
# 用法：
#   bash scripts/make-icon.sh <图片路径> [输出.icns]
#   SKIP_WATERMARK=1 bash scripts/make-icon.sh <图片路径>          # 图片本身无水印时
#   WATERMARK_PATCH_X=0.75 WATERMARK_PATCH_Y=0.90 bash scripts/make-icon.sh <图片路径>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INPUT="${1:-}"
OUTPUT="${2:-$ROOT/Resources/AppIcon.icns}"

if [[ -z "$INPUT" ]]; then
    echo "用法：bash scripts/make-icon.sh <图片路径> [输出.icns]" >&2
    exit 1
fi
if [[ ! -f "$INPUT" ]]; then
    echo "图片不存在：$INPUT" >&2
    exit 1
fi

SRC_IMAGE="$INPUT" OUT_ICNS="$OUTPUT" swift "$ROOT/scripts/make-icon.swift"

echo "==> 校验尺寸：$(sips -g pixelWidth -g pixelHeight "$OUTPUT" | tail -2 | tr -d '\n' | sed 's/  */ /g')"
echo "    文件大小：$(du -h "$OUTPUT" | cut -f1)"
