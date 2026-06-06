#!/usr/bin/env bash
# 起"公网部署"所需的两个本地服务，Cloudflare Tunnel 会把它们暴露到你的二级域名：
#   1) 游戏权威服务器（Godot headless, :8971）
#   2) 网页客户端静态站（COOP/COEP, :8060）—— 需先 `bash packaging/build_web.sh` 导出过 build/web
# 然后另开一个终端跑隧道：
#   cloudflared tunnel --config deploy/cloudflared-config.yml run
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
GAME_PORT="${OW_PORT:-8971}"
WEB_PORT="${WEB_PORT:-8060}"

[ -f "$HERE/build/web/index.html" ] || { echo "未找到 build/web —— 先跑 'bash packaging/build_web.sh' 导出网页版。"; exit 1; }

echo "起游戏权威服务器 :$GAME_PORT ..."
OW_SERVER=1 OW_PORT="$GAME_PORT" "$GODOT" --headless --path "$HERE" &
GAME=$!
echo "起网页静态站 :$WEB_PORT（COOP/COEP）..."
python3 "$HERE/packaging/serve_web.py" "$WEB_PORT" &
WEB=$!
trap 'kill $GAME $WEB 2>/dev/null; echo "已停止。"; exit 0' INT

cat <<'TIP'

本地服务已起。下一步（另开一个终端）：
  cloudflared tunnel --config deploy/cloudflared-config.yml run

玩家入口链接（把 <你的域名> 换成你在 Cloudflare 绑定的）：
  https://ourworlds.<你的域名>/?connect=wss://play.ourworlds.<你的域名>

Ctrl+C 停本地服务。
TIP
wait
