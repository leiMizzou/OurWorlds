#!/usr/bin/env bash
# OurWorlds 发布部署：把【已提交】的代码部署到独立的发布检出（git worktree）并重启服务。
# 动机：此前 launchd 服务直接跑开发工作区 → 任何会话的未提交改动会随服务重启"被动上线"。
# 现在：开发在工作区随便改；上线 = 提交 → 跑本脚本（只部署提交过的 ref）。
#
#   用法: bash packaging/deploy_release.sh [ref]   # ref 默认 main（本地分支即可，无需推送）
#   发布目录: $OW_RELEASE_DIR（默认 ~/ourworlds-release，git worktree，与主仓共享对象库）
#   服务切换: 哪个 plist 的路径指向发布目录，就重启哪个（play-server 已切；
#             play-web 等面板 v3 合入后把 plist 路径同样指过来即可）。
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REL="${OW_RELEASE_DIR:-$HOME/ourworlds-release}"
REF="${1:-main}"
UID_N="$(id -u)"

echo "==> [1/5] 同步发布检出 $REL → $REF"
if [ ! -e "$REL/.git" ]; then
  git -C "$REPO" worktree add --detach "$REL" "$REF"
else
  git -C "$REL" checkout --detach "$REF"
fi
echo "    发布版本: $(git -C "$REL" log --oneline -1)"

echo "==> [2/5] Agent 桥依赖 + 单文件 bundle"
( cd "$REL/agent-bridge-mcp" && npm ci --silent --no-audit --no-fund )
bash "$REL/packaging/build_agent_bundle.sh"

echo "==> [3/5] 导出 Web（含预压缩；OW_SERVE=0 只构建不起服务）"
OW_SERVE=0 bash "$REL/packaging/build_web.sh"

echo "==> [4/5] 重启指向发布检出的服务"
for SVC in app.ourworlds.play-server app.ourworlds.play-web; do
  PL="$HOME/Library/LaunchAgents/$SVC.plist"
  [ -f "$PL" ] || continue
  if grep -q "$REL" "$PL"; then
    launchctl bootout "gui/$UID_N/$SVC" 2>/dev/null || true
    # launchctl bootstrap 偶发瞬态 "5: Input/output error"——重试最多 3 次
    ok=""
    for _ in 1 2 3; do
      if launchctl bootstrap "gui/$UID_N" "$PL" 2>/dev/null; then ok=1; break; fi
      sleep 2
    done
    [ -n "$ok" ] || launchctl bootstrap "gui/$UID_N" "$PL"   # 最后一次让错误冒出来
    echo "    重启: $SVC（release）"
  else
    echo "    跳过: $SVC（plist 未指向发布目录，仍跑原路径）"
  fi
done

echo "==> [5/5] 健康检查"
sleep 4
for P in 8971 8060; do
  if lsof -nP -iTCP:"$P" -sTCP:LISTEN >/dev/null 2>&1; then echo "    :$P listening ✅"; else echo "    :$P NOT listening ❌"; fi
done
tail -2 "$HOME/Library/Logs/ourworlds/server.log" 2>/dev/null || true
echo "完成。线上 = $(git -C "$REL" rev-parse --short HEAD)（$REF）"
