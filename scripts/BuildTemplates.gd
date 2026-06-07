extends RefCounted
# 建造模板的"纯几何"模块（无节点、无 Player 状态）：把方块清单算法从 Player.gd 抽出来，
# 让无头服务器（没有 Player 节点）也能复用同一套模板。所有函数都是 STATIC，只吃显式参数。
#
# 设计：
# - 简单模板（platform/pillar/arch/wall/stairs/room_frame）只描述"格子"，由调用方填入当前选中方块
#   （default_block_id）。
# - 装饰模板（cabin/campfire/bridge/garden/beacon_tower/signpost）自带方块 id，写在各自的 _*_edits()。
# - 朝向：orientation 0=东西，1=南北；right/depth 轴随之互换（与 Player._template_right_axis 一致）。
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

const TEMPLATE_IDS := ["platform","pillar","arch","wall","stairs","room_frame",
	"cabin","campfire","bridge","garden","beacon_tower","signpost"]
const DECORATED := ["cabin","campfire","bridge","garden","beacon_tower","signpost"]

# 公共入口：按模板 id 在锚点 origin 以朝向 orientation 算出 [{"pos":Vector3i,"id":int}, ...]。
# 简单模板用 default_block_id 填充；装饰模板自带方块 id；未知模板返回 []。
static func edits_for(template_id: String, origin: Vector3i, orientation: int, default_block_id: int) -> Array:
	var o := posmod(orientation, 2)
	match template_id:
		"campfire":
			return _campfire_edits(origin, o)
		"bridge":
			return _bridge_edits(origin, o)
		"garden":
			return _garden_edits(origin, o)
		"cabin":
			return _cabin_edits(origin, o)
		"beacon_tower":
			return _beacon_tower_edits(origin, o)
		"signpost":
			return _signpost_edits(origin, o)
		"platform", "pillar", "arch", "wall", "stairs", "room_frame":
			var out := []
			for cell in _cells(template_id, origin, o):
				out.append({"pos": cell, "id": default_block_id})
			return out
	return []

# ---------- 朝向轴 ----------
static func _right_axis(orientation: int) -> Vector3i:
	return Vector3i.RIGHT if orientation == 0 else Vector3i(0, 0, 1)

static func _depth_axis(orientation: int) -> Vector3i:
	return Vector3i(0, 0, 1) if orientation == 0 else Vector3i.RIGHT

# ---------- 简单模板（仅几何） ----------
static func _cells(template_id: String, origin: Vector3i, orientation: int) -> Array:
	match template_id:
		"platform":
			return _platform_cells(origin, orientation)
		"pillar":
			return _pillar_cells(origin)
		"arch":
			return _arch_cells(origin, orientation)
		"wall":
			return _wall_cells(origin, orientation)
		"stairs":
			return _stairs_cells(origin, orientation)
		"room_frame":
			return _room_frame_cells(origin, orientation)
	return []

static func _platform_cells(origin: Vector3i, orientation: int) -> Array:
	var axis_a := _right_axis(orientation)
	var axis_b := _depth_axis(orientation)
	var cells := []
	for b in range(-2, 3):
		for a in range(-2, 3):
			cells.append(origin + axis_a * a + axis_b * b)
	return cells

static func _pillar_cells(origin: Vector3i) -> Array:
	var cells := []
	for y in range(0, 5):
		cells.append(origin + Vector3i.UP * y)
	return cells

static func _arch_cells(origin: Vector3i, orientation: int) -> Array:
	var right := _right_axis(orientation)
	var up := Vector3i.UP
	var cells := []
	for y in range(0, 4):
		cells.append(origin + right * -2 + up * y)
		cells.append(origin + right * 2 + up * y)
	for x in range(-2, 3):
		cells.append(origin + right * x + up * 4)
	return cells

static func _wall_cells(origin: Vector3i, orientation: int) -> Array:
	var right := _right_axis(orientation)
	var up := Vector3i.UP
	var cells := []
	for y in range(0, 3):
		for x in range(-2, 3):
			cells.append(origin + right * x + up * y)
	return cells

static func _stairs_cells(origin: Vector3i, orientation: int) -> Array:
	var right := _right_axis(orientation)
	var forward := _depth_axis(orientation)
	var up := Vector3i.UP
	var cells := []
	for step in range(0, 5):
		for y in range(0, step + 1):
			for x in range(-1, 2):
				cells.append(origin + right * x + forward * step + up * y)
	return cells

static func _room_frame_cells(origin: Vector3i, orientation: int) -> Array:
	var right := _right_axis(orientation)
	var depth := _depth_axis(orientation)
	var up := Vector3i.UP
	var cells := []
	for sx in [-3, 3]:
		for sz in [-3, 3]:
			for y in range(0, 4):
				cells.append(origin + right * sx + depth * sz + up * y)
	for x in range(-3, 4):
		cells.append(origin + right * x + depth * -3 + up * 4)
		cells.append(origin + right * x + depth * 3 + up * 4)
	for z in range(-2, 3):
		cells.append(origin + right * -3 + depth * z + up * 4)
		cells.append(origin + right * 3 + depth * z + up * 4)
	return cells

# ---------- 装饰模板（自带方块 id） ----------
static func _add_edit(edits: Array, seen: Dictionary, pos: Vector3i, id: int) -> void:
	var key := "%d,%d,%d" % [pos.x, pos.y, pos.z]
	if seen.has(key):
		return
	seen[key] = true
	edits.append({"pos": pos, "id": id})

static func _cabin_edits(origin: Vector3i, orientation: int) -> Array:
	var right := _right_axis(orientation)
	var depth := _depth_axis(orientation)
	var up := Vector3i.UP
	var edits := []
	var seen := {}
	for z in range(-3, 4):
		for x in range(-3, 4):
			_add_edit(edits, seen, origin + right * x + depth * z, BlockLibrary.PLANKS)
	for y in range(1, 4):
		for z in range(-3, 4):
			for x in range(-3, 4):
				if abs(x) != 3 and abs(z) != 3:
					continue
				if z == -3 and x == 0 and y <= 2:
					continue
				var id := BlockLibrary.PLANKS
				if abs(x) == 3 and abs(z) == 3:
					id = BlockLibrary.LOG
				elif y == 2 and ((abs(x) == 3 and z == 0) or (z == 3 and x == 0) or (z == -3 and abs(x) == 1)):
					id = BlockLibrary.GLASS
				_add_edit(edits, seen, origin + right * x + depth * z + up * y, id)
	for z in range(-4, 5):
		for x in range(-4, 5):
			var ax := absi(x)
			var y := 4
			if ax <= 1:
				y = 6
			elif ax <= 3:
				y = 5
			_add_edit(edits, seen, origin + right * x + depth * z + up * y, BlockLibrary.BRICK)
	for x in range(-1, 2):
		_add_edit(edits, seen, origin + right * x + depth * -4, BlockLibrary.COBBLE)
	_add_edit(edits, seen, origin + up * 3, BlockLibrary.LANTERN)
	return edits

static func _campfire_edits(origin: Vector3i, orientation: int) -> Array:
	var right := _right_axis(orientation)
	var depth := _depth_axis(orientation)
	var up := Vector3i.UP
	return [
		{"pos": origin, "id": BlockLibrary.MOONSTONE_LAMP},
		{"pos": origin + up, "id": BlockLibrary.LANTERN},
		{"pos": origin + right, "id": BlockLibrary.LOG},
		{"pos": origin - right, "id": BlockLibrary.LOG},
		{"pos": origin + depth, "id": BlockLibrary.LOG},
		{"pos": origin - depth, "id": BlockLibrary.LOG},
		{"pos": origin + right + depth, "id": BlockLibrary.COBBLE},
		{"pos": origin + right - depth, "id": BlockLibrary.COBBLE},
		{"pos": origin - right + depth, "id": BlockLibrary.COBBLE},
		{"pos": origin - right - depth, "id": BlockLibrary.COBBLE},
	]

static func _bridge_edits(origin: Vector3i, orientation: int) -> Array:
	var right := _right_axis(orientation)
	var depth := _depth_axis(orientation)
	var up := Vector3i.UP
	var edits := []
	for z in range(-3, 4):
		for x in range(-1, 2):
			edits.append({"pos": origin + right * x + depth * z, "id": BlockLibrary.PLANKS})
		edits.append({"pos": origin + right * -2 + depth * z + up, "id": BlockLibrary.LOG})
		edits.append({"pos": origin + right * 2 + depth * z + up, "id": BlockLibrary.LOG})
	for sx in [-2, 2]:
		for sz in [-3, 3]:
			edits.append({"pos": origin + right * sx + depth * sz + up * 2, "id": BlockLibrary.LANTERN})
	return edits

static func _garden_edits(origin: Vector3i, orientation: int) -> Array:
	var right := _right_axis(orientation)
	var depth := _depth_axis(orientation)
	var up := Vector3i.UP
	var edits := []
	for z in range(-2, 3):
		for x in range(-2, 3):
			var id := BlockLibrary.CLAY if abs(x) == 2 or abs(z) == 2 else BlockLibrary.GRASS
			edits.append({"pos": origin + right * x + depth * z, "id": id})
	var plant_plan := [
		{"x": 0, "z": 0, "id": BlockLibrary.RED_MUSHROOM},
		{"x": -1, "z": 0, "id": BlockLibrary.WILDFLOWER},
		{"x": 1, "z": 0, "id": BlockLibrary.WILDFLOWER},
		{"x": 0, "z": -1, "id": BlockLibrary.WILDFLOWER},
		{"x": 0, "z": 1, "id": BlockLibrary.WILDFLOWER},
		{"x": -1, "z": -1, "id": BlockLibrary.TALL_GRASS},
		{"x": 1, "z": -1, "id": BlockLibrary.TALL_GRASS},
		{"x": -1, "z": 1, "id": BlockLibrary.TALL_GRASS},
		{"x": 1, "z": 1, "id": BlockLibrary.TALL_GRASS},
	]
	for raw in plant_plan:
		var item: Dictionary = raw
		edits.append({"pos": origin + right * int(item["x"]) + depth * int(item["z"]) + up, "id": int(item["id"])})
	return edits

static func _beacon_tower_edits(origin: Vector3i, orientation: int) -> Array:
	var right := _right_axis(orientation)
	var depth := _depth_axis(orientation)
	var up := Vector3i.UP
	var edits := []
	for z in range(-2, 3):
		for x in range(-2, 3):
			var base_id := BlockLibrary.COBBLE if abs(x) == 2 or abs(z) == 2 else BlockLibrary.MOSSY_STONE
			edits.append({"pos": origin + right * x + depth * z, "id": base_id})
	for y in range(1, 5):
		for sx in [-1, 1]:
			for sz in [-1, 1]:
				edits.append({"pos": origin + right * sx + depth * sz + up * y, "id": BlockLibrary.MARBLE})
		for side in [Vector2i(0, -1), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(1, 0)]:
			var wall_id := BlockLibrary.GLASS if y == 2 or y == 3 else BlockLibrary.MARBLE
			edits.append({"pos": origin + right * side.x + depth * side.y + up * y, "id": wall_id})
	for z in range(-1, 2):
		for x in range(-1, 2):
			var deck_id := BlockLibrary.MOONSTONE_LAMP if x == 0 and z == 0 else BlockLibrary.GLASS
			edits.append({"pos": origin + right * x + depth * z + up * 5, "id": deck_id})
	edits.append({"pos": origin + up * 6, "id": BlockLibrary.LANTERN})
	for side in [Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1), Vector2i(-1, 0), Vector2i(1, 0), Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)]:
		edits.append({"pos": origin + right * side.x + depth * side.y + up * 6, "id": BlockLibrary.BRICK})
	edits.append({"pos": origin + up * 7, "id": BlockLibrary.BRICK})
	return edits

static func _signpost_edits(origin: Vector3i, orientation: int) -> Array:
	var right := _right_axis(orientation)
	var depth := _depth_axis(orientation)
	var up := Vector3i.UP
	return [
		{"pos": origin, "id": BlockLibrary.MOSSY_STONE},
		{"pos": origin + right, "id": BlockLibrary.COBBLE},
		{"pos": origin - right, "id": BlockLibrary.COBBLE},
		{"pos": origin + depth, "id": BlockLibrary.COBBLE},
		{"pos": origin - depth, "id": BlockLibrary.COBBLE},
		{"pos": origin + up, "id": BlockLibrary.LOG},
		{"pos": origin + up * 2, "id": BlockLibrary.LOG},
		{"pos": origin + up * 3, "id": BlockLibrary.LOG},
		{"pos": origin + right * -1 + up * 3, "id": BlockLibrary.PLANKS},
		{"pos": origin + right + up * 3, "id": BlockLibrary.PLANKS},
		{"pos": origin + right * 2 + up * 3, "id": BlockLibrary.PLANKS},
		{"pos": origin - depth + up * 2, "id": BlockLibrary.LANTERN},
		{"pos": origin + up * 4, "id": BlockLibrary.MOONSTONE_LAMP},
	]
