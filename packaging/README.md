# 打包发布（Packaging）

可复现的桌面端打包脚本。当前已实现 **macOS（universal，Apple Silicon 原生 + Intel）** 的导出 → 签名 →（可选）公证 → 打包全流程。

## macOS

### 前置条件
- Godot **4.6.3** 命令行可用（`godot` 在 PATH 中）。
- 已安装 4.6.3 导出模板（编辑器 → 项目 → 导出 → 管理导出模板，或下载官方 `.tpz` 解压到
  `~/Library/Application Support/Godot/export_templates/4.6.3.stable/`）。
- 钥匙串里有 **Developer ID Application** 证书（用你自己的；脚本通过 `SIGN_IDENTITY` 环境变量读取）。

### 一条命令：导出 + 签名
```bash
bash packaging/build_macos.sh
```
产出 `build/macos/OurWorlds-macos.zip`：已用 Developer ID 签名、启用硬化运行时、带安全时间戳。
**本机可直接运行**；但在别人的 Mac 上，未公证会被 Gatekeeper 拦截（需下一步公证）。

### 补公证（拿到 Apple 凭证后）
先一次性把凭证存进钥匙串（二选一）：
```bash
# A. App Store Connect API 密钥（推荐）
xcrun notarytool store-credentials "ourworlds-notary" \
  --key /path/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_UUID>

# B. Apple ID + 专用密码
xcrun notarytool store-credentials "ourworlds-notary" \
  --apple-id <APPLE_ID> --team-id <TEAM_ID> --password <APP_SPECIFIC_PASSWORD>
```
然后带 profile 重新跑，自动完成公证 + staple：
```bash
NOTARY_PROFILE=ourworlds-notary bash packaging/build_macos.sh
```
完成后 `spctl -a -t exec -vvv build/macos/stage/OurWorlds.app` 应显示 `accepted / source=Notarized Developer ID`。

## Windows / Linux（待办）
`export_presets.cfg` 已配好 `Windows Desktop` 与 `Linux` 预设；安装对应导出模板后可用
`godot --headless --path . --export-release "<preset>" <out>` 产出。Windows 分发建议另配代码签名证书（避免 SmartScreen 拦截）。
