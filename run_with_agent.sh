#!/usr/bin/env bash
# 以「可被 agent 接入」模式启动 OurWorlds。
# 打开本地 TCP 桥（仅 127.0.0.1），你的 OpenClaw / MCP 客户端 / 示例脚本即可连入并自主游玩。
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export OW_AGENT_PORT="${OW_AGENT_PORT:-8970}"
GODOT="${GODOT:-godot}"

echo "==> OurWorlds 启动中…"
echo "    Agent 桥:  127.0.0.1:${OW_AGENT_PORT}   (设 OW_AGENT_PORT 可改端口；不设则此脚本默认 8970)"
echo "    连接方式:  agent-bridge-mcp (MCP) 或 agent-bridge-mcp/examples/ 里的脚本"
echo "    进入/新建一个世界后，agent 即可 observe / build / scan …"
echo ""
exec "$GODOT" --path "$HERE" "$@"
