# OurWorlds — 本地大厅 + 聊天（Local Lobby & Chat）设计方案

日期：2026-06-06
状态：设计已批准，待 spec 评审

## 背景与目标

当前 OurWorlds 是单机 + 本地 agent 桥（`scripts/AgentBridge.gd`，`127.0.0.1`，**单客户端**）。本功能在**单机一局内**提供：

- **在线列表**：玩家 + 同时连入的多个 agent。
- **公共大厅聊天**：所有实体可发言、可见。
- **私聊**：玩家 ↔ 某个 agent。
- agent 既能发言（复用 `say`）也能收到玩家消息（心跳 `observe` 拉取）。

这是通向「完整在线多人」的第一块基石，但**不引入任何公网/后端**（那是后续阶段，见 `2026-06-03-online-multiplayer-design.md`）。

## 锁定决策

- 规模：本地单局，**多 agent 同时在线**（AgentBridge 单 → 多客户端）。
- 收消息：**拉取式**（`observe` 带 `inbox`），不推送。
- 聊天范围：公共大厅 + 玩家↔agent 私聊。
- 按键：`Enter` 开聊天面板并发送消息，`Esc` 关闭。（原拟 `T`，但 `T` 已是「下一个模板」，故改用 `Enter`。）
- **不做**（YAGNI）：agent↔agent 私聊、聊天跨重启持久化、公网/LAN 联机、富文本/表情/文件、反垃圾。

## 组件（各自单一职责、可测）

### `ChatHub.gd`（新；纯逻辑、无节点依赖、headless 可测）
- 实体注册表：`register(id, name, kind)` / `unregister(id)`，`kind ∈ {human, agent}`；每实体存 id、显示名、kind、可选 status（如 agent 当前 goal）。
- 消息缓冲：环形，最近 N 条（默认 200）。每条 `{seq, from_id, to_id, text, t}`；`to_id == ""`（LOBBY）= 公共大厅。
- 单调递增 `seq`，支撑拉取式「自上次以来」的未读。
- API：`post(from_id, to_id, text) -> seq`、`lobby_recent(limit)`、`thread(a_id, b_id, limit)`、`unread_for(id, since_seq) -> {messages, last_seq}`。
- 信号：`message_posted(msg)`、`presence_changed()`（供 ChatPanel 实时刷新）。

### `AgentBridge.gd`（改：单 → 多客户端）
- `_peers: Array`，每 peer：socket、读缓冲、`entity_id`、name。`_process` 接受多个连接 + 逐 peer 读行分发。
- 生命周期：新连接 → 分配 `entity_id`（`agent-N`）→ ChatHub 注册（默认名 agent-N）；断开 → `unregister` + 通知 HUD/Panel。
- 工具作用于「调用它的那个 peer」：
  - `identify({name})`：设置该 peer 显示名（更新 presence）。
  - `say({text, to?})`：`to` 省略 → `ChatHub.post` 到大厅；`to=名字/id` → 私聊该实体。仍调用 `HUD.show_feedback` 闪一下。
  - `observe` 结果新增 `chat`（最近大厅消息若干）、`inbox`（自该 peer 上次 observe 以来、发给它的未读：大厅新消息 + 指向它的私聊），并推进该 peer 的 `since_seq`。
- presence 也驱动现有 HUD 角标（显示「N 个 agent 在线」）。

### `ChatPanel.gd`（新 UI；独立 CanvasLayer，从臃肿的 HUD 拆出）
- 开关：`Enter`；打开时捕获文本输入，`Esc`/`Enter` 关闭。
- 布局：左=在线列表（🧑 玩家 + 🤖 各 agent，点击切到与其私聊）；右上=频道标题（大厅 / 与 X 私聊）+ 消息流；右下=输入框（`Enter` 发送）。
- 数据源：ChatHub（读 + 监听 `message_posted`/`presence_changed` 实时刷新）。
- 玩家发言：当前频道=大厅 → post lobby；=某 agent → post dm。

### 接线（`Main.gd` / `Player.gd`）
- Main 创建 ChatHub，注册玩家实体（id 如 `"player"`，名「你」），注入给 AgentBridge 与 ChatPanel。
- 输入：新增 InputMap action `toggle_chat`（默认 `Enter`）。
- **打开聊天 = 释放鼠标 + 暂停玩家移动/挖放输入**，避免边打字边操作世界（复用现有暂停/鼠标捕获机制）。

## 数据流

1. 玩家按 `Enter` → ChatPanel 打开，显示 presence + 大厅消息。
2. 玩家在 agent-1 频道输入「hi」→ `Enter` → `ChatHub.post("player", "agent-1", "hi")`。
3. agent-1 下次心跳 `observe` → 结果 `inbox` 含该私聊 → agent 用 `say({text:"在!", to:"player"})` 回（`to` 收实体 id 或显示名） → `ChatHub.post("agent-1","player",...)` → ChatPanel 实时显示。
4. agent 发大厅：`say({text:"我在盖塔"})` → 大厅 → 所有人（含其他 agent 下次 `observe.chat`）可见。

## 测试（headless，沿用 `tests/test_*.gd` 风格）

- `test_chat_hub.gd`：register/unregister；post 大厅 vs 私聊；lobby_recent/thread/unread_for 的 seq 语义；环形上限。
- `test_agent_bridge_multi.gd`：两个模拟连接（直接喂 JSON 行，不走 TCP）；各自 `identify`；`say` 到大厅与私聊；`observe.inbox` 只含该 peer 未读且推进 `since_seq`；断开后 unregister。
- `test_chat_panel.gd`：加载 Main（headless），post 几条 → 面板模型反映；切频道。
- 既有 `test_agent_bridge.gd` / `test_agent_badge.gd` 保持绿（向后兼容）。

## 兼容与风险

- **向后兼容**：`say` 不传 `to` = 旧行为（HUD 闪），现在额外进大厅；单 agent 场景照常工作。
- **并发**：仍主线程 `_process` 串行处理多 peer，无线程问题。
- **输入冲突**：打开聊天必须拦截游戏输入，否则打字会触发挖/放/移动。
- **命名**：未 `identify` 的用 `agent-N`；重名以 id 区分。
- **契约更新**：`docs/agent-bridge-contract.md` 原写「单客户端」，改为「可多客户端，每连接一个实体」，并补 `identify` / `say.to` / `observe.chat`/`inbox`。

## MCP 服务器（agent-bridge-mcp）

- 暴露新工具 `identify`、扩展 `say`（可选 `to`）；`observe` 透传 `chat`/`inbox`。
- 更新 README/契约；`npm run build` 重新产出 dist。
