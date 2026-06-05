extends SceneTree
# 验证新增自然内容：泉池、水边黏土/芦苇、林地蘑菇、洞穴蓝晶和蓝晶晶洞会在固定种子中稳定出现。
#   godot --headless --path <项目> --script res://tests/test_natural_content.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")

var failed := 0

func _process(_delta: float) -> bool:
	return true

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	var gen := WorldGenerator.new(1337)
	var counts := {
		"mushroom": 0,
		"reeds": 0,
		"crystal": 0,
		"clay": 0,
		"spring_water": 0,
		"fallen_log_pairs": 0,
		"boulder_blocks": 0,
		"crystal_geodes": 0,
		# 新增（二维群系 + 地下奇观 + 地下地标）
		"meadow_flora": 0,        # 花海草甸的高密度野花/高草（成片）
		"desert_sand": 0,         # 沙漠成片表层沙
		"mesa_terracotta": 0,     # 红土台地赤陶分层
		"cavern_floor_crystal": 0,# 溶洞水晶洞地面蓝晶（深层）
		"underground_altar": 0,   # 地下祭坛锚点（SUNSTONE 暖光锚 + MARBLE 基座）
	}
	var first_chunk: Chunk = null
	var first_cc := Vector2i.ZERO
	var first_geode_chunk: Chunk = null
	var first_geode_cc := Vector2i.ZERO

	for cz in range(-8, 9):
		for cx in range(-8, 9):
			var ch := Chunk.new(cx, cz)
			gen.generate(ch)
			if first_chunk == null:
				first_chunk = ch
				first_cc = Vector2i(cx, cz)
			counts["mushroom"] += _count_block(ch, BlockLibrary.RED_MUSHROOM)
			counts["reeds"] += _count_block(ch, BlockLibrary.REEDS)
			counts["crystal"] += _count_block(ch, BlockLibrary.BLUE_CRYSTAL)
			counts["clay"] += _count_block(ch, BlockLibrary.CLAY)
			counts["spring_water"] += _count_spring_water(ch)
			counts["fallen_log_pairs"] += _count_horizontal_log_pairs(ch)
			counts["boulder_blocks"] += _count_boulder_blocks(ch, gen)
			var geode_count := _count_crystal_geode_chunks(ch)
			counts["crystal_geodes"] += geode_count
			if geode_count > 0 and first_geode_chunk == null:
				first_geode_chunk = ch
				first_geode_cc = Vector2i(cx, cz)
			counts["meadow_flora"] += _count_meadow_flora(ch, gen)
			counts["cavern_floor_crystal"] += _count_cavern_floor_crystal(ch)
			counts["underground_altar"] += _count_underground_altars(ch)

	# 二维群系成片表层材质：沙漠/红土台地不一定落在 -8..8，单独定位最近的群系区块取材质验证。
	counts["desert_sand"] = _count_biome_material("沙漠", BlockLibrary.SAND, gen)
	counts["mesa_terracotta"] = _count_biome_material("红土台地", BlockLibrary.TERRACOTTA, gen)
	var wide_labels := _wide_region_labels(gen)

	print("  ..   natural content counts = ", counts)
	check(int(counts["mushroom"]) > 0, "固定种子附近生成红蘑菇")
	check(int(counts["reeds"]) > 0, "固定种子附近生成芦苇")
	check(int(counts["crystal"]) > 0, "固定种子附近生成蓝晶")
	check(int(counts["clay"]) > 0, "固定种子附近生成黏土岸线")
	check(int(counts["spring_water"]) > 0, "固定种子附近生成高于海平面的泉池")
	check(int(counts["fallen_log_pairs"]) > 0, "固定种子附近生成倒木小景观")
	check(int(counts["boulder_blocks"]) > 0, "固定种子附近生成自然石丘小景观")
	check(int(counts["crystal_geodes"]) > 0, "固定种子附近生成蓝晶晶洞小景观")
	# 新增内容：二维群系 + 地下溶洞奇观 + 地下地标
	check(int(counts["meadow_flora"]) > 0, "固定种子附近生成花海草甸高密度花草")
	check(int(counts["cavern_floor_crystal"]) > 0, "固定种子附近生成溶洞水晶洞地面蓝晶")
	check(int(counts["underground_altar"]) > 0, "固定种子附近生成地下祭坛地标")
	check(int(counts["desert_sand"]) > 0, "二维群系：沙漠铺连续沙表层")
	check(int(counts["mesa_terracotta"]) > 0, "二维群系：红土台地铺赤陶分层")
	check(wide_labels.has("沙漠"), "区域标签覆盖沙漠")
	check(wide_labels.has("红土台地"), "区域标签覆盖红土台地")
	check(wide_labels.has("花海草甸"), "区域标签覆盖花海草甸")

	if first_chunk != null:
		var regen := Chunk.new(first_cc.x, first_cc.y)
		gen.generate(regen)
		check(first_chunk.blocks == regen.blocks, "新增自然内容重复生成结果确定")
	if first_geode_chunk != null:
		var geode_regen := Chunk.new(first_geode_cc.x, first_geode_cc.y)
		gen.generate(geode_regen)
		check(first_geode_chunk.blocks == geode_regen.blocks, "蓝晶晶洞重复生成结果确定")
	# 地下祭坛重复生成一致：定位首个含祭坛的区块再生成对比。
	var altar_cc := _find_altar_chunk(gen)
	if altar_cc.x < 99999:
		var altar_ref := Chunk.new(altar_cc.x, altar_cc.y)
		gen.generate(altar_ref)
		var altar_regen := Chunk.new(altar_cc.x, altar_cc.y)
		gen.generate(altar_regen)
		check(altar_ref.blocks == altar_regen.blocks, "地下祭坛重复生成结果确定")

	if failed == 0:
		print("✅ ALL NATURAL CONTENT TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个自然内容测试失败")
	quit(failed)

func _count_block(chunk: Chunk, id: int) -> int:
	var count := 0
	for raw in chunk.blocks:
		if int(raw) == id:
			count += 1
	return count

func _count_horizontal_log_pairs(chunk: Chunk) -> int:
	var count := 0
	for y in range(1, Chunk.SY - 1):
		for z in range(Chunk.SZ):
			for x in range(Chunk.SX):
				if chunk.get_block(x, y, z) != BlockLibrary.LOG:
					continue
				if x + 1 < Chunk.SX and chunk.get_block(x + 1, y, z) == BlockLibrary.LOG:
					count += 1
				if z + 1 < Chunk.SZ and chunk.get_block(x, y, z + 1) == BlockLibrary.LOG:
					count += 1
	return count

func _count_spring_water(chunk: Chunk) -> int:
	var count := 0
	for y in range(WorldGenerator.SEA_LEVEL + 3, Chunk.SY):
		for z in range(Chunk.SZ):
			for x in range(Chunk.SX):
				if chunk.get_block(x, y, z) == BlockLibrary.WATER \
						and y > 0 \
						and chunk.get_block(x, y - 1, z) == BlockLibrary.CLAY:
					count += 1
	return count

func _count_boulder_blocks(chunk: Chunk, gen: WorldGenerator) -> int:
	if _count_block(chunk, BlockLibrary.LANTERN) > 0:
		return 0
	var count := 0
	for z in range(Chunk.SZ):
		for x in range(Chunk.SX):
			var wx := chunk.cx * Chunk.SX + x
			var wz := chunk.cz * Chunk.SZ + z
			var surface := gen.surface_height(wx, wz)
			for y in range(surface + 1, mini(surface + 4, Chunk.SY)):
				var id := chunk.get_block(x, y, z)
				if id == BlockLibrary.STONE \
						or id == BlockLibrary.COBBLE \
						or id == BlockLibrary.MOSSY_STONE \
						or id == BlockLibrary.BASALT:
					count += 1
	return count

func _count_crystal_geode_chunks(chunk: Chunk) -> int:
	var crystals := []
	for y in range(1, Chunk.SY - 1):
		for z in range(Chunk.SZ):
			for x in range(Chunk.SX):
				if chunk.get_block(x, y, z) == BlockLibrary.BLUE_CRYSTAL:
					crystals.append(Vector3i(x, y, z))
	if crystals.size() < 4:
		return 0
	for raw in crystals:
		var pos: Vector3i = raw
		var nearby := 0
		for other_raw in crystals:
			var other: Vector3i = other_raw
			if abs(other.x - pos.x) <= 4 and abs(other.y - pos.y) <= 4 and abs(other.z - pos.z) <= 4:
				nearby += 1
		if nearby >= 4 and _has_geode_air_and_shell(chunk, pos):
			return 1
	return 0

func _has_geode_air_and_shell(chunk: Chunk, pos: Vector3i) -> bool:
	var has_air := false
	var has_shell := false
	for dy in range(-3, 4):
		for dz in range(-3, 4):
			for dx in range(-3, 4):
				var id := chunk.get_block(pos.x + dx, pos.y + dy, pos.z + dz)
				if id == BlockLibrary.AIR:
					has_air = true
				elif id == BlockLibrary.BASALT or id == BlockLibrary.MARBLE:
					has_shell = true
				if has_air and has_shell:
					return true
	return false

# 花海草甸：成片野花/高草。统计"地表上方为野花/高草"的格子，作为草甸密度证据。
func _count_meadow_flora(chunk: Chunk, gen: WorldGenerator) -> int:
	var count := 0
	for z in range(Chunk.SZ):
		for x in range(Chunk.SX):
			var wx := chunk.cx * Chunk.SX + x
			var wz := chunk.cz * Chunk.SZ + z
			if gen.region_label(wx, wz) != "花海草甸":
				continue
			var surface := gen.surface_height(wx, wz)
			var id := chunk.get_block(x, surface + 1, z)
			if id == BlockLibrary.WILDFLOWER or id == BlockLibrary.TALL_GRASS:
				count += 1
	return count

# 溶洞水晶洞：深层(空腔带内)地面蓝晶，且其下方为可作洞底的固体。
func _count_cavern_floor_crystal(chunk: Chunk) -> int:
	var count := 0
	for y in range(11, 41):
		for z in range(Chunk.SZ):
			for x in range(Chunk.SX):
				if chunk.get_block(x, y, z) != BlockLibrary.BLUE_CRYSTAL:
					continue
				var below := chunk.get_block(x, y - 1, z)
				if below == BlockLibrary.MOSSY_STONE or below == BlockLibrary.STONE:
					count += 1
	return count

# 地下祭坛：SUNSTONE 暖光锚立于 MARBLE 基座(其下两格皆 MARBLE)上，与 DiscoveryTracker 识别规则一致。
func _count_underground_altars(chunk: Chunk) -> int:
	var count := 0
	for y in range(12, 45):
		for z in range(Chunk.SZ):
			for x in range(Chunk.SX):
				if chunk.get_block(x, y, z) != BlockLibrary.SUNSTONE:
					continue
				if chunk.get_block(x, y - 1, z) != BlockLibrary.MARBLE:
					continue
				if chunk.get_block(x, y - 2, z) != BlockLibrary.MARBLE:
					continue
				count += 1
	return count

# 定位最近含某二维群系标签的区块，生成它并统计指定表层材质数（验证成片表层）。
func _count_biome_material(label: String, material_id: int, gen: WorldGenerator) -> int:
	var cc := _find_biome_chunk(label, gen)
	if cc.x >= 99999:
		return 0
	var ch := Chunk.new(cc.x, cc.y)
	gen.generate(ch)
	return _count_block(ch, material_id)

func _find_biome_chunk(label: String, gen: WorldGenerator) -> Vector2i:
	for r in range(0, 30):
		for raw_dz in range(-r, r + 1):
			for raw_dx in range(-r, r + 1):
				if max(abs(raw_dx), abs(raw_dz)) != r:
					continue
				var wx := raw_dx * Chunk.SX + 8
				var wz := raw_dz * Chunk.SZ + 8
				if gen.region_label(wx, wz) == label:
					return Vector2i(raw_dx, raw_dz)
	return Vector2i(99999, 0)

func _find_altar_chunk(gen: WorldGenerator) -> Vector2i:
	for cz in range(-8, 9):
		for cx in range(-8, 9):
			var ch := Chunk.new(cx, cz)
			gen.generate(ch)
			if _count_underground_altars(ch) > 0:
				return Vector2i(cx, cz)
	return Vector2i(99999, 0)

func _wide_region_labels(gen: WorldGenerator) -> Dictionary:
	var labels := {}
	for z in range(-420, 421, 7):
		for x in range(-420, 421, 7):
			labels[gen.region_label(x, z)] = true
	return labels
