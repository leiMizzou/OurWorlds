#!/usr/bin/env bash
# M1 端到端联机冒烟（无头、自动化）：起一个权威服务器 + 一个客户端，验证
#   连上 -> 收到 welcome（种子/出生点/增量）-> 客户端建出世界。退出码 0=通过。
# 用途：本地或 CI 快速确认联机数据链路没坏（避免每次都要人工开两个窗口）。
#   bash packaging/coop_smoke.sh
# 注意：这验证的是“连接 + 入场 + 世界同步”的数据链路；avatar 视觉/走动需 run_coop_demo.sh 人工确认。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
PORT="${OW_PORT:-8973}"
SRV_LOG="$(mktemp)"; CLI_LOG="$(mktemp)"

OW_SERVER=1 OW_PORT="$PORT" VC_SEED=4242 "$GODOT" --headless --path "$HERE" > "$SRV_LOG" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; rm -f "$SRV_LOG" "$CLI_LOG"' EXIT

# 等服务器监听就绪（最多 ~15s）
ready=0
for _i in $(seq 1 60); do
	kill -0 "$SRV" 2>/dev/null || break
	grep -q "联机服务器监听" "$SRV_LOG" && { ready=1; break; }
	sleep 0.25
done
[ "$ready" = 1 ] || { echo "❌ 服务器未监听"; sed 's/^/  srv| /' "$SRV_LOG" | tail -8; exit 1; }

# 客户端连上来，跑 ~6s 后自退
OW_CONNECT="ws://127.0.0.1:$PORT" VC_NO_SAVE=1 "$GODOT" --headless --path "$HERE" --quit-after 360 > "$CLI_LOG" 2>&1

err=0
grep -qE "SCRIPT ERROR|Parse Error" "$CLI_LOG" && { echo "❌ 客户端有脚本错误"; grep -nE "SCRIPT ERROR|Parse Error" "$CLI_LOG" | head -5; err=1; }
if grep -q "已连上服务器" "$CLI_LOG" && grep -q "脚下区域就绪" "$CLI_LOG"; then
	echo "✅ COOP SMOKE PASSED：客户端连上 → 收到 welcome → 建出世界（端到端数据链路通）"
else
	echo "❌ COOP SMOKE FAILED：客户端未完成入场"; sed 's/^/  cli| /' "$CLI_LOG" | grep -E "连接|已连上|入场|就绪|ERROR" | head -10; err=1
fi
exit $err
