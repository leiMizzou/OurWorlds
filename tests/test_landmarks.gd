extends SceneTree
# 验证程序化地标：固定种子下能生成可探索遗迹，且生成结果确定。
#   godot --headless --path <项目> --script res://tests/test_landmarks.gd

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
	var lantern_count := 0
	var moonstone_count := 0
	var ruin_blocks := 0
	var first_chunk: Chunk = null
	var first_cc := Vector2i.ZERO
	var first_lantern := Vector3i.ZERO
	var variants := {}

	for cz in range(-10, 11):
		for cx in range(-10, 11):
			var ch := Chunk.new(cx, cz)
			gen.generate(ch)
			var local_lantern := _find_block(ch, BlockLibrary.LANTERN)
			if local_lantern.y >= 0:
				lantern_count += 1
				variants[_landmark_variant(ch, local_lantern)] = true
				if first_chunk == null:
					first_chunk = ch
					first_cc = Vector2i(cx, cz)
					first_lantern = local_lantern
			moonstone_count += _count_block(ch, BlockLibrary.MOONSTONE_LAMP)
			ruin_blocks += _count_ruin_blocks(ch)

	check(lantern_count > 0, "固定种子附近生成至少一处遗迹灯笼")
	check(moonstone_count > 0, "固定种子附近生成月石灯遗迹点缀")
	check(ruin_blocks >= lantern_count * 18, "遗迹包含足够石质结构块")
	check(variants.size() >= 2, "固定种子附近生成多种遗迹变体")
	if first_chunk != null:
		var wx := first_cc.x * Chunk.SX + first_lantern.x
		var wz := first_cc.y * Chunk.SZ + first_lantern.z
		var surface := gen.surface_height(wx, wz)
		check(first_lantern.y > surface, "遗迹灯笼位于地表上方")
		check(surface > WorldGenerator.SEA_LEVEL + 2 and surface < WorldGenerator.ROCK_LINE, "遗迹落在可步行草地高度")
		check(first_chunk.get_block(first_lantern.x, first_lantern.y - 1, first_lantern.z) == BlockLibrary.MARBLE, "灯笼下方有遗迹基座")
		var regen := Chunk.new(first_cc.x, first_cc.y)
		gen.generate(regen)
		check(first_chunk.blocks == regen.blocks, "同一区块重复生成结果确定")

	if failed == 0:
		print("✅ ALL LANDMARK TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个地标测试失败")
	quit(failed)

func _find_block(chunk: Chunk, id: int) -> Vector3i:
	for y in range(Chunk.SY):
		for z in range(Chunk.SZ):
			for x in range(Chunk.SX):
				if chunk.get_block(x, y, z) == id:
					return Vector3i(x, y, z)
	return Vector3i(0, -1, 0)

func _count_ruin_blocks(chunk: Chunk) -> int:
	var count := 0
	for id in chunk.blocks:
		var block_id := int(id)
		if block_id == BlockLibrary.COBBLE \
				or block_id == BlockLibrary.MOSSY_STONE \
				or block_id == BlockLibrary.BRICK \
				or block_id == BlockLibrary.MARBLE \
				or block_id == BlockLibrary.LANTERN \
				or block_id == BlockLibrary.MOONSTONE_LAMP:
			count += 1
	return count

func _count_block(chunk: Chunk, id: int) -> int:
	var count := 0
	for raw in chunk.blocks:
		if int(raw) == id:
			count += 1
	return count

func _landmark_variant(chunk: Chunk, lantern: Vector3i) -> String:
	var marker := BlockLibrary.MOSSY_STONE
	if lantern.y >= 2:
		marker = chunk.get_block(lantern.x, lantern.y - 2, lantern.z)
	match marker:
		BlockLibrary.BRICK:
			return "spire"
		BlockLibrary.COBBLE:
			return "circle"
		_:
			return "ruin"
