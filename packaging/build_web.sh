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

echo "==> [1/3] 导出 Web → $OUT/index.html"
rm -rf "$OUT"; mkdir -p "$OUT"
"$GODOT" --headless --path "$HERE" --export-release "Web" "$OUT/index.html"

echo "==> [2/3] 预压缩大资产（serve_web 按 Accept-Encoding 直发 .br/.gz —— 37MB wasm 压到约 1/4）"
for f in "$OUT"/index.wasm "$OUT"/index.pck "$OUT"/index.js; do
  [ -f "$f" ] || continue
  gzip -9 -kf "$f"
  if command -v brotli >/dev/null 2>&1; then brotli -q 9 -f -o "$f.br" "$f"; fi
done
ls -la "$OUT" | awk '{print "    "$5"\t"$9}' | grep -E 'wasm|pck|index\.js' || true

# OW_SERVE=0：只构建不起服务（部署脚本用）；默认保持原行为——构建完本地起服。
if [ "${OW_SERVE:-1}" = "0" ]; then
  echo "==> 完成（OW_SERVE=0，不起本地服务器）"
  exit 0
fi
echo "==> [3/3] 起本地服务器（COOP/COEP，多线程 WASM 需要）"
exec python3 "$HERE/packaging/serve_web.py" "$PORT"
