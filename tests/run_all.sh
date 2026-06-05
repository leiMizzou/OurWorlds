#!/usr/bin/env bash
# 一键跑全部 headless 逻辑自检（test_*.gd），汇总通过/失败。
# 用法: bash tests/run_all.sh   （在项目根或任意目录都可，自动定位）
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
pass=0; fail=0; failed_list=""
echo "== VoxelCraft headless 自检 =="
for f in "$HERE"/tests/test_*.gd; do
  name="$(basename "$f")"
  out="$("$GODOT" --headless --path "$HERE" --script "res://tests/$name" 2>&1)"
  if echo "$out" | grep -qiE "FAIL|❌|Parse Error|SCRIPT ERROR|Failed to load|Can't load"; then
    fail=$((fail+1)); failed_list="$failed_list $name"
    printf "  ❌ %-34s\n" "$name"
    echo "$out" | grep -iE "FAIL|ERROR|Parse" | head -3 | sed 's/^/        /'
  elif echo "$out" | grep -qiE "PASSED|✅|ALL .*PASS|OK$| ok |PLAY OK|通过"; then
    pass=$((pass+1)); printf "  ✅ %-34s\n" "$name"
  else
    # 没有明确标记的，按无错误处理为通过，但标注
    pass=$((pass+1)); printf "  ✅ %-34s (no explicit marker)\n" "$name"
  fi
done
echo "------------------------------------"
echo "通过 $pass  失败 $fail"
if [ "$fail" -gt 0 ]; then echo "失败项:$failed_list"; exit 1; fi
echo "✅ 全部通过"
