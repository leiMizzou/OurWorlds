# OurWorlds 在线平台目标（2026-06-06 用户目标 → 路线图对齐）

本文件把用户 2026-06-06 设定的 `/goal` 拆成可执行里程碑，并标出**我无法自动完成、到点必须由用户操作的外部依赖**（账号/密钥/授权类，受安全规则约束）。底层架构沿用 [`2026-06-03-online-multiplayer-design.md`](2026-06-03-online-multiplayer-design.md)，部署方式按用户要求由 VPS+Caddy 改为 **Cloudflare Tunnel**。

## 目标原文要点（用户）
1. 客户端 + 服务器架构。
2. **两类客户端**：① 人类玩家接入游玩；② **AI agent（如 OpenClaw）作为一等公民接入并主动参与游玩**。
3. **强交互**：互相看见；绘画/创建并**分享建造**；**广播自己的坐标 → 别人一键瞬移过来参观/访问**。
4. **两层接入**：① 浏览器（轻量、免下载）；② **Mac 原生 App**（体验更顺，下载使用）。
5. **部署**：**Cloudflare Tunnel 反向代理 + 专属二级域名**，别人直接访问/登录/下载 App。
6. **账号**：注册登录 + 设密码；**支持 Google / GitHub / Twitter 社交登录**。
7. "做到这些就可以了，暂时。"

## 里程碑对齐（在 M0/M0.5 已完成的基础上）

| 里程碑 | 内容 | 对应目标点 | 外部依赖门槛（需用户） |
|---|---|---|---|
| **M1**（进行中） | 本地权威联机：headless 服务器 + 多客户端，互见走动 + 编辑实时同步；in-memory 增量 | 1, 3(看见/同步) | 仅"双窗口肉眼确认"需用户看画面 |
| **M2** | Web/WASM 客户端联机 + **AI agent 作为联机客户端接入**（AgentBridge 的 agent 进入多人世界，成为第 2 类客户端） | 1, 2, 4(浏览器) | — |
| **M2.5（新）** | **强交互玩法**：广播坐标→他人一键瞬移参观；分享/展示建造（导出建造为可分享数据 + 在世界里加载/参观） | 3 | — |
| **M3** | 服务器上云：**Cloudflare Tunnel(`cloudflared`) 反代 + 专属二级域名**；wss/TLS 由 CF 边缘提供 | 5 | **CF 账号、域名、`cloudflared login` 授权、DNS/Tunnel 路由创建**（我写好 config+脚本+文档，授权这步由用户执行） |
| **M4** | 账号 + 云存档（Nakama）：注册/登录、入场票、chunk-delta & 玩家数据落库；**Google/GitHub/Twitter 社交登录** | 6 | **各家 OAuth 应用注册 + client id/secret**（我接好登录流程代码，应用注册+密钥由用户提供） |
| **M5** | 大厅/多世界 + 兴趣管理（人多时） | （扩展） | — |
| **Mac App** | 原生 Mac 客户端：导出 + 公证 + 分发（导出/签名管线已存在，见 commit a2720d6） | 4(Mac) | **Apple 开发者凭证用于公证 notarize** |
| **M6** | 公开加固：限流、举报、封禁、备份、监控、成本 | （上线前） | — |

## 我能自动做完 vs 必须卡在用户处的边界
- **我能做完（代码/配置/脚本/本地测试/文档）**：M1 全部；M2 Web 联机 + agent-as-client；M2.5 瞬移/分享建造；M3 的 `cloudflared` 配置文件 + Tunnel ingress + 部署脚本 + 文档；M4 的 Nakama 集成 + OAuth 登录流程代码 + 本地 docker-compose；Mac App 的导出脚本。
- **必须用户亲自做（受安全规则约束，我不碰密钥/账号/DNS/付费）**：
  - Cloudflare：注册/登录、`cloudflared tunnel login`、创建 Tunnel、绑定二级域名 DNS 记录。
  - OAuth：在 Google/GitHub/Twitter 开发者后台注册应用、拿到并填入 client id/secret。
  - Apple：用开发者账号做公证（notarization）。
  - 任何"按钮一点就外发/上线/收费"的确认动作。
- **必须用户肉眼确认**：联机时"多个窗口里互相看得见走动、看得见对方挖/放/瞬移"。

## 现状（2026-06-06）
- ✅ M0（WorldData 数据核心）、M0.5（Web 烟测 + 字体）已完成并入 main。
- ✅ **M1 完成**（分支 `m1-local-coop`，10 个任务全绿，52/52 自检）：headless 权威服务器 + 客户端，编辑/走动实时同步、增量持久、晚加入可见已有改动；端到端冒烟 `packaging/coop_smoke.sh` 通过。**仅剩"两个窗口里互看走动"的人工肉眼验收**（`packaging/run_coop_demo.sh`），我无头看不到画面。
- 🔄 **M2 进行中**：**网页客户端联机已实测通过**——浏览器里 Godot WASM 启动+渲染（标题/3D 地形/中文字体都正常），经 WebSocket 连上权威服务器并入场（控制台确认：连接中→已连上服务器→脚下区域就绪 2.7s；多线程 crossOriginIsolated via COOP/COEP）。`?connect=ws://…` URL 参数自动连服已落地（`Main._connect_url`）。已知小瑕：网页端有 Emscripten "blocking on main thread" 警告（非致命，连接成功；M5 性能再优化）。待办：网页"加入"菜单走 ?connect 跳转、AI agent 作为联机玩家、坐标瞬移/分享建造。
- ⬜ M3（Cloudflare Tunnel）、M4（账号 + 社交 OAuth）、M5、M6、Mac App：依次推进；外部账号步骤（CF/OAuth/Apple）到点交给你。
