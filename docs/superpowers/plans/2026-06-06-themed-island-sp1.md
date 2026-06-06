# 主题岛世界 SP1（地基）实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增一个与现有无限世界并存的"主题岛"世界类型：按种子确定性生成的有限浮空岛，划成 3×3 主题扇区，单人+多人都能创建/进入，现有无限世界一字节不动。

**Architecture:** 新增 `scripts/IslandGenerator.gd`（与 `WorldGenerator` 同接口的纯函数生成器）。`WorldData` 按"世界 kind"在两个生成器间分派。kind 通过"新建=环境变量、继续=存档元数据"跨场景重载传递，并写入存档；多人靠 welcome 握手多带一个 `kind` 字段保证两端按同一生成器重生。

**Tech Stack:** Godot 4.6 · 纯 GDScript · headless 自检（`extends SceneTree`，`tests/run_all.sh` 自动发现 `test_*.gd`）。

**Spec:** [`docs/superpowers/specs/2026-06-06-themed-island-sp1-design.md`](../specs/2026-06-06-themed-island-sp1-design.md)

---

## 文件结构

- **新增 `scripts/IslandGenerator.gd`** — 有限浮空岛确定性生成器。接口与 `WorldGenerator` 一致：`_init(seed)` / `generate(chunk)` / `surface_height(wx,wz)` / `region_label(wx,wz)` / `region_description(wx,wz)`。另暴露 `theme_at(wx,wz)` / `sector_cell(wx,wz)` 供测试与后续 SP3 用。
- **改 `scripts/WorldData.gd`** — `_init(seed, kind)` 按 kind 选生成器（默认 `"infinite"` 走 `WorldGenerator`，不变）。
- **改 `scripts/World.gd`** — `setup(...)` 增 `kind` 参并存 `_world_kind`；`save_world` 写入 `"kind"`。
- **改 `scripts/Main.gd`** — `_enter_world` 解析 kind 并传给 `world.setup`；`_start_new_world(seed, kind)` 用 `VC_WORLD_KIND` 环境变量跨重载传递；dedicated server / host 用 kind 建 `WorldData` 并设 `net_manager.world_kind`；`_on_welcomed` 用 welcome 的 kind 建客户端世界。
- **改 `scripts/TitleScreen.gd`** — 新建面板加"世界类型"开关；`new_world_requested(seed, kind)`。
- **改 `scripts/WorldCatalog.gd`** — `_read_world_meta` 读出 `"kind"`（默认 `"infinite"`）。
- **改 `scripts/NetworkManager.gd`** — `world_kind` 字段；`build_welcome` 带 `kind`；`apply_welcome` 存下。
- **新增测试**：`tests/test_island_generator.gd`、`tests/test_world_kind.gd`、`tests/test_title_world_kind.gd`、`tests/test_island_save.gd`、`tests/test_island_multiplayer.gd`（均 `test_*.gd`，`run_all.sh` 自动跑）。
- **新增 `tests/shot_island.gd`** — 俯瞰截图（人工肉眼确认，非自动跑）。

> 现有方块 id 常量（`scripts/BlockLibrary.gd`）：`AIR=0 GRASS=1 DIRT=2 STONE=3 LOG=5 SAND=7 GLASS=8 WATER=9 LEAVES=10 SNOW=11 MARBLE=17 STEEL_BLOCK=30 RED_SAND=32 TERRACOTTA=33`。`Chunk`：`SX=SZ=16, SY=96`，`set_block(lx,y,lz,id)`，`Chunk.index(x,y,z)`。

---

### Task 1: IslandGenerator 骨架 —— 有界浮空石板 + 扇区划分

**Files:**
- Create: `scripts/IslandGenerator.gd`
- Test: `tests/test_island_generator.gd`

- [ ] **Step 1: 写失败测试** — `tests/test_island_generator.gd`

```gdscript
extends SceneTree
# IslandGenerator 自检：确定性 / 有界（界外空气）/ 扇区划分。
const IslandGenerator = preload("res://scripts/IslandGenerator.gd")
const Chunk = preload("res://scripts/Chunk.gd")

var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var g := IslandGenerator.new(1337)
	var h := IslandGenerator.new(1337)

	# 确定性：同种子同区块逐字节一致
	var ca := Chunk.new(0, 0); g.generate(ca)
	var cb := Chunk.new(0, 0); h.generate(cb)
	check(ca.blocks == cb.blocks, "同种子 generate 逐字节一致")

	# 中心（原点扇区）地表为实体方块，且在合理高度
	var sy := g.surface_height(4, 4)
	check(sy > 0 and sy < Chunk.SY, "中心 surface_height 在 (0,SY)")
	check(g.get_top_block_for_test(4, 4) != 0, "中心地表非空气")

	# 界外（远超半径）整列空气
	var far := IslandGenerator.HALF + 64
	var cfar := Chunk.new(g_chunk_x(far), g_chunk_x(far)); g.generate(cfar)
	var any_solid := false
	for y in range(Chunk.SY):
		if cfar.get_block(far % Chunk.SX, y, far % Chunk.SX) != 0:
			any_solid = true
	check(not any_solid, "界外整列空气（浮空）")

	# 扇区划分：9 格各自落到 0..8，中心格=4（PLAZA）
	check(g.sector_cell(0, 0) == 4, "原点落在中央格(=4)")
	var corners := {}
	for sx in [-IslandGenerator.HALF + 8, 0, IslandGenerator.HALF - 8]:
		for sz in [-IslandGenerator.HALF + 8, 0, IslandGenerator.HALF - 8]:
			corners[g.sector_cell(sx, sz)] = true
	check(corners.size() == 9, "九宫格采样覆盖全部 9 个扇区")

	if failed == 0: print("✅ ALL ISLANDGEN TESTS PASSED")
	else: printerr("❌ ", failed, " 个 IslandGenerator 测试失败")
	quit(0 if failed == 0 else 1)

# 把世界坐标映射到所在区块的区块坐标（仅测试辅助）
func g_chunk_x(w: int) -> int:
	return floori(float(w) / Chunk.SX)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --script res://tests/test_island_generator.gd`
Expected: FAIL / 加载错误（`IslandGenerator.gd` 尚不存在）。

- [ ] **Step 3: 写最小实现** — `scripts/IslandGenerator.gd`

```gdscript
extends RefCounted
# IslandGenerator —— 有限浮空主题岛的确定性生成器。
# 与 WorldGenerator 同接口（generate/surface_height/region_label/region_description），供 WorldData 按 kind 选用。
# 纯函数：仅依赖 (seed, wx, wz)；generate 不触碰任何全局可变状态，可在后台线程安全调用。
const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

const ISLAND_SIZE := 512           # 岛边长（格）
const HALF := 256                  # = ISLAND_SIZE / 2
const SECTORS := 3                 # 3×3 扇区
const BASE_Y := 40                 # 岛面基准高度
const FLOOR_Y := 24                # 岛体底壳；其下为空气（浮空）
const WATER_Y := 38                # 水面（含水扇区）
const EDGE := 10                   # 边缘崖壁余量带

enum Theme { SNOW, DESERT, TROPICAL, VILLAGE, PLAZA, CYBER, OBSERVATORY, FARM, BAY }
const CELL_THEME := [
	Theme.SNOW, Theme.DESERT, Theme.TROPICAL,        # 北排：西→东
	Theme.VILLAGE, Theme.PLAZA, Theme.CYBER,         # 中排
	Theme.OBSERVATORY, Theme.FARM, Theme.BAY,        # 南排
]

var _seed := 1337
func _init(world_seed: int = 1337) -> void:
	_seed = world_seed

func inside(wx: int, wz: int) -> bool:
	return absi(wx) <= HALF and absi(wz) <= HALF

# (wx,wz) -> 扇区索引 0..8（row*3+col；col 按 x 西→东，row 按 z 北→南）
func sector_cell(wx: int, wz: int) -> int:
	var span := float(ISLAND_SIZE) / float(SECTORS)
	var col := clampi(int(floor((float(wx) + HALF) / span)), 0, SECTORS - 1)
	var row := clampi(int(floor((float(wz) + HALF) / span)), 0, SECTORS - 1)
	return row * SECTORS + col

func theme_at(wx: int, wz: int) -> int:
	return CELL_THEME[sector_cell(wx, wz)]

func surface_height(wx: int, wz: int) -> int:
	if not inside(wx, wz):
		return 0
	return BASE_Y

# 仅测试辅助：取某列地表方块（避免测试里手算 index）。
func get_top_block_for_test(wx: int, wz: int) -> int:
	var ch := Chunk.new(floori(float(wx) / Chunk.SX), floori(float(wz) / Chunk.SZ))
	generate(ch)
	return ch.get_block(posmod(wx, Chunk.SX), surface_height(wx, wz), posmod(wz, Chunk.SZ))

func generate(chunk: Chunk) -> void:
	for lx in range(Chunk.SX):
		for lz in range(Chunk.SZ):
			var wx := chunk.cx * Chunk.SX + lx
			var wz := chunk.cz * Chunk.SZ + lz
			if not inside(wx, wz):
				continue   # 界外：保持空气（浮空）
			var top := surface_height(wx, wz)
			for y in range(FLOOR_Y, top):
				chunk.set_block(lx, y, lz, BlockLibrary.STONE)
			chunk.set_block(lx, top, lz, BlockLibrary.GRASS)

func region_label(_wx: int, _wz: int) -> String:
	return "主题岛"

func region_description(_wx: int, _wz: int) -> String:
	return "一座浮空的主题岛。"
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --script res://tests/test_island_generator.gd`
Expected: `✅ ALL ISLANDGEN TESTS PASSED`

- [ ] **Step 5: 提交**

```bash
git add scripts/IslandGenerator.gd tests/test_island_generator.gd
git commit -m "feat(themed-island): IslandGenerator skeleton — bounded floating slab + 3x3 sectors (TDD)"
```

---

### Task 2: WorldData 按 kind 分派生成器（infinite 回归保护）

**Files:**
- Modify: `scripts/WorldData.gd:6-17`
- Test: `tests/test_world_kind.gd`

- [ ] **Step 1: 写失败测试** — `tests/test_world_kind.gd`

```gdscript
extends SceneTree
# 世界 kind 分派：infinite 仍用 WorldGenerator（回归）；themed_island 用 IslandGenerator。
const WorldData = preload("res://scripts/WorldData.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")
const Chunk = preload("res://scripts/Chunk.gd")

var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	# 默认 = infinite，且与直接用 WorldGenerator 的样本一致（回归保护）
	var wd := WorldData.new(1337)
	check(wd.world_kind() == "infinite", "默认 kind == infinite")
	var gen := WorldGenerator.new(1337)
	var ref := Chunk.new(0, 0); gen.generate(ref)
	check(wd.get_block(8, gen.surface_height(8, 8), 8) == ref.get_block(8, gen.surface_height(8, 8), 8), "infinite 路径与 WorldGenerator 一致")

	# themed_island：远在岛外的列应为空气（无限世界几乎不可能整列空气）
	var isl := WorldData.new(1337, "themed_island")
	check(isl.world_kind() == "themed_island", "kind == themed_island")
	var far := 4000
	var any_solid := false
	for y in range(0, 80):
		if isl.get_block(far, y, far) != 0:
			any_solid = true
	check(not any_solid, "themed_island 岛外列为空气")

	if failed == 0: print("✅ ALL WORLDKIND TESTS PASSED")
	else: printerr("❌ ", failed, " 个 kind 测试失败")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --script res://tests/test_world_kind.gd`
Expected: FAIL（`world_kind()` 未定义 / themed_island 仍用了无限生成器）。

- [ ] **Step 3: 改 `scripts/WorldData.gd`** —— 头部 preload + `_init` + 新增 `world_kind()`

把开头 6-20 行：

```gdscript
const Chunk = preload("res://scripts/Chunk.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")

var _gen: WorldGenerator
var _world_seed := 1337
var _chunks := {}              # Vector2i -> Chunk
var _deltas := {}
var _revisions := {}

func _init(world_seed: int = 1337) -> void:
	_world_seed = world_seed
	_gen = WorldGenerator.new(world_seed)
```

改为：

```gdscript
const Chunk = preload("res://scripts/Chunk.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")
const IslandGenerator = preload("res://scripts/IslandGenerator.gd")

var _gen                       # WorldGenerator 或 IslandGenerator（同接口）
var _kind := "infinite"
var _world_seed := 1337
var _chunks := {}              # Vector2i -> Chunk
var _deltas := {}
var _revisions := {}

func _init(world_seed: int = 1337, kind: String = "infinite") -> void:
	_world_seed = world_seed
	_kind = kind
	if kind == "themed_island":
		_gen = IslandGenerator.new(world_seed)
	else:
		_gen = WorldGenerator.new(world_seed)

func world_kind() -> String:
	return _kind
```

> 其余方法（`surface_y`/`region_label`/`region_description`/`ensure_data`/`_base_block`）都通过 `_gen.xxx` 调用，两个生成器同接口，无需改动。

- [ ] **Step 4: 跑测试确认通过（含全量回归）**

Run: `godot --headless --path . --script res://tests/test_world_kind.gd`
Expected: `✅ ALL WORLDKIND TESTS PASSED`
Run: `godot --headless --path . --script res://tests/test_world_data.gd`
Expected: `✅ ALL WORLDDATA TESTS PASSED`（确认 infinite 路径未被破坏）

- [ ] **Step 5: 提交**

```bash
git add scripts/WorldData.gd tests/test_world_kind.gd
git commit -m "feat(themed-island): WorldData dispatches generator by world kind (infinite unchanged)"
```

---

### Task 3: 各扇区主题地表 + 边缘崖壁/水环 + 分区 region_label

**Files:**
- Modify: `scripts/IslandGenerator.gd`（替换 `surface_height` / `generate` / `region_label`，新增主题表与高度/方块辅助）
- Test: `tests/test_island_generator.gd`（追加断言）

- [ ] **Step 1: 追加失败断言** —— 在 `tests/test_island_generator.gd` 的 `if failed == 0` 之前插入：

```gdscript
	# 各扇区地表方块属于其主题族
	var snow_xz := [-IslandGenerator.HALF + 40, -IslandGenerator.HALF + 40]   # 北-西 = 雪山
	check(g.get_top_block_for_test(snow_xz[0], snow_xz[1]) == BlockLibrary.SNOW, "雪山扇区地表=雪")
	var desert_xz := [0, -IslandGenerator.HALF + 40]                          # 北-中 = 沙漠
	var dtop := g.get_top_block_for_test(desert_xz[0], desert_xz[1])
	check(dtop == BlockLibrary.SAND or dtop == BlockLibrary.RED_SAND, "沙漠扇区地表=沙/红沙")
	var cyber_xz := [IslandGenerator.HALF - 40, 0]                            # 中-东 = 赛博
	check(g.get_top_block_for_test(cyber_xz[0], cyber_xz[1]) == BlockLibrary.STEEL_BLOCK, "赛博扇区地基=钢块")
	var obs_xz := [-IslandGenerator.HALF + 40, IslandGenerator.HALF - 40]     # 南-西 = 天文台
	check(g.get_top_block_for_test(obs_xz[0], obs_xz[1]) == BlockLibrary.MARBLE, "天文台扇区地基=大理石")

	# region_label 在不同扇区给出不同标签
	check(g.region_label(snow_xz[0], snow_xz[1]) != g.region_label(cyber_xz[0], cyber_xz[1]), "不同扇区 region_label 不同")

	# 边缘：紧贴边界处地表显著低于中心（崖壁），且边界外侧为水或空
	check(g.surface_height(0, 0) - g.surface_height(IslandGenerator.HALF - 1, 0) >= IslandGenerator.EDGE - 1, "边缘地表跌落成崖")
```

(顶部 `const` 区加上 `const BlockLibrary = preload("res://scripts/BlockLibrary.gd")` 以便测试引用。)

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --script res://tests/test_island_generator.gd`
Expected: FAIL（地表全是 GRASS，主题/崖壁断言不满足）。

- [ ] **Step 3: 替换 `IslandGenerator.gd` 的地形逻辑**

主题地表表 + 高度/方块函数（加在 `theme_at` 之后）：

```gdscript
# 每个主题的地表：{top=地表块, sub=次表层填充块, water=是否注水}
const THEME_SURFACE := {
	Theme.SNOW:        {"top": BlockLibrary.SNOW,        "sub": BlockLibrary.STONE, "water": false},
	Theme.DESERT:      {"top": BlockLibrary.SAND,        "sub": BlockLibrary.RED_SAND, "water": false},
	Theme.TROPICAL:    {"top": BlockLibrary.GRASS,       "sub": BlockLibrary.DIRT,  "water": true},
	Theme.VILLAGE:     {"top": BlockLibrary.GRASS,       "sub": BlockLibrary.DIRT,  "water": false},
	Theme.PLAZA:       {"top": BlockLibrary.GRASS,       "sub": BlockLibrary.DIRT,  "water": false},
	Theme.CYBER:       {"top": BlockLibrary.STEEL_BLOCK, "sub": BlockLibrary.STONE, "water": false},
	Theme.OBSERVATORY: {"top": BlockLibrary.MARBLE,      "sub": BlockLibrary.STONE, "water": false},
	Theme.FARM:        {"top": BlockLibrary.DIRT,        "sub": BlockLibrary.DIRT,  "water": false},
	Theme.BAY:         {"top": BlockLibrary.SAND,        "sub": BlockLibrary.SAND,  "water": true},
}

# 确定性伪噪声 [-1,1]（无需 FastNoiseLite；同 seed 同坐标恒定）
func _noise(a: int, b: int) -> float:
	var n: int = (a * 73856093) ^ (b * 19349663) ^ (_seed * 83492791)
	n = (n << 13) ^ n
	var m: int = (n * (n * n * 15731 + 789221) + 1376312589) & 0x7fffffff
	return 1.0 - float(m) / 1073741824.0

func _theme_height(theme: int, wx: int, wz: int) -> int:
	match theme:
		Theme.SNOW:
			return BASE_Y + 6 + int(round(10.0 * absf(_noise(wx >> 3, wz >> 3))))   # 雪峰
		Theme.DESERT:
			return BASE_Y + int(round(3.0 * _noise(wx >> 4, wz >> 4)))              # 沙丘
		Theme.BAY:
			return BASE_Y - 4                                                       # 海湾低地（水下）
		Theme.TROPICAL:
			return BASE_Y - (1 if _noise(wx >> 4, wz >> 4) < -0.3 else 0)           # 偶有浅滩
		_:
			return BASE_Y
```

替换 `surface_height`：

```gdscript
func surface_height(wx: int, wz: int) -> int:
	if not inside(wx, wz):
		return 0
	var h := _theme_height(theme_at(wx, wz), wx, wz)
	var edge_d := HALF - maxi(absi(wx), absi(wz))   # 到最近边界的距离
	if edge_d < EDGE:
		h -= (EDGE - edge_d) * 2                     # 边缘跌落成崖
	return maxi(h, FLOOR_Y + 1)
```

替换 `generate`：

```gdscript
func generate(chunk: Chunk) -> void:
	for lx in range(Chunk.SX):
		for lz in range(Chunk.SZ):
			var wx := chunk.cx * Chunk.SX + lx
			var wz := chunk.cz * Chunk.SZ + lz
			if not inside(wx, wz):
				continue
			var theme := theme_at(wx, wz)
			var surf: Dictionary = THEME_SURFACE[theme]
			var top := surface_height(wx, wz)
			for y in range(FLOOR_Y, top):
				chunk.set_block(lx, y, lz, surf["sub"])
			chunk.set_block(lx, top, lz, surf["top"])
			# 含水扇区 / 低于水面处注水到 WATER_Y
			if surf["water"]:
				for y in range(top + 1, WATER_Y + 1):
					chunk.set_block(lx, y, lz, BlockLibrary.WATER)
```

替换 `region_label`（按扇区给名）：

```gdscript
const THEME_LABEL := {
	Theme.SNOW: "雪山", Theme.DESERT: "沙漠", Theme.TROPICAL: "热带海岸",
	Theme.VILLAGE: "村庄", Theme.PLAZA: "中央广场", Theme.CYBER: "霓虹城",
	Theme.OBSERVATORY: "天文台", Theme.FARM: "农田", Theme.BAY: "海湾",
}
func region_label(wx: int, wz: int) -> String:
	if not inside(wx, wz):
		return "虚空"
	return THEME_LABEL[theme_at(wx, wz)]
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --script res://tests/test_island_generator.gd`
Expected: `✅ ALL ISLANDGEN TESTS PASSED`

- [ ] **Step 5: 提交**

```bash
git add scripts/IslandGenerator.gd tests/test_island_generator.gd
git commit -m "feat(themed-island): per-sector themed terrain + edge cliffs + water + region labels (TDD)"
```

---

### Task 4: World.setup 携带 kind + 存档写入 kind

**Files:**
- Modify: `scripts/World.gd:73`（`setup` 签名 + `_world_kind`）、`scripts/World.gd:582`（save 数据）
- Test: `tests/test_island_save.gd`

- [ ] **Step 1: 写失败测试** — `tests/test_island_save.gd`

```gdscript
extends SceneTree
# World 携带 kind 并写入存档；themed_island 世界数据用 IslandGenerator。
const World = preload("res://scripts/World.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var path := "user://tests/island_save.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://tests"))
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	var lib := BlockLibrary.new()
	var w := World.new()
	root.add_child(w)
	w.setup(lib, 1337, path, "themed_island")
	check(w.world_kind() == "themed_island", "World.world_kind == themed_island")
	# 岛外列为空气（证明确实用了 IslandGenerator）
	check(w.get_block(4000, 50, 4000) == 0, "岛外列空气（IslandGenerator 生效）")
	check(w.save_world(true), "save_world 成功")

	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(typeof(data) == TYPE_DICTIONARY and str((data as Dictionary).get("kind", "")) == "themed_island", "存档写入 kind=themed_island")

	if failed == 0: print("✅ ALL ISLAND SAVE TESTS PASSED")
	else: printerr("❌ ", failed, " 个存档测试失败")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --script res://tests/test_island_save.gd`
Expected: FAIL（`setup` 不接受第 4 参 / `world_kind()` 未定义 / 存档无 kind）。

- [ ] **Step 3: 改 `scripts/World.gd`**

在变量区（与 `_world_seed` 相邻）新增：

```gdscript
var _world_kind := "infinite"
```

把 `setup`（73 行起）签名与建 WorldData 改为：

```gdscript
func setup(block_lib: BlockLibrary, world_seed: int = 1337, save_file: String = "", kind: String = "infinite") -> void:
	lib = block_lib
	_world_seed = world_seed
	_world_kind = kind
	save_path = save_file
	_data = WorldData.new(world_seed, kind)
```

（其余 `setup` 内容不变。）新增读取器（放在 `setup` 之后）：

```gdscript
func world_kind() -> String:
	return _world_kind
```

在 `save_world` 的 `data` 字典（582 行）里 `"seed": _world_seed,` 下一行加：

```gdscript
		"kind": _world_kind,
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --script res://tests/test_island_save.gd`
Expected: `✅ ALL ISLAND SAVE TESTS PASSED`

- [ ] **Step 5: 提交**

```bash
git add scripts/World.gd tests/test_island_save.gd
git commit -m "feat(themed-island): World.setup carries world kind; save persists it"
```

---

### Task 5: WorldCatalog 读出 kind（继续世界用）

**Files:**
- Modify: `scripts/WorldCatalog.gd:140`（`_read_world_meta` 返回字典加 `kind`）
- Test: `tests/test_island_save.gd`（追加断言：写完读 meta 拿到 kind）

- [ ] **Step 1: 追加失败断言** —— 在 `tests/test_island_save.gd` 顶部 const 区加 `const WorldCatalog = preload("res://scripts/WorldCatalog.gd")`；在 `save_world` 断言之后插入：

```gdscript
	var meta := WorldCatalog._read_world_meta(path)
	check(not meta.is_empty() and str(meta.get("kind", "")) == "themed_island", "WorldCatalog 读出 kind=themed_island")
	# 旧存档（无 kind 字段）默认 infinite
	var legacy := "user://tests/legacy.json"
	var lf := FileAccess.open(legacy, FileAccess.WRITE)
	lf.store_string(JSON.stringify({"seed": 5, "edits": {}})); lf.close()
	check(str(WorldCatalog._read_world_meta(legacy).get("kind", "")) == "infinite", "旧存档默认 kind=infinite")
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --script res://tests/test_island_save.gd`
Expected: FAIL（meta 无 `kind`）。

- [ ] **Step 3: 改 `scripts/WorldCatalog.gd`** —— 在 `_read_world_meta` 返回字典里（`"seed": seed,` 附近）加一行：

```gdscript
		"kind": String(data.get("kind", "infinite")),
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --script res://tests/test_island_save.gd`
Expected: `✅ ALL ISLAND SAVE TESTS PASSED`

- [ ] **Step 5: 提交**

```bash
git add scripts/WorldCatalog.gd tests/test_island_save.gd
git commit -m "feat(themed-island): WorldCatalog reads world kind from save meta"
```

---

### Task 6: TitleScreen 世界类型开关 + 信号带 kind

**Files:**
- Modify: `scripts/TitleScreen.gd:5`（信号）、`:295`（`_new_seed_panel` 加开关）、`:361`（`_on_new_world_pressed`）
- Test: `tests/test_title_world_kind.gd`

- [ ] **Step 1: 写失败测试** — `tests/test_title_world_kind.gd`

```gdscript
extends SceneTree
# 标题页：选"主题岛"后，new_world_requested 携带 kind=themed_island。
const TitleScreen = preload("res://scripts/TitleScreen.gd")

var failed := 0
var captured := []
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var ts := TitleScreen.new()
	root.add_child(ts)
	ts.setup([], 1337, 1337)
	ts.new_world_requested.connect(func(seed, kind): captured = [seed, kind])

	# 默认 infinite
	ts._on_new_world_pressed()
	check(captured.size() == 2 and captured[1] == "infinite", "默认新世界 kind=infinite")

	# 选主题岛后再创建
	ts.set_new_kind_for_test("themed_island")
	ts._on_new_world_pressed()
	check(captured[1] == "themed_island", "选主题岛后 kind=themed_island")

	if failed == 0: print("✅ ALL TITLE KIND TESTS PASSED")
	else: printerr("❌ ", failed, " 个标题 kind 测试失败")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --script res://tests/test_title_world_kind.gd`
Expected: FAIL（信号只有 1 参 / `set_new_kind_for_test` 未定义）。

- [ ] **Step 3: 改 `scripts/TitleScreen.gd`**

信号（第 5 行）改为：

```gdscript
signal new_world_requested(seed: int, kind: String)
```

变量区（`_new_seed := 1337` 附近）新增：

```gdscript
var _new_kind := "infinite"
var _kind_button: CheckButton
```

`_new_seed_panel()` 内，在 `box.add_child(_new_seed_name_label)` 之后、`return box` 之前插入开关：

```gdscript
	_kind_button = CheckButton.new()
	_kind_button.text = "主题岛（浮空·分区主题）"
	_kind_button.tooltip_text = "开：生成有限浮空主题岛；关：经典无限世界"
	_kind_button.add_theme_font_size_override("font_size", 13)
	_kind_button.toggled.connect(func(on): _new_kind = "themed_island" if on else "infinite")
	box.add_child(_kind_button)
```

`_on_new_world_pressed()`（361 行）改为：

```gdscript
func _on_new_world_pressed() -> void:
	new_world_requested.emit(_new_world_seed(), _new_kind)
```

文件末尾新增测试辅助：

```gdscript
# 仅测试用：直接设定世界类型（绕过 UI 勾选）。
func set_new_kind_for_test(kind: String) -> void:
	_new_kind = kind
	if _kind_button != null:
		_kind_button.set_pressed_no_signal(kind == "themed_island")
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --script res://tests/test_title_world_kind.gd`
Expected: `✅ ALL TITLE KIND TESTS PASSED`

- [ ] **Step 5: 提交**

```bash
git add scripts/TitleScreen.gd tests/test_title_world_kind.gd
git commit -m "feat(themed-island): title screen world-type toggle; new_world_requested carries kind"
```

---

### Task 7: Main 跨重载传 kind（新建用环境变量，继续读存档）

**Files:**
- Modify: `scripts/Main.gd:158`（`_enter_world` 解析并传 kind）、`:1299`（`_start_new_world` 带 kind + 设环境变量）、信号连接处（`new_world_requested.connect`）
- Test: 手动验证（Main 是重型 Node，逻辑已被 Task 4/5/6 的单测覆盖；此处只接线）

- [ ] **Step 1: 新增 kind 解析器** —— 在 `Main.gd` 的 `_save_path_for_seed`（455 行）附近新增：

```gdscript
# 解析本次进入世界的 kind：存档已存在 -> 读存档元数据；否则看新建时设的环境变量；再否则 infinite。
func _resolve_world_kind(save_file: String) -> String:
	var meta := WorldCatalog._read_world_meta(save_file)
	if not meta.is_empty():
		return str(meta.get("kind", "infinite"))
	if OS.has_environment("VC_WORLD_KIND"):
		return OS.get_environment("VC_WORLD_KIND")
	return "infinite"
```

- [ ] **Step 2: `_enter_world` 传 kind** —— 把 161-162 行：

```gdscript
	var save_file := _save_path_for_seed(_current_seed)
	world.setup(lib, _current_seed, save_file)
```

改为：

```gdscript
	var save_file := _save_path_for_seed(_current_seed)
	var kind := _resolve_world_kind(save_file)
	world.setup(lib, _current_seed, save_file, kind)
```

- [ ] **Step 3: `_start_new_world` 带 kind + 设环境变量** —— 把 1299 行起改为：

```gdscript
func _start_new_world(seed: int = 0, kind: String = "infinite") -> void:
	if world != null:
		world.save_world(true)
	var next_seed := seed if seed > 0 else _random_seed()
	OS.set_environment("VC_SEED", str(next_seed))
	OS.set_environment("VC_WORLD_KIND", kind)
	get_tree().paused = false
	get_tree().reload_current_scene()
```

> `title_screen.new_world_requested.connect(_start_new_world)`（约 298 行）无需改：信号现发 `(seed, kind)` 两参，正好对上新签名。`_continue_selected_world` 无需改：继续世界时 `_resolve_world_kind` 会从存档读回 kind。

- [ ] **Step 4: 手动冒烟** —— 起一个主题岛世界确认能进：

```bash
VC_SEED=2026 VC_WORLD_KIND=themed_island VC_SKIP_TITLE=1 godot --path . 2>&1 | head -20
```
Expected: 正常进入世界、打印"脚下区域就绪 …"，无 Parse/Script Error；俯瞰可见有限浮空岛（下一步截图验证）。手动关闭窗口。

- [ ] **Step 5: 提交**

```bash
git add scripts/Main.gd
git commit -m "feat(themed-island): Main resolves world kind across scene reload (new=env, continue=save)"
```

---

### Task 8: 多人 —— welcome 携带 kind，服务器/客户端按 kind 重生

**Files:**
- Modify: `scripts/NetworkManager.gd`（`world_kind` 字段、`build_welcome` 带 kind、`apply_welcome` 存下）、`scripts/Main.gd`（dedicated server / host 设 kind；`_on_welcomed` 用 kind 建世界）
- Test: `tests/test_island_multiplayer.gd`

- [ ] **Step 1: 写失败测试** — `tests/test_island_multiplayer.gd`

```gdscript
extends SceneTree
# 多人：welcome 携带 kind；客户端按 (seed,kind) 重生出与服务器一致的岛外列（空气）。
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")

var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var nm := NetworkManager.new()
	nm.mode = NetworkManager.Mode.SERVER
	nm.world_kind = "themed_island"
	var data := WorldData.new(2026, "themed_island")
	nm.set_authority_data(data, 2026, Vector3(0, 50, 0))
	nm.register_peer(7, "tester")
	var welcome := nm.build_welcome(7)
	check(str(welcome.get("kind", "")) == "themed_island", "welcome 携带 kind=themed_island")
	check(int(welcome.get("seed", 0)) == 2026, "welcome 携带 seed")

	# 客户端据 welcome 的 (seed,kind) 重建，岛外列与服务器一致（皆空气）
	var client := WorldData.new(int(welcome["seed"]), str(welcome["kind"]))
	check(client.get_block(4000, 50, 4000) == data.get_block(4000, 50, 4000), "客户端按 kind 重生与服务器一致")

	if failed == 0: print("✅ ALL ISLAND MP TESTS PASSED")
	else: printerr("❌ ", failed, " 个多人测试失败")
	quit(0 if failed == 0 else 1)
```

- [ ] **Step 2: 跑测试确认失败**

Run: `godot --headless --path . --script res://tests/test_island_multiplayer.gd`
Expected: FAIL（`world_kind` 未定义 / welcome 无 kind）。

- [ ] **Step 3: 改 `scripts/NetworkManager.gd`**

在字段区（`var world_save_path := ""` 附近）新增：

```gdscript
var world_kind := "infinite"     # 权威世界的类型（infinite / themed_island），随 welcome 下发给客户端
```

`build_welcome` 返回字典里加 `"kind": world_kind`：

```gdscript
	return {
		"seed": _seed,
		"kind": world_kind,
		"spawn": [_spawn.x, _spawn.y, _spawn.z],
		"your_eid": str(_peers.get(peer_id, {}).get("eid", "")),
		"peers": roster,
		"deltas": _data.all_deltas(),
	}
```

`apply_welcome` 开头存下 kind（供 Main 读取）：

```gdscript
func apply_welcome(payload: Dictionary) -> void:
	_seed = int(payload.get("seed", 1337))
	world_kind = str(payload.get("kind", "infinite"))
	var sp: Array = payload.get("spawn", [0, 0, 0])
	if sp.size() == 3:
		_spawn = Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
```

- [ ] **Step 4: 跑测试确认通过**

Run: `godot --headless --path . --script res://tests/test_island_multiplayer.gd`
Expected: `✅ ALL ISLAND MP TESTS PASSED`

- [ ] **Step 5: 接线 Main（server / host / client 用 kind）**

`_start_dedicated_server`（约 393 行）：建 WorldData 时带 kind，并设 net_manager.world_kind。把

```gdscript
	var data := WorldData.new(_current_seed)
```
改为
```gdscript
	var server_kind := _resolve_world_kind(_server_save_path())
	if OS.has_environment("VC_WORLD_KIND"):
		server_kind = OS.get_environment("VC_WORLD_KIND")
	var data := WorldData.new(_current_seed, server_kind)
```
并在该函数内 `add_child(net_manager)` 之前加：
```gdscript
	net_manager.world_kind = server_kind
```

HOST 路径（`_start_host_after_enter`，约 420 行，`set_authority_data(world._data, ...)` 附近）加一行，让房主下发自己世界的 kind：
```gdscript
	net_manager.world_kind = world.world_kind()
```

CLIENT 路径 `_on_welcomed`（约 440 行）—— 客户端建世界时用 welcome 的 kind。该函数当前调用 `_enter_world(int(payload.get("seed", _current_seed)), spawn)`；客户端世界**不从存档读 kind**（客户端无该存档），需直接用 payload 的 kind。最稳妥：在调用前设环境变量，让 `_resolve_world_kind` 命中：
```gdscript
	OS.set_environment("VC_WORLD_KIND", str(payload.get("kind", "infinite")))
	_enter_world(int(payload.get("seed", _current_seed)), spawn)
```

- [ ] **Step 6: 跑回归 + 提交**

Run: `godot --headless --path . --script res://tests/test_island_multiplayer.gd`（仍 PASS）
Run: `godot --headless --path . --script res://tests/test_agent_bridge_multi.gd`（确认多人/桥未坏）
Expected: 皆 PASS

```bash
git add scripts/NetworkManager.gd scripts/Main.gd tests/test_island_multiplayer.gd
git commit -m "feat(themed-island): multiplayer welcome carries world kind; server/host/client regen by kind (TDD)"
```

---

### Task 9: 全量自检 + 俯瞰截图（人工肉眼确认）

**Files:**
- Create: `tests/shot_island.gd`

- [ ] **Step 1: 跑全部 headless 自检**

Run: `bash tests/run_all.sh`
Expected: `✅ 全部通过`（新增的 `test_island_generator` / `test_world_kind` / `test_island_save` / `test_title_world_kind` / `test_island_multiplayer` 均被自动发现并通过，且原有测试不回归）。

- [ ] **Step 2: 写俯瞰截图脚本** — `tests/shot_island.gd`

```gdscript
extends SceneTree
# 俯瞰主题岛截图（需渲染，勿加 --headless）：
#   VC_SEED=2026 godot --path . --script res://tests/shot_island.gd
const World = preload("res://scripts/World.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

func _initialize() -> void:
	var lib := BlockLibrary.new()
	var w := World.new()
	root.add_child(w)
	w.setup(lib, 2026, "", "themed_island")
	w.set_view_radius(6)
	# 把视野中心放到岛中心，预热若干区块
	w.prime(Vector2i(0, 0), 6)
	var cam := Camera3D.new()
	root.add_child(cam)
	cam.global_position = Vector3(0, 180, 220)
	cam.look_at(Vector3(0, 40, 0), Vector3.UP)
	cam.current = true
	await create_timer(2.0).timeout
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("res://_shot_island.png"))
	print("PLAY OK: wrote _shot_island.png")
	quit(0)
```

> `run_all.sh` 只跑 `test_*.gd`，本文件名为 `shot_*.gd`，不会进自动套件（与现有 `shot_*.gd` 一致）。

- [ ] **Step 3: 生成截图并肉眼确认**

Run: `VC_SEED=2026 godot --path . --script res://tests/shot_island.gd`
Expected: 项目根生成 `_shot_island.png`；打开应能看到一座**有限浮空岛**、可分辨多块不同主题地表（雪白/沙黄/草绿/钢灰/大理石白/水蓝），边缘成崖。

- [ ] **Step 4: 提交**

```bash
git add tests/shot_island.gd
git commit -m "test(themed-island): aerial screenshot script for SP1 island"
```

---

## 自检（计划 vs spec）

**Spec 覆盖：** 新世界类型(kind)✓(T2/T4/T5) · 有限浮空岛+界外空气✓(T1) · 边缘崖壁/水环✓(T3) · 3×3 扇区→主题✓(T1/T3) · 现有方块铺主题地表✓(T3) · 出生中心(PLAZA=grass)✓(T1/T3) · 标题入口✓(T6) · 跨重载/持久化 kind✓(T5/T7) · 多人 welcome 带 kind✓(T8) · 自检+截图✓(T9)。无遗漏。

**占位符扫描：** 无 TBD/TODO；每个改代码的步骤都给了完整代码块与确切命令/期望输出。

**类型一致性：** `world_kind()`（WorldData/World）、`world_kind`（NetworkManager 字段）、`_new_kind`/`set_new_kind_for_test`（TitleScreen）、`_resolve_world_kind`（Main）、`sector_cell`/`theme_at`/`inside`/`surface_height`/`generate`（IslandGenerator）跨任务命名一致；`kind` 取值统一为 `"infinite"` / `"themed_island"`；`WorldData.new(seed, kind)` 全程二参一致。

**已知风险/留意：** Task 4/6/9 的测试会实例化 `BlockLibrary.new()` 与 `World`/`TitleScreen` 节点（headless 下需 `root.add_child`）——与现有 `test_save.gd`/`test_title_*.gd` 同模式，可行。`shot_island.gd` 需真实渲染，勿加 `--headless`。
