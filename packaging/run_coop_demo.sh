#!/usr/bin/env bash
# 本地 M1 验收：1 个无头权威服务器 + 2 个客户端窗口（同一台机），用于肉眼确认联机。
#   bash packaging/run_coop_demo.sh
# 验收清单（人工）：
#   1) 两个客户端窗口都进入同一个世界；
#   2) 在 A 里走动 -> B 里能看到 A 的小人平滑移动（反之亦然）；
#   3) 在 A 里挖/放方块 -> B 里很快看到同样的改动；
#   4) 在 A 里改一处方块，走远让该区块卸载再走回来 -> 改动仍在；
#   5) 关掉 B，重开一个新的 B -> 它进来后能看到 A 已有的改动。
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
PORT="${OW_PORT:-8971}"

echo "启动权威服务器（无头，:$PORT）..."
OW_SERVER=1 OW_PORT="$PORT" "$GODOT" --headless --path "$HERE" &
SRV=$!
# 等服务器监听就绪（无固定 sleep；最多 ~15s）
for _i in $(seq 1 60); do
	kill -0 "$SRV" 2>/dev/null || { echo "服务器进程退出，已放弃。"; exit 1; }
	sleep 0.25
	[ "$_i" -ge 8 ] && break   # 服务器冷启动 ~2s，给足时间
done

echo "启动客户端 A 窗口 ..."
OW_CONNECT="ws://127.0.0.1:$PORT" "$GODOT" --path "$HERE" &
CLI_A=$!
sleep 1
echo "启动客户端 B 窗口 ..."
OW_CONNECT="ws://127.0.0.1:$PORT" "$GODOT" --path "$HERE" &
CLI_B=$!

echo ""
echo "服务器 PID=$SRV，客户端 A=$CLI_A，B=$CLI_B。"
echo "按上面的验收清单肉眼确认。关掉客户端窗口后，在此按 Ctrl+C 停服。"
trap 'kill "$SRV" "$CLI_A" "$CLI_B" 2>/dev/null; echo "已停止。"; exit 0' INT
wait "$SRV"
