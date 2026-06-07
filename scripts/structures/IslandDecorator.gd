extends RefCounted
# 主题岛装饰散布器——按扇区主题在地面上放置植被、灯柱、水景等细节。
# 确定性：同 seed + 同 theme + 同 anchor = 相同结果。
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")

# 散布参数
const SCATTER_GRID := 6       # 每 6 格一个散布格
const SCATTER_RANGE := 60     # 散布区半径（从 anchor 起）

static func stamp(chunk: Chunk, anchor: Vector3i, theme: int, world_seed: int) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	# 扫描散布区中属于本 chunk 的列
	var x0: int = maxi(anchor.x - SCATTER_RANGE, cwx)
	var x1: int = mini(anchor.x + SCATTER_RANGE, cwx + Chunk.SX - 1)
	var z0: int = maxi(anchor.z - SCATTER_RANGE, cwz)
	var z1: int = mini(anchor.z + SCATTER_RANGE, cwz + Chunk.SZ - 1)
	if x0 > x1 or z0 > z1: return
	for wx in range(x0, x1 + 1):
		for wz in range(z0, z1 + 1):
			# 散布网格：每 SCATTER_GRID 格中心选一个点
			if (wx % SCATTER_GRID) != 0 or (wz % SCATTER_GRID) != 0:
				continue
			var h: int = _hash(wx, wz, world_seed)
			# 50% 的网格不放任何东西（自然稀疏感）
			if h % 100 < 50: continue
			var lx: int = wx - cwx
			var lz: int = wz - cwz
			# 找地表（往下搜索第一个非空气格）
			var sy := -1
			for y in range(Chunk.SY - 1, 0, -1):
				if chunk.get_block(lx, y, lz) != 0:
					sy = y
					break
			if sy < 0: continue
			# 不在水上/结构内部放置
			var ground: int = chunk.get_block(lx, sy, lz)
			if ground == BL.WATER or ground == BL.GLASS or ground == BL.RAIL:
				continue
			_place_by_theme(chunk, lx, sy, lz, wx, wz, theme, h)

static func _place_by_theme(chunk: Chunk, lx: int, sy: int, lz: int, wx: int, wz: int, theme: int, h: int) -> void:
	var kind: int = (h >> 8) % 100
	match theme:
		0:  # SNOW
			if kind < 40: _place_pine_tree(chunk, lx, sy + 1, lz, h)
			elif kind < 60: _place_block(chunk, lx, sy + 1, lz, BL.BLUE_CRYSTAL)
			# else: nothing (barren snow)
		1:  # DESERT
			if kind < 25: _place_cactus(chunk, lx, sy + 1, lz, h)
			elif kind < 45: _place_block(chunk, lx, sy + 1, lz, BL.REEDS)
			elif kind < 55: _place_rock_cluster(chunk, lx, sy + 1, lz, h)
		2:  # TROPICAL
			if kind < 35: _place_palm_tree(chunk, lx, sy + 1, lz, h)
			elif kind < 55: _place_block(chunk, lx, sy + 1, lz, BL.WILDFLOWER)
			elif kind < 70: _place_block(chunk, lx, sy + 1, lz, BL.TALL_GRASS)
		3:  # VILLAGE
			if kind < 30: _place_block(chunk, lx, sy + 1, lz, BL.WILDFLOWER)
			elif kind < 45: _place_block(chunk, lx, sy + 1, lz, BL.TALL_GRASS)
			elif kind < 55: _place_lamp_post(chunk, lx, sy + 1, lz)
		4:  # PLAZA
			if kind < 25: _place_block(chunk, lx, sy + 1, lz, BL.WILDFLOWER)
			elif kind < 40: _place_lamp_post(chunk, lx, sy + 1, lz)
			elif kind < 50: _place_block(chunk, lx, sy + 1, lz, BL.TALL_GRASS)
		5:  # CYBER
			if kind < 30: _place_neon_pillar(chunk, lx, sy + 1, lz, h)
			elif kind < 45: _place_block(chunk, lx, sy + 1, lz, BL.STEEL_BLOCK)
		6:  # OBSERVATORY
			if kind < 25: _place_block(chunk, lx, sy + 1, lz, BL.BLUE_CRYSTAL)
			elif kind < 40: _place_lamp_post(chunk, lx, sy + 1, lz)
		7:  # FARM
			if kind < 40: _place_crop_patch(chunk, lx, sy, lz, h)
			elif kind < 55: _place_block(chunk, lx, sy + 1, lz, BL.TALL_GRASS)
		8:  # BAY
			if kind < 30: _place_block(chunk, lx, sy + 1, lz, BL.REEDS)
			elif kind < 45: _place_dock_post(chunk, lx, sy, lz)

# ---- 装饰物构建器 ----

static func _place_block(chunk: Chunk, lx: int, y: int, lz: int, bid: int) -> void:
	if y >= 0 and y < Chunk.SY and lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
		if chunk.get_block(lx, y, lz) == 0:
			chunk.set_block(lx, y, lz, bid)

static func _place_pine_tree(chunk: Chunk, lx: int, base_y: int, lz: int, h: int) -> void:
	var trunk_h: int = 4 + (h >> 12) % 3   # 4-6 tall
	for dy in range(trunk_h):
		var y: int = base_y + dy
		if y >= 0 and y < Chunk.SY:
			chunk.set_block(lx, y, lz, BL.LOG)
	# 松叶锥形冠（半径从2到0）
	for layer in range(3):
		var r: int = 2 - layer
		var cy: int = base_y + trunk_h - 1 + layer
		if cy >= Chunk.SY: break
		for dx in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if absi(dx) + absi(dz) > r + 1: continue
				var nx: int = lx + dx
				var nz: int = lz + dz
				if nx >= 0 and nx < Chunk.SX and nz >= 0 and nz < Chunk.SZ and cy >= 0 and cy < Chunk.SY:
					if chunk.get_block(nx, cy, nz) == 0:
						chunk.set_block(nx, cy, nz, BL.PINE_LEAVES)
	# 树尖
	var tip_y: int = base_y + trunk_h + 2
	if tip_y >= 0 and tip_y < Chunk.SY:
		chunk.set_block(lx, tip_y, lz, BL.PINE_LEAVES)

static func _place_palm_tree(chunk: Chunk, lx: int, base_y: int, lz: int, h: int) -> void:
	var trunk_h: int = 5 + (h >> 12) % 3   # 5-7 tall
	for dy in range(trunk_h):
		var y: int = base_y + dy
		if y >= 0 and y < Chunk.SY:
			chunk.set_block(lx, y, lz, BL.LOG)
	# 棕榈叶冠：四方向展开
	var top_y: int = base_y + trunk_h
	if top_y >= 0 and top_y < Chunk.SY:
		chunk.set_block(lx, top_y, lz, BL.LEAVES)
	for dir in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
		for dist in [1, 2, 3]:
			var nx: int = lx + dir.x * dist
			var nz: int = lz + dir.y * dist
			var ny: int = top_y - (1 if dist == 3 else 0)   # 末端下垂
			if nx >= 0 and nx < Chunk.SX and nz >= 0 and nz < Chunk.SZ and ny >= 0 and ny < Chunk.SY:
				if chunk.get_block(nx, ny, nz) == 0:
					chunk.set_block(nx, ny, nz, BL.LEAVES)

static func _place_cactus(chunk: Chunk, lx: int, base_y: int, lz: int, h: int) -> void:
	var cactus_h: int = 3 + (h >> 14) % 3   # 3-5 tall
	for dy in range(cactus_h):
		var y: int = base_y + dy
		if y >= 0 and y < Chunk.SY:
			chunk.set_block(lx, y, lz, BL.TALL_GRASS)   # green-ish cactus
	# 仙人掌 arm（侧枝）
	if cactus_h >= 4:
		var arm_y: int = base_y + 2
		var arm_x: int = lx + (1 if (h >> 16) % 2 == 0 else -1)
		if arm_x >= 0 and arm_x < Chunk.SX and arm_y >= 0 and arm_y < Chunk.SY:
			chunk.set_block(arm_x, arm_y, lz, BL.TALL_GRASS)
			if arm_y + 1 < Chunk.SY:
				chunk.set_block(arm_x, arm_y + 1, lz, BL.TALL_GRASS)

static func _place_rock_cluster(chunk: Chunk, lx: int, base_y: int, lz: int, h: int) -> void:
	var rock_type: int = BL.BASALT if (h >> 10) % 2 == 0 else BL.STONE
	_place_block(chunk, lx, base_y, lz, rock_type)
	if (h >> 11) % 3 > 0:
		_place_block(chunk, lx, base_y + 1, lz, rock_type)

static func _place_lamp_post(chunk: Chunk, lx: int, base_y: int, lz: int) -> void:
	for dy in range(3):
		var y: int = base_y + dy
		if y >= 0 and y < Chunk.SY:
			chunk.set_block(lx, y, lz, BL.LOG)
	var top_y: int = base_y + 3
	if top_y >= 0 and top_y < Chunk.SY:
		chunk.set_block(lx, top_y, lz, BL.LANTERN)

static func _place_neon_pillar(chunk: Chunk, lx: int, base_y: int, lz: int, h: int) -> void:
	var neon_colors := [BL.NEON_CYAN, BL.NEON_MAGENTA, BL.NEON_LIME]
	var neon_id: int = neon_colors[(h >> 10) % 3]
	var pillar_h: int = 2 + (h >> 13) % 4   # 2-5 tall
	for dy in range(pillar_h):
		var y: int = base_y + dy
		if y >= 0 and y < Chunk.SY:
			chunk.set_block(lx, y, lz, neon_id)

static func _place_crop_patch(chunk: Chunk, lx: int, sy: int, lz: int, h: int) -> void:
	# 在地面上种一小片庄稼：先放 WATER 灌溉沟再放 TALL_GRASS/REEDS
	if (h >> 9) % 3 == 0:
		# 灌溉沟
		if sy >= 0 and sy < Chunk.SY:
			chunk.set_block(lx, sy, lz, BL.WATER)
	else:
		var crop: int = BL.TALL_GRASS if (h >> 11) % 2 == 0 else BL.REEDS
		_place_block(chunk, lx, sy + 1, lz, crop)

static func _place_dock_post(chunk: Chunk, lx: int, sy: int, lz: int) -> void:
	# LOG 柱子从水底/地面向上伸出
	for dy in range(4):
		var y: int = sy - 1 + dy
		if y >= 0 and y < Chunk.SY:
			chunk.set_block(lx, y, lz, BL.LOG)
	var top_y: int = sy + 3
	if top_y >= 0 and top_y < Chunk.SY:
		chunk.set_block(lx, top_y, lz, BL.PLANKS)

# ---- 确定性哈希 ----
static func _hash(a: int, b: int, seed: int) -> int:
	var n: int = (a * 73856093) ^ (b * 19349663) ^ (seed * 83492791)
	n = (n << 13) ^ n
	n = (n * (n * n * 15731 + 789221) + 1376312589) & 0x7fffffff
	return n
