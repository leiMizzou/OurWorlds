#!/usr/bin/env bash
# 导出 Web(WASM) 单机版 + 本地起带 COOP/COEP 头的服务器（M0.5 网页烟测）。
#
# 前置条件：已安装 Godot 4.6.x 的 **Web 导出模板**
#   （编辑器 → 项目 → 导出 → 管理导出模板 → 下载并安装；或解压官方 export_templates.tpz）。
#   没装的话本脚本会在导出处报 "no export template found for Web"。
#
# 用法：bash packaging/build_web.sh        # 导出后自动在 http://localhost:8060/ 起服务
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
OUT="$HERE/build/web"
PORT="${PORT:-8060}"

echo "==> [1/2] 导出 Web → $OUT/index.html"
rm -rf "$OUT"; mkdir -p "$OUT"
"$GODOT" --headless --path "$HERE" --export-release "Web" "$OUT/index.html"

echo "==> [2/2] 起本地服务器（COOP/COEP，多线程 WASM 需要）"
exec python3 "$HERE/packaging/serve_web.py" "$PORT"
