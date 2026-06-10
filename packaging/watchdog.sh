#!/bin/sh
# OurWorlds watchdog：定期检查核心服务，状态【变化】时发 macOS 通知（恢复也通知，绝不刷屏）。
# launchd 安装（StartInterval 300）：~/Library/LaunchAgents/app.ourworlds.watchdog.plist
# 检查项：游戏 :8971 / 网关 :8972 / 网页 :8060（/onboard）/ 公网（OW_WATCH_PUBLIC，留空跳过）。
STATE="$HOME/.ourworlds/watchdog.state"
PUB="${OW_WATCH_PUBLIC-https://play.ourworlds.app/onboard}"
mkdir -p "$HOME/.ourworlds"

fails=""
nc -z -G 3 127.0.0.1 8971 >/dev/null 2>&1 || fails="$fails game:8971"
nc -z -G 3 127.0.0.1 8972 >/dev/null 2>&1 || fails="$fails gateway:8972"
curl -fsS -m 5 -o /dev/null http://127.0.0.1:8060/onboard 2>/dev/null || fails="$fails web:8060"
if [ -n "$PUB" ]; then
  curl -fsS -m 10 -o /dev/null "$PUB" 2>/dev/null || fails="$fails public"
fi

prev=$(cat "$STATE" 2>/dev/null || echo "")
now="${fails:-ok}"
echo "$(date '+%F %T') $now"
if [ "$now" != "$prev" ]; then
  printf '%s' "$now" > "$STATE"
  if [ "$now" = "ok" ]; then
    osascript -e 'display notification "全部服务恢复正常 ✅" with title "OurWorlds watchdog"' 2>/dev/null || true
  else
    osascript -e "display notification \"服务异常:$now\" with title \"OurWorlds watchdog\" sound name \"Basso\"" 2>/dev/null || true
  fi
fi
