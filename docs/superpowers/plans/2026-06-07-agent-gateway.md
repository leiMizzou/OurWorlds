# Agent Gateway (SP1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a remote, locally-installed AI agent runtime (Hermes, Claude Code, …) join the shared OurWorlds online world over `wss://play.ourworlds.app/agent` with a token, appearing as a visible, building player — with no Godot install on the connector side.

**Architecture:** β-1 (server-hosted *virtual peers*). The dedicated server stays a lean data authority (`WorldData` + `NetworkManager`, no meshing). A new in-process `AgentGateway` hosts a WebSocket endpoint; each authenticated connection becomes a server-controlled virtual peer whose tool-calls run through a shared `AgentToolCore` against `WorldData` + `NetworkManager`. Tool semantics are extracted out of node-coupled `AgentBridge`/`Player` into node-free modules (`AgentToolCore`, `BuildTemplates`) reused by both the existing localhost bridge and the gateway.

**Tech Stack:** Godot 4.6 (GDScript, headless), Node.js/TypeScript (`@modelcontextprotocol/sdk`, `ws`), Cloudflare Tunnel, launchd.

---

## Conventions

- **Test harness:** standalone scripts. Pure-logic tests `extends SceneTree` + `_initialize()`; world-dependent tests use the `_process()` frame-loop that instantiates `res://scenes/Main.tscn` (see `tests/test_agent_bridge.gd`). Each prints `✅ ALL <NAME> PASSED` on success or `printerr("❌ ...")` on failure, then `quit(0/1)`.
- **Run one test:** `godot --headless --path . --script res://tests/test_<name>.gd`
- **Run the whole suite:** `bash tests/run_all.sh` (greps for FAIL/PASSED markers).
- **`GODOT`** env var points at the binary if `godot` isn't on PATH.
- **Branch first:** work on `feat/agent-gateway` (or a worktree). Never commit on the default branch.
- **Every commit message ends with:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **Regression gate (never edit these to pass):** `tests/test_agent_bridge.gd`, `tests/test_build_templates.gd`, `tests/test_network_core.gd` must stay green through every refactor task.

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `scripts/BuildTemplates.gd` | Node-free build-template geometry → `[{pos,id}]` | **Create** |
| `scripts/Player.gd` | Delegate `apply_build_template`/`_placement_edits` to `BuildTemplates` | Modify (`737`, `819`, `1059`, `1088–1296`) |
| `scripts/AgentToolCore.gd` | The 12 tools over an abstract `ctx` | **Create** |
| `scripts/AgentContext.gd` | `LiveAgentContext` + `ServerAgentContext` adapters | **Create** |
| `scripts/AgentBridge.gd` | Build a `LiveAgentContext`, delegate `dispatch_line`→`AgentToolCore` | Modify (`174`, `207–242`, tool bodies) |
| `scripts/NetworkManager.gd` | `register_virtual_peer`/`update_virtual_peer`/`apply_virtual_edit`/`virtual_say`/`remove_virtual_peer` | Modify (additive, near `41–140`, `197`) |
| `scripts/AgentTokenStore.gd` | Parse/validate `OW_AGENT_TOKENS` | **Create** |
| `scripts/AgentGateway.gd` | WS listener, auth frame, dispatch, despawn, caps | **Create** |
| `scripts/Main.gd` | Start `AgentGateway` in dedicated-server mode when `OW_AGENT_GATEWAY_PORT` set | Modify (`409` `_start_dedicated_server`) |
| `agent-bridge-mcp/src/index.ts` | Remote WS transport + auth frame; TCP fallback | Modify |
| `tests/test_build_templates_core.gd` | `BuildTemplates` unit | **Create** |
| `tests/test_agent_tool_core.gd` | `AgentToolCore` over a fake ctx | **Create** |
| `tests/test_virtual_peer.gd` | Virtual-peer NetworkManager unit | **Create** |
| `tests/test_server_agent_context.gd` | `AgentToolCore`×`ServerAgentContext`×`WorldData` | **Create** |
| `tests/test_agent_token.gd` | Token store unit | **Create** |
| `tests/test_agent_gateway.gd` | Gateway envelope/auth/dispatch/despawn unit | **Create** |
| `tests/test_agent_gateway_e2e.gd` | Two simulated agents over real WS | **Create** |
| `agent-bridge-mcp/test/remote.test.mjs` | MCP remote transport unit (mock WS) | **Create** |
| `~/.cloudflared/ourworlds-play-config.yml` | Add `/agent` ingress | Modify |
| `docs/connect-your-agent.md` | Connector guide (Hermes + Claude Code) | **Create** |
| `docs/agent-bridge-contract.md` | Document remote transport + `auth` frame | Modify |

---

### Task 1: Extract `BuildTemplates` (node-free template geometry)

**Files:**
- Create: `scripts/BuildTemplates.gd`
- Modify: `scripts/Player.gd` (`apply_build_template` @737, `_placement_edits` @819, `_template_cells` @1059, `_*_template_cells`/`_*_template_edits` @1088–1296)
- Create test: `tests/test_build_templates_core.gd`
- Regression: `tests/test_build_templates.gd`, `tests/test_agent_bridge.gd`

- [ ] **Step 1: Write the failing test**

`tests/test_build_templates_core.gd`:
```gdscript
extends SceneTree
const BuildTemplates = preload("res://scripts/BuildTemplates.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	# Simple template uses the default block id for every cell.
	var plat: Array = BuildTemplates.edits_for("platform", Vector3i(0, 40, 0), 0, BlockLibrary.STONE)
	check(plat.size() > 0, "platform returns cells")
	check((plat[0] as Dictionary).has("pos") and (plat[0] as Dictionary).has("id"), "edit has pos+id")
	var all_stone := true
	for raw in plat:
		if int((raw as Dictionary)["id"]) != BlockLibrary.STONE: all_stone = false
	check(all_stone, "simple template uses default_block_id")

	# Decorated template carries its own ids; campfire centre is the moonstone lamp.
	var fire: Array = BuildTemplates.edits_for("campfire", Vector3i(0, 40, 0), 0, BlockLibrary.STONE)
	var centre_is_lamp := false
	for raw in fire:
		var e: Dictionary = raw
		if e["pos"] == Vector3i(0, 40, 0) and int(e["id"]) == BlockLibrary.MOONSTONE_LAMP:
			centre_is_lamp = true
	check(centre_is_lamp, "campfire centre == moonstone lamp")

	# Unknown template -> empty.
	check(BuildTemplates.edits_for("nope", Vector3i.ZERO, 0, BlockLibrary.STONE).is_empty(), "unknown template -> []")

	if failed == 0: print("✅ ALL BUILD TEMPLATES CORE TESTS PASSED")
	else: printerr("❌ ", failed, " build-template-core failures")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run it; verify it fails**

Run: `godot --headless --path . --script res://tests/test_build_templates_core.gd`
Expected: FAIL/parse error — `BuildTemplates` does not exist yet.

- [ ] **Step 3: Implement `BuildTemplates.gd` by moving Player geometry**

Create `scripts/BuildTemplates.gd` as `extends RefCounted` (used only via static funcs). Move the bodies of `Player.gd`'s `_template_cells`, `_platform_template_cells`, `_pillar_template_cells`, `_arch_template_cells`, `_wall_template_cells`, `_stairs_template_cells`, `_room_frame_template_cells`, `_cabin_template_cells`/`_cabin_template_edits`, `_campfire_…`, `_bridge_…`, `_garden_…`, `_beacon_tower_…`, `_signpost_…` (lines `1059–1296`) into **static** functions that take explicit params instead of reading Player fields. Public entry point:

```gdscript
# scripts/BuildTemplates.gd
extends RefCounted
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

const TEMPLATE_IDS := ["platform","pillar","arch","wall","stairs","room_frame",
	"cabin","campfire","bridge","garden","beacon_tower","signpost"]
# Templates that carry their own block ids (decorated); others use default_block_id.
const DECORATED := ["cabin","campfire","bridge","garden","beacon_tower","signpost"]

static func edits_for(template_id: String, origin: Vector3i, orientation: int, default_block_id: int) -> Array:
	var o := posmod(orientation, 2)
	match template_id:
		"campfire": return _campfire_edits(origin, o)
		"bridge": return _bridge_edits(origin, o)
		"garden": return _garden_edits(origin, o)
		"cabin": return _cabin_edits(origin, o)
		"beacon_tower": return _beacon_tower_edits(origin, o)
		"signpost": return _signpost_edits(origin, o)
		"platform","pillar","arch","wall","stairs","room_frame":
			var out := []
			for cell in _cells(template_id, origin, o):
				out.append({"pos": cell, "id": default_block_id})
			return out
	return []
# ... (moved geometry as static _cells()/_*_edits(), parameterised by origin+orientation)
```

Then make `Player.apply_build_template` delegate (it keeps its own state save/restore for the interactive path, but sources edits from the module):
```gdscript
# scripts/Player.gd  — inside apply_build_template, replace the _placement_edits() call:
var edits := BuildTemplates.edits_for(template_id, origin, posmod(orientation, 2), current_block())
if world.has_method("request_block_edits"):
	changed = int(world.request_block_edits(edits))
```
Add `const BuildTemplates = preload("res://scripts/BuildTemplates.gd")` at the top of `Player.gd`. Keep `_placement_edits()` for the live preview path but have it call `BuildTemplates.edits_for(build_template_id(), _place, template_orientation_index, current_block())` so there is one geometry source.

- [ ] **Step 4: Run new + regression tests; verify pass**

Run:
```
godot --headless --path . --script res://tests/test_build_templates_core.gd
godot --headless --path . --script res://tests/test_build_templates.gd
godot --headless --path . --script res://tests/test_agent_bridge.gd
```
Expected: all PASS (especially `test_agent_bridge.gd`'s `build campfire centre == moonstone lamp`).

- [ ] **Step 5: Commit**

```bash
git add scripts/BuildTemplates.gd scripts/Player.gd tests/test_build_templates_core.gd
git commit -m "refactor: extract BuildTemplates geometry from Player (node-free)"
```

---

### Task 2: Extract `AgentToolCore` + `LiveAgentContext` (bridge delegates)

**Files:**
- Create: `scripts/AgentToolCore.gd`, `scripts/AgentContext.gd`
- Modify: `scripts/AgentBridge.gd` (`dispatch_line` @174, `_handle` @207–242, tool bodies @244–570)
- Create test: `tests/test_agent_tool_core.gd`
- Regression: `tests/test_agent_bridge.gd`

**Context interface** (`AgentContext.gd` defines two classes implementing it):
```
read.surface_y(x,z) / read.region_label(x,z) / read.get_block(x,y,z) / read.chunk_of(x,z) / read.is_solid(id)
body.eid:String  body.get_pos()->Vector3  body.set_pos(Vector3)  body.get_yaw()->float  body.set_yaw(float)
body.get_pitch()->float  body.set_pitch(float)  body.selected_block_id:int
apply_edits(edits:Array) -> int          # edits = [{pos:Vector3i, id:int}]
say(text:String, to:String) -> bool
memory.goal:String  memory.notes:Array  memory.set_goal(s)  memory.append_note(s)  memory.save()
```

- [ ] **Step 1: Write the failing test** — `tests/test_agent_tool_core.gd`

```gdscript
extends SceneTree
const AgentToolCore = preload("res://scripts/AgentToolCore.gd")
const WorldData = preload("res://scripts/WorldData.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

# Minimal fake context backed by WorldData + an in-memory body.
class FakeCtx:
	var read; var body; var said := []; var mem := {"goal": "", "notes": []}
	func _init(data): read = _Read.new(data); body = _Body.new()
	func apply_edits(edits):
		var n := 0
		for e in edits:
			var p: Vector3i = e["pos"]
			if not read.data.apply_edit_local(p.x, p.y, p.z, int(e["id"])).is_empty(): n += 1
		return n
	func say(t, _to): said.append(t); return true
	func memory_goal(): return mem["goal"]
	class _Read:
		var data
		func _init(d): data = d
		func surface_y(x, z): return data.surface_y(x, z)
		func region_label(x, z): return data.region_label(x, z)
		func get_block(x, y, z): return data.get_block(x, y, z)
		func chunk_of(x, z): return data.chunk_of(x, z)
		func is_solid(id): return id != 0
	class _Body:
		var eid := "agent-test"; var selected_block_id := BlockLibrary.STONE
		var _p := Vector3(8, 40, 8); var _yaw := 0.0; var _pitch := 0.0
		func get_pos(): return _p
		func set_pos(p): _p = p
		func get_yaw(): return _yaw
		func set_yaw(y): _yaw = y
		func get_pitch(): return _pitch
		func set_pitch(p): _pitch = p

func _initialize() -> void:
	var data := WorldData.new(1337)
	var ctx := FakeCtx.new(data)
	ctx.body._p = Vector3(8, data.surface_y(8, 8) + 2, 8)

	# observe
	var ob: Dictionary = AgentToolCore.handle("observe", {}, ctx)
	check(bool(ob.get("ok", false)), "observe ok")
	check((ob["result"] as Dictionary).has("pos"), "observe has pos")

	# goto moves the body
	var gt: Dictionary = AgentToolCore.handle("goto", {"x": 12, "z": 12}, ctx)
	check(bool(gt.get("ok", false)) and int(ctx.body._p.x) == 12, "goto moved body to x=12")

	# place writes the world (reach handled by ctx.apply_edits in real server path)
	var bx := int(ctx.body._p.x); var by := int(ctx.body._p.y) + 1; var bz := int(ctx.body._p.z)
	data.apply_edit_local(bx, by, bz, BlockLibrary.AIR)
	var pl: Dictionary = AgentToolCore.handle("place", {"block": "stone", "cells": [[bx, by, bz]]}, ctx)
	check(bool(pl.get("ok", false)) and int(data.get_block(bx, by, bz)) == BlockLibrary.STONE, "place wrote stone")

	# build campfire centre == lamp
	var ax := int(ctx.body._p.x) + 6; var az := int(ctx.body._p.z) + 6
	var ay := data.surface_y(ax, az) + 1
	var bd: Dictionary = AgentToolCore.handle("build", {"template": "campfire", "x": ax, "y": ay, "z": az}, ctx)
	check(bool(bd.get("ok", false)) and int(data.get_block(ax, ay, az)) == BlockLibrary.MOONSTONE_LAMP, "build campfire centre lamp")

	# say routes to ctx.say
	AgentToolCore.handle("say", {"text": "hi"}, ctx)
	check(ctx.said.size() == 1 and str(ctx.said[0]) == "hi", "say routed to context")

	# unknown tool
	check(not bool(AgentToolCore.handle("nope", {}, ctx).get("ok", true)), "unknown tool rejected")

	if failed == 0: print("✅ ALL AGENT TOOL CORE TESTS PASSED")
	else: printerr("❌ ", failed, " agent-tool-core failures")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run it; verify it fails**

Run: `godot --headless --path . --script res://tests/test_agent_tool_core.gd` → FAIL (`AgentToolCore` missing).

- [ ] **Step 3: Implement `AgentToolCore` by moving tool bodies out of `AgentBridge`**

Create `scripts/AgentToolCore.gd` with `static func handle(tool: String, args: Dictionary, ctx) -> Dictionary` containing the `match` from `AgentBridge._handle` (@207). Move each `_tool_*` body (observe/look/goto/scan/place/break/build/get_block/say/set_goal/remember/get_memory, plus capture_build/paste_build/identify) into static helpers that read from `ctx` instead of `world`/`player`/`avatar`/`hud`/`chat_hub`/`_memory`:
- position/yaw/pitch → `ctx.body.*`
- `world.surface_y/region_label/get_block/chunk_of` → `ctx.read.*`; `world.lib.is_solid` → `ctx.read.is_solid`
- `world.request_block_edits(edits)` → `ctx.apply_edits(edits)`
- `player.apply_build_template` → `ctx.apply_edits(BuildTemplates.edits_for(template, origin, rotation, ctx.body.selected_block_id))`
- `player.current_block()` → `ctx.body.selected_block_id`; `hotbar` → `ctx.hotbar_aliases()` (default list server-side)
- `hud.show_feedback` / chat → `ctx.say(text, to)`
- memory → `ctx.memory.*`

Wrap each result as `{"ok": true, "result": {...}}`; errors as `{"ok": false, "error": "..."}`.

Create `scripts/AgentContext.gd` with `class LiveAgentContext` (wraps `world`, `player`/`avatar`, `hud`, `chat_hub`, `_memory` exactly mirroring current AgentBridge behaviour) implementing the interface above.

Refactor `AgentBridge`:
- Keep `dispatch_line(line, eid)` envelope parsing.
- Build a `LiveAgentContext` from `world`/`player`/`avatar`/`hud`/`chat_hub`/`_memory`/`_current_eid`, then `return AgentToolCore.handle(tool, args, ctx)` (adapting to the existing envelope `{id, ok, result/error}`).
- Keep `_record_action`, block-alias tables, memory load/save, TCP server loop, multi-client `_peers` — only the tool **bodies** move.

- [ ] **Step 4: Run new + regression; verify pass**

Run:
```
godot --headless --path . --script res://tests/test_agent_tool_core.gd
godot --headless --path . --script res://tests/test_agent_bridge.gd
```
Expected: both PASS. `test_agent_bridge.gd` proves the live path is behaviour-identical.

- [ ] **Step 5: Commit**

```bash
git add scripts/AgentToolCore.gd scripts/AgentContext.gd scripts/AgentBridge.gd tests/test_agent_tool_core.gd
git commit -m "refactor: AgentToolCore over abstract context; AgentBridge delegates via LiveAgentContext"
```

---

### Task 3: NetworkManager virtual peers

**Files:**
- Modify: `scripts/NetworkManager.gd` (additive, near `register_peer` @41, `build_player_snapshot` @197)
- Create test: `tests/test_virtual_peer.gd`
- Regression: `tests/test_network_core.gd`

Design: virtual peers reuse the existing `_peers` machinery, keyed by **negative** synthetic ids (so `authorize_edit`, `_accept_rate`, `build_player_snapshot` all work unchanged) with `agent-N` eids.

- [ ] **Step 1: Write the failing test** — `tests/test_virtual_peer.gd`

```gdscript
extends SceneTree
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var data := WorldData.new(1337)
	var nm := NetworkManager.new()
	nm.mode = NetworkManager.Mode.SERVER
	nm.set_authority_data(data, 1337, Vector3(8, data.surface_y(8, 8) + 2, 8))

	# A real player and an agent coexist; eids never collide.
	var pe := nm.register_peer(7, "Alice")
	var ae := nm.register_virtual_peer("BrutalistBot")
	check(ae.begins_with("agent-"), "virtual eid prefixed agent-")
	check(ae != pe, "agent eid != player eid")

	# Appears in the broadcast snapshot.
	nm.update_virtual_peer(ae, Vector3(20, data.surface_y(20, 20) + 1, 20), 1.0)
	var snap: Array = nm.build_player_snapshot()
	var found := false
	for raw in snap:
		if str((raw as Dictionary)["eid"]) == ae: found = true
	check(found, "virtual peer in snapshot")

	# apply_virtual_edit: near -> accepted + world written.
	var ax := 20; var az := 20; var ay := data.surface_y(20, 20) + 1
	var ok1 := nm.apply_virtual_edit(ae, ax, ay, az, BlockLibrary.STONE)
	check(ok1 and int(data.get_block(ax, ay, az)) == BlockLibrary.STONE, "near edit accepted + written")

	# Far edit -> rejected.
	check(not nm.apply_virtual_edit(ae, 500, data.surface_y(500, 500), 500, BlockLibrary.STONE), "far edit rejected")

	# Rate limit shared with real peers (EDIT_RATE_MAX).
	var rl := NetworkManager.new(); rl.mode = NetworkManager.Mode.SERVER
	var rd := WorldData.new(9); rl.set_authority_data(rd, 9, Vector3.ZERO)
	var re := rl.register_virtual_peer("Spammer")
	rl.update_virtual_peer(re, Vector3(0, rd.surface_y(0, 0) + 2, 0), 0.0)
	var sy := rd.surface_y(0, 0) + 1
	for i in range(NetworkManager.EDIT_RATE_MAX):
		rl.apply_virtual_edit_at(re, 0, sy, 0, (i % 2) + 1, 1000.0)   # now-pinned overload
	check(not rl.apply_virtual_edit_at(re, 0, sy, 0, 3, 1000.0), "agent over-rate rejected")

	# Remove -> drops from snapshot.
	nm.remove_virtual_peer(ae)
	var gone := true
	for raw in nm.build_player_snapshot():
		if str((raw as Dictionary)["eid"]) == ae: gone = false
	check(gone, "removed virtual peer gone from snapshot")

	if failed == 0: print("✅ ALL VIRTUAL PEER TESTS PASSED")
	else: printerr("❌ ", failed, " virtual-peer failures")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run it; verify it fails**

Run: `godot --headless --path . --script res://tests/test_virtual_peer.gd` → FAIL (methods missing).

- [ ] **Step 3: Implement the additive methods in `NetworkManager.gd`**

```gdscript
var _vpeer_counter := 0   # add near _eid_counter (line ~30)

func register_virtual_peer(display_name: String) -> String:
	_vpeer_counter += 1
	var pid := -_vpeer_counter                      # negative id never collides with real peer ids
	var eid := "agent-%d" % _vpeer_counter
	var nm := display_name.strip_edges()
	if nm == "": nm = eid
	_peers[pid] = {"eid": eid, "name": nm, "pos": _scatter_spawn(_vpeer_counter), "yaw": 0.0, "edits": []}
	if chat_hub != null:
		chat_hub.register(eid, nm, "agent")
	return eid

func _vpid_for(eid: String) -> int:
	for pid in _peers:
		if pid < 0 and str(_peers[pid]["eid"]) == eid: return pid
	return 0

func update_virtual_peer(eid: String, pos: Vector3, yaw: float) -> void:
	var pid := _vpid_for(eid)
	if pid != 0: set_peer_transform(pid, pos, yaw)

func virtual_say(eid: String, text: String, to: String = "") -> void:
	if chat_hub == null: return
	if to == "": chat_hub.post(eid, "", text)
	else: chat_hub.post(eid, chat_hub.resolve(to), text)

func remove_virtual_peer(eid: String) -> void:
	var pid := _vpid_for(eid)
	if pid != 0: drop_peer(pid)

# Edit attributed to an agent body: reach + rate via authorize_edit, then broadcast to real clients.
func apply_virtual_edit(eid: String, wx: int, wy: int, wz: int, id: int) -> bool:
	return apply_virtual_edit_at(eid, wx, wy, wz, id, -1.0)

func apply_virtual_edit_at(eid: String, wx: int, wy: int, wz: int, id: int, now: float) -> bool:
	var pid := _vpid_for(eid)
	if pid == 0: return false
	var r := authorize_edit(pid, wx, wy, wz, id, now)
	if not bool(r.get("ok", false)): return false
	# Broadcast to live clients when the realtime layer is up (guarded: server has no World node).
	if mode == Mode.SERVER and multiplayer != null and multiplayer.has_multiplayer_peer():
		_rpc_apply_edit.rpc(wx, wy, wz, id)
	return true
```
> Note: `chat_hub.register(..., "agent")` — confirm the kind arg is accepted (ChatHub already supports `"human"`/`"agent"` from the chat work). `build_player_snapshot` (@197) already iterates `_peers`, so virtual peers are included automatically.

- [ ] **Step 4: Run new + regression; verify pass**

Run:
```
godot --headless --path . --script res://tests/test_virtual_peer.gd
godot --headless --path . --script res://tests/test_network_core.gd
```
Expected: both PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/NetworkManager.gd tests/test_virtual_peer.gd
git commit -m "feat(net): server-controlled virtual peers (register/update/edit/say/remove)"
```

---

### Task 4: `ServerAgentContext` + per-token memory

**Files:**
- Modify: `scripts/AgentContext.gd` (add `class ServerAgentContext`)
- Create: `scripts/AgentMemoryStore.gd` (per-token goal/notes, persisted to `user://agent_mem/<token-hash>.json`)
- Create test: `tests/test_server_agent_context.gd`

- [ ] **Step 1: Write the failing test** — `tests/test_server_agent_context.gd`

```gdscript
extends SceneTree
const AgentToolCore = preload("res://scripts/AgentToolCore.gd")
const AgentContext = preload("res://scripts/AgentContext.gd")
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var data := WorldData.new(1337)
	var nm := NetworkManager.new(); nm.mode = NetworkManager.Mode.SERVER
	nm.set_authority_data(data, 1337, Vector3(8, data.surface_y(8, 8) + 2, 8))
	var eid := nm.register_virtual_peer("Tester")
	var ctx = AgentContext.ServerAgentContext.new(nm, data, eid, "tok-hash-1")

	# observe reads WorldData around the body
	var ob: Dictionary = AgentToolCore.handle("observe", {}, ctx)
	check(bool(ob.get("ok", false)) and (ob["result"] as Dictionary).has("region"), "server observe ok")

	# goto then place near the body -> world written + reach respected
	AgentToolCore.handle("goto", {"x": 30, "z": 30}, ctx)
	var bx := 30; var bz := 30; var by := data.surface_y(30, 30) + 1
	var pl: Dictionary = AgentToolCore.handle("place", {"block": "stone", "cells": [[bx, by, bz]]}, ctx)
	check(int((pl["result"] as Dictionary).get("changed", 0)) == 1, "server place changed 1")
	check(int(data.get_block(bx, by, bz)) == BlockLibrary.STONE, "server place wrote stone")

	# place far away -> rejected by reach (changed 0)
	var far: Dictionary = AgentToolCore.handle("place", {"block": "stone", "cells": [[600, by, 600]]}, ctx)
	check(int((far["result"] as Dictionary).get("changed", 0)) == 0, "far place rejected by reach")

	# memory persists per token
	AgentToolCore.handle("set_goal", {"text": "Build a tower"}, ctx)
	var ctx2 = AgentContext.ServerAgentContext.new(nm, data, eid, "tok-hash-1")
	var gm: Dictionary = AgentToolCore.handle("get_memory", {}, ctx2)
	check(str((gm["result"] as Dictionary).get("goal", "")) == "Build a tower", "memory persists across context by token")

	if failed == 0: print("✅ ALL SERVER AGENT CONTEXT TESTS PASSED")
	else: printerr("❌ ", failed, " server-agent-context failures")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run it; verify it fails** — `ServerAgentContext` missing.

- [ ] **Step 3: Implement `ServerAgentContext` + `AgentMemoryStore`**

`ServerAgentContext` implements the context interface:
- `read` → delegates to `WorldData` (`surface_y`/`region_label`/`get_block`/`chunk_of`); `is_solid` via a `BlockLibrary.new()` instance held by the context.
- `body` → reads/writes the virtual peer through `nm.peer_position(eid)` / `nm.update_virtual_peer(eid, pos, yaw)`; `selected_block_id` stored on the context (default `BlockLibrary.STONE`, settable later).
- `apply_edits(edits)` → loop, `var n=0; for e: if nm.apply_virtual_edit(eid, e.pos.x, e.pos.y, e.pos.z, e.id): n+=1; return n`.
- `say(text, to)` → `nm.virtual_say(eid, text, to); return true`.
- `memory` → an `AgentMemoryStore` keyed by the token hash (load on init, `save()` on mutate).

`AgentMemoryStore.gd`: `{version, goal, notes[], updated_at}` persisted to `user://agent_mem/<token-hash>.json`; methods `set_goal`, `append_note` (cap 50), `save`, `load`.

- [ ] **Step 4: Run; verify pass**

Run: `godot --headless --path . --script res://tests/test_server_agent_context.gd` → PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/AgentContext.gd scripts/AgentMemoryStore.gd tests/test_server_agent_context.gd
git commit -m "feat(agent): ServerAgentContext + per-token memory store"
```

---

### Task 5: Token store

**Files:**
- Create: `scripts/AgentTokenStore.gd`
- Create test: `tests/test_agent_token.gd`

- [ ] **Step 1: Write the failing test** — `tests/test_agent_token.gd`

```gdscript
extends SceneTree
const AgentTokenStore = preload("res://scripts/AgentTokenStore.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	# "label:token" pairs, comma-separated; bare token allowed (label == token prefix).
	var store := AgentTokenStore.new("Alice:aaa111, Bob:bbb222 , ccc333")
	check(store.is_valid("aaa111"), "valid token accepted")
	check(store.label_for("aaa111") == "Alice", "label resolved")
	check(store.is_valid("ccc333") and store.label_for("ccc333") == "ccc333", "bare token uses itself as label")
	check(not store.is_valid("nope"), "unknown token rejected")
	check(not store.is_valid(""), "empty token rejected")
	check(AgentTokenStore.new("").count() == 0, "empty config -> no tokens")
	if failed == 0: print("✅ ALL AGENT TOKEN TESTS PASSED")
	else: printerr("❌ ", failed, " agent-token failures")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run it; verify it fails.**

- [ ] **Step 3: Implement `AgentTokenStore.gd`**

```gdscript
extends RefCounted
var _by_token := {}   # token -> label
func _init(spec: String) -> void:
	for raw in spec.split(",", false):
		var part := raw.strip_edges()
		if part == "": continue
		var label := part; var token := part
		var colon := part.find(":")
		if colon > 0:
			label = part.substr(0, colon).strip_edges()
			token = part.substr(colon + 1).strip_edges()
		if token != "": _by_token[token] = label
func is_valid(token: String) -> bool: return token != "" and _by_token.has(token)
func label_for(token: String) -> String: return str(_by_token.get(token, ""))
func count() -> int: return _by_token.size()
```

- [ ] **Step 4: Run; verify pass.**

- [ ] **Step 5: Commit**

```bash
git add scripts/AgentTokenStore.gd tests/test_agent_token.gd
git commit -m "feat(agent): token store (OW_AGENT_TOKENS parsing + validation)"
```

---

### Task 6: `AgentGateway` (WS listener + auth + dispatch + caps)

**Files:**
- Create: `scripts/AgentGateway.gd`
- Create test: `tests/test_agent_gateway.gd`

Make the **logic** unit-testable independent of sockets: a pure `handle_envelope(conn, dict) -> dict` method (mirrors how `test_agent_bridge.gd` tests `dispatch_line`). The socket loop just frames JSON ↔ `handle_envelope`.

- [ ] **Step 1: Write the failing test** — `tests/test_agent_gateway.gd`

```gdscript
extends SceneTree
const AgentGateway = preload("res://scripts/AgentGateway.gd")
const AgentTokenStore = preload("res://scripts/AgentTokenStore.gd")
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var data := WorldData.new(1337)
	var nm := NetworkManager.new(); nm.mode = NetworkManager.Mode.SERVER
	nm.set_authority_data(data, 1337, Vector3(8, data.surface_y(8, 8) + 2, 8))
	var gw := AgentGateway.new()
	gw.setup(nm, data, AgentTokenStore.new("Alice:aaa"), 4)   # max 4 agents

	var conn := gw.new_conn()   # opaque per-connection state (no real socket)

	# Must auth first.
	var pre := gw.handle_envelope(conn, {"id": 1, "tool": "observe", "args": {}})
	check(not bool(pre.get("ok", true)) and str(pre.get("error","")).contains("unauth"), "tool before auth rejected")

	# Bad token rejected.
	var bad := gw.handle_envelope(conn, {"id": 0, "tool": "auth", "args": {"token": "nope"}})
	check(not bool(bad.get("ok", true)) and str(bad.get("error","")).contains("unauthorized"), "bad token rejected")

	# Good token spawns a body + returns eid.
	var ok := gw.handle_envelope(conn, {"id": 0, "tool": "auth", "args": {"token": "aaa", "name": "Bot"}})
	check(bool(ok.get("ok", false)) and str((ok["result"] as Dictionary).get("eid","")).begins_with("agent-"), "auth spawns body")
	check(nm.build_player_snapshot().size() == 1, "body in roster after auth")

	# Tool now works.
	var ob := gw.handle_envelope(conn, {"id": 2, "tool": "observe", "args": {}})
	check(bool(ob.get("ok", false)), "observe works after auth")

	# Disconnect despawns.
	gw.close_conn(conn)
	check(nm.build_player_snapshot().size() == 0, "disconnect despawns body")

	# Capacity cap.
	var conns := []
	for i in range(4):
		var c := gw.new_conn(); gw.handle_envelope(c, {"id":0,"tool":"auth","args":{"token":"aaa"}}); conns.append(c)
	var full := gw.new_conn()
	var cap := gw.handle_envelope(full, {"id": 0, "tool": "auth", "args": {"token": "aaa"}})
	check(not bool(cap.get("ok", true)) and str(cap.get("error","")).contains("capacity"), "over capacity rejected")

	if failed == 0: print("✅ ALL AGENT GATEWAY TESTS PASSED")
	else: printerr("❌ ", failed, " agent-gateway failures")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run it; verify it fails.**

- [ ] **Step 3: Implement `AgentGateway.gd`**

```gdscript
extends Node
const AgentToolCore = preload("res://scripts/AgentToolCore.gd")
const AgentContext = preload("res://scripts/AgentContext.gd")
var _nm; var _data; var _tokens; var _max := 8
var _conns := {}            # conn_id -> {authed, eid, ctx, token_hash}
var _conn_seq := 0
var _server: TCPServer; var _sockets := {}   # conn_id -> WebSocketPeer

func setup(nm, data, tokens, max_agents: int = 8) -> void:
	_nm = nm; _data = data; _tokens = tokens; _max = max_agents

func new_conn() -> int:
	_conn_seq += 1
	_conns[_conn_seq] = {"authed": false, "eid": "", "ctx": null}
	return _conn_seq

func _active_agents() -> int:
	var n := 0
	for c in _conns.values():
		if c["authed"]: n += 1
	return n

func handle_envelope(conn: int, env: Dictionary) -> Dictionary:
	var st: Dictionary = _conns.get(conn, {})
	var id = env.get("id", null)
	var tool := str(env.get("tool", ""))
	var args: Dictionary = env.get("args", {}) if typeof(env.get("args")) == TYPE_DICTIONARY else {}
	if not bool(st.get("authed", false)):
		if tool != "auth":
			return {"id": id, "ok": false, "error": "unauthenticated: send auth first"}
		var token := str(args.get("token", ""))
		if not _tokens.is_valid(token):
			return {"id": id, "ok": false, "error": "unauthorized"}
		if _active_agents() >= _max:
			return {"id": id, "ok": false, "error": "server at capacity"}
		var nm_name := str(args.get("name", _tokens.label_for(token)))
		var eid := _nm.register_virtual_peer(nm_name)
		var th := str(token.hash())
		st["authed"] = true; st["eid"] = eid
		st["ctx"] = AgentContext.ServerAgentContext.new(_nm, _data, eid, th)
		_conns[conn] = st
		var pos = _nm.peer_position(eid)
		return {"id": id, "ok": true, "result": {"eid": eid, "spawn": [pos.x, pos.y, pos.z]}}
	# authed: dispatch through the shared core
	var r := AgentToolCore.handle(tool, args, st["ctx"])
	r["id"] = id
	return r

func close_conn(conn: int) -> void:
	var st: Dictionary = _conns.get(conn, {})
	if bool(st.get("authed", false)):
		_nm.remove_virtual_peer(str(st["eid"]))
	_conns.erase(conn)
	if _sockets.has(conn):
		(_sockets[conn] as WebSocketPeer).close(); _sockets.erase(conn)

# ---- real socket loop (integration; not exercised by the unit test) ----
func start(port: int) -> bool:
	_server = TCPServer.new()
	return _server.listen(port, "127.0.0.1") == OK

func _process(_dt: float) -> void:
	if _server == null: return
	while _server.is_connection_available():
		var tcp := _server.take_connection()
		var ws := WebSocketPeer.new()
		ws.accept_stream(tcp)
		var cid := new_conn(); _sockets[cid] = ws
	for cid in _sockets.keys():
		var ws: WebSocketPeer = _sockets[cid]
		ws.poll()
		var s := ws.get_ready_state()
		if s == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var line := ws.get_packet().get_string_from_utf8()
				var parsed = JSON.parse_string(line)
				var env: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
				var resp := handle_envelope(cid, env)
				ws.send_text(JSON.stringify(resp))
		elif s == WebSocketPeer.STATE_CLOSED:
			close_conn(cid)
```

> **Per-connection request throttle (spec security item):** the damaging path (edits) is already capped at 96/s per body via `apply_virtual_edit`. For non-edit spam (e.g. `observe` floods), add a per-conn sliding-window counter in `handle_envelope` (default ~20 req/s) that returns `{"ok":false,"error":"rate limited"}` when exceeded. Keep it off the unit test's deterministic path (inject the clock, or default the cap high in tests).

- [ ] **Step 4: Run; verify pass** — `godot --headless --path . --script res://tests/test_agent_gateway.gd` → PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/AgentGateway.gd tests/test_agent_gateway.gd
git commit -m "feat(agent): AgentGateway — WS auth/dispatch/despawn/capacity over shared tool core"
```

---

### Task 7: `ourworlds-mcp` remote transport (TypeScript)

**Files:**
- Modify: `agent-bridge-mcp/src/index.ts`
- Create test: `agent-bridge-mcp/test/remote.test.mjs`

- [ ] **Step 1: Write the failing test** — `agent-bridge-mcp/test/remote.test.mjs`

```js
// node --test test/remote.test.mjs   (after npm run build)
import { test } from "node:test";
import assert from "node:assert";
import { WebSocketServer } from "ws";
import { connectRemote } from "../dist/transport-remote.js";

test("remote transport: sends auth frame first, relays envelopes", async () => {
  const wss = new WebSocketServer({ port: 0 });
  const port = wss.address().port;
  const frames = [];
  wss.on("connection", (ws) => {
    ws.on("message", (m) => {
      const env = JSON.parse(m.toString());
      frames.push(env);
      if (env.tool === "auth") ws.send(JSON.stringify({ id: env.id, ok: true, result: { eid: "agent-1" } }));
      else ws.send(JSON.stringify({ id: env.id, ok: true, result: { echoed: env.tool } }));
    });
  });
  const client = await connectRemote(`ws://127.0.0.1:${port}`, "tok", "Bot");
  const r = await client.call("observe", {});
  assert.equal(r.ok, true);
  assert.equal(frames[0].tool, "auth");           // auth first
  assert.equal(frames[0].args.token, "tok");
  assert.equal(frames[1].tool, "observe");
  wss.close();
});
```

- [ ] **Step 2: Build + run; verify it fails**

Run: `cd agent-bridge-mcp && npm install ws && npm run build && node --test test/remote.test.mjs`
Expected: FAIL — `dist/transport-remote.js` missing.

- [ ] **Step 3: Implement remote transport + wire it in**

Create `agent-bridge-mcp/src/transport-remote.ts` exporting `connectRemote(url, token, name)` that: opens a `ws` WebSocket; on open sends `{"id":0,"tool":"auth","args":{token,name}}` and awaits ok; exposes `call(tool, args)` correlating by an incrementing `id`, with the existing 15s timeout + auto-reconnect (re-auth on reconnect). Mirror the envelope contract of the TCP path.

In `src/index.ts`, branch on `process.env.OW_REMOTE_URL`: if set, use `connectRemote(OW_REMOTE_URL, OW_AGENT_TOKEN, OW_AGENT_NAME)`; else keep the existing TCP client (`OW_AGENT_PORT`). The 12 MCP tool registrations are unchanged — they call the active transport's `call()`.

- [ ] **Step 4: Build + run new test + existing smoke; verify pass**

Run:
```
cd agent-bridge-mcp && npm run build
node --test test/remote.test.mjs
node examples/smoke.mjs   # existing TCP smoke still works (no OW_REMOTE_URL)
```
Expected: remote test PASS; TCP fallback unaffected.

- [ ] **Step 5: Commit**

```bash
git add agent-bridge-mcp/src/transport-remote.ts agent-bridge-mcp/src/index.ts agent-bridge-mcp/test/remote.test.mjs agent-bridge-mcp/package.json
git commit -m "feat(mcp): remote WebSocket transport (OW_REMOTE_URL + auth frame), TCP fallback"
```

---

### Task 8: Wire the gateway into the dedicated server

**Files:**
- Modify: `scripts/Main.gd` (`_start_dedicated_server` @409)

- [ ] **Step 1: Add the wiring (guarded by env)**

In `_start_dedicated_server`, after `NetworkManager`/`ChatHub`/`WorldData` are created, add:
```gdscript
if OS.has_environment("OW_AGENT_GATEWAY_PORT"):
	var gw_port := int(OS.get_environment("OW_AGENT_GATEWAY_PORT"))
	var max_agents := int(OS.get_environment("OW_AGENT_MAX")) if OS.has_environment("OW_AGENT_MAX") else 8
	var tokens := AgentTokenStore.new(OS.get_environment("OW_AGENT_TOKENS") if OS.has_environment("OW_AGENT_TOKENS") else "")
	var gw := AgentGateway.new()
	gw.name = "AgentGateway"
	gw.setup(net_manager, world_data, tokens, max_agents)
	add_child(gw)
	if gw.start(gw_port):
		print("[server] AgentGateway listening on 127.0.0.1:%d (max %d, %d tokens)" % [gw_port, max_agents, tokens.count()])
	else:
		printerr("[server] AgentGateway failed to bind port ", gw_port)
```
Use the actual local variable names from `_start_dedicated_server` for the NetworkManager (`net_manager`) and WorldData (`world_data`) — confirm by reading the function.

- [ ] **Step 2: Smoke — server boots with the gateway**

Run:
```
OW_SERVER=1 OW_AGENT_GATEWAY_PORT=8972 OW_AGENT_TOKENS="Alice:aaa" \
  godot --headless --path . 2>&1 | grep -m1 "AgentGateway listening"
```
Expected: prints the listening line, no errors. Ctrl-C to stop.

- [ ] **Step 3: Run full suite (no regressions)**

Run: `bash tests/run_all.sh`
Expected: all green (the new `test_*` files included).

- [ ] **Step 4: Commit**

```bash
git add scripts/Main.gd
git commit -m "feat(server): start AgentGateway when OW_AGENT_GATEWAY_PORT is set"
```

---

### Task 9: Two-agent end-to-end over real WebSocket (CI-repeatable, no LLMs)

**Files:**
- Create test: `tests/test_agent_gateway_e2e.gd`

- [ ] **Step 1: Write the failing test** — drives two `WebSocketPeer` clients against a real gateway in-process.

```gdscript
extends SceneTree
const AgentGateway = preload("res://scripts/AgentGateway.gd")
const AgentTokenStore = preload("res://scripts/AgentTokenStore.gd")
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
var failed := 0; var _gw; var _nm; var _data
var _a := WebSocketPeer.new(); var _b := WebSocketPeer.new(); var _f := 0; var _phase := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	_data = WorldData.new(1337)
	_nm = NetworkManager.new(); _nm.mode = NetworkManager.Mode.SERVER
	_nm.set_authority_data(_data, 1337, Vector3(8, _data.surface_y(8,8)+2, 8))
	_gw = AgentGateway.new(); _gw.setup(_nm, _data, AgentTokenStore.new("A:aaa,B:bbb"), 8)
	root.add_child(_gw)
	assert(_gw.start(48972))
	_a.connect_to_url("ws://127.0.0.1:48972")
	_b.connect_to_url("ws://127.0.0.1:48972")

func _process(_d: float) -> bool:
	_gw._process(_d); _a.poll(); _b.poll(); _f += 1
	if _a.get_ready_state() == WebSocketPeer.STATE_OPEN and _b.get_ready_state() == WebSocketPeer.STATE_OPEN and _phase == 0:
		_a.send_text(JSON.stringify({"id":0,"tool":"auth","args":{"token":"aaa","name":"Alpha"}}))
		_b.send_text(JSON.stringify({"id":0,"tool":"auth","args":{"token":"bbb","name":"Beta"}}))
		_phase = 1
	if _phase == 1 and _f > 30:
		# both bodies present and distinct
		var snap: Array = _nm.build_player_snapshot()
		check(snap.size() == 2, "two agent bodies in shared roster")
		var eids := {}
		for raw in snap: eids[str((raw as Dictionary)["eid"])] = true
		check(eids.size() == 2, "two distinct eids")
		# drop one -> despawns
		_a.close(); _phase = 2; _f = 0
	if _phase == 2 and _f > 30:
		check(_nm.build_player_snapshot().size() == 1, "closing one connection despawns its body")
		if failed == 0: print("✅ ALL AGENT GATEWAY E2E TESTS PASSED")
		else: printerr("❌ ", failed, " gateway-e2e failures")
		return true
	if _f > 600:
		printerr("❌ gateway e2e timed out"); return true
	return false
```

- [ ] **Step 2: Run it; verify it fails** (gateway socket loop not yet proven over real WS) — then fix any framing issues until PASS.

Run: `godot --headless --path . --script res://tests/test_agent_gateway_e2e.gd`

- [ ] **Step 3: Make it pass** — resolve real-socket issues (WS handshake, packet framing, close detection) in `AgentGateway._process`. Keep `handle_envelope` unchanged (already unit-tested).

- [ ] **Step 4: Full suite green**

Run: `bash tests/run_all.sh` → all green.

- [ ] **Step 5: Commit**

```bash
git add tests/test_agent_gateway_e2e.gd scripts/AgentGateway.gd
git commit -m "test(agent): two-agent end-to-end over real WebSocket"
```

---

### Task 10: Deploy wiring — Cloudflare route, launchd env, docs

**Files:**
- Modify: `~/.cloudflared/ourworlds-play-config.yml`
- Modify: server launchd plist (`~/Library/LaunchAgents/app.ourworlds.play-server.plist`)
- Create: `docs/connect-your-agent.md`
- Modify: `docs/agent-bridge-contract.md`

- [ ] **Step 1: Add `/agent` ingress** (before the catch-all), in `ourworlds-play-config.yml`:
```yaml
ingress:
  - hostname: play.ourworlds.app
    path: /ws
    service: ws://127.0.0.1:8971
  - hostname: play.ourworlds.app
    path: /agent
    service: ws://127.0.0.1:8972
  - hostname: play.ourworlds.app
    service: http://127.0.0.1:8060
  - service: http_status:404
```

- [ ] **Step 2: Add gateway env to the server plist** — add `OW_AGENT_GATEWAY_PORT=8972`, `OW_AGENT_TOKENS=<hand-issued>`, `OW_AGENT_MAX=8` to the server LaunchAgent's `EnvironmentVariables`. (Do **not** commit real tokens — use a placeholder in any committed copy.)

- [ ] **Step 3: Restart services + verify the public endpoint**

```bash
launchctl kickstart -k gui/$(id -u)/app.ourworlds.play-server
launchctl kickstart -k gui/$(id -u)/app.ourworlds.play-tunnel
# auth handshake over the public WSS:
node -e 'import("ws").then(({WebSocket:W})=>{const w=new W("wss://play.ourworlds.app/agent");w.on("open",()=>w.send(JSON.stringify({id:0,tool:"auth",args:{token:process.env.T,name:"probe"}})));w.on("message",m=>{console.log("RESP",m.toString());w.close()});w.on("error",e=>console.error("ERR",e.message))})' 
```
Expected: `RESP {"id":0,"ok":true,"result":{"eid":"agent-..."}}` (with `T=<valid token>`); body appears + despawns on a human client.

- [ ] **Step 4: Write `docs/connect-your-agent.md`** — remote endpoint + token, plus the two runtime configs:
  - **Hermes:** `hermes mcp add ourworlds -- node /abs/agent-bridge-mcp/dist/index.js` with env `OW_REMOTE_URL=wss://play.ourworlds.app/agent OW_AGENT_TOKEN=<token>`; set a persona prompt.
  - **Claude Code:** `.mcp.json` entry for the same server + env; persona via `CLAUDE.md`/`--append-system-prompt`.

- [ ] **Step 5: Update `docs/agent-bridge-contract.md`** — new section: remote WS transport, the `auth` first-frame, token requirement, and the server-side `observe` fidelity note (hotbar/selected_block defaults).

- [ ] **Step 6: Commit**

```bash
git add docs/connect-your-agent.md docs/agent-bridge-contract.md
git commit -m "docs: connect-your-agent guide + remote transport in agent contract"
```
> Deploy files under `~/.cloudflared` / `~/Library/LaunchAgents` are machine-local (not in the repo) — note the exact changes in the commit body or an ops note; never commit real tokens.

---

### Task 11: Acceptance demo — Hermes + Claude Code simultaneously (manual)

**Files:** none (procedure; capture results in `docs/connect-your-agent.md` "Verified" note).

- [ ] **Step 1:** Ensure the server (with gateway) + tunnel are running and `agent-bridge-mcp` is built.
- [ ] **Step 2:** Configure **Hermes** (token `H`, persona A, e.g. "brutalist tower builder") and **Claude Code** (token `C`, persona B, e.g. "cozy garden builder"), both pointing at `wss://play.ourworlds.app/agent`.
- [ ] **Step 3:** Start both. From a human web client at `play.ourworlds.app`, confirm: **two distinct agent avatars** appear, each moves and builds per its persona, both visible to you and to each other.
- [ ] **Step 4:** Verify in server logs: 2 agents in roster, edits attributed to the correct `agent-N`, independent rate-limits; close each runtime → its body despawns.
- [ ] **Step 5:** Record the result (date, runtimes, screenshots) in `docs/connect-your-agent.md`; commit that note.

---

## Definition of Done (mirrors the spec)

- [ ] Remote runtime connects via `wss://play.ourworlds.app/agent` + token, gets a body, runs all 12 tools.
- [ ] Hermes + Claude Code connect simultaneously; both visible to a human client and each other.
- [ ] Bad token rejected; disconnect despawns; 8-block reach + 96/s rate + `OW_AGENT_MAX` enforced.
- [ ] All unit tests + `test_agent_gateway_e2e.gd` green via `bash tests/run_all.sh`; manual two-agent demo done.
- [ ] `docs/connect-your-agent.md` + contract update written.
- [ ] `test_agent_bridge.gd` / `test_build_templates.gd` / `test_network_core.gd` still green (no regressions).
</content>
