# M1 — Local Authoritative Co-op Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run one headless authoritative Godot world server + 2 Godot clients on the same machine; players see each other move and see each other's block edits in real time; in-memory deltas survive within the session (leave a chunk and return → edits still there; a late-joining client sees existing edits). No accounts, no web export, no cloud, no lobby, no interest management.

**Architecture:** Authoritative client-server over `WebSocketMultiplayerPeer` + Godot high-level RPC. The server owns a headless `WorldData` (the M0 data core) as the single source of truth and never meshes. Clients render a deterministic copy from the server-sent seed and apply server-broadcast block deltas. Player avatars sync via **custom server-authoritative RPC** (snapshot broadcast + client-side interpolation), not `MultiplayerSynchronizer` — see "Key design decisions" below. Single-player stays 100% working; all networking is gated behind a launch mode.

**Tech Stack:** Godot 4.6 GDScript · `WebSocketMultiplayerPeer` · `@rpc` high-level multiplayer · existing `WorldData` (M0) · existing `ChatHub`/avatar precedents.

---

## Key design decisions (read before executing)

1. **Custom RPC for player/avatar sync, NOT `MultiplayerSpawner`/`MultiplayerSynchronizer`.**
   The 2026-06-03 spec (§6, §11) names `MultiplayerSynchronizer` as M1's fast path "to be replaced by manual sync + interest management later (M5)". This plan **deviates deliberately**: this codebase is code-first (avatars are built in GDScript — `AgentAvatar.gd`, `Player._make_avatar` — with no PackedScenes; networking precedents `AgentBridge`/`ChatHub` are hand-rolled). `MultiplayerSpawner` needs a scene to spawn and `MultiplayerSynchronizer` needs a replication-config resource, both of which fight the code-first style and are opaque to headless unit tests. A custom snapshot-broadcast (server → clients at ~15 Hz, client-side interpolation) is **fewer moving parts here, fully unit-testable, and is the M5 target anyway** — so we build it once. **If the reviewer prefers the spec's `MultiplayerSynchronizer` path, stop and re-plan Tasks 4/6/9 before executing.**

2. **The authority core is pure and headless-testable.** All validation + apply + payload-building live in `NetworkManager` as plain methods operating on an injected `WorldData` — no `MultiplayerAPI`, no sockets. This mirrors `AgentBridge.dispatch()` (logic separated from TCP). Phase A tests drive these methods directly (like `tests/test_world_data.gd` and `tests/test_agent_bridge_multi.gd`). The live socket/RPC layer (Phase B) is verified manually with 2 windows + a few automated "it boots / connects / suite stays green" checks.

3. **Server owns `WorldData` directly; no `World` node, no meshing on the server.** (Spec risk #3.) `SERVER` mode builds only `WorldData` + `NetworkManager`. `HOST`/`CLIENT`/`OFFLINE` modes build the full `World` (render shell) whose `World._data` is the local `WorldData`; in `HOST` the local `World._data` is the authority.

4. **Edit routing through a single choke point.** `World.request_edit/request_edits/request_block_edits` gain an optional `net` reference. `OFFLINE` → apply locally (today's behavior, unchanged). `CLIENT` → forward to server via RPC, do **not** apply locally (apply on broadcast). `HOST` → apply locally **and** broadcast. `Player.gd` is **not** touched — all its `world.request_*` calls keep working.

5. **No client-side prediction in M1.** A client's own edit waits one localhost round-trip before showing. Spec accepts this ("建造类游戏不抢帧"). Keeps M1 simple.

6. **Launch modes via env vars** (scriptable + testable). A minimal in-title "Join / Host" UI is the last task (manual). Modes:
   - `OW_SERVER=1` [`OW_PORT=8971`] → headless authoritative server.
   - `OW_HOST=1` [`OW_PORT`] → host: authoritative server **and** local player in one window (one-machine testing).
   - `OW_CONNECT=ws://127.0.0.1:8971` → client connects on launch.
   - none → single-player (today).

## Milestone scope guard (from spec §11 — "M1 明确不做")

NOT in M1: accounts, cloud save, web/WASM export, lobby/matchmaking, full anti-cheat, interest management, multiplayer perf optimization, WebRTC. Those are M2+. M1's anti-cheat is the essential authority only: y-bounds, reach-distance from the editing player, and a basic per-peer edit rate cap.

---

## File structure

- **Create** `scripts/NetworkManager.gd` (`extends Node`) — owns mode, peer roster, authority core (pure), handshake/snapshot builders (pure), and the live RPC/socket layer (Phase B). Injected refs (`world`/`player`/`chat_hub`) like `AgentBridge`.
- **Create** `scripts/RemoteAvatar.gd` (`extends Node3D`) — a networked player's body: name label + per-player color + **interpolated** movement (`set_net_target(pos, yaw)` lerped in `_process`). Modeled on `AgentAvatar.gd` but parameterized and smooth-moving.
- **Create** `tests/test_network_core.gd` (`extends SceneTree`) — Phase A: authority + handshake + snapshot, driven headlessly with an injected `WorldData`. No SceneTree members, no sockets.
- **Create** `tests/test_network_lifecycle.gd` (`extends SceneTree`) — Phase A: peer register/drop + presence + roster, driven by calling handlers directly (no real `MultiplayerAPI`).
- **Modify** `scripts/World.gd` — add `var net = null` + route `request_edit/request_edits/request_block_edits` through it; add `apply_remote_edit()` (local apply, no history, no re-broadcast).
- **Modify** `scripts/Main.gd` — detect launch mode; extract the gameplay build into `_enter_world(seed, spawn)`; wire `SERVER`/`HOST`/`CLIENT`; deferred world-build for `CLIENT` (on welcome).
- **Create** `scripts/NetMenu.gd` (`extends CanvasLayer`) — Task 9 minimal "Host & Play / Join (address)" panel (manual-verified).
- **Create** `packaging/run_coop_demo.sh` — launch 1 headless server + 2 client windows for the manual M1 acceptance test.
- **Unchanged** `scripts/Player.gd`, `scripts/WorldData.gd`, `scripts/Chunk.gd`, `scripts/AgentAvatar.gd`, `scripts/ChatHub.gd`.

`NetworkManager` public surface (target):

```gdscript
# scripts/NetworkManager.gd  (extends Node)
enum Mode { OFFLINE, SERVER, CLIENT, HOST }
var mode: int
var world            # World node (CLIENT/HOST) or null (SERVER)
var player           # local Player (CLIENT/HOST) or null (SERVER)
var chat_hub         # ChatHub (optional)
var avatar_factory: Callable   # () -> Node3D ; injected so tests use a stub

# ---- pure authority core (headless-testable; no MultiplayerAPI/sockets) ----
func set_authority_data(data: WorldData, world_seed: int, spawn: Vector3) -> void
func register_peer(peer_id: int, display_name: String) -> String          # -> eid
func drop_peer(peer_id: int) -> void
func set_peer_transform(peer_id: int, pos: Vector3, yaw: float) -> void
func authorize_edit(peer_id: int, wx: int, wy: int, wz: int, id: int, now: float = -1.0) -> Dictionary
                                  # -> {ok, pos:[x,y,z], id, revision, affected:[[cx,cz]...]} or {ok:false, reason}
func build_welcome(peer_id: int) -> Dictionary    # {seed, spawn:[x,y,z], your_eid, peers:[{eid,name,pos}], deltas:{...}}
func apply_welcome(payload: Dictionary) -> void   # CLIENT: world.setup(seed) + load deltas
func build_player_snapshot() -> Array             # [{eid, pos:[x,y,z], yaw}]
func apply_player_snapshot(snapshot: Array) -> void   # CLIENT: upsert/remove RemoteAvatars
func peer_eids() -> Array                          # roster (sorted), for tests/UI

# ---- live layer (Phase B; MultiplayerAPI + WebSocketMultiplayerPeer) ----
func start_server(port: int) -> int
func start_client(url: String) -> int
func start_host(port: int) -> int
```

---

# PHASE A — Authority core (headless, TDD)

**Principle:** TDD. Build the pure logic against headless tests first. No sockets, no `MultiplayerAPI`. Commit after each task.

### Task 1: `NetworkManager` skeleton + `authorize_edit` (validate → apply → payload)

**Files:** Create `scripts/NetworkManager.gd`; Create `tests/test_network_core.gd`

- [ ] **Step 1: Write the failing test** (`tests/test_network_core.gd`)

```gdscript
extends SceneTree
# NetworkManager 权威核心自检（纯逻辑，无 socket / 无 MultiplayerAPI）：
#   godot --headless --path . --script res://tests/test_network_core.gd
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var data := WorldData.new(1337)
	var nm := NetworkManager.new()
	nm.mode = NetworkManager.Mode.SERVER
	nm.set_authority_data(data, 1337, Vector3(8, data.surface_y(8, 8) + 2, 8))
	var eid := nm.register_peer(7, "Alice")
	check(eid != "", "register_peer 返回非空 eid")
	# 把该玩家放到编辑点附近（服务器才允许就近编辑）
	var sy := data.surface_y(8, 8)
	nm.set_peer_transform(7, Vector3(8, sy + 1, 8), 0.0)

	# 合法编辑：就近、y 合法、值有变化 -> 接受
	var r: Dictionary = nm.authorize_edit(7, 8, sy, 8, 0)
	check(bool(r.get("ok", false)), "就近合法编辑被接受")
	check(int(data.get_block(8, sy, 8)) == 0, "权威数据已写入新值")
	check(int(r.get("revision", 0)) >= 1, "返回的 revision 递增")
	check((r.get("affected", []) as Array).size() >= 1, "返回受影响区块")

	# 越界 y -> 拒绝
	check(not bool(nm.authorize_edit(7, 8, -1, 8, 3).get("ok", true)), "y 越界被拒绝")
	check(not bool(nm.authorize_edit(7, 8, 100000, 8, 3).get("ok", true)), "y 超高被拒绝")

	# 太远 -> 拒绝（玩家在 (8,*,8)，编辑 (500,*,500)）
	var far: Dictionary = nm.authorize_edit(7, 500, data.surface_y(500, 500), 500, 0)
	check(not bool(far.get("ok", true)), "超出可及距离的编辑被拒绝")
	check(str(far.get("reason", "")) != "", "拒绝带原因")

	# 未注册的 peer -> 拒绝
	check(not bool(nm.authorize_edit(999, 8, sy, 8, 0).get("ok", true)), "未注册 peer 被拒绝")

	# 值未变（已是 air）-> 视为无变化（ok=false 或 changed=false）
	var noop: Dictionary = nm.authorize_edit(7, 8, sy, 8, 0)
	check(not bool(noop.get("ok", true)), "重复挖空气=无变化被拒绝")

	if failed == 0: print("✅ ALL NETWORK CORE TESTS PASSED")
	else: printerr("❌ ", failed, " 个网络核心测试失败")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run it, verify RED**

Run: `godot --headless --path . --script res://tests/test_network_core.gd`
Expected: FAIL — `Preload file "res://scripts/NetworkManager.gd" does not exist.`

- [ ] **Step 3: Create `scripts/NetworkManager.gd`** (skeleton + pure authority; no sockets yet)

```gdscript
extends Node
# OurWorlds 联机管理器（M1：本地权威联机）。
# 设计要点（详见 docs/superpowers/plans/2026-06-06-m1-local-coop.md）：
#   - 权威核心（校验/写入/打包）是纯方法，作用在注入的 WorldData 上，可无头单测；
#     真正的 socket/RPC 在 Phase B 接上，跟核心解耦（镜像 AgentBridge.dispatch 的可测性）。
#   - 服务器直接持有 WorldData（无 World 节点、不造网格）；HOST/CLIENT 用 World._data。
const WorldData = preload("res://scripts/WorldData.gd")
const Chunk = preload("res://scripts/Chunk.gd")

enum Mode { OFFLINE, SERVER, CLIENT, HOST }

const DEFAULT_PORT := 8971
const PLAYER_REACH := 8.0          # 服务器校验：编辑点离该玩家的最大水平+垂直距离（基础防作弊）
const EDIT_RATE_WINDOW := 1.0      # 频率限制窗口（秒）
const EDIT_RATE_MAX := 96          # 每窗口每 peer 最多接受的编辑次数

var mode: int = Mode.OFFLINE
var world                          # World 节点（CLIENT/HOST）；SERVER 为空
var player                         # 本地玩家（CLIENT/HOST）；SERVER 为空
var chat_hub                       # ChatHub（可空）
var avatar_factory: Callable = Callable()   # () -> Node3D，生成 RemoteAvatar；测试用桩

var _data: WorldData               # 权威数据（SERVER/HOST）
var _seed: int = 1337
var _spawn: Vector3 = Vector3.ZERO
var _peers := {}                   # peer_id:int -> {eid, name, pos:Vector3, yaw:float, edits:Array[float]}
var _eid_counter := 0

func set_authority_data(data: WorldData, world_seed: int, spawn: Vector3) -> void:
	_data = data
	_seed = world_seed
	_spawn = spawn

func register_peer(peer_id: int, display_name: String) -> String:
	_eid_counter += 1
	var eid := "player-%d" % _eid_counter
	var nm := display_name.strip_edges()
	if nm == "":
		nm = eid
	_peers[peer_id] = {"eid": eid, "name": nm, "pos": _spawn, "yaw": 0.0, "edits": []}
	if chat_hub != null:
		chat_hub.register(eid, nm, "human")
	return eid

func drop_peer(peer_id: int) -> void:
	if not _peers.has(peer_id):
		return
	var eid := str(_peers[peer_id]["eid"])
	if chat_hub != null:
		chat_hub.unregister(eid)
	_peers.erase(peer_id)

func set_peer_transform(peer_id: int, pos: Vector3, yaw: float) -> void:
	if not _peers.has(peer_id):
		return
	_peers[peer_id]["pos"] = pos
	_peers[peer_id]["yaw"] = yaw

func peer_eids() -> Array:
	var out := []
	for pid in _peers:
		out.append(str(_peers[pid]["eid"]))
	out.sort()
	return out

# 服务器权威：校验一条编辑请求，合法则写入 WorldData 并返回广播载荷。
# now<0 时用真实时钟（运行时）；测试可显式传 now 以测频率限制。
func authorize_edit(peer_id: int, wx: int, wy: int, wz: int, id: int, now: float = -1.0) -> Dictionary:
	if not _peers.has(peer_id):
		return {"ok": false, "reason": "unknown peer"}
	if wy < 0 or wy >= Chunk.SY:
		return {"ok": false, "reason": "y out of range"}
	var ppos: Vector3 = _peers[peer_id]["pos"]
	var d := Vector3(float(wx) + 0.5, float(wy) + 0.5, float(wz) + 0.5) - ppos
	if absf(d.x) > PLAYER_REACH + 1.0 or absf(d.y) > PLAYER_REACH + 1.0 or absf(d.z) > PLAYER_REACH + 1.0:
		return {"ok": false, "reason": "out of reach"}
	if not _accept_rate(peer_id, now):
		return {"ok": false, "reason": "rate limited"}
	var affected: Array = _data.apply_edit_local(wx, wy, wz, id)
	if affected.is_empty():
		return {"ok": false, "reason": "no change"}
	var cc := _data.chunk_of(wx, wz)
	var aff_out := []
	for c in affected:
		aff_out.append([c.x, c.y])
	return {
		"ok": true,
		"pos": [wx, wy, wz],
		"id": id,
		"revision": _data.chunk_revision(cc),
		"affected": aff_out,
	}

# 每 peer 的滑动窗口频率限制。now<0 用真实时钟。
func _accept_rate(peer_id: int, now: float) -> bool:
	var t := now
	if t < 0.0:
		t = float(Time.get_ticks_msec()) / 1000.0
	var edits: Array = _peers[peer_id]["edits"]
	var keep := []
	for ts in edits:
		if t - float(ts) < EDIT_RATE_WINDOW:
			keep.append(ts)
	if keep.size() >= EDIT_RATE_MAX:
		_peers[peer_id]["edits"] = keep
		return false
	keep.append(t)
	_peers[peer_id]["edits"] = keep
	return true
```

> Copy `Chunk.SY` semantics and `apply_edit_local`/`chunk_revision`/`chunk_of` usage verbatim from `WorldData.gd` (M0). The reach test uses per-axis `PLAYER_REACH + 1.0` so a player standing at the surface can edit a block at their feet/eye level.

- [ ] **Step 4: Run it, verify GREEN**

Run: `godot --headless --path . --script res://tests/test_network_core.gd`
Expected: PASS — `✅ ALL NETWORK CORE TESTS PASSED`

- [ ] **Step 5: Commit**

```bash
git add scripts/NetworkManager.gd tests/test_network_core.gd
git commit -m "feat(m1): NetworkManager authority core — validate + apply_edit (TDD)"
```

---

### Task 2: Peer lifecycle + presence (register/drop/roster)

**Files:** Create `tests/test_network_lifecycle.gd`

> The lifecycle code (`register_peer`/`drop_peer`/`peer_eids` + ChatHub presence) already landed in Task 1. This task pins it with a dedicated test that also proves ChatHub integration mirrors the `AgentBridge` multi-client pattern.

- [ ] **Step 1: Write the failing test** (`tests/test_network_lifecycle.gd`)

```gdscript
extends SceneTree
# NetworkManager 连接生命周期 + 在线名册（直接调用 handler，不经真实 MultiplayerAPI）：
#   godot --headless --path . --script res://tests/test_network_lifecycle.gd
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
const ChatHub = preload("res://scripts/ChatHub.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var hub := ChatHub.new()
	hub.register("host", "房主", "human")
	var nm := NetworkManager.new()
	nm.mode = NetworkManager.Mode.SERVER
	nm.chat_hub = hub
	nm.set_authority_data(WorldData.new(5), 5, Vector3.ZERO)

	var e1 := nm.register_peer(11, "Alice")
	var e2 := nm.register_peer(12, "Bob")
	check(e1 != e2, "两个 peer 得到不同 eid")
	check(nm.peer_eids().size() == 2, "名册有 2 个联机玩家")
	# 进了 ChatHub 在线列表（human）
	var ids := []
	for e in hub.entities():
		ids.append(str((e as Dictionary).get("id", "")))
	check(e1 in ids and e2 in ids, "联机玩家进入 ChatHub 在线列表")

	nm.drop_peer(11)
	check(nm.peer_eids().size() == 1, "断开后名册剩 1")
	var ids2 := []
	for e in hub.entities():
		ids2.append(str((e as Dictionary).get("id", "")))
	check(not (e1 in ids2), "断开的玩家从在线列表移除")
	check(e2 in ids2, "其余玩家仍在线")

	if failed == 0: print("✅ ALL NETWORK LIFECYCLE TESTS PASSED")
	else: printerr("❌ ", failed, " 个生命周期测试失败")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run, verify GREEN** (code already exists from Task 1)

Run: `godot --headless --path . --script res://tests/test_network_lifecycle.gd`
Expected: PASS — `✅ ALL NETWORK LIFECYCLE TESTS PASSED`

> If it fails, the bug is in Task 1's `register_peer`/`drop_peer`/`peer_eids`/ChatHub calls — fix there.

- [ ] **Step 3: Commit**

```bash
git add tests/test_network_lifecycle.gd
git commit -m "test(m1): NetworkManager peer lifecycle + ChatHub presence"
```

---

### Task 3: Welcome handshake (seed + spawn + deltas + roster)

**Files:** Modify `scripts/NetworkManager.gd`; Modify `tests/test_network_core.gd`

- [ ] **Step 1: Add failing tests** (append before the PASS print in `_initialize`)

```gdscript
	# ---- 入场握手：服务器打包 welcome，客户端套用后地形增量一致 ----
	var srv := NetworkManager.new()
	srv.mode = NetworkManager.Mode.SERVER
	var sdata := WorldData.new(2024)
	srv.set_authority_data(sdata, 2024, Vector3(4, sdata.surface_y(4, 4) + 2, 4))
	var pe := srv.register_peer(20, "Carol")
	srv.set_peer_transform(20, Vector3(4, sdata.surface_y(4, 4) + 1, 4), 0.0)
	# 服务器上已有一处编辑
	srv.authorize_edit(20, 4, sdata.surface_y(4, 4) + 1, 4, 3)
	var welcome: Dictionary = srv.build_welcome(20)
	check(int(welcome.get("seed", 0)) == 2024, "welcome 带服务器种子")
	check(str(welcome.get("your_eid", "")) == pe, "welcome 带本端 eid")
	check((welcome.get("deltas", {}) as Dictionary).size() == 1, "welcome 带 1 个脏区块增量")

	# 客户端：用一个空 WorldData 套用 welcome 的增量，地形应一致
	var cdata := WorldData.new(int(welcome["seed"]))
	cdata.load_deltas(welcome["deltas"])
	check(int(cdata.get_block(4, sdata.surface_y(4, 4) + 1, 4)) == 3, "客户端套用 welcome 后看到已有编辑")
```

- [ ] **Step 2: Run, verify RED** — `build_welcome` undefined.

Run: `godot --headless --path . --script res://tests/test_network_core.gd`
Expected: FAIL — nonexistent function `build_welcome`.

- [ ] **Step 3: Implement `build_welcome` + `apply_welcome` in `NetworkManager.gd`**

```gdscript
# 服务器：给一个刚连进来的 peer 打包入场信息（种子+出生点+本端 eid+在线名册+全部增量）。
# M1 世界小，直接发全部 delta；兴趣管理（按区块按需发）是 M5。
func build_welcome(peer_id: int) -> Dictionary:
	var roster := []
	for pid in _peers:
		var p: Dictionary = _peers[pid]
		var pos: Vector3 = p["pos"]
		roster.append({"eid": p["eid"], "name": p["name"], "pos": [pos.x, pos.y, pos.z]})
	return {
		"seed": _seed,
		"spawn": [_spawn.x, _spawn.y, _spawn.z],
		"your_eid": str(_peers.get(peer_id, {}).get("eid", "")),
		"peers": roster,
		"deltas": _data.all_deltas(),
	}

# 客户端：套用 welcome —— 用服务器种子建世界并载入增量。world 由 Main 在 CLIENT 模式下注入。
func apply_welcome(payload: Dictionary) -> void:
	_seed = int(payload.get("seed", 1337))
	var sp: Array = payload.get("spawn", [0, 0, 0])
	if sp.size() == 3:
		_spawn = Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
	if world != null and world.has_method("load_deltas_from_net"):
		world.load_deltas_from_net(payload.get("deltas", {}))
```

> `World.load_deltas_from_net` is added in Task 7 (client local-apply path). In Phase A it is only referenced behind a `has_method` guard, so the headless test (which sets no `world`) does not call it.

- [ ] **Step 4: Run, verify GREEN.** Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/NetworkManager.gd tests/test_network_core.gd
git commit -m "feat(m1): NetworkManager welcome handshake (seed + spawn + deltas + roster)"
```

---

### Task 4: Player snapshot (build on server, apply on client → avatars)

**Files:** Modify `scripts/NetworkManager.gd`; Modify `tests/test_network_core.gd`

- [ ] **Step 1: Add failing tests** (append before the PASS print in `_initialize`)

```gdscript
	# ---- 玩家快照：服务器打包所有人的位置，客户端套用后生成/更新/移除 RemoteAvatar ----
	var snap_srv := NetworkManager.new()
	snap_srv.mode = NetworkManager.Mode.SERVER
	snap_srv.set_authority_data(WorldData.new(1), 1, Vector3.ZERO)
	snap_srv.register_peer(31, "Dan")
	snap_srv.register_peer(32, "Eve")
	snap_srv.set_peer_transform(31, Vector3(10, 40, 10), 1.5)
	snap_srv.set_peer_transform(32, Vector3(20, 41, 22), 0.0)
	var snap: Array = snap_srv.build_player_snapshot()
	check(snap.size() == 2, "快照含 2 个玩家")

	# 客户端套用：用桩工厂生成假 avatar，验证 upsert/remove
	var made := {}              # eid -> stub avatar
	var client := NetworkManager.new()
	client.mode = NetworkManager.Mode.CLIENT
	client.avatar_factory = func() -> Node3D:
		var n := Node3D.new()
		return n
	client._self_eid = "me"     # 不给自己造分身
	# 第一次：生成两个 avatar
	client.apply_player_snapshot(snap)
	check(client.avatar_count() == 2, "首次快照生成 2 个 RemoteAvatar")
	# 再来一次（同样的人）：不应重复生成
	client.apply_player_snapshot(snap)
	check(client.avatar_count() == 2, "重复快照不重复生成")
	# 其中一人离开：快照里去掉 -> 移除其 avatar
	var snap2: Array = [snap[0]]
	client.apply_player_snapshot(snap2)
	check(client.avatar_count() == 1, "玩家离开后其 avatar 被移除")
	# 自己的 eid 不会生成分身
	var with_self: Array = snap2.duplicate()
	with_self.append({"eid": "me", "pos": [0, 40, 0], "yaw": 0.0})
	client.apply_player_snapshot(with_self)
	check(client.avatar_count() == 1, "不给本端自己生成 avatar")
```

- [ ] **Step 2: Run, verify RED** — `build_player_snapshot`/`apply_player_snapshot`/`avatar_count`/`_self_eid` undefined.

- [ ] **Step 3: Implement in `NetworkManager.gd`** (add the avatar bookkeeping fields near the other vars, then the methods)

Add fields (next to `_peers`):

```gdscript
var _self_eid := ""                # 本端自己的 eid（CLIENT/HOST）；快照里跳过它
var _avatars := {}                 # eid -> RemoteAvatar 节点（CLIENT）
```

Methods:

```gdscript
# 服务器：打包所有联机玩家的位置/朝向（HOST 下也含房主自己——房主也是一个 peer，见 Task 8）。
func build_player_snapshot() -> Array:
	var out := []
	for pid in _peers:
		var p: Dictionary = _peers[pid]
		var pos: Vector3 = p["pos"]
		out.append({"eid": p["eid"], "pos": [pos.x, pos.y, pos.z], "yaw": p["yaw"]})
	return out

# 客户端：按快照增量更新 avatar —— 缺的生成、有的更新目标、走了的移除。跳过本端自己。
func apply_player_snapshot(snapshot: Array) -> void:
	var seen := {}
	for raw in snapshot:
		var e: Dictionary = raw
		var eid := str(e.get("eid", ""))
		if eid == "" or eid == _self_eid:
			continue
		seen[eid] = true
		var ap: Array = e.get("pos", [0, 0, 0])
		var pos := Vector3(float(ap[0]), float(ap[1]), float(ap[2]))
		var yaw := float(e.get("yaw", 0.0))
		if not _avatars.has(eid):
			var node: Node3D = _spawn_avatar(eid)
			if node == null:
				continue
			_avatars[eid] = node
		var av: Node3D = _avatars[eid]
		if av.has_method("set_net_target"):
			av.set_net_target(pos, yaw)
		else:
			av.global_position = pos
	# 移除快照里不再出现的
	for eid in _avatars.keys():
		if not seen.has(eid):
			var node: Node3D = _avatars[eid]
			if is_instance_valid(node):
				node.queue_free()
			_avatars.erase(eid)

func avatar_count() -> int:
	return _avatars.size()

# 生成一个 RemoteAvatar：优先用注入的工厂（测试桩 / Main 真身），否则返回 null。
func _spawn_avatar(eid: String) -> Node3D:
	if not avatar_factory.is_valid():
		return null
	var node: Node3D = avatar_factory.call()
	if node == null:
		return null
	if node.has_method("set_label"):
		var nm := eid
		if _peers_name_for(eid) != "":
			nm = _peers_name_for(eid)
		node.set_label(nm)
	if world != null:
		world.add_child(node)
	else:
		add_child(node)
	return node

func _peers_name_for(eid: String) -> String:
	for pid in _peers:
		if str(_peers[pid]["eid"]) == eid:
			return str(_peers[pid]["name"])
	return ""
```

> The test's stub `Node3D` has no `set_net_target`/`set_label`, so the `has_method` guards keep it working headlessly. `world` is null in the test, so avatars are added as children of the `NetworkManager` — fine for counting.

- [ ] **Step 4: Run, verify GREEN.** Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/NetworkManager.gd tests/test_network_core.gd
git commit -m "feat(m1): NetworkManager player snapshot build/apply (avatar upsert/remove)"
```

---

# PHASE B — Live wiring (WebSocket + RPC + avatars; manual-verified)

**Principle:** Phase A logic is green and stays green. Phase B adds the socket/RPC transport and the visible avatar, wires `World`/`Main`, and is verified by (a) the full headless suite staying green, (b) automated "boots / connects" smoke checks, and (c) the manual 2-window acceptance test (Task 10). Commit after each task.

### Task 5: `RemoteAvatar.gd` — interpolated networked body

**Files:** Create `scripts/RemoteAvatar.gd`; Create `tests/test_remote_avatar.gd`

- [ ] **Step 1: Write the failing test** (`tests/test_remote_avatar.gd`)

```gdscript
extends SceneTree
# RemoteAvatar：可设名字、设网络目标后朝目标插值移动（不瞬移）。
#   godot --headless --path . --script res://tests/test_remote_avatar.gd
const RemoteAvatar = preload("res://scripts/RemoteAvatar.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var a := RemoteAvatar.new()
	root.add_child(a)            # 需要进树才能跑 _ready/_process
	a.set_label("Alice")
	a.global_position = Vector3.ZERO
	a.set_net_target(Vector3(10, 0, 0), 0.0)
	# 模拟若干帧插值：应朝目标靠近但（单帧）不立刻到达
	a._net_step(0.1)
	check(a.global_position.x > 0.0 and a.global_position.x < 10.0, "设目标后朝目标插值（未瞬移）")
	# 足够多帧后应收敛到目标附近
	for i in range(120):
		a._net_step(0.1)
	check(a.global_position.distance_to(Vector3(10, 0, 0)) < 0.2, "多帧后收敛到目标")
	check(str(a.label_text()) == "Alice", "名牌文字可读")
	if failed == 0: print("✅ ALL REMOTE AVATAR TESTS PASSED")
	else: printerr("❌ ", failed, " 个 RemoteAvatar 测试失败")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run, verify RED** — preload missing.

- [ ] **Step 3: Create `scripts/RemoteAvatar.gd`** (modeled on `AgentAvatar.gd`, parameterized + interpolated; `_process` delegates to `_net_step` so it's unit-testable)

```gdscript
extends Node3D
# 联机里"别人"的身体：方块小人 + 头顶名牌 + 朝网络目标平滑插值（区别于 AgentAvatar 的瞬移）。
# 位置/朝向由 NetworkManager 的玩家快照驱动（set_net_target）。每个玩家一个不同的工装色。

const LERP_POS := 10.0             # 位置插值速度（越大越跟手；localhost 用大值几乎贴目标）
const LERP_YAW := 12.0

var _rig: Node3D
var _label: Label3D
var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _color := Color(0.30, 0.62, 1.00)   # 默认蓝工装；set_color 可改

func _ready() -> void:
	_rig = Node3D.new()
	add_child(_rig)
	_build_body(_rig)
	_build_nameplate()
	_target_pos = global_position

func set_label(text: String) -> void:
	if _label == null:
		_pending_label = text
	else:
		_label.text = text

func label_text() -> String:
	if _label != null:
		return _label.text
	return _pending_label

var _pending_label := ""

func set_color(c: Color) -> void:
	_color = c

func set_net_target(pos: Vector3, yaw: float) -> void:
	_target_pos = pos
	_target_yaw = yaw

func _process(delta: float) -> void:
	_net_step(delta)

# 纯插值步进（测试直接调用）：朝目标平滑移动 + 转向。
func _net_step(delta: float) -> void:
	var t := clampf(LERP_POS * delta, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, t)
	var ty := clampf(LERP_YAW * delta, 0.0, 1.0)
	rotation.y = lerp_angle(rotation.y, _target_yaw, ty)

# ---------- 造型（仿 AgentAvatar，配色可变）----------
func _build_body(rootn: Node3D) -> void:
	var skin := Color(0.85, 0.66, 0.50)
	var jacket := _color
	var pants := Color(0.20, 0.22, 0.28)
	rootn.add_child(_box(Vector3(0.50, 0.50, 0.50), Vector3(0, 1.45, 0), skin))      # 头
	rootn.add_child(_box(Vector3(0.52, 0.62, 0.30), Vector3(0, 0.94, 0), jacket))    # 身体
	rootn.add_child(_box(Vector3(0.18, 0.62, 0.22), Vector3(-0.35, 0.94, 0), jacket))# 左臂
	rootn.add_child(_box(Vector3(0.18, 0.62, 0.22), Vector3(0.35, 0.94, 0), jacket)) # 右臂
	rootn.add_child(_box(Vector3(0.22, 0.64, 0.24), Vector3(-0.13, 0.32, 0), pants)) # 左腿
	rootn.add_child(_box(Vector3(0.22, 0.64, 0.24), Vector3(0.13, 0.32, 0), pants))  # 右腿

func _box(size: Vector3, pos: Vector3, col: Color) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	bm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	return mi

func _build_nameplate() -> void:
	_label = Label3D.new()
	_label.text = _pending_label
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.0014
	_label.font_size = 72
	_label.outline_size = 12
	_label.modulate = Color(0.85, 0.95, 1.0)
	_label.position = Vector3(0, 2.25, 0)
	add_child(_label)
```

> Note the `_pending_label` field is declared before first use in `set_label`; move its `var _pending_label := ""` declaration to the top var block during implementation so it parses (GDScript needs the member declared). The test calls `_net_step` directly and reads `label_text()`.

- [ ] **Step 4: Run, verify GREEN.** Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/RemoteAvatar.gd tests/test_remote_avatar.gd
git commit -m "feat(m1): RemoteAvatar — interpolated networked body (TDD)"
```

---

### Task 6: `World` edit routing + remote-apply path

**Files:** Modify `scripts/World.gd`; Modify `tests/test_world_data.gd` is NOT touched — add `tests/test_world_net_routing.gd`

- [ ] **Step 1: Write the failing test** (`tests/test_world_net_routing.gd`) — proves that when a `net` stub is attached in CLIENT mode, `World.request_edit` forwards instead of applying locally; and `apply_remote_edit` applies locally.

```gdscript
extends SceneTree
# World 编辑路由：CLIENT 模式下 request_edit 转发给 net（不本地应用）；apply_remote_edit 本地应用。
#   godot --headless --path . --script res://tests/test_world_net_routing.gd
const World = preload("res://scripts/World.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

class NetStub:
	var forwarded := []
	var client := true
	func is_client() -> bool: return client
	func submit_edit(wx: int, wy: int, wz: int, id: int) -> void:
		forwarded.append([wx, wy, wz, id])

func _initialize() -> void:
	var w := World.new()
	w.setup(BlockLibrary.new(), 77, "")
	var sy := w.surface_y(2, 2)
	var base := w.get_block(2, sy, 2)

	# 无 net（单机）：request_edit 本地应用（保持原行为）
	check(w.request_edit(2, sy, 2, 0), "单机 request_edit 本地生效")
	check(w.get_block(2, sy, 2) == 0, "单机编辑后值改变")

	# 挂上 CLIENT net：request_edit 应转发、且不本地应用
	var stub := NetStub.new()
	w.net = stub
	var before := w.get_block(3, sy, 3)
	var ret := w.request_edit(3, sy, 3, 0)
	check(stub.forwarded.size() == 1, "CLIENT 模式 request_edit 转发给 net")
	check(w.get_block(3, sy, 3) == before, "CLIENT 模式不本地应用（等服务器广播）")

	# 服务器广播到来：apply_remote_edit 本地应用（无历史、无再转发）
	check(w.apply_remote_edit(3, sy, 3, 0), "apply_remote_edit 本地应用成功")
	check(w.get_block(3, sy, 3) == 0, "apply_remote_edit 后值改变")
	check(stub.forwarded.size() == 1, "apply_remote_edit 不再转发")

	if failed == 0: print("✅ ALL WORLD NET ROUTING TESTS PASSED")
	else: printerr("❌ ", failed, " 个 World 路由测试失败")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run, verify RED** — `World.net`/`apply_remote_edit` undefined; routing not present.

- [ ] **Step 3: Implement in `World.gd`**

Add the field near the other top-level vars (e.g., after the existing `_data` declaration region; place with the injected-refs):

```gdscript
var net = null     # NetworkManager（Main 注入）。null=单机。CLIENT 转发编辑、不本地应用；HOST/OFFLINE 本地应用。
```

Add a routing guard helper and route the three entry points. Replace the body of `request_edit` (`World.gd:105-116`) to forward in client mode first:

```gdscript
func request_edit(wx: int, wy: int, wz: int, id: int) -> bool:
	if net != null and net.has_method("is_client") and net.is_client():
		net.submit_edit(wx, wy, wz, id)
		return true                       # 乐观返回；实际生效等服务器广播 apply_remote_edit
	if wy < 0 or wy >= Chunk.SY:
		return false
	var before := get_block(wx, wy, wz)
	if before == id:
		return false
	var dirty := {}
	if not set_block_data(wx, wy, wz, id, dirty):
		return false
	flush_remesh(dirty)
	_push_history(Vector3i(wx, wy, wz), before, id)
	if net != null and net.has_method("broadcast_edit"):
		net.broadcast_edit(wx, wy, wz, id)   # HOST：本地应用后广播给客户端
	return true
```

For `request_edits` (`:118-139`) and `request_block_edits` (`:141-164`), add the same client-forward guard at the top of each, forwarding each cell, and after the local apply + `flush_remesh` + history, broadcast each applied entry. Insert at the very top of `request_edits`:

```gdscript
	if net != null and net.has_method("is_client") and net.is_client():
		var n := 0
		for raw in cells:
			var pos: Vector3i = raw
			net.submit_edit(pos.x, pos.y, pos.z, id)
			n += 1
		return n
```

and at the very top of `request_block_edits`:

```gdscript
	if net != null and net.has_method("is_client") and net.is_client():
		var n := 0
		for raw in edits:
			var edit: Dictionary = raw
			var pos: Vector3i = edit.get("pos", Vector3i.ZERO)
			net.submit_edit(pos.x, pos.y, pos.z, int(edit.get("id", BlockLibrary.AIR)))
			n += 1
		return n
```

After the existing `_push_history_entries(entries)` line in BOTH `request_edits` and `request_block_edits`, before `return entries.size()`, add the HOST broadcast:

```gdscript
	if net != null and net.has_method("broadcast_edit"):
		for e in entries:
			var p: Vector3i = e["pos"]
			net.broadcast_edit(p.x, p.y, p.z, int(e["after"]))
```

Add the remote-apply path + the welcome-delta loader at the end of the read/write section:

```gdscript
# 客户端：套用服务器广播的一条编辑（只写数据 + 重建网格；不记历史、不再转发）。
func apply_remote_edit(wx: int, wy: int, wz: int, id: int) -> bool:
	if wy < 0 or wy >= Chunk.SY:
		return false
	var dirty := {}
	if not set_block_data(wx, wy, wz, id, dirty):
		return false
	flush_remesh(dirty)
	return true

# 客户端：入场时一次性载入服务器下发的全部增量，并重建已加载区块。
func load_deltas_from_net(deltas: Dictionary) -> void:
	_data.load_deltas(deltas)
	_chunks = _data.chunks()      # load_deltas 清了内部 chunk 缓存；重新取共享引用
	var dirty := {}
	for cc in _chunks.keys():
		dirty[cc] = true
	flush_remesh(dirty)
```

> `submit_edit`/`broadcast_edit`/`is_client` are `NetworkManager` methods added in Task 7. The stub in this test provides `is_client`/`submit_edit`; the HOST `broadcast_edit` path is guarded by `has_method`, so with the CLIENT stub it never fires. `load_deltas` already exists on `WorldData` (M0).

- [ ] **Step 4: Run, verify GREEN.** Expected: PASS.

- [ ] **Step 5: Run the FULL suite (regression gate):**

Run: `bash tests/run_all.sh`
Expected: `通过 N  失败 0` (N = prior count + new net tests). Single-player edit/save/undo paths unchanged (net is null in all existing tests).

- [ ] **Step 6: Commit**

```bash
git add scripts/World.gd tests/test_world_net_routing.gd
git commit -m "feat(m1): World edit routing (client forward / host broadcast) + apply_remote_edit"
```

---

### Task 7: `NetworkManager` live layer — server/client, RPC, sync loop

**Files:** Modify `scripts/NetworkManager.gd`

> This is the socket/RPC transport. It has no headless unit test (needs live peers); it is covered by the boot smoke check (Task 8) and the manual 2-window test (Task 10). Write it carefully against the Godot 4.6 API confirmed in the plan header.

- [ ] **Step 1: Add the live methods to `NetworkManager.gd`** (append after the pure core)

```gdscript
# ============ 实时层（Phase B：WebSocketMultiplayerPeer + 高层 RPC）============
# 服务器恒为 peer 1。CLIENT 用 rpc_id(1, ...) 把编辑请求发给服务器；
# 服务器校验后用 rpc(...) 把 apply_edit 广播给所有客户端。玩家快照由服务器 ~15Hz 广播。

const SNAPSHOT_HZ := 15.0
var _snap_accum := 0.0
var _self_sync_accum := 0.0

func is_server() -> bool:
	return mode == Mode.SERVER or mode == Mode.HOST

func is_client() -> bool:
	return mode == Mode.CLIENT

func start_server(port: int) -> int:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		push_warning("联机服务器监听失败 :%d (err=%d)" % [port, err])
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print("OurWorlds 联机服务器监听 :%d（权威，无渲染）" % port)
	return OK

func start_client(url: String) -> int:
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		push_warning("联机连接失败 %s (err=%d)" % [url, err])
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	print("OurWorlds 客户端连接中 %s ..." % url)
	return OK

func start_host(port: int) -> int:
	# HOST = 服务器 + 本地玩家。把房主自己也登记成一个 peer（id=1），这样快照/名册统一处理。
	var r := start_server(port)
	if r != OK:
		return r
	var eid := register_peer(1, "房主")
	_self_eid = eid
	if player != null:
		set_peer_transform(1, player.global_position, player.rotation.y)
	return OK

# ---- 服务器侧信号 ----
func _on_peer_connected(id: int) -> void:
	# peer 连上后等它先 rpc 报名（_rpc_hello）；这里只占位，正式注册在 _rpc_hello。
	pass

func _on_peer_disconnected(id: int) -> void:
	if _peers.has(id):
		drop_peer(id)

# ---- 客户端侧信号 ----
func _on_connected_to_server() -> void:
	# 连上后向服务器报名（带本机玩家名）；服务器回 _rpc_welcome。
	_rpc_hello.rpc_id(1, _local_player_name())
	print("已连上服务器，等待入场 ...")

func _on_server_disconnected() -> void:
	print("与服务器断开。")

func _local_player_name() -> String:
	return "玩家"   # M1 先用固定名；Task 9 的连接界面可让玩家填名

# ---- RPC：客户端->服务器 ----
@rpc("any_peer", "reliable")
func _rpc_hello(display_name: String) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var eid := register_peer(sender, display_name)
	# 给新人发 welcome（种子+出生点+全部增量+名册）
	_rpc_welcome.rpc_id(sender, build_welcome(sender))

@rpc("any_peer", "call_local", "reliable")
func _rpc_request_edit(wx: int, wy: int, wz: int, id: int) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var res := authorize_edit(sender, wx, wy, wz, id)
	if not bool(res.get("ok", false)):
		return
	# 广播给所有客户端（HOST 的本地世界已在 broadcast_edit 里就地应用，这里只发远端）
	_rpc_apply_edit.rpc(wx, wy, wz, id)

@rpc("any_peer", "unreliable_ordered")
func _rpc_update_self(px: float, py: float, pz: float, yaw: float) -> void:
	if not is_server():
		return
	set_peer_transform(multiplayer.get_remote_sender_id(), Vector3(px, py, pz), yaw)

# ---- RPC：服务器->客户端 ----
@rpc("authority", "reliable")
func _rpc_welcome(payload: Dictionary) -> void:
	_self_eid = str(payload.get("your_eid", ""))
	apply_welcome(payload)
	welcomed.emit(payload)        # Main 在 CLIENT 模式下接它来建世界/玩家（Task 8）

@rpc("authority", "call_local", "reliable")
func _rpc_apply_edit(wx: int, wy: int, wz: int, id: int) -> void:
	if world != null and world.has_method("apply_remote_edit"):
		world.apply_remote_edit(wx, wy, wz, id)

@rpc("authority", "unreliable_ordered")
func _rpc_sync_players(snapshot: Array) -> void:
	apply_player_snapshot(snapshot)

signal welcomed(payload: Dictionary)

# ---- 编辑出入口（World.net 调用）----
func submit_edit(wx: int, wy: int, wz: int, id: int) -> void:
	_rpc_request_edit.rpc_id(1, wx, wy, wz, id)     # 客户端：请求发给服务器

func broadcast_edit(wx: int, wy: int, wz: int, id: int) -> void:
	# HOST：本地世界已应用，把这条编辑广播给所有客户端（不含自己，故用 call_remote 语义的 rpc）。
	_rpc_apply_edit.rpc(wx, wy, wz, id)

# ---- 帧循环：服务器广播玩家快照；客户端上报自身位置 ----
func _process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if is_server():
		# HOST：把房主自己的最新位置写进 peer 表
		if mode == Mode.HOST and player != null and _peers.has(1):
			set_peer_transform(1, player.global_position, player.rotation.y)
		_snap_accum += delta
		if _snap_accum >= 1.0 / SNAPSHOT_HZ:
			_snap_accum = 0.0
			if not _peers.is_empty():
				_rpc_sync_players.rpc(build_player_snapshot())
	elif is_client():
		_self_sync_accum += delta
		if _self_sync_accum >= 1.0 / SNAPSHOT_HZ:
			_self_sync_accum = 0.0
			if player != null:
				_rpc_update_self.rpc_id(1, player.global_position.x, player.global_position.y, player.global_position.z, player.rotation.y)
```

> **Execution-time verification:** confirm in the running engine that `WebSocketMultiplayerPeer.create_client` wants a `ws://host:port` URL and `create_server(port)` binds all interfaces (localhost is fine for M1). Confirm `@rpc` annotations parse on a plain `Node`. If `unreliable_ordered` is rejected for WebSocket (TCP-backed), fall back to `"reliable"` for the sync RPCs — note this in the commit.

- [ ] **Step 2: Parse/boot check** — the script must at least parse and the server must start listening headlessly:

Run: `OW_SERVER=1 OW_PORT=8971 godot --headless --path . --quit-after 120 2>&1 | head -30`
Expected: prints `OurWorlds 联机服务器监听 :8971（权威，无渲染）`, no `SCRIPT ERROR`/`Parse Error`. (Wiring of `OW_SERVER` happens in Task 8; until then, test parse only via `godot --headless --check-only --script res://scripts/NetworkManager.gd` or a temporary loader.)

> If Task 8 isn't done yet, verify parse with: `godot --headless --path . --script res://tests/test_network_core.gd` (it preloads NetworkManager — a parse error there fails the whole suite).

- [ ] **Step 3: Run the FULL suite (regression gate).**

Run: `bash tests/run_all.sh`
Expected: `失败 0`. The new live methods are inert in headless tests (no `multiplayer_peer` set).

- [ ] **Step 4: Commit**

```bash
git add scripts/NetworkManager.gd
git commit -m "feat(m1): NetworkManager live layer — WebSocket server/client + RPC + sync loop"
```

---

### Task 8: `Main` launch modes + deferred client world-build

**Files:** Modify `scripts/Main.gd`

- [ ] **Step 1: Extract the gameplay build into `_enter_world(seed, spawn)`.** Move the body of `_ready` from the `world.setup(...)`/spawn/player/HUD/subsystems region (`Main.gd:135`–`285`, i.e. from computing `save_file` through `_setup_agent_bridge()`) into a new method `func _enter_world(seed_value: int, spawn_override) -> void:`, using `seed_value` in place of `_current_seed` for `world.setup` and using `spawn_override` (a `Vector3`, or `null` to call `_find_spawn_position()`). Keep `_current_seed = seed_value` at the top of `_enter_world`. The `world` node creation (`Main.gd:130-132`) stays in `_ready` (the node must exist for CLIENT to receive `apply_remote_edit` before entering). 

The extracted method begins:

```gdscript
func _enter_world(seed_value: int, spawn_override) -> void:
	_current_seed = seed_value
	_setup_celestial_bodies()
	var save_file := _save_path_for_seed(_current_seed)
	world.setup(lib, _current_seed, save_file)
	world.set_view_radius(int(_settings.get("view_radius", 4)))
	if OS.has_environment("VC_RADIUS"):
		world.set_view_radius(int(OS.get_environment("VC_RADIUS")))
	_apply_graphics_quality(_graphics_quality)
	var spawn: Vector3 = spawn_override if spawn_override is Vector3 else _find_spawn_position()
	# ... (rest of the moved block verbatim, through _setup_agent_bridge()) ...
```

> **Amend the title check inside the moved block** (`Main.gd:275-278`): a freshly-welcomed client (and host) should skip the title and drop straight into the world. Change it to:
> ```gdscript
> if OS.has_environment("VC_SKIP_TITLE") or _net_mode != NetworkManager.Mode.OFFLINE:
> 	set_title_active(false)
> else:
> 	set_title_active(true)
> ```

- [ ] **Step 2: Add mode detection + branching in `_ready`.** After `world = World.new(); world.name = "World"; add_child(world)` (`Main.gd:130-132`) and computing `_current_seed = _initial_seed()` (`:133`), branch on launch mode instead of unconditionally calling the (now-extracted) gameplay build:

```gdscript
	_net_mode = _detect_net_mode()
	if _net_mode == NetworkManager.Mode.SERVER:
		_start_dedicated_server()
		return                                  # 纯服务器：不建玩家/HUD/渲染子系统
	if _net_mode == NetworkManager.Mode.CLIENT:
		_start_client_and_wait()                # 先连服务器，welcome 到了再 _enter_world
		return
	# OFFLINE / HOST：立即进世界（HOST 进完再开服）
	_enter_world(_current_seed, null)
	if _net_mode == NetworkManager.Mode.HOST:
		_start_host_after_enter()
```

- [ ] **Step 3: Add the mode helpers + net field.** Add near the top vars: `var _net_mode: int = NetworkManager.Mode.OFFLINE` and `var net_manager: NetworkManager`. Add a `const NetworkManager = preload("res://scripts/NetworkManager.gd")` and `const RemoteAvatar = preload("res://scripts/RemoteAvatar.gd")` with the other preloads. Then:

```gdscript
func _detect_net_mode() -> int:
	if OS.has_environment("OW_SERVER"):
		return NetworkManager.Mode.SERVER
	if OS.has_environment("OW_HOST"):
		return NetworkManager.Mode.HOST
	if OS.has_environment("OW_CONNECT"):
		return NetworkManager.Mode.CLIENT
	return NetworkManager.Mode.OFFLINE

func _net_port() -> int:
	if OS.has_environment("OW_PORT"):
		return int(OS.get_environment("OW_PORT"))
	return NetworkManager.DEFAULT_PORT

func _make_remote_avatar() -> Node3D:
	return RemoteAvatar.new()

func _start_dedicated_server() -> void:
	# 纯权威服务器：只建 WorldData + NetworkManager，不建玩家/HUD/渲染。
	var data := WorldData.new(_current_seed)
	net_manager = NetworkManager.new()
	net_manager.name = "NetworkManager"
	net_manager.mode = NetworkManager.Mode.SERVER
	net_manager.chat_hub = ChatHub.new()
	var spawn := Vector3(0.5, data.surface_y(0, 0) + 3, 0.5)
	net_manager.set_authority_data(data, _current_seed, spawn)
	add_child(net_manager)
	net_manager.start_server(_net_port())
	if title_screen != null:
		set_title_active(false)

func _start_host_after_enter() -> void:
	net_manager = NetworkManager.new()
	net_manager.name = "NetworkManager"
	net_manager.mode = NetworkManager.Mode.HOST
	net_manager.world = world
	net_manager.player = player
	net_manager.chat_hub = chat_hub
	net_manager.avatar_factory = _make_remote_avatar
	net_manager.set_authority_data(world._data, _current_seed, player.global_position)
	world.net = net_manager
	add_child(net_manager)
	net_manager.start_host(_net_port())

func _start_client_and_wait() -> void:
	net_manager = NetworkManager.new()
	net_manager.name = "NetworkManager"
	net_manager.mode = NetworkManager.Mode.CLIENT
	net_manager.world = world
	net_manager.avatar_factory = _make_remote_avatar
	net_manager.welcomed.connect(_on_welcomed)
	add_child(net_manager)
	print("连接服务器中，等待入场 ...")   # 注意：此刻 title_screen 还没建（在 _enter_world 里建），别调 set_title_active
	net_manager.start_client(OS.get_environment("OW_CONNECT"))

func _on_welcomed(payload: Dictionary) -> void:
	# 服务器种子/出生点到了：建世界+玩家+子系统，并把 player 交给 net（位置上报）。
	var sp: Array = payload.get("spawn", [0, 40, 0])
	var spawn := Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
	_enter_world(int(payload.get("seed", _current_seed)), spawn)
	world.net = net_manager
	net_manager.player = player
	net_manager.chat_hub = chat_hub
	# welcome 里的初始增量在 apply_welcome 时已尝试载入；此刻 world 已就绪，补一次确保渲染
	if payload.has("deltas"):
		world.load_deltas_from_net(payload["deltas"])
```

> `apply_welcome` ran at `_rpc_welcome` time when `world` existed but had not yet `setup()`. The re-load in `_on_welcomed` after `_enter_world` is the authoritative one. (Alternatively, skip the load in `apply_welcome` for CLIENT and only load here — either is fine; loading twice is idempotent.)

- [ ] **Step 4: Boot smoke checks (automated).**

Dedicated server boots and listens:
Run: `OW_SERVER=1 OW_PORT=8971 godot --headless --path . --quit-after 90 2>&1 | grep -E "监听|SCRIPT ERROR|Parse"`
Expected: `OurWorlds 联机服务器监听 :8971（权威，无渲染）`, no errors.

Offline still boots unchanged:
Run: `VC_SKIP_TITLE=1 VC_NO_SAVE=1 godot --headless --path . --quit-after 60 2>&1 | grep -E "脚下区域就绪|SCRIPT ERROR|Parse"`
Expected: `脚下区域就绪 ... ms`, no errors.

- [ ] **Step 5: Run the FULL suite (regression gate).** `bash tests/run_all.sh` → `失败 0`.

- [ ] **Step 6: Commit**

```bash
git add scripts/Main.gd
git commit -m "feat(m1): Main launch modes (server/host/client) + deferred client world-build"
```

---

### Task 9: Minimal connect UI (Host & Play / Join) — manual

**Files:** Create `scripts/NetMenu.gd`; Modify `scripts/Main.gd` (title hook)

> Optional polish so multiplayer is reachable without env vars. Keep it tiny. Env-var launch remains the tested path; this is manual-verified.

- [ ] **Step 1: Create `scripts/NetMenu.gd`** — a `CanvasLayer` with two buttons ("开服并游玩" / "加入") and an address `LineEdit` (default `ws://127.0.0.1:8971`), emitting `host_requested()` and `join_requested(url)`. (Model the panel styling on `ChatPanel.gd`; reuse `ui/theme.tres`.) Provide `open()`/`close()`/`is_open()` and a headless-safe `submit_join(url)` for a smoke test.

- [ ] **Step 2: Add a small "联机" affordance to the title screen** (or a key in `_unhandled_input`, e.g. `KEY_J`) that calls `net_menu.open()`. Wire `host_requested` → set `_net_mode = HOST`, `_enter_world(...)` if not already, `_start_host_after_enter()`. Wire `join_requested(url)` → set `OW_CONNECT` equivalent in memory, `_start_client_and_wait()` using the provided url (refactor `_start_client_and_wait` to take an explicit `url` param defaulting to `OS.get_environment("OW_CONNECT")`).

- [ ] **Step 3: Create `tests/test_net_menu.gd`** — headless: instantiate `NetMenu`, assert `is_open()` toggles and `join_requested` fires with the typed url via `submit_join`. (UI rendering is manual.)

Run: `godot --headless --path . --script res://tests/test_net_menu.gd` → PASS.

- [ ] **Step 4: Run the FULL suite.** `bash tests/run_all.sh` → `失败 0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/NetMenu.gd scripts/Main.gd tests/test_net_menu.gd
git commit -m "feat(m1): minimal Host/Join connect menu"
```

---

# PHASE C — Acceptance + finish

### Task 10: Demo launcher, manual acceptance, docs, finish

**Files:** Create `packaging/run_coop_demo.sh`; Modify the two design docs

- [ ] **Step 1: Create `packaging/run_coop_demo.sh`** — launches 1 headless server + 2 client windows on localhost:

```bash
#!/usr/bin/env bash
# 本地 M1 验收：1 个无头权威服务器 + 2 个客户端窗口（同一台机）。
#   bash packaging/run_coop_demo.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GODOT="${GODOT:-godot}"
PORT="${OW_PORT:-8971}"
echo "启动权威服务器 :$PORT ..."
OW_SERVER=1 OW_PORT="$PORT" "$GODOT" --headless --path "$HERE" &
SRV=$!
sleep 2
echo "启动客户端 A ..."
OW_CONNECT="ws://127.0.0.1:$PORT" "$GODOT" --path "$HERE" &
sleep 1
echo "启动客户端 B ..."
OW_CONNECT="ws://127.0.0.1:$PORT" "$GODOT" --path "$HERE" &
echo "服务器 PID=$SRV。关掉两个客户端窗口后，按 Ctrl+C 停服。"
wait $SRV
```

- [ ] **Step 2: Manual acceptance (the M1 verification — requires a human at the screen):**
  1. `bash packaging/run_coop_demo.sh` → two client windows open and enter the world.
  2. In window A, move around → window B shows A's avatar moving (smoothly). And vice-versa. ✅ "互相看得见走动"
  3. In window A, place/break blocks → window B sees the same edits within a moment. ✅ "看得见对方挖/放"
  4. In window A, edit a block, walk far enough that the chunk unloads, walk back → the edit is still there. ✅ "远离再回来改动仍在"
  5. Close client B, relaunch a fresh client B → it joins and sees all of A's existing edits. ✅ "后加入也能看到已有改动"
  6. (Single-player guard) Launch with no env vars → plays exactly as before. ✅

- [ ] **Step 3: Update docs.** In `docs/superpowers/specs/2026-06-03-online-multiplayer-design.md` header/§9, mark **M1 done** and note the `MultiplayerSynchronizer`→custom-RPC deviation. In `docs/superpowers/plans/2026-06-06-p1-online-multiplayer.md` roadmap table, mark M1 status. Note `OW_SERVER/OW_HOST/OW_CONNECT/OW_PORT` env vars in `README` (multiplayer dev section).

- [ ] **Step 4: Final regression.** `bash tests/run_all.sh` → `失败 0`.

- [ ] **Step 5:** Use **superpowers:finishing-a-development-branch** to verify tests, present options, and complete the branch.

---

## Self-review

- **Spec coverage (§11):** mode split (server/client/host) — Tasks 7-9 ✅; `NetworkManager` — Tasks 1-7 ✅; World authoritative/replica two-state — Task 6 (`net` routing + `apply_remote_edit`) + Task 8 (server owns `WorldData`) ✅; edit via RPC (`request_edit.rpc_id(1)` → authorize → `apply_edit` broadcast) — Tasks 1,6,7 ✅; per-peer avatar spawn — Tasks 4,5,7 ✅; seed distribution — Task 3 (welcome) ✅; connect UI — Task 9 ✅. Verification: pure-logic unit test of the edit chain (Task 1: validate→delta→reject illegal) ✅; 1 server + 2 clients manual (Task 10) ✅; persistence + late-join (Task 10 steps 4-5) ✅.
- **Spec deviation flagged:** custom RPC instead of `MultiplayerSynchronizer` (Key decision #1) — reviewer gate before executing Tasks 4/6/9.
- **Single-player safety:** `net` is null in all existing tests and in OFFLINE mode; routing guards are `net != null and net.is_client()`. Full suite is the regression gate after Tasks 6, 7, 8, 9, 10. ✅
- **Type consistency:** `submit_edit`/`broadcast_edit`/`is_client`/`apply_remote_edit`/`load_deltas_from_net`/`set_net_target`/`set_label` are defined where first referenced behind `has_method` guards, then implemented in the named task. `Mode` enum, `_self_eid`, `_avatars`, `welcomed` signal all declared in the file. ✅
- **Headless-testability:** authority (Task 1), lifecycle (Task 2), handshake (Task 3), snapshot (Task 4), avatar interpolation (Task 5), world routing (Task 6) are all unit-tested without sockets/`MultiplayerAPI`. Only the transport (Task 7) + UI (Task 9) + integration (Task 8) rely on boot-smoke + manual checks — inherent to networking. ✅
- **Risk:** Task 8 (Main refactor) is the riskiest (touches working `_ready`). Mitigation: extract-then-branch, OFFLINE path unchanged, full suite + offline-boot smoke gate. Task 7 RPC transfer modes (`unreliable_ordered` over WebSocket) flagged for execution-time confirmation.
