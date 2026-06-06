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
