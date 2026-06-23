#!/usr/bin/env bash
# 全自动 UI 截图：重建 → 激活 → 取窗口边界 → 按区域截图
# 用法：./shoot.sh [输出文件名（默认 .design_shots/shot.png）]
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-.design_shots/shot.png}"
APP="$(pwd)/dist/AI工具助手.app"
PROC="ClaudeTokenUsage"

mkdir -p "$(dirname "$OUT")"

# 优雅退出旧实例（用 quit 事件，避免被 macOS 当作异常退出而弹"窗口恢复"提示）
if pgrep -x "$PROC" >/dev/null 2>&1; then
  osascript -e 'tell application id "local.claude-token-usage" to quit' >/dev/null 2>&1 || true
  sleep 1.2
  pkill -x "$PROC" 2>/dev/null || true   # 兜底
fi
sleep 0.5
open "$APP"
sleep 2.5

# 置前
osascript -e "tell application \"System Events\" to tell (first process whose name contains \"$PROC\") to set frontmost to true" >/dev/null 2>&1 || true
sleep 0.8

# 取窗口边界 position+size -> x,y,w,h
BOUNDS=$(osascript -e "tell application \"System Events\" to tell (first process whose name contains \"$PROC\") to get {position, size} of front window" 2>/dev/null || echo "")
if [[ -z "$BOUNDS" ]]; then
  echo "未取到窗口边界，回退全屏截图" >&2
  screencapture -x -o "$OUT"
else
  R=$(echo "$BOUNDS" | tr -d ' ' | awk -F, '{print $1","$2","$3","$4}')
  screencapture -x -o -R"$R" "$OUT"
fi
echo "saved $OUT"
