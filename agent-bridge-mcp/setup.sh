#!/usr/bin/env bash
# OurWorlds × OpenClaw 接入一键准备：环境自检 → 构建 MCP 服务器 → 拷贝示例 agent 工作区。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

echo "== OurWorlds agent 接入 setup =="

# 1) 环境自检 (doctor)
MISSING=0
check() {
  if command -v "$1" >/dev/null 2>&1; then
    echo "  ✅ $1"
  else
    echo "  ❌ 缺少 $1 — $2"; MISSING=1
  fi
}
check node  "安装 Node.js >= 18 (https://nodejs.org)"
check godot "安装 Godot 4.6.x 并加入 PATH"
if command -v openclaw >/dev/null 2>&1; then
  echo "  ✅ openclaw"
else
  echo "  ⚠️ 未检测到 openclaw —— 仅当你用 OpenClaw 自带 agent 时需要；其它 MCP 客户端可忽略。"
fi
if [ "$MISSING" = "1" ]; then
  echo "请先安装缺失的依赖再重试。"; exit 1
fi

# 2) 构建 MCP 服务器
echo "==> 构建 MCP 服务器 (npm install && npm run build)…"
( cd "$HERE" && npm install && npm run build )

# 3) 拷贝示例 agent 工作区（若尚不存在）
WS="$HOME/.openclaw/agents/opc-ourworlds/workspace"
TMPL="$ROOT/docs/openclaw/opc-ourworlds"
if [ -d "$TMPL" ] && [ ! -e "$WS" ]; then
  mkdir -p "$WS" && cp -R "$TMPL"/. "$WS"/
  echo "  ✅ 已拷贝 agent 工作区模板 → $WS"
else
  echo "  ℹ️ 跳过工作区拷贝（模板缺失或 $WS 已存在）。"
fi

echo ""
echo "完成 ✅"
echo "下一步："
echo "  1) 启动游戏：       bash \"$ROOT/run_with_agent.sh\""
echo "  2) 进入/新建一个世界"
echo "  3) 把本 MCP 服务器接入你的 OpenClaw（详见 docs/openclaw-integration.md 的 Quickstart）"
