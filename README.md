# OurWorlds

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Godot 4.6](https://img.shields.io/badge/Godot-4.6-478CBF.svg)](https://godotengine.org)

一个宏大、可无限延伸的 **3D 体素创造沙盒**，用 **Godot 4.6 + 纯 GDScript** 从零实现，不依赖第三方体素库。
它不只是给人玩的世界：你也可以把自己的本地或远程 AI agent 接进来，让它观察、移动、聊天、建造、保存蓝图、复用蓝图，并作为多人世界里可见的角色一起创造。

> A grand, endless **3D voxel creative sandbox**, built from scratch with **Godot 4.6 + pure GDScript**.
> It is designed for both human players and AI agents: agents can observe, move, chat, build, capture blueprints,
> paste shared builds, and appear as visible participants in multiplayer worlds.

![OurWorlds](_gallery_rendercore.png)

---

## 中文

### 当前进展

**已经可玩**
- 无限风格体素世界：丘陵、山脊高山、海平面湖水、沙岸、二维群系、地下溶洞、矿物房间、遗迹与自然结构。
- 30+ 方块与材料体系：地形、建材、自然、装饰、矿物、可发光方块、霓虹/轨道类扩展方块。
- 第一人称创造玩法：移动、跳跃、创造飞行、挖/放、材料库、最近材料、建造画笔、模板库、整组撤销/重做。
- 探索循环：遗迹发现与修复、旅行手记、世界地图、区域足迹、成就式旅程进度、拍照模式。
- 视觉与氛围：逐顶点 AO、SSAO、软阴影、mipmap、像素图集、菲涅尔水面、昼夜、星空、雨雪、体积感云、自发光与泛光。
- UI 与发布体验：统一主题、中文字体/emoji 回退、标题世界选择、封面预览、暂停设置、画质/天气/音量/灵敏度选项。

**联机与 Web**
- 本地/局域网权威联机：headless Godot 世界服务器 + WebSocket 客户端，玩家走动和方块编辑实时同步。
- 游戏内按 **N** 打开联机菜单；也支持环境变量启动 server / host / client。
- Web/WASM 导出脚本已就绪，静态服务带 COOP/COEP 响应头以支持多线程 WASM。
- 网页端支持 `?connect=ws://...` / `?connect=wss://...` 自动连服。
- 在线列表支持坐标参观：看到其他玩家或 agent 后，可一键前往对方位置附近。

**AI agent**
- 本地 AgentBridge：TCP / NDJSON，只监听 `127.0.0.1`，通过 `OW_AGENT_PORT` 显式开启。
- MCP bridge：`agent-bridge-mcp` 可把 OpenClaw / MCP runtime 的工具调用转发给游戏。
- 工具集覆盖 `observe / identify / look / goto / scan / place / break / build / capture_build / paste_build / get_block / say / set_goal / remember / get_memory`。
- 多 agent 连接、agent 名牌、聊天、记忆、最近行动、蓝图捕获/粘贴已经接入。
- 远程 Agent Gateway 已有本地实现：远程 MCP bridge 可通过 WebSocket + token 接入 headless server，成为服务器托管的虚拟 peer，并被人类客户端看见。

**账号、部署、打包**
- Nakama 账号地基已接入：本地 docker 后端、邮箱密码认证、游戏内登录/注册/游客入口、云存档原型。
- Google / GitHub / Twitter(X) 社交登录仍需要外部 OAuth 应用与密钥。
- Cloudflare Tunnel 部署模板已准备：网页站、游戏 WebSocket、Agent Gateway `/agent` 路由。
- macOS universal App 导出、Developer ID 签名、硬化运行时脚本已就绪；公证需要自己的 Apple 凭证。

**自检状态**
- `tests/run_all.sh` 会遍历当前 `tests/test_*.gd` 的 headless 逻辑测试，当前测试脚本已扩展到 78 个。
- 本次 README 复核中，AgentBridge、AgentGateway、server agent context、蓝图、Nakama、标题页、进游戏路径等关键单测可单独通过。
- 完整顺序跑曾出现一次 `AgentContext.gd` 资源加载不稳定，因此 README 暂不再写固定的 `70/70` 通过数；后续以最新 CI / 本地完整跑为准。

### 让 AI agent 玩你的世界

```bash
# 1) 准备 MCP 服务器 + 环境自检 + 拷贝示例 agent 工作区
bash agent-bridge-mcp/setup.sh

# 2) 以可被本地 agent 接入的模式启动游戏
bash run_with_agent.sh

# 3) 在游戏中进入或新建世界；agent 连上后，HUD 会显示连接状态
```

文档：
- 协议契约：[`docs/agent-bridge-contract.md`](docs/agent-bridge-contract.md)
- OpenClaw 接入指南：[`docs/openclaw-integration.md`](docs/openclaw-integration.md)
- 远程 agent 接入指南：[`docs/connect-your-agent.md`](docs/connect-your-agent.md)
- MCP 示例脚本：[`agent-bridge-mcp/examples/`](agent-bridge-mcp/examples/)

> 安全提醒：本地 AgentBridge 只监听 `127.0.0.1`，且必须设置 `OW_AGENT_PORT` 才启用。远程 Agent Gateway 需要 token，并建议只通过受控隧道暴露。不要把本地 agent 端口直接暴露到公网。

### 操作

| 操作 | 键 | 操作 | 键 |
|---|---|---|---|
| 移动 | W A S D | 挖 / 放方块 | 鼠标左键 / 右键 |
| 视角 | 鼠标 | 选方块 | 数字键 1-8 / 滚轮 |
| 跳 / 跑 | 空格 / Shift | 材料库 / 最近材料 | E / R |
| 飞行切换 | 双击空格 | 飞行升 / 降 | 空格 / Shift |
| 暂停 / 抓放鼠标 | Esc | 建造画笔 | B |
| 模板 上/下 / 旋转 | Q / T / G | 撤销 / 重做 | Z / Y |
| 旅行手记 / 世界地图 | J / M | 拍照模式 / 截图 | F1 / F2 |
| 联机菜单 | N | 切换视角 | V 或 F5 |

### 运行

```bash
# 编辑器：用 Godot 4.6 打开本工程，按 F5
godot --path .
```

### 联机

```bash
# 一台机演示：1 个无头权威服务器 + 2 个客户端窗口
bash packaging/run_coop_demo.sh

# 端到端冒烟：连上 -> 入场 -> 建出世界
bash packaging/coop_smoke.sh
```

也可以手动启动：

```bash
OW_SERVER=1 OW_PORT=8971 godot --headless --path .    # 权威服务器
OW_CONNECT=ws://127.0.0.1:8971 godot --path .          # 客户端加入
OW_HOST=1 godot --path .                               # 开服并本地同时游玩
```

### 打包与部署

```bash
# Web/WASM 导出并启动本地 COOP/COEP 静态站
bash packaging/build_web.sh

# macOS universal App 导出 + 签名
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash packaging/build_macos.sh
```

更多说明：
- 打包：[`packaging/README.md`](packaging/README.md)
- Cloudflare Tunnel 公网部署：[`deploy/README.md`](deploy/README.md)
- Nakama 账号脚手架：[`deploy/accounts/README.md`](deploy/accounts/README.md)

### 架构

| 模块 | 文件 | 职责 |
|---|---|---|
| BlockLibrary | `scripts/BlockLibrary.gd` | 方块数据、程序像素图集、材质、自发光分桶 |
| Chunk / ChunkMesher | `scripts/Chunk.gd` / `scripts/ChunkMesher.gd` | 区块数据、隐藏面剔除、逐顶点 AO、碰撞 |
| WorldGenerator | `scripts/WorldGenerator.gd` | 程序地形、群系、洞穴、自然内容、结构 |
| World / WorldData | `scripts/World.gd` / `scripts/WorldData.gd` | 客户端渲染世界、权威数据核心、存档与批量编辑 |
| Player / HUD | `scripts/Player.gd` / `scripts/HUD.gd` | 第一人称控制、建造、快捷栏、反馈、状态 |
| NetworkManager | `scripts/NetworkManager.gd` | WebSocket 联机、权威校验、玩家/agent 快照、虚拟 peer |
| AgentBridge / AgentGateway | `scripts/AgentBridge.gd` / `scripts/AgentGateway.gd` | 本地 agent 桥、远程 agent gateway |
| AgentToolCore | `scripts/AgentToolCore.gd` | 共享 agent 工具语义，本地桥和服务器 gateway 共用 |
| NakamaClient / LoginScreen | `scripts/NakamaClient.gd` / `scripts/LoginScreen.gd` | 账号认证原型、登录/注册/游客入口 |

更多设计见 [`docs/DESIGN.md`](docs/DESIGN.md)。

### 招募共同开发者 / 共同建造者

OurWorlds 正在寻找一起把这个世界做大的朋友：

- Godot / GDScript 开发者：体素渲染、性能、UI、工具链、跨平台导出。
- 联机与后端开发者：Nakama、Cloudflare Tunnel、WebSocket、账号、云存档、公共服安全。
- AI agent 开发者：MCP runtime、OpenClaw / Hermes / Claude Code / Codex 接入、agent persona、自动建造策略。
- 世界建造者：主题岛屿、结构模板、地标、公共世界活动、截图和演示视频。
- 测试与发布伙伴：Web/Mac 客户端试玩、多人压测、CI 稳定化、文档翻译。

欢迎直接开 issue / PR，或者先联系：

- Email: `lhua0420@gmail.com`
- Twitter/X: `TBD`（待补充公开 handle）

---

## English

### Project Status

**Playable core**
- Endless-style voxel terrain with hills, ridges, lakes, beaches, 2D biomes, caves, mineral rooms, ruins, and natural structures.
- 30+ blocks across terrain, building, natural, decorative, mineral, emissive, neon, and rail categories.
- First-person creative play: movement, jumping, creative flight, mining, placing, material library, recent materials, build brush, templates, undo/redo.
- Exploration loop: landmark discovery and restoration, travel journal, world map, biome footprints, journey progress, and photo mode.
- Visual atmosphere: vertex AO, SSAO, soft shadows, mipmaps, procedural pixel atlas, Fresnel water, day/night, stars, rain/snow, volumetric-feeling clouds, emissive bloom.
- UI and release polish: unified theme, Chinese font / emoji fallback, title world picker, cover previews, pause settings, quality/weather/audio/sensitivity controls.

**Multiplayer and Web**
- Local/LAN authoritative multiplayer: a headless Godot world server plus WebSocket clients, with synced movement and block edits.
- Press **N** in game for the networking menu; server / host / client modes are also available through environment variables.
- Web/WASM export scripts are ready, with a COOP/COEP static server for multithreaded WASM.
- Web clients can auto-connect through `?connect=ws://...` or `?connect=wss://...`.
- The online roster supports coordinate visits: jump near another human player or agent to inspect their build.

**AI agents**
- Local AgentBridge: TCP / NDJSON, loopback-only, explicitly enabled through `OW_AGENT_PORT`.
- MCP bridge: `agent-bridge-mcp` forwards OpenClaw / MCP runtime tool calls into the game.
- Tool set: `observe / identify / look / goto / scan / place / break / build / capture_build / paste_build / get_block / say / set_goal / remember / get_memory`.
- Multiple agents, agent nameplates, chat, memory, recent actions, blueprint capture, and blueprint paste are wired in.
- Remote Agent Gateway has a local implementation: a remote MCP bridge can connect over WebSocket + token to the headless server, become a server-hosted virtual peer, and be seen by human clients.

**Accounts, deployment, packaging**
- Nakama account foundation is in place: local docker backend, email/password auth, in-game login/register/guest entry, and cloud-save prototype.
- Google / GitHub / Twitter(X) social login still requires external OAuth apps and secrets.
- Cloudflare Tunnel templates are ready for the web site, game WebSocket, and Agent Gateway `/agent` route.
- macOS universal App export, Developer ID signing, and hardened runtime scripts are ready; notarization requires your own Apple credentials.

**Testing**
- `tests/run_all.sh` iterates the current `tests/test_*.gd` headless logic tests; the suite has grown to 78 scripts.
- During this README refresh, key checks for AgentBridge, AgentGateway, server agent context, blueprints, Nakama, title screen, and play boot passed individually.
- A full ordered run showed an intermittent `AgentContext.gd` resource-load instability, so this README no longer advertises the older fixed `70/70` count. Use the latest CI or local full run as the source of truth.

### Let AI Agents Play

```bash
# 1) Prepare the MCP server, run environment checks, and copy the sample agent workspace
bash agent-bridge-mcp/setup.sh

# 2) Launch the game in local-agent mode
bash run_with_agent.sh

# 3) Enter or create a world; the HUD shows agent connection state when an agent connects
```

Docs:
- Protocol contract: [`docs/agent-bridge-contract.md`](docs/agent-bridge-contract.md)
- OpenClaw guide: [`docs/openclaw-integration.md`](docs/openclaw-integration.md)
- Remote agent guide: [`docs/connect-your-agent.md`](docs/connect-your-agent.md)
- MCP examples: [`agent-bridge-mcp/examples/`](agent-bridge-mcp/examples/)

> Security note: the local AgentBridge only listens on `127.0.0.1` and only starts when `OW_AGENT_PORT` is set. The remote Agent Gateway requires tokens and should be exposed only through a controlled tunnel. Do not expose the local agent port directly to the public internet.

### Controls

| Action | Key | Action | Key |
|---|---|---|---|
| Move | W A S D | Break / place block | Left / right mouse |
| Look | Mouse | Select block | Number 1-8 / wheel |
| Jump / sprint | Space / Shift | Material library / recent | E / R |
| Toggle flight | Double Space | Fly up / down | Space / Shift |
| Pause / release mouse | Esc | Build brush | B |
| Template prev / next / rotate | Q / T / G | Undo / redo | Z / Y |
| Travel journal / world map | J / M | Photo mode / screenshot | F1 / F2 |
| Network menu | N | Camera view | V or F5 |

### Run

```bash
# Open the project with Godot 4.6, or run:
godot --path .
```

### Multiplayer

```bash
# One-machine demo: 1 headless authority + 2 client windows
bash packaging/run_coop_demo.sh

# Headless smoke: connect -> enter -> build world
bash packaging/coop_smoke.sh
```

Manual modes:

```bash
OW_SERVER=1 OW_PORT=8971 godot --headless --path .    # authority server
OW_CONNECT=ws://127.0.0.1:8971 godot --path .          # client
OW_HOST=1 godot --path .                               # host and play locally
```

### Build And Deploy

```bash
# Export Web/WASM and start a local COOP/COEP static server
bash packaging/build_web.sh

# Export and sign a macOS universal app
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" bash packaging/build_macos.sh
```

More:
- Packaging: [`packaging/README.md`](packaging/README.md)
- Cloudflare Tunnel deployment: [`deploy/README.md`](deploy/README.md)
- Nakama account scaffold: [`deploy/accounts/README.md`](deploy/accounts/README.md)

### Architecture

| Module | File | Responsibility |
|---|---|---|
| BlockLibrary | `scripts/BlockLibrary.gd` | Block data, procedural pixel atlas, materials, emissive buckets |
| Chunk / ChunkMesher | `scripts/Chunk.gd` / `scripts/ChunkMesher.gd` | Chunk data, hidden-face culling, vertex AO, collision |
| WorldGenerator | `scripts/WorldGenerator.gd` | Procedural terrain, biomes, caves, natural content, structures |
| World / WorldData | `scripts/World.gd` / `scripts/WorldData.gd` | Rendered client world, authoritative data core, saves, batch edits |
| Player / HUD | `scripts/Player.gd` / `scripts/HUD.gd` | First-person control, building, hotbar, feedback, status |
| NetworkManager | `scripts/NetworkManager.gd` | WebSocket multiplayer, authority checks, player/agent snapshots, virtual peers |
| AgentBridge / AgentGateway | `scripts/AgentBridge.gd` / `scripts/AgentGateway.gd` | Local agent bridge and remote agent gateway |
| AgentToolCore | `scripts/AgentToolCore.gd` | Shared agent tool semantics used by both local bridge and server gateway |
| NakamaClient / LoginScreen | `scripts/NakamaClient.gd` / `scripts/LoginScreen.gd` | Account auth prototype and login/register/guest entry |

See [`docs/DESIGN.md`](docs/DESIGN.md) for more design notes.

### Join Us: Co-developers And Co-builders

OurWorlds is looking for people who want to help grow the world:

- Godot / GDScript developers: voxel rendering, performance, UI, tooling, cross-platform export.
- Multiplayer and backend developers: Nakama, Cloudflare Tunnel, WebSocket, accounts, cloud saves, public-server safety.
- AI agent developers: MCP runtimes, OpenClaw / Hermes / Claude Code / Codex integration, agent personas, autonomous building strategy.
- World builders: themed islands, structure templates, landmarks, public-world events, screenshots, demo videos.
- Testing and release partners: Web/Mac playtests, multiplayer stress tests, CI stabilization, documentation translation.

Open an issue / PR, or reach out:

- Email: `lhua0420@gmail.com`
- Twitter/X: `TBD` (public handle to be added)

## License

MIT — see [LICENSE](LICENSE). Contribution flow: [CONTRIBUTING.md](CONTRIBUTING.md).

## Disclaimer

OurWorlds is an independent, open-source research project and is **not affiliated with, authorized by, or endorsed by Mojang, Microsoft, or Minecraft**.
All names and trademarks belong to their respective owners.
