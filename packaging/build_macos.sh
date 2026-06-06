#!/usr/bin/env bash
# 构建 + 签名 +（可选）公证 + staple + 打包 macOS 发布包。
#
# 前置条件：
#   1. 已安装 Godot 4.6.3 与对应导出模板（编辑器 -> 项目 -> 导出 -> 管理导出模板）。
#   2. 钥匙串里有 "Developer ID Application" 证书。
#
# 用法：
#   bash packaging/build_macos.sh                         # 仅导出 + 签名（产出已签名、未公证的 zip，可本机运行）
#   NOTARY_PROFILE=ourworlds-notary bash packaging/build_macos.sh   # 额外公证 + staple（需先存好凭证档，见下）
#
# 一次性存公证凭证（二选一，存进钥匙串，之后复用）：
#   App Store Connect API 密钥：
#     xcrun notarytool store-credentials "ourworlds-notary" \
#       --key /path/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>
#   或 Apple ID + 专用密码：
#     xcrun notarytool store-credentials "ourworlds-notary" \
#       --apple-id <APPLE_ID> --team-id <TEAM_ID> --password <APP_SPECIFIC_PASSWORD>
#
# 可覆盖的环境变量：GODOT、SIGN_IDENTITY、NOTARY_PROFILE
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
# 用你自己的证书。脚本不内置任何签名身份；未设置则报错退出。
SIGN_IDENTITY="${SIGN_IDENTITY:?请设置 SIGN_IDENTITY，例如：'Developer ID Application: Your Name (TEAMID)'}"
ENTITLEMENTS="$HERE/packaging/ourworlds.entitlements"
OUT_DIR="$HERE/build/macos"
APP_NAME="OurWorlds"
APP="$OUT_DIR/stage/$APP_NAME.app"

echo "==> [1/5] Godot 导出（未签名）…"
rm -rf "$OUT_DIR"; mkdir -p "$OUT_DIR"
"$GODOT" --headless --path "$HERE" --export-release "macOS" "$OUT_DIR/$APP_NAME.zip"

echo "==> [2/5] 解包 .app（ditto 保留元数据）…"
ditto -x -k "$OUT_DIR/$APP_NAME.zip" "$OUT_DIR/stage"

echo "==> [3/5] 签名（Developer ID + 硬化运行时 + 时间戳）…"
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  -s "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  echo "==> [4/5] 公证（profile: $NOTARY_PROFILE，submit --wait）…"
  ditto -c -k --keepParent "$APP" "$OUT_DIR/$APP_NAME-notarize.zip"
  xcrun notarytool submit "$OUT_DIR/$APP_NAME-notarize.zip" \
    --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> staple 装订公证票据…"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
else
  echo "==> [4/5] 跳过公证（未设置 NOTARY_PROFILE）。产物已签名但未公证。"
fi

echo "==> [5/5] 打包发布 zip（ditto 保留签名）…"
ditto -c -k --keepParent "$APP" "$OUT_DIR/$APP_NAME-macos.zip"

echo ""
echo "完成 ✅  发布包: $OUT_DIR/$APP_NAME-macos.zip"
spctl -a -t exec -vvv "$APP" 2>&1 | sed 's/^/   spctl: /' || true
