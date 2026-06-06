# OurWorlds — P0 开源发布就绪 设计方案

日期：2026-06-06
状态：已批准（决策见下），实施中

## 背景与定位

项目原名 VoxelCraft，是完成度较高的单机体素创造沙盒（Godot 4.6 + 纯 GDScript）。差异化亮点：AI agent 通过 TCP/NDJSON 桥（`scripts/AgentBridge.gd`）+ MCP 服务器（`agent-bridge-mcp/`）被 OpenClaw 驱动，自主观察/建造/探索/修复地标。

现决定**作为开源研究系统发布到 GitHub**。agent 采用**用户自带本地 OpenClaw**模式：用户在本机配好自己的 OpenClaw → 通过一个顺滑的方式连接到游戏 → agent 自主游玩。无云托管、无多租户、无 token 计费问题（每个用户用自己的本地配置与模型凭证）。

## 目标（本轮 = P0）

让项目能**干净、合法、体面地公开**，并把 **agent 入场体验**打通顺滑。

## 锁定决策

- 项目改名：**VoxelCraft → OurWorlds**（显示名 `OurWorlds`，标识符 `ourworlds`）
- 许可证：**MIT**，版权行 `Copyright (c) 2026 The OurWorlds Authors`
- agent 入场深度：**启动脚本 + 游戏内状态角标**
- 加 **基础 GitHub Actions CI**（headless 自检）
- bundle id：`com.ourworlds.game`（占位，发布前可改为你的反域名 / `io.github.<user>`）
- 环境变量：`VC_AGENT_PORT → OW_AGENT_PORT`
- MCP 包名：`voxelcraft-mcp → ourworlds-mcp`
- OpenClaw 示例 agent id：`opc-voxel → opc-ourworlds`（含目录 `git mv`）；agent 角色显示名 `Voxel → OurWorlds`；MCP 工具命名空间 `voxel.* → ourworlds.*`、mcporter 别名 `voxel → ourworlds`（全部统一为 OurWorlds）

## 范围外（后续路线，明确不做）

联机/多人、**生存玩法**（用户提到的 agent "生存"依赖此项；当前为纯创造模式）、性能项（greedy meshing / LOD / 二进制存档）、Windows 代码签名、i18n 本地化、手柄/触控。

## 工作流

### A. 许可证 → MIT
- 用标准 MIT 文本替换 `LICENSE`，版权 `The OurWorlds Authors`。
- `agent-bridge-mcp/package.json`：`license: "MIT"`（去掉 `SEE LICENSE IN ../LICENSE`）。

### B. 个人信息清理（公开前必须）

| 位置 | 现状 | 处理 |
|---|---|---|
| `LICENSE:3` | `leiMizzou` | 随 MIT 重写移除 |
| `packaging/build_macos.sh:25` | 硬编码 `Developer ID Application: lei hua (67KN33LJAQ)` | 改为必填 env：未设 `SIGN_IDENTITY` 即报错退出 |
| `build_macos.sh` / `packaging/README.md` | `67KN33LJAQ`（Team ID） | 换 `<TEAM_ID>` 占位 |
| `packaging/README.md:11` | “本项目用 lei hua (...)” | 改为通用说明（用你自己的证书，经 `SIGN_IDENTITY` 读取） |
| `docs/openclaw/.../agent.config.json5:19` 等 | `/Users/mac/.openclaw/...` | 换 `~/.openclaw/...` |
| `docs/superpowers/plans/2026-06-03-m0-...md` | `/Users/mac/Documents/.../VoxelCraft` | 换 `.`（`--path .`） |
| `export_presets.cfg` | `Labubu`（公司 / 版权） | company → `OurWorlds`，copyright → `The OurWorlds Authors` |

- 收尾：全仓 `git grep -i` 确认无 `lei hua | leimizzou | hualei | labubu | /Users/mac | 67KN33LJAQ` 残留（占位符除外）。
- `.gitignore`：确认 `build/`、`*.zip`、`.godot/` 已忽略；`user://` 运行期数据（存档、`agent_memory.json`、covers）本就不在仓库；OAuth 凭证从不入库（config 已注明）。

### C. 改名 VoxelCraft → OurWorlds（替换映射）

标识符替换：`VoxelCraft→OurWorlds`、`voxelcraft→ourworlds`、`VC_AGENT_PORT→OW_AGENT_PORT`、`voxelcraft-mcp→ourworlds-mcp`、`voxelcraft.entitlements→ourworlds.entitlements`（含 `git mv`）、`com.labubu.voxelcraft→com.ourworlds.game`、`opc-voxel→opc-ourworlds`（含目录 `git mv`）。

受影响（16 个 tracked 文件含 voxelcraft + openclaw 文档）：`project.godot`、`export_presets.cfg`、`packaging/*`、`scripts/Main.gd`、`scripts/PauseMenu.gd`、`scripts/TitleScreen.gd`、`ui/theme.tres`、`tests/*`、`README.md`、`docs/*`。

注：改 bundle id / 项目名会改变 Godot `user://` 数据路径；全新开源发布无存量用户，无影响。

实施方式：含逻辑/歧义的文件用定向编辑（`LICENSE`、`build_macos.sh`、`packaging/README.md`、`export_presets.cfg`、`package.json`、`project.godot`）；纯 token 替换的文件（`scripts/`、`ui/`、`tests/`、`docs/`、`README.md`）用一次受控脚本替换，替换后 `git grep` 校验无残留。

### D. agent 入场体验（启动脚本 + 游戏内角标）

- `run_with_agent.sh`：设 `OW_AGENT_PORT`（默认 8970）+ 启动 Godot（编辑器工程或导出包）。一条命令把游戏跑成“可被 agent 接入”。
- `agent-bridge-mcp/setup.sh`（或 Makefile target）：doctor 检查（`node`/`godot`/`openclaw` 是否在 PATH）→ `npm install && npm run build` → 若不存在则把 `docs/openclaw/opc-ourworlds` 工作区模板拷到 `~/.openclaw/agents/opc-ourworlds/workspace`。
- 游戏内 HUD：AgentBridge 连接/断开时，HUD 常驻角标 `🤖 agent 已连接 · 目标：<goal>`（复用现有 `set_goal` 与 recent actions）。改动点：`AgentBridge.gd` 暴露连接信号；`HUD.gd` 加角标控件。
- 文档：`docs/openclaw-integration.md` 顶部加「一页 Quickstart」，正文保留详版。

### E. 开源仓库门面

- 重写 `README.md`（英文为主，可附中文）：MIT 徽章、一句话定位、截图、Quickstart（普通玩 + agent 玩）、构建/打包、`bash tests/run_all.sh` 自检、贡献指引、免责声明「与 Mojang/Microsoft 无关联」。
- 新增 `CONTRIBUTING.md`：跑测试、GDScript 风格、PR 流程。
- 清理 `agent-bridge-mcp` 散落开发脚本（`debug_think.py`/`demo_drive.py`/`opc_voxel_runner.py`/`verify_avatar.py`/`smoke.mjs`）→ 移入 `agent-bridge-mcp/examples/` 并加说明，或删除。
- `.github/workflows/ci.yml`：on push/PR，安装 Godot 4.6.x headless，跑 `bash tests/run_all.sh`。

## 验证

- `git grep -i` 确认无旧名 / PII 残留（占位符除外）。
- `bash tests/run_all.sh` 全绿（headless 逻辑自检，含 `tests/test_agent_bridge.gd`）。
- 模拟 agent：设 `OW_AGENT_PORT` 起游戏 → smoke 连通 → 确认 HUD 角标出现。
- `LICENSE` / `README` 渲染检查。

## 风险 / 开放项

- bundle id `com.ourworlds.game` 为占位。
- CI 需要 Godot 4.6.x headless（用社区 action 或下载官方二进制）。
- git 历史含 committer 身份（`Labubu` / email）；如需彻底脱敏可后续 `git filter-repo` 重写历史（本轮不做，仅前进式使用一致署名）。
