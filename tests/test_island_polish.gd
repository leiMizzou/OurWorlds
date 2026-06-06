extends SceneTree
# SP4 测试：岛屿装饰散布 + 瀑布 + 氛围主题色
const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const IslandGenerator = preload("res://scripts/IslandGenerator.gd")
const IslandDecorator = preload("res://scripts/structures/IslandDecorator.gd")
const Waterfall = preload("res://scripts/structures/Waterfall.gd")
const AmbientMotes = preload("res://scripts/AmbientMotes.gd")
const WeatherSystem = preload("res://scripts/WeatherSystem.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)
func has_block_type(chunk, bid: int) -> bool:
	for i in chunk.blocks.size():
		if chunk.blocks[i] == bid: return true
	return false
func count_block_type(chunk, bid: int) -> int:
	var n := 0
	for i in chunk.blocks.size():
		if chunk.blocks[i] == bid: n += 1
	return n
func _initialize() -> void:
	# 1) IslandDecorator stamps blocks for each theme
	var themes := [0, 1, 2, 3, 4, 5, 6, 7, 8]
	for t in themes:
		var chunk := Chunk.new(0, 0)
		# 先铺一层地面（装饰器需要找到地表）
		for lx in range(Chunk.SX):
			for lz in range(Chunk.SZ):
				chunk.set_block(lx, 40, lz, BlockLibrary.GRASS)
		IslandDecorator.stamp(chunk, null, Vector3i(0, 40, 0), t, 2026)
		var count := 0
		for i in chunk.blocks.size():
			var bid: int = chunk.blocks[i]
			if bid != 0 and bid != BlockLibrary.GRASS: count += 1
		check(count > 0, "Decorator stamps theme %d (%d decor blocks)" % [t, count])

	# 2) Waterfall stamps WATER + MOSSY_STONE
	var wc := Chunk.new(0, 0)
	Waterfall.stamp(wc, null, Vector3i(0, 40, 0))
	check(has_block_type(wc, BlockLibrary.WATER), "Waterfall has WATER")
	check(has_block_type(wc, BlockLibrary.MOSSY_STONE), "Waterfall has MOSSY_STONE")

	# 3) Full island generate includes decorator blocks
	var gen := IslandGenerator.new(2026)
	var ic := Chunk.new(0, 0)
	gen.generate(ic)
	# 装饰器放了 WILDFLOWER/TALL_GRASS/LANTERN 等
	var deco_count := 0
	for bid in [BlockLibrary.WILDFLOWER, BlockLibrary.TALL_GRASS, BlockLibrary.REEDS, BlockLibrary.LANTERN, BlockLibrary.BLUE_CRYSTAL]:
		deco_count += count_block_type(ic, bid)
	check(deco_count > 0, "generate() has decorator vegetation (%d)" % deco_count)

	# 4) AmbientMotes recognizes island theme labels
	var motes := AmbientMotes.new()
	for label in ["雪山", "沙漠", "热带海岸", "村庄", "中央广场", "霓虹城", "天文台", "农田", "海湾"]:
		motes.set_region_label(label)
		var tint := motes.current_theme_color()
		check(tint != Color(1.0, 0.86, 0.44), "Motes tint for '%s' is themed" % label)

	# 5) WeatherSystem cold region includes 雪山
	var ws := WeatherSystem.new()
	ws.set_region_label("雪山")
	check(ws._is_cold_region(), "WeatherSystem cold for 雪山")
	ws.set_region_label("沙漠")
	check(not ws._is_cold_region(), "WeatherSystem not cold for 沙漠")

	# 6) Determinism
	var gen2 := IslandGenerator.new(2026)
	var d1 := Chunk.new(0, 0)
	var d2 := Chunk.new(0, 0)
	gen.generate(d1)
	gen2.generate(d2)
	check(d1.blocks == d2.blocks, "SP4 deterministic")

	if failed == 0: print("✅ ALL SP4 POLISH TESTS PASSED")
	else: printerr("❌ ", failed, " SP4 tests failed")
	quit(0 if failed == 0 else 1)
