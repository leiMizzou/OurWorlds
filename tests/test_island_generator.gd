extends SceneTree
# IslandGenerator 自检：确定性 / 有界（界外空气）/ 扇区划分。
const IslandGenerator = preload("res://scripts/IslandGenerator.gd")
const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

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

	# 各扇区地表方块属于其主题族
	var snow_xz := [-IslandGenerator.HALF + 40, -IslandGenerator.HALF + 40]   # 北-西 = 雪山
	check(top_block(g, snow_xz[0], snow_xz[1]) == BlockLibrary.SNOW, "雪山扇区地表=雪")
	var desert_xz := [0, -IslandGenerator.HALF + 40]                          # 北-中 = 沙漠
	var dtop := top_block(g, desert_xz[0], desert_xz[1])
	check(dtop == BlockLibrary.SAND or dtop == BlockLibrary.RED_SAND, "沙漠扇区地表=沙/红沙")
	var cyber_xz := [IslandGenerator.HALF - 40, 0]                            # 中-东 = 赛博
	check(top_block(g, cyber_xz[0], cyber_xz[1]) == BlockLibrary.STEEL_BLOCK, "赛博扇区地基=钢块")
	var obs_xz := [-IslandGenerator.HALF + 40, IslandGenerator.HALF - 40]     # 南-西 = 天文台
	check(top_block(g, obs_xz[0], obs_xz[1]) == BlockLibrary.MARBLE, "天文台扇区地基=大理石")

	# region_label 在不同扇区给出不同标签
	check(g.region_label(snow_xz[0], snow_xz[1]) != g.region_label(cyber_xz[0], cyber_xz[1]), "不同扇区 region_label 不同")

	# 边缘：紧贴边界处地表显著低于中心（崖壁）
	check(g.surface_height(0, 0) - g.surface_height(IslandGenerator.HALF - 1, 0) >= IslandGenerator.EDGE - 1, "边缘地表跌落成崖")

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
