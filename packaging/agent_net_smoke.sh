#!/usr/bin/env bash
# M2b 冒烟（无头）：AI agent 作为联机玩家。
# 起 权威服务器 + 一个 agent-client（OW_CONNECT + OW_AGENT_PORT）；用 TCP 扮演 OpenClaw 驱动它：
#   goto 到远离出生点的地方 → 在小人脚下放一块石头 → 读回该格。
# 关键点：服务器按 agent 小人的真实位置（report_node）校验编辑——若没接好，远处放置会因"超出可及距离"被拒，
#         读回就不是石头。读回是 stone 即证明 agent 作为联机玩家能在它走到的地方改世界。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"; PORT="${OW_PORT:-8975}"; AGENT_PORT="${OW_AGENT_PORT:-8970}"
SRV_LOG="$(mktemp)"; CLI_LOG="$(mktemp)"

OW_SERVER=1 OW_PORT="$PORT" VC_SEED=4242 "$GODOT" --headless --path "$HERE" > "$SRV_LOG" 2>&1 &
SRV=$!
OW_CONNECT="ws://127.0.0.1:$PORT" OW_AGENT_PORT="$AGENT_PORT" VC_NO_SAVE=1 "$GODOT" --headless --path "$HERE" > "$CLI_LOG" 2>&1 &
CLI=$!
trap 'kill "$SRV" "$CLI" 2>/dev/null; wait "$SRV" "$CLI" 2>/dev/null; rm -f "$SRV_LOG" "$CLI_LOG"' EXIT

# 等 agent-client 入场 + agent 桥监听
ready=0
for _i in $(seq 1 80); do
	kill -0 "$CLI" 2>/dev/null || break
	if grep -q "脚下区域就绪" "$CLI_LOG" && grep -q "AgentBridge 监听" "$CLI_LOG"; then ready=1; break; fi
	sleep 0.25
done
[ "$ready" = 1 ] || { echo "❌ agent-client 未就绪（入场/agent 桥）"; grep -nE "连接|已连上|就绪|监听|ERROR" "$CLI_LOG" | head; exit 1; }

python3 - "$AGENT_PORT" <<'PY'
import socket, json, time, sys
port = int(sys.argv[1])
s = socket.create_connection(("127.0.0.1", port), timeout=10)
f = s.makefile("rwb")
def call(tool, args):
    f.write((json.dumps({"id": 1, "tool": tool, "args": args}) + "\n").encode()); f.flush()
    return json.loads(f.readline().decode())
g = call("goto", {"x": 60, "z": 60})                       # 走到远离出生点处
py = g["result"]["pos"][1]
time.sleep(0.5)                                            # 让客户端把 agent 位置上报给服务器
call("place", {"block": "stone", "cells": [[60, py, 60]]}) # 在小人脚下放石头
time.sleep(0.9)                                            # 等 请求→服务器校验→广播→本地应用 的往返
gb = call("get_block", {"x": 60, "y": py, "z": 60})
blk = gb.get("result", {}).get("block", "?")
print("place_y=%d  get_block=%s" % (py, blk))
sys.exit(0 if blk == "stone" else 2)
PY
rc=$?
if [ "$rc" = 0 ]; then
	echo "✅ AGENT NET SMOKE PASSED：agent 走到远处 → 在那里放方块 → 服务器按其真实位置授权 → 改动落到世界"
else
	echo "❌ AGENT NET SMOKE FAILED（rc=$rc）：远处放置未生效（report_node 没接好？编辑被 reach 拒绝？）"
	grep -nE "ERROR|SCRIPT" "$CLI_LOG" | head
fi
exit $rc
