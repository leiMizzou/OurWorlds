# P1 Online Multiplayer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn single-player OurWorlds into an online, shared-world game (browser-playable, accounts, cloud saves) via an authoritative headless-Godot world server + Nakama backend — starting with the architecture foundation (M0).

**Architecture:** Authoritative client-server. The world server is headless Godot reusing the same GDScript simulation; clients render a deterministic copy from the same seed and apply server-sent block deltas over WebSocket. Nakama handles only accounts / tickets / lobby / cloud storage. (Full rationale: [`docs/superpowers/specs/2026-06-03-online-multiplayer-design.md`](../specs/2026-06-03-online-multiplayer-design.md).)

**Tech Stack:** Godot 4.6 GDScript · `WebSocketMultiplayerPeer` · Godot Web/WASM export · Nakama (Postgres) · Docker + Caddy (wss/TLS).

---

## Current-state reconciliation (READ FIRST — the 2026-06-03 spec predates this)

Much of the spec's **M0 data layer already exists** inside `scripts/World.gd` (added by the save system + agent bridge). Verified against current code:

| Spec M0 item | Status in current code |
|---|---|
| Seed injectable | ✅ `World.setup(lib, world_seed, save_file)` → `WorldGenerator.new(world_seed)` (`World.gd:72-76`) |
| In-memory delta store | ✅ `_deltas` + `_record_delta` + `_apply_deltas_to_chunk` (`World.gd:46,358,376`) |
| `request_edit` entry point | ✅ `request_edit` / `request_edits` / `request_block_edits` (`World.gd:109-168`) |
| Edit survives chunk unload→reload | ✅ `_ensure_data` snapshots `base_blocks` then re-applies deltas (`World.gd:319-328`) |
| Revert-to-generated removes delta | ✅ `_record_delta` erases when `id == base` (`World.gd:358-374`) |
| Data/render seam | ✅ `set_block_data` (writes data + records delta) is already separate from `flush_remesh` (renders) (`World.gd:182-222`) |

**So M0 is NOT "build the delta store"** — it is **extracting the headless-usable data core (`WorldData`) out of the render/stream shell (`World`)**, adding **per-chunk revisions** (needed for sync), and **formalizing `apply_edit_local`** as the data-only apply path. Single-player must stay 100% working (47/47 self-checks).

> **Open option (decide before M0):** instead of a full `WorldData` extraction, a lighter path is a "server/no-render mode" flag on `World` that skips meshing. Extraction is cleaner long-term and is what the spec chose; this plan follows extraction but Task 7 notes the fallback. The two are not mutually exclusive — extraction also makes the no-render server trivial.

---

## Milestone roadmap (umbrella — each milestone gets its own detailed plan when reached)

| Milestone | Scope | Verify | Rough effort |
|---|---|---|---|
| **M0** (this plan) | Extract `WorldData` (pure data+gen+delta, no nodes) from `World`; add per-chunk `revision`; `apply_edit_local` data path; SP unchanged | 47/47 green; new `test_world_data.gd`; WorldData usable with **no SceneTree** | ~1 week |
| **M0.5** | Web/WASM single-player smoke: export, COOP/COEP threads, view distance, FPS | Playable in browser; min view dist + FPS known | ~3–5 days |
| **M1** ✅ done | Local authoritative co-op: headless server (`WebSocketMultiplayerPeer`) + 2 clients; avatars visible; edits sync; in-memory deltas persist within session; no accounts/web/cloud | 1 server + 2 clients locally see each other move + edit; leave/return keeps edits | ~2–3 weeks |
| **M2** | Web client connects to LAN/local Godot server over wss | Browser client plays stably | ~1 week |
| **M3** | Server on a VPS; Caddy wss/TLS; optional local-file save | Public address connects; world survives restart | ~1 week |
| **M4** | Accounts + cloud save (Nakama): login, entry ticket, chunk-delta & player-state to DB, autosave, reconnect-resume | Log in on another device → same world, builds intact | ~3–4 weeks |
| **M5** | Lobby/multi-world + interest management; 8–16-player load test | Players pick worlds from lobby; load test passes | ~3–4 weeks |
| **M6** | Public hardening: anti-cheat validation, rate limits, reports, bans, backups, monitoring, cost control | Invite-only public; issues traceable/recoverable | ~3–4 weeks |

**Reusable precedents already in the repo:** the chat work shipped a `ChatHub` (presence roster + per-entity unread cursors) and made `AgentBridge` **multi-client** (per-connection entity ids, accept/drop lifecycle). M1's `NetworkManager` (peer_connected/disconnected, per-peer identity, broadcast) mirrors that lifecycle; the lobby/presence UI (`ChatPanel`) can surface networked players too.

---

## M0 — Detailed plan (data-layer foundation)

**Principle:** TDD. Build `WorldData` fresh against new tests (Tasks 1–4), then swap `World` to delegate to it (Task 5), keeping every existing self-check green (Task 6). Commit after each task.

### File structure

- **Create** `scripts/WorldData.gd` — pure data core (`extends RefCounted`, no nodes/render). Owns seed, `WorldGenerator`, chunk dict, deltas, revisions. Headless-safe.
- **Create** `tests/test_world_data.gd` — `extends SceneTree`, drives `WorldData` directly (no Main scene).
- **Modify** `scripts/World.gd` — keep as the render/stream shell + edit entry points + undo/redo; hold a `WorldData` and delegate all data/delta calls to it. Remove the moved data internals.
- **Unchanged** `scripts/Chunk.gd` (data container, already pure).

`WorldData` public interface (target):

```gdscript
# scripts/WorldData.gd  (extends RefCounted)
func _init(world_seed: int) -> void
func chunk_of(wx: int, wz: int) -> Vector2i
func surface_y(wx: int, wz: int) -> int
func region_label(wx: int, wz: int) -> String
func region_description(wx: int, wz: int) -> String
func get_block(wx: int, wy: int, wz: int) -> int
func ensure_data(cc: Vector2i) -> Chunk          # generate baseline + apply deltas
func apply_edit_local(wx: int, wy: int, wz: int, id: int) -> Array  # returns affected chunk coords (Vector2i[]); [] = no change. Writes data, records delta, bumps revision
func chunk_revision(cc: Vector2i) -> int          # NEW
func chunk_delta(cc: Vector2i) -> Dictionary      # {local_index: block_id} for sync/save
func set_chunk_delta(cc: Vector2i, edits: Dictionary, revision: int) -> void  # for load/server push
func all_deltas() -> Dictionary                   # "cx,cz" -> {index: id} (save)
func load_deltas(d: Dictionary) -> void           # (load)
func edit_count() -> int
func edited_blocks_near(pos: Vector3i, r: int, vr: int) -> int
func landmark_restoration(pos: Vector3i) -> Dictionary
func unload_chunk(cc: Vector2i) -> void           # drop the Chunk node-less data; deltas persist
```

---

### Task 1: `WorldData` — deterministic generation + get_block

**Files:** Create `scripts/WorldData.gd`; Create `tests/test_world_data.gd`

- [ ] **Step 1: Write the failing test** (`tests/test_world_data.gd`)

```gdscript
extends SceneTree
# WorldData 纯数据核心自检（无 SceneTree/节点依赖）：
#   godot --headless --path . --script res://tests/test_world_data.gd
const WorldData = preload("res://scripts/WorldData.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var a := WorldData.new(1337)
	var b := WorldData.new(1337)
	# 确定性：同种子，同坐标，同方块
	var sa := a.get_block(8, a.surface_y(8, 8), 8)
	var sb := b.get_block(8, b.surface_y(8, 8), 8)
	check(sa == sb, "同种子 get_block 确定性一致")
	check(a.surface_y(8, 8) == b.surface_y(8, 8), "同种子 surface_y 一致")
	check(a.get_block(0, -1, 0) == 0 and a.get_block(0, 9999, 0) == 0, "越界 y 返回 air")
	check(str(a.region_label(8, 8)) != "", "region_label 非空")
	if failed == 0: print("✅ ALL WORLDDATA GEN TESTS PASSED")
	else: printerr("❌ ", failed, " 个 WorldData 生成测试失败")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: Run it, verify RED**

Run: `godot --headless --path . --script res://tests/test_world_data.gd`
Expected: FAIL — `Preload file "res://scripts/WorldData.gd" does not exist.`

- [ ] **Step 3: Create `scripts/WorldData.gd` (gen + get_block)**

Extract from `World.gd` (unchanged logic): the `WorldGenerator` field + `_init`, `chunk_of` (`World.gd:88-89`), `surface_y` (`:91`), `region_label`/`region_description` (`:94-99`), `get_block` (`:101-107`), the chunk dict, and `ensure_data` (from `_ensure_data` `:319-328`, renamed public). Use `Chunk` + `WorldGenerator` preloads. No nodes, no signals, no meshing.

```gdscript
extends RefCounted
const Chunk = preload("res://scripts/Chunk.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")

var _gen: WorldGenerator
var _world_seed := 1337
var _chunks := {}          # Vector2i -> Chunk
var _deltas := {}          # "cx,cz" -> {index:int -> block_id:int}
var _revisions := {}       # "cx,cz" -> int

func _init(world_seed: int = 1337) -> void:
	_world_seed = world_seed
	_gen = WorldGenerator.new(world_seed)

func chunk_of(wx: int, wz: int) -> Vector2i:
	return Vector2i(floori(float(wx) / Chunk.SX), floori(float(wz) / Chunk.SZ))

func surface_y(wx: int, wz: int) -> int:
	return _gen.surface_y(wx, wz)        # mirror current World.surface_y delegation

func region_label(wx: int, wz: int) -> String:
	return _gen.region_label(wx, wz)

func get_block(wx: int, wy: int, wz: int) -> int:
	if wy < 0 or wy >= Chunk.SY:
		return 0
	var cc := chunk_of(wx, wz)
	var ch := ensure_data(cc)
	return ch.get_block(wx - cc.x * Chunk.SX, wy, wz - cc.y * Chunk.SZ)

func _chunk_key(cc: Vector2i) -> String:
	return "%d,%d" % [cc.x, cc.y]

func ensure_data(cc: Vector2i) -> Chunk:
	if _chunks.has(cc):
		return _chunks[cc]
	var ch := _gen.generate_chunk(cc.x, cc.y)   # use the exact generate call from World._ensure_data:319-328
	ch.base_blocks = ch.blocks.duplicate()
	_chunks[cc] = ch
	_apply_deltas_to_chunk(cc, ch)
	return ch

func _apply_deltas_to_chunk(cc: Vector2i, chunk: Chunk) -> void:
	var key := _chunk_key(cc)
	if not _deltas.has(key):
		return
	for idx in (_deltas[key] as Dictionary):
		chunk.blocks[int(idx)] = int(_deltas[key][idx])
```

> Copy `region_description`, the exact `_gen.generate_chunk(...)` call, and `surface_y` delegation verbatim from `World.gd` so generation is byte-identical.

- [ ] **Step 4: Run it, verify GREEN**

Run: `godot --headless --path . --script res://tests/test_world_data.gd`
Expected: PASS — `✅ ALL WORLDDATA GEN TESTS PASSED`

- [ ] **Step 5: Commit**

```bash
git add scripts/WorldData.gd tests/test_world_data.gd
git commit -m "feat(m0): WorldData — headless data core (gen + get_block)"
```

---

### Task 2: `WorldData.apply_edit_local` + per-chunk revision + delta lifecycle

**Files:** Modify `scripts/WorldData.gd`; Modify `tests/test_world_data.gd`

- [ ] **Step 1: Add failing tests** (append checks before the PASS print in `_initialize`)

```gdscript
	var w := WorldData.new(42)
	var sy := w.surface_y(3, 3)
	var base := w.get_block(3, sy, 3)
	# apply edit returns affected chunk(s) + writes data
	var affected: Array = w.apply_edit_local(3, sy, 3, 0)   # dig to air
	check(affected.size() >= 1 and (w.chunk_of(3, 3) in affected), "apply_edit_local 返回受影响区块")
	check(w.get_block(3, sy, 3) == 0, "编辑后 get_block 反映新值")
	check(w.chunk_revision(w.chunk_of(3, 3)) >= 1, "编辑后该区块 revision 递增")
	# edit survives unload -> reload
	w.unload_chunk(w.chunk_of(3, 3))
	check(w.get_block(3, sy, 3) == 0, "卸载该区块后重载，编辑仍在（delta 重套）")
	# revert to generated value removes the delta
	w.apply_edit_local(3, sy, 3, base)
	check(int(w.chunk_delta(w.chunk_of(3, 3)).size()) == 0, "改回生成值 -> 该格 delta 被移除")
	# no-op edit returns empty
	check(w.apply_edit_local(3, sy, 3, base).is_empty(), "值未变 -> 返回空（无变化）")
```

- [ ] **Step 2: Run, verify RED** (`apply_edit_local`/`chunk_revision`/`unload_chunk`/`chunk_delta` undefined)

Run: `godot --headless --path . --script res://tests/test_world_data.gd`
Expected: FAIL — nonexistent function `apply_edit_local`.

- [ ] **Step 3: Implement in `WorldData.gd`** (port `_record_delta` `World.gd:358-374` + `_base_block` `:346-356`; add revision bump + return affected chunks; `apply_edit_local` mirrors `set_block_data`'s data writes incl. cross-chunk neighbor coords but **no render/light bookkeeping**)

```gdscript
func chunk_revision(cc: Vector2i) -> int:
	return int(_revisions.get(_chunk_key(cc), 0))

func chunk_delta(cc: Vector2i) -> Dictionary:
	return (_deltas.get(_chunk_key(cc), {}) as Dictionary).duplicate()

func unload_chunk(cc: Vector2i) -> void:
	_chunks.erase(cc)        # deltas + revisions persist; ensure_data re-applies on reload

func apply_edit_local(wx: int, wy: int, wz: int, id: int) -> Array:
	if wy < 0 or wy >= Chunk.SY:
		return []
	var cc := chunk_of(wx, wz)
	var ch := ensure_data(cc)
	var lx := wx - cc.x * Chunk.SX
	var lz := wz - cc.y * Chunk.SZ
	if ch.get_block(lx, wy, lz) == id:
		return []
	ch.set_block(lx, wy, lz, id)
	_record_delta(cc, lx, wy, lz, id)
	_revisions[_chunk_key(cc)] = chunk_revision(cc) + 1
	var affected := [cc]
	if lx == 0: affected.append(cc + Vector2i(-1, 0))
	elif lx == Chunk.SX - 1: affected.append(cc + Vector2i(1, 0))
	if lz == 0: affected.append(cc + Vector2i(0, -1))
	elif lz == Chunk.SZ - 1: affected.append(cc + Vector2i(0, 1))
	return affected

# port verbatim from World.gd:346-374
func _base_block(cc: Vector2i, lx: int, wy: int, lz: int) -> int: ...   # uses ensure_data + Chunk.index + base_blocks
func _record_delta(cc: Vector2i, lx: int, wy: int, lz: int, id: int) -> void: ...  # erases entry when id == base
```

- [ ] **Step 4: Run, verify GREEN.** Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/WorldData.gd tests/test_world_data.gd
git commit -m "feat(m0): WorldData edit-apply, per-chunk revision, delta lifecycle"
```

---

### Task 3: Delta serialization + data queries (save/sync surface)

**Files:** Modify `scripts/WorldData.gd`; Modify `tests/test_world_data.gd`

- [ ] **Step 1: Add failing tests**

```gdscript
	var w2 := WorldData.new(7)
	var y := w2.surface_y(5, 5)
	w2.apply_edit_local(5, y + 1, 5, 3)         # place stone above surface
	var dump: Dictionary = w2.all_deltas()
	check(dump.size() == 1, "all_deltas 导出 1 个脏区块")
	# round-trip into a fresh instance
	var w3 := WorldData.new(7)
	w3.load_deltas(dump)
	check(w3.get_block(5, y + 1, 5) == 3, "load_deltas 还原编辑")
	check(w2.edit_count() == 1, "edit_count == 1")
```

- [ ] **Step 2: Run, verify RED** (`all_deltas`/`load_deltas`/`edit_count` undefined).

- [ ] **Step 3: Implement** — `all_deltas` returns `_deltas.duplicate(true)`; `load_deltas(d)` sets `_deltas = d.duplicate(true)` and clears `_chunks` so reload re-applies; port `edit_count` (`World.gd:387-392`), `edited_blocks_near` (`:394-412`), `landmark_restoration` (`:414-423`) verbatim (pure delta queries).

- [ ] **Step 4: Run, verify GREEN.**

- [ ] **Step 5: Commit** `git commit -m "feat(m0): WorldData delta serialization + queries"`

---

### Task 4: Headless-usability assertion (the server-readiness proof)

**Files:** Modify `tests/test_world_data.gd`

- [ ] **Step 1: Add a check that exercises WorldData with zero nodes/SceneTree members** — it already runs in `_initialize()` (no `root`, no `add_child`). Add an explicit assertion that 200 edits across multiple chunks apply + survive reload, proving a headless server can own the world with no rendering:

```gdscript
	var srv := WorldData.new(99)
	for i in range(200):
		var x := i * 3
		srv.apply_edit_local(x, srv.surface_y(x, 0) + 1, 0, 6)
	var touched := srv.all_deltas().size()
	for cc_key in srv.all_deltas().keys():
		pass
	# unload everything, then verify a sample still reads back
	srv.unload_chunk(srv.chunk_of(0, 0))
	check(srv.get_block(0, srv.surface_y(0, 0) + 1, 0) == 6, "200 编辑跨区块 + 卸载重载后样本仍在")
	check(touched >= 1, "多区块脏块被记录")
```

- [ ] **Step 2: Run, verify GREEN** (no rendering, no Main scene needed).
- [ ] **Step 3: Commit** `git commit -m "test(m0): WorldData headless server-readiness"`

---

### Task 5: Refactor `World` to delegate to `WorldData` (SP unchanged)

**Files:** Modify `scripts/World.gd`

- [ ] **Step 1: Inject WorldData.** In `World.setup` (`:72-81`), after computing seed: `_data = WorldData.new(world_seed)`. Keep `_gen`? No — remove `World._gen`; route `surface_y`/`region_label`/`region_description`/`chunk_of` to `_data`.

- [ ] **Step 2: Delegate reads.** `World.get_block` → `return _data.get_block(...)`. `World._ensure_data(cc)` → `_data.ensure_data(cc)` and use the returned Chunk for rendering. Keep `World._chunks`? Use `_data`'s chunk dict as the single source: `World` reads chunks via `_data.ensure_data`. Remove `World._deltas`, `_record_delta`, `_apply_deltas_to_chunk`, `_base_block`, `_ensure_data` data internals (now in WorldData).

- [ ] **Step 3: Route edits through `apply_edit_local`.** Rewrite `set_block_data` (`:182-205`) to: `var affected = _data.apply_edit_local(wx,wy,wz,id); if affected.is_empty(): return false; for cc in affected: dirty[cc]=true; _light_dirty bookkeeping; return true`. `request_edit`/`request_edits`/`request_block_edits`/`set_block` keep their flow (history + `flush_remesh`) unchanged — only the data write now goes via `_data`.

- [ ] **Step 4: Route save/load.** Wherever `World` serializes `_deltas` for save (search `World.gd` for `_deltas` in the save/load methods), use `_data.all_deltas()` / `_data.load_deltas(...)`. Route `edit_count`/`edited_blocks_near`/`landmark_restoration` to `_data`.

- [ ] **Step 5: Run the FULL self-check suite (regression gate — must stay green):**

Run: `bash tests/run_all.sh`
Expected: `通过 48  失败 0` (47 existing + `test_world_data`). Pay special attention to `test_save`, `test_undo_redo`, `test_mesher`, `test_agent_bridge*`, `test_play`.

- [ ] **Step 6: Commit** `git commit -m "refactor(m0): World delegates data/delta to WorldData; render shell only"`

---

### Task 6: Final M0 verification + docs

- [ ] **Step 1:** `bash tests/run_all.sh` → 48/48 green.
- [ ] **Step 2:** Confirm headless data path: `godot --headless --path . --script res://tests/test_world_data.gd` green.
- [ ] **Step 3:** Update `docs/superpowers/specs/2026-06-03-online-multiplayer-design.md` §10 note: "M0 data layer landed as `WorldData`; `World` is now the render/stream shell." 
- [ ] **Step 4: Commit** `git commit -m "docs(m0): mark WorldData extraction complete"`

### M0 explicitly NOT in scope

Networking, RPC, `NetworkManager`, headless server entry point, WebSocket, web export, accounts, Nakama, interest management. Those are M1+ (each its own plan). M0 only reshapes the data layer so the server can own the world without rendering.

---

## Self-review

- **Spec coverage:** M0 covers spec §5 (WorldData/DeltaStore split) and §10 (M0 detail), corrected for code that already exists. WorldView is left as `World` (render shell) — naming differs from spec but boundary matches. ✅
- **Revisions:** added (`chunk_revision`) per spec §6 sync needs, ahead of M1 use. ✅
- **Risk:** Task 5 is the only risky step (refactor working code). Mitigation: WorldData built + tested first (Tasks 1–4); full 48/48 suite is the regression gate; commit is isolated and revertible.
- **Open item:** the exact `WorldGenerator.generate_chunk(...)` signature and `surface_y` delegation must be copied verbatim from `World._ensure_data`/`World.surface_y` — the executor reads those lines (cited) rather than guessing.
