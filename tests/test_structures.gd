extends SceneTree
const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const IslandGenerator = preload("res://scripts/IslandGenerator.gd")
const Pyramid = preload("res://scripts/structures/Pyramid.gd")
const ObservatoryDome = preload("res://scripts/structures/ObservatoryDome.gd")
const CyberTowers = preload("res://scripts/structures/CyberTowers.gd")
const WindmillFarm = preload("res://scripts/structures/WindmillFarm.gd")
const LighthouseDock = preload("res://scripts/structures/LighthouseDock.gd")
const SnowCabin = preload("res://scripts/structures/SnowCabin.gd")
const Village = preload("res://scripts/structures/Village.gd")
const PlazaMonument = preload("res://scripts/structures/PlazaMonument.gd")
const RailBridgeNet = preload("res://scripts/structures/RailBridgeNet.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)
func count_blocks(chunk) -> int:
	var n := 0
	for i in chunk.blocks.size():
		if chunk.blocks[i] != 0: n += 1
	return n
func has_block_type(chunk, bid: int) -> bool:
	for i in chunk.blocks.size():
		if chunk.blocks[i] == bid: return true
	return false
func _initialize() -> void:
	var builders := [
		["Pyramid", Pyramid, Vector3i(0,40,0)],
		["ObservatoryDome", ObservatoryDome, Vector3i(0,40,0)],
		["CyberTowers", CyberTowers, Vector3i(0,40,0)],
		["WindmillFarm", WindmillFarm, Vector3i(0,40,0)],
		["LighthouseDock", LighthouseDock, Vector3i(0,40,0)],
		["SnowCabin", SnowCabin, Vector3i(0,40,0)],
		["Village", Village, Vector3i(0,40,0)],
		["PlazaMonument", PlazaMonument, Vector3i(0,40,0)],
		# RailBridgeNet 单独测试（铁轨不经过 chunk(0,0)）
	]
	for entry in builders:
		var bname: String = entry[0]
		var builder = entry[1]
		var anchor: Vector3i = entry[2]
		var chunk := Chunk.new(0, 0)
		builder.stamp(chunk, anchor)
		check(count_blocks(chunk) > 0, "%s stamps >0 blocks (%d)" % [bname, count_blocks(chunk)])
	var pc := Chunk.new(0, 0)
	Pyramid.stamp(pc, Vector3i(0,40,0))
	check(has_block_type(pc, BlockLibrary.TERRACOTTA), "Pyramid TERRACOTTA")
	check(has_block_type(pc, BlockLibrary.GOLD_TRIM), "Pyramid GOLD_TRIM")
	var cc := Chunk.new(0, 0)
	CyberTowers.stamp(cc, Vector3i(8,40,8))  # 居中让三塔都落入本 chunk
	check(has_block_type(cc, BlockLibrary.NEON_CYAN), "CyberTowers NEON_CYAN")
	check(has_block_type(cc, BlockLibrary.NEON_MAGENTA), "CyberTowers NEON_MAGENTA")
	check(has_block_type(cc, BlockLibrary.GLASS), "CyberTowers GLASS")
	# ObservatoryDome block types
	var oc := Chunk.new(0, 0)
	ObservatoryDome.stamp(oc, Vector3i(0,40,0))
	check(has_block_type(oc, BlockLibrary.MARBLE), "ObservatoryDome MARBLE")
	check(has_block_type(oc, BlockLibrary.GLASS), "ObservatoryDome GLASS")
	check(has_block_type(oc, BlockLibrary.POLISHED_IRON), "ObservatoryDome POLISHED_IRON")
	# SnowCabin block types
	var sc := Chunk.new(0, 0)
	SnowCabin.stamp(sc, Vector3i(0,40,0))
	check(has_block_type(sc, BlockLibrary.PLANKS), "SnowCabin PLANKS")
	check(has_block_type(sc, BlockLibrary.PINE_LEAVES), "SnowCabin PINE_LEAVES")
	check(has_block_type(sc, BlockLibrary.LANTERN), "SnowCabin LANTERN")
	# WindmillFarm block types
	var wfc := Chunk.new(0, 0)
	WindmillFarm.stamp(wfc, Vector3i(0,40,0))
	check(has_block_type(wfc, BlockLibrary.BRICK), "WindmillFarm BRICK")
	check(has_block_type(wfc, BlockLibrary.WATER), "WindmillFarm WATER")
	# LighthouseDock block types
	var ldc := Chunk.new(0, 0)
	LighthouseDock.stamp(ldc, Vector3i(0,40,0))
	check(has_block_type(ldc, BlockLibrary.SUNSTONE), "LighthouseDock SUNSTONE")
	check(has_block_type(ldc, BlockLibrary.GLASS), "LighthouseDock GLASS")
	var plc := Chunk.new(0, 0)
	PlazaMonument.stamp(plc, Vector3i(0,40,0))
	check(has_block_type(plc, BlockLibrary.MARBLE), "PlazaMonument MARBLE")
	check(has_block_type(plc, BlockLibrary.LANTERN), "PlazaMonument LANTERN")
	check(has_block_type(plc, BlockLibrary.WATER), "PlazaMonument WATER")
	var vc := Chunk.new(0, 0)
	Village.stamp(vc, Vector3i(0,40,0))
	check(has_block_type(vc, BlockLibrary.COBBLE), "Village COBBLE")
	check(has_block_type(vc, BlockLibrary.PLANKS), "Village PLANKS")
	# RailBridgeNet：浮点 span 后 cell4 中心=(0,0)，铁轨经过 chunk(0,0)
	var rc := Chunk.new(0, 0)
	RailBridgeNet.stamp(rc, Vector3i(0,40,0))
	check(has_block_type(rc, BlockLibrary.RAIL), "RailBridgeNet RAIL")
	check(has_block_type(rc, BlockLibrary.PLANKS), "RailBridgeNet PLANKS support")
	# --- IslandGenerator integration ---
	var gen := IslandGenerator.new(2026)
	var ig := Chunk.new(0, 0)
	gen.generate(ig)
	check(has_block_type(ig, BlockLibrary.GOLD_TRIM) or has_block_type(ig, BlockLibrary.MARBLE), "generate() stamps structures")
	# 浮点 span 后铁轨经过 chunk(0,0)
	check(has_block_type(ig, BlockLibrary.RAIL), "generate() stamps rail at center chunk")
	# --- region_label / region_description ---
	check(gen.region_label(0, 0) == "中央广场", "center label is 中央广场")
	check(gen.region_label(500, 500) == "虚空", "outside label is 虚空")
	check(gen.region_description(0, 0) != "", "region_description non-empty")
	# --- determinism at center and edge ---
	var gen2 := IslandGenerator.new(2026)
	var d1 := Chunk.new(0, 0)
	var d2 := Chunk.new(0, 0)
	gen.generate(d1)
	gen2.generate(d2)
	check(d1.blocks == d2.blocks, "deterministic center")
	var d3 := Chunk.new(5, -5)
	var d4 := Chunk.new(5, -5)
	gen.generate(d3)
	gen2.generate(d4)
	check(d3.blocks == d4.blocks, "deterministic non-center")
	if failed == 0: print("✅ ALL STRUCTURE TESTS PASSED")
	else: printerr("❌ ", failed, " structure tests failed")
	quit(0 if failed == 0 else 1)
