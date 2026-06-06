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
	check(top_block(g, 4, 4) != 0, "中心地表非空气")

	# 界外（远超半径）整列空气
	var far := IslandGenerator.HALF + 64
	var fc := chunk_coord(far)
	var cfar := Chunk.new(fc, fc); g.generate(cfar)
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
func chunk_coord(w: int) -> int:
	return floori(float(w) / Chunk.SX)

# 取某列地表方块（测试本地辅助）
func top_block(g, wx: int, wz: int) -> int:
	var ch := Chunk.new(floori(float(wx) / Chunk.SX), floori(float(wz) / Chunk.SZ))
	g.generate(ch)
	return ch.get_block(posmod(wx, Chunk.SX), g.surface_height(wx, wz), posmod(wz, Chunk.SZ))
