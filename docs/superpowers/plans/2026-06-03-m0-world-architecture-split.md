# M0 — 世界架构拆分 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把单机 `World`（数据+渲染+流式+编辑混在一起）拆成可联机的形状：纯数据层 `WorldData`、增量层 `WorldDeltaStore`、渲染外壳保留在 `World`；编辑入口拆成"请求/本地应用"；seed 可注入。全程单机、用 headless 单测验证，单机版不退化。

**Architecture:** 新增 `WorldDeltaStore`（内存增量：每区块 `局部下标→方块ID`，含 dirty/revision）和 `WorldData`（持有 seed + `WorldGenerator` + delta store，缓存 base/live 区块，提供 `get_block/apply_block/get_live/unload`）。`World` 不再自己存 `_chunks`，改为持有一个 `WorldData`，只负责造网格/碰撞/流式/卸载。编辑从 `world.set_block()` 改为 `world.request_edit()`→`apply_edit_local()`，为 M1 的服务器权威留好接缝。

**Tech Stack:** Godot 4.6 + GDScript。测试沿用本项目惯例——`SceneTree` 脚本 + `godot --headless --script`，不用第三方测试框架。

---

## File Structure

- **新增** `scripts/WorldDeltaStore.gd` — 内存增量表（纯逻辑，RefCounted）。
- **新增** `scripts/WorldData.gd` — 数据层：seed、生成、base/live 缓存、delta 叠加、编辑、卸载（RefCounted）。
- **改** `scripts/Chunk.gd` — 加 `get_index/set_index`（按一维下标读写，给 delta 叠加用）。
- **改** `scripts/World.gd` — 去掉自存 `_chunks`，改用 `WorldData`；`set_block` 拆成 `request_edit/apply_edit_local`；流式/卸载改走 `WorldData`。
- **改** `scripts/Player.gd` — 挖/放从 `world.set_block(...)` 改为 `world.request_edit(...)`。
- **改** `scripts/Main.gd` — `world.setup(lib)` 传入世界 seed。
- **新增** `tests/test_delta_store.gd` — 增量表单测。
- **新增** `tests/test_world_data.gd` — 数据层单测（编辑跨卸载/重载保留、挖空气、改回原值移除）。
- **改** `tests/test_play.gd` — 挖方块从 `set_block` 改为 `request_edit`。

每个区块仍是 `Chunk`（16×16×96 `PackedByteArray`）。增量按"区块坐标 `Vector2i` → { 局部一维下标 `int` → 方块ID `int` }"组织；局部下标用 `Chunk.index(x,y,z)`。

---

## Task 1: Chunk 加按下标读写

**Files:**
- Modify: `scripts/Chunk.gd`
- Test: `tests/test_world_data.gd`（本任务先不写测试，Task 3 覆盖；这里仅加方法）

- [ ] **Step 1: 加 get_index / set_index**

在 `scripts/Chunk.gd` 末尾追加（`blocks` 是成员变量，按下标原地写入是安全的）：

```gdscript
# 按一维下标直接读写（给 delta 叠加用，避免反复算 index）
func get_index(i: int) -> int:
	return blocks[i]

func set_index(i: int, id: int) -> void:
	blocks[i] = id
	dirty = true
```

- [ ] **Step 2: 语法自检**

Run: `godot --headless --path . --check-only scripts/Chunk.gd`
Expected: 无 `SCRIPT ERROR`（命令静默或仅打印引擎横幅即通过）。

- [ ] **Step 3: 提交**

```bash
cd .
git add scripts/Chunk.gd
git commit -m "feat(voxel): Chunk add get_index/set_index for delta overlay"
```

---

## Task 2: WorldDeltaStore（内存增量表）

**Files:**
- Create: `scripts/WorldDeltaStore.gd`
- Test: `tests/test_delta_store.gd`

- [ ] **Step 1: 写失败测试**

Create `tests/test_delta_store.gd`:

```gdscript
extends SceneTree
# headless: godot --headless --path <项目> --script res://tests/test_delta_store.gd
const WorldDeltaStore = preload("res://scripts/WorldDeltaStore.gd")
const Chunk = preload("res://scripts/Chunk.gd")

var failed := 0
func _process(_d: float) -> bool: return true   # 兜底：绝不空转
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var s = WorldDeltaStore.new()
	var cc := Vector2i(0, 0)
	var i := Chunk.index(1, 2, 3)

	check(not s.has_chunk(cc), "起初无该区块增量")
	s.set_edit(cc, i, 5)
	check(s.has_chunk(cc), "写入后有增量")
	check(s.get_edits(cc).get(i, -1) == 5, "增量值正确")
	check(s.edit_count() == 1, "增量计数=1")
	check(s.revision(cc) == 1, "revision=1")
	check(s.is_dirty(cc), "标记 dirty")

	# 叠加到一个区块上
	var ch := Chunk.new(0, 0)
	s.apply_to_chunk(cc, ch)
	check(ch.get_block(1, 2, 3) == 5, "apply_to_chunk 把增量写进区块")

	# 清除
	s.clear_edit(cc, i)
	check(not s.has_chunk(cc), "清空后该区块无增量")
	check(s.edit_count() == 0, "增量计数=0")

	if failed == 0: print("✅ ALL DELTA STORE TESTS PASSED")
	else: printerr("❌ ", failed, " 个失败")
	quit(failed)
```

- [ ] **Step 2: 运行，确认失败**

Run: `godot --headless --path . --script res://tests/test_delta_store.gd`
Expected: 报错 `Failed to load script ... WorldDeltaStore.gd`（文件还不存在）。

- [ ] **Step 3: 实现 WorldDeltaStore**

Create `scripts/WorldDeltaStore.gd`:

```gdscript
extends RefCounted
# 内存增量表：每个区块记录"玩家把哪些格改成了什么"。
# 键：区块坐标 Vector2i -> { 局部一维下标 int -> 方块ID int }
# 注意：把方块挖成空气(0) 也是有效增量，必须记录，不能当"无记录"。

var _edits := {}     # Vector2i -> Dictionary(int -> int)
var _dirty := {}     # Vector2i -> bool
var _rev := {}       # Vector2i -> int

func has_chunk(cc: Vector2i) -> bool:
	return _edits.has(cc)

func get_edits(cc: Vector2i) -> Dictionary:
	return _edits.get(cc, {})

func revision(cc: Vector2i) -> int:
	return int(_rev.get(cc, 0))

func is_dirty(cc: Vector2i) -> bool:
	return bool(_dirty.get(cc, false))

func clear_dirty(cc: Vector2i) -> void:
	_dirty[cc] = false

func dirty_chunks() -> Array:
	var out := []
	for cc in _dirty.keys():
		if _dirty[cc]:
			out.append(cc)
	return out

func edit_count() -> int:
	var n := 0
	for cc in _edits.keys():
		n += _edits[cc].size()
	return n

func set_edit(cc: Vector2i, idx: int, id: int) -> void:
	if not _edits.has(cc):
		_edits[cc] = {}
	_edits[cc][idx] = id
	_dirty[cc] = true
	_rev[cc] = int(_rev.get(cc, 0)) + 1

func clear_edit(cc: Vector2i, idx: int) -> void:
	if not _edits.has(cc):
		return
	if _edits[cc].erase(idx):
		_dirty[cc] = true
		_rev[cc] = int(_rev.get(cc, 0)) + 1
		if _edits[cc].is_empty():
			_edits.erase(cc)

# 把某区块的增量叠加到一个（已生成基础地形的）Chunk 上
func apply_to_chunk(cc: Vector2i, chunk) -> void:
	if not _edits.has(cc):
		return
	for idx in _edits[cc].keys():
		chunk.set_index(idx, _edits[cc][idx])
```

- [ ] **Step 4: 运行，确认通过**

Run: `godot --headless --path . --script res://tests/test_delta_store.gd`
Expected: `✅ ALL DELTA STORE TESTS PASSED`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add scripts/WorldDeltaStore.gd tests/test_delta_store.gd
git commit -m "feat(voxel): in-memory WorldDeltaStore (per-chunk block deltas)"
```

---

## Task 3: WorldData（数据层：生成 + 增量叠加 + 编辑 + 卸载）

**Files:**
- Create: `scripts/WorldData.gd`
- Test: `tests/test_world_data.gd`

- [ ] **Step 1: 写失败测试**

Create `tests/test_world_data.gd`:

```gdscript
extends SceneTree
# headless: godot --headless --path <项目> --script res://tests/test_world_data.gd
const WorldData = preload("res://scripts/WorldData.gd")

var failed := 0
func _process(_d: float) -> bool: return true
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var data = WorldData.new(1337)
	var cc := data.chunk_of(5, 5)

	# 找一个"生成出来是实心(非空气)"的格子：地表
	var h: int = data.surface_y(5, 5)
	var base_id: int = data.get_block(5, h, 5)
	check(base_id != 0, "地表格子是实心")

	# 1) 编辑后值变了，且卸载重载仍保留
	data.apply_block(5, h, 5, 6)   # 6 = 木板(PLANKS)，覆盖实心地表
	check(data.get_block(5, h, 5) == 6, "编辑后读到新值")
	check(data.deltas.edit_count() == 1, "产生 1 条增量")
	data.unload(cc)
	check(not data.is_built(cc), "卸载后该区块未建")
	check(data.get_block(5, h, 5) == 6, "卸载重载后编辑仍在")

	# 2) 把实心地表挖成空气 —— 空气(0) 也是有效增量，必须跨卸载保留
	data.apply_block(5, h, 5, 0)
	check(data.get_block(5, h, 5) == 0, "挖成空气")
	check(data.deltas.edit_count() == 1, "空气仍是 1 条增量（不是删除）")
	data.unload(cc)
	check(data.get_block(5, h, 5) == 0, "空气增量跨重载保留")

	# 3) 把该格改回它本来的生成值 -> 该条增量被移除
	data.apply_block(5, h, 5, base_id)
	check(data.get_block(5, h, 5) == base_id, "改回原值")
	check(data.deltas.edit_count() == 0, "改回原值后增量被移除")

	if failed == 0: print("✅ ALL WORLD DATA TESTS PASSED")
	else: printerr("❌ ", failed, " 个失败")
	quit(failed)
```

- [ ] **Step 2: 运行，确认失败**

Run: `godot --headless --path . --script res://tests/test_world_data.gd`
Expected: 报错找不到 `WorldData.gd`。

- [ ] **Step 3: 实现 WorldData**

Create `scripts/WorldData.gd`:

```gdscript
extends RefCounted
# 数据层：持有 seed + 生成器 + 增量表；缓存 base(纯生成) 与 live(base+增量) 两份区块。
# 服务端/客户端都用它。它不碰任何渲染/节点。
#
# 为什么缓存 base：检测"改回生成值"需要知道原值；而地形里有树等结构，无法靠单格公式
# 反推，所以保留整块 base。live = base 叠加增量，是对外可见/可渲染的真相。

const Chunk = preload("res://scripts/Chunk.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")
const WorldDeltaStore = preload("res://scripts/WorldDeltaStore.gd")

var seed: int
var gen: WorldGenerator
var deltas: WorldDeltaStore

var _base := {}   # Vector2i -> Chunk（纯生成）
var _live := {}   # Vector2i -> Chunk（base + 增量）

func _init(world_seed: int) -> void:
	seed = world_seed
	gen = WorldGenerator.new(world_seed)
	deltas = WorldDeltaStore.new()

func chunk_of(wx: int, wz: int) -> Vector2i:
	return Vector2i(floori(float(wx) / Chunk.SX), floori(float(wz) / Chunk.SZ))

func surface_y(wx: int, wz: int) -> int:
	return gen.surface_height(wx, wz)

func is_built(cc: Vector2i) -> bool:
	return _live.has(cc)

func peek_live(cc: Vector2i):
	return _live.get(cc, null)

func get_live(cc: Vector2i) -> Chunk:
	if not _live.has(cc):
		_build(cc)
	return _live[cc]

func _build(cc: Vector2i) -> void:
	var base := Chunk.new(cc.x, cc.y)
	gen.generate(base)
	_base[cc] = base
	var live := Chunk.new(cc.x, cc.y)
	live.blocks = base.blocks.duplicate()
	deltas.apply_to_chunk(cc, live)
	_live[cc] = live

func get_block(wx: int, wy: int, wz: int) -> int:
	var cc := chunk_of(wx, wz)
	var ch := get_live(cc)
	return ch.get_block(wx - cc.x * Chunk.SX, wy, wz - cc.y * Chunk.SZ)

# 权威地写入一个方块。返回是否真的改变了。
func apply_block(wx: int, wy: int, wz: int, id: int) -> bool:
	var cc := chunk_of(wx, wz)
	get_live(cc)                          # 确保 base/live 已建
	var lx := wx - cc.x * Chunk.SX
	var ly := wy
	var lz := wz - cc.y * Chunk.SZ
	if not _live[cc].in_bounds(lx, ly, lz):
		return false
	var live: Chunk = _live[cc]
	if live.get_block(lx, ly, lz) == id:
		return false                      # 没变化
	var idx := Chunk.index(lx, ly, lz)
	var base_id: int = _base[cc].get_index(idx)
	live.set_index(idx, id)
	if id == base_id:
		deltas.clear_edit(cc, idx)        # 改回生成值 -> 移除增量
	else:
		deltas.set_edit(cc, idx, id)
	return true

# 卸载区块缓存（base/live），但保留增量表（重载时能恢复玩家修改）
func unload(cc: Vector2i) -> void:
	_base.erase(cc)
	_live.erase(cc)
```

- [ ] **Step 4: 运行，确认通过**

Run: `godot --headless --path . --script res://tests/test_world_data.gd`
Expected: `✅ ALL WORLD DATA TESTS PASSED`，退出码 0。

- [ ] **Step 5: 提交**

```bash
git add scripts/WorldData.gd tests/test_world_data.gd
git commit -m "feat(voxel): WorldData layer (gen + delta overlay + edit + unload)"
```

---

## Task 4: World 改用 WorldData（去掉自存 _chunks）

**Files:**
- Modify: `scripts/World.gd`
- Test: `tests/test_play.gd`（Task 6 再跑全套；本任务后跑 test_world_data 不受影响）

> 说明：`World` 现在自己用 `_chunks` 存区块数据，并在多线程造网格里复制其字节数组。本任务把"数据归属"整体搬到 `WorldData`，`World` 只留渲染/流式/卸载。线程模型、LUT、version 作废机制都保留。

- [ ] **Step 1: 替换数据成员与 setup**

在 `scripts/World.gd`：把 `const` 区块下方新增 `WorldData` 预载，删除 `var _chunks := {}`，新增 `var data: WorldData`。

把：
```gdscript
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")
```
改为同时有：
```gdscript
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")
const WorldData = preload("res://scripts/WorldData.gd")
```

删除：
```gdscript
var _gen: WorldGenerator
var _chunks := {}              # Vector2i -> Chunk(数据)   —— 仅主线程访问
```
新增（放在 `var lib` 附近）：
```gdscript
var data: WorldData
```

把 `setup()` 改为接收 seed 并建 `WorldData`：
```gdscript
func setup(block_lib: BlockLibrary, world_seed: int = 1337) -> void:
	lib = block_lib
	data = WorldData.new(world_seed)
	_solid = lib.solid_lut; _opaque = lib.opaque_lut; _transp = lib.transp_lut; _water = lib.water_lut
	_ttop = lib.tile_top_lut; _tside = lib.tile_side_lut; _tbot = lib.tile_bot_lut
```

- [ ] **Step 2: 坐标/读方块委托给 data，编辑拆成 request/local**

把 `chunk_of` / `surface_y` / `get_block` / `set_block` 整段替换为：
```gdscript
# ---------- 坐标 ----------
func chunk_of(wx: int, wz: int) -> Vector2i:
	return data.chunk_of(wx, wz)

func surface_y(wx: int, wz: int) -> int:
	return data.surface_y(wx, wz)

# ---------- 读方块 ----------
func get_block(wx: int, wy: int, wz: int) -> int:
	if not data.is_built(data.chunk_of(wx, wz)):
		return 0
	return data.get_block(wx, wy, wz)

# ---------- 编辑入口（为 M1 服务器权威留接缝）----------
# 玩家/网络层调用。M0 单机：请求即本地权威应用。
func request_edit(wx: int, wy: int, wz: int, id: int) -> void:
	apply_edit_local(wx, wy, wz, id)

# 把"事实"应用到数据并重建受影响区块（含边界邻居）。
func apply_edit_local(wx: int, wy: int, wz: int, id: int) -> void:
	if not data.apply_block(wx, wy, wz, id):
		return
	var cc := data.chunk_of(wx, wz)
	var lx := wx - cc.x * Chunk.SX
	var lz := wz - cc.y * Chunk.SZ
	_remesh_sync(cc)
	if lx == 0: _remesh_sync(cc + Vector2i(-1, 0))
	elif lx == Chunk.SX - 1: _remesh_sync(cc + Vector2i(1, 0))
	if lz == 0: _remesh_sync(cc + Vector2i(0, -1))
	elif lz == Chunk.SZ - 1: _remesh_sync(cc + Vector2i(0, 1))
```

- [ ] **Step 3: 数据生成/取邻居/卸载改走 data**

把 `_ensure_data` / `_ensure_data_with_margin` / `_blocks_or_null` 三个函数整段替换为：
```gdscript
# ---------- 数据生成 ----------
func _ensure_data(cc: Vector2i) -> void:
	data.get_live(cc)                 # 建好 base/live（含增量叠加）

func _ensure_data_with_margin(cc: Vector2i) -> void:
	_ensure_data(cc)
	for d in NEI:
		_ensure_data(cc + d)
```
（`_blocks_or_null` 删除：已无人用。）

把 `_remesh_sync` 里取邻居数据的 4 个 `_chunks.get(...)` 改成 `data.peek_live(...)`，并把取本块从 `_chunks[cc]` 改成 `data.get_live(cc)`：
```gdscript
func _remesh_sync(cc: Vector2i) -> void:
	if not data.is_built(cc):
		return
	_version[cc] = int(_version.get(cc, 0)) + 1
	var ch: Chunk = data.get_live(cc)
	var built := ChunkMesher.build(ch, lib,
		data.peek_live(cc + Vector2i(-1, 0)), data.peek_live(cc + Vector2i(1, 0)),
		data.peek_live(cc + Vector2i(0, -1)), data.peek_live(cc + Vector2i(0, 1)))
	_apply_node(cc, built)
```

把 `_dispatch` 里读字节数组的部分改成走 `data`：
```gdscript
func _dispatch(cc: Vector2i) -> void:
	_ensure_data_with_margin(cc)
	var d: PackedByteArray = data.get_live(cc).blocks.duplicate()
	var a_nx = _dup(cc + Vector2i(-1, 0))
	var a_px = _dup(cc + Vector2i(1, 0))
	var a_nz = _dup(cc + Vector2i(0, -1))
	var a_pz = _dup(cc + Vector2i(0, 1))
	var ver: int = int(_version.get(cc, 0))
	_meshing[cc] = true
	WorkerThreadPool.add_task(_mesh_worker.bind(cc, ver, d, a_nx, a_px, a_nz, a_pz,
		_solid.duplicate(), _opaque.duplicate(), _transp.duplicate(), _water.duplicate(),
		_ttop.duplicate(), _tside.duplicate(), _tbot.duplicate()))

func _dup(cc: Vector2i):
	var ch = data.peek_live(cc)
	return ch.blocks.duplicate() if ch != null else null
```

把 `_unload_far` 里 `_chunks.erase(cc)` 改为 `data.unload(cc)`：
```gdscript
func _unload_far(c: Vector2i) -> void:
	var drop := []
	for cc in _nodes.keys():
		if max(abs(cc.x - c.x), abs(cc.y - c.y)) > view_radius + 1:
			drop.append(cc)
	for cc in drop:
		var e: Dictionary = _nodes[cc]
		e["mesh"].queue_free()
		e["body"].queue_free()
		_nodes.erase(cc)
		data.unload(cc)
		_version[cc] = int(_version.get(cc, 0)) + 1
```

`prime` / `generate_initial` 里调用的是 `_ensure_data` 和 `_remesh_sync`，已自动走 data，无需改动。

- [ ] **Step 4: 语法自检**

Run: `godot --headless --path . --check-only scripts/World.gd`
Expected: 无 `SCRIPT ERROR`。

- [ ] **Step 5: 提交**

```bash
git add scripts/World.gd
git commit -m "refactor(voxel): World uses WorldData; split edit into request/apply_local"
```

---

## Task 5: Player 与 Main 接入新接口

**Files:**
- Modify: `scripts/Player.gd`
- Modify: `scripts/Main.gd`

- [ ] **Step 1: Player 改用 request_edit**

在 `scripts/Player.gd` 的 `_on_click`：把两处 `world.set_block(...)` 改为 `world.request_edit(...)`：
```gdscript
	if button == MOUSE_BUTTON_LEFT and _has_target:
		world.request_edit(_target.x, _target.y, _target.z, BlockLibrary.AIR)   # 挖
	elif button == MOUSE_BUTTON_RIGHT and _has_target:
		if not _blocked_by_self(_place):
			world.request_edit(_place.x, _place.y, _place.z, current_block())   # 放
```

- [ ] **Step 2: Main 传入世界 seed**

在 `scripts/Main.gd`：加一个常量并在 `setup` 时传入。

`const HUD = preload(...)` 下方加：
```gdscript
const WORLD_SEED := 1337
```
把：
```gdscript
	world.setup(lib)
```
改为：
```gdscript
	world.setup(lib, WORLD_SEED)
```

- [ ] **Step 3: 语法自检**

Run: `godot --headless --path . --check-only scripts/Player.gd` 然后 `... --check-only scripts/Main.gd`
Expected: 均无 `SCRIPT ERROR`。

- [ ] **Step 4: 提交**

```bash
git add scripts/Player.gd scripts/Main.gd
git commit -m "refactor(voxel): Player uses request_edit; Main injects world seed"
```

---

## Task 6: 回归验证（单机不退化）

**Files:**
- Modify: `tests/test_play.gd`

- [ ] **Step 1: test_play 改用 request_edit**

在 `tests/test_play.gd` 的挖方块那行（frame 70 附近）：把
```gdscript
		_main.world.set_block(int(floor(p.x)), int(floor(p.y)) - 1, int(floor(p.z)), 0)
```
改为：
```gdscript
		_main.world.request_edit(int(floor(p.x)), int(floor(p.y)) - 1, int(floor(p.z)), 0)
```

- [ ] **Step 2: 跑全部 headless 测试**

Run（逐条）：
```bash
cd .
godot --headless --path . --script res://tests/test_delta_store.gd
godot --headless --path . --script res://tests/test_world_data.gd
godot --headless --path . --script res://tests/test_mesher.gd
perl -e 'alarm(shift); exec @ARGV' 40 godot --headless --path . --script res://tests/test_play.gd
```
Expected：
- delta store / world data / mesher：各自打印 `✅ ... PASSED`，退出码 0。
- test_play：打印 `脚下区域就绪 ...`、`PLAY OK ... 已加载区块=>0`、`✅ 进游戏路径正常`，无 `SCRIPT ERROR`/`null value`。

- [ ] **Step 3: 真机烟测（手动）**

Run: `godot --path .`
确认：能进游戏、走动、挖/放、F5 切视角；**走远让区块卸载，再走回来，之前挖/放的改动仍在**（这是 M0 的核心验收点：增量跨卸载/重载保留）。

- [ ] **Step 4: 提交**

```bash
git add tests/test_play.gd
git commit -m "test(voxel): test_play uses request_edit; M0 architecture split complete"
```

---

## Self-Review（已核对）

- **Spec 覆盖**（方案第 5、10 节）：`WorldData`(Task 3) / `WorldDeltaStore`(Task 2) / `WorldView` 即 `World` 渲染外壳(Task 4) ✓；seed 可注入(Task 4 setup + Task 5 Main) ✓；`set_block` 拆成 `request_edit`/`apply_edit_local`(Task 4) ✓；卸载不丢增量(Task 3 `unload` 保留 deltas + Task 4 `_unload_far` 走 `data.unload`) ✓；重载先生成基础再套 delta(Task 3 `_build`) ✓。
- **验收点**：改一格→卸载→重载仍是改后值（test_world_data 用例 2）✓；改回生成值移除增量（用例 4）✓；挖成空气是有效增量（用例 3）✓；单机不退化（Task 6）✓。
- **占位符扫描**：无 TBD/TODO；每个代码步骤含完整代码 ✓。
- **类型/命名一致**：`WorldData.apply_block` 返回 `bool`，`World.apply_edit_local` 据此判断；`peek_live` 返回 `Chunk` 或 `null`，`ChunkMesher.build` 已支持 `null` 邻居；`Chunk.index/get_index/set_index` 命名贯穿一致 ✓。

## Execution Handoff

见对话中的执行方式选择。M0 完成后，下一份计划是 **M0.5（网页单机烟测）** 或 **M1（本地双人联机）**。
