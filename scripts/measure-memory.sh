#!/bin/bash
# SilTerm 内存测试：冷启动 / 空闲 / 多 Pane 的 RSS 采样
# 用法：bash scripts/measure-memory.sh [SilTerm.app 路径]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/SilTerm.app}"

if [[ ! -d "$APP" ]]; then
    echo "未找到 $APP，请先运行：bash scripts/build-app.sh" >&2
    exit 1
fi

echo "==> 启动 SilTerm（冷启动）"
open -n "$APP"
sleep 1

PID="$(pgrep -n -f "$APP/Contents/MacOS/SilTerm" || true)"
if [[ -z "$PID" ]]; then
    echo "未能获取 SilTerm 进程号" >&2
    exit 1
fi

rss() {
    ps -o rss= -p "$1" 2>/dev/null | awk '{printf "%.1f MB", $1/1024}'
}

echo "PID: $PID"
echo "冷启动 RSS: $(rss "$PID")  （目标 ≤ 30MB）"

echo "==> 空闲采样（10s）"
for _ in 1 2 3 4 5; do
    sleep 2
    echo "  空闲 RSS: $(rss "$PID")"
done

echo
echo "==> 多 Pane 测试"
echo "    请在 SilTerm 中执行：Cmd+D 三次（共 4 个 Pane），然后重新运行："
echo "    ps -o rss= -p $PID | awk '{printf \"4 Pane RSS: %.1f MB\\n\", \$1/1024}'"
echo "    目标：每个额外 Pane 增量 5~8MB。"
echo
echo "==> 退出测试：osascript -e 'tell application \"SilTerm\" to quit'"
