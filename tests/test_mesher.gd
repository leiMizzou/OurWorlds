extends SceneTree
# 地基自检（无需渲染，headless 跑）：
#   godot --headless --path <项目> --script res://tests/test_mesher.gd
# 验证：贴图图集生成、方块读写、造网格出可见面、碰撞体生成、隐藏面被剔除。

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")
const ChunkMesher = preload("res://scripts/ChunkMesher.gd")

var failed := 0

# 兜底：万一 _initialize 中途报错没走到 quit()，下一帧也强制退出，绝不空转挂死。
func _process(_delta: float) -> bool:
	return true

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	var lib = BlockLibrary.new()

	# 1) 图集生成
	check(lib.atlas != null, "图集已生成")
	check(lib.atlas != null and lib.atlas.get_width() == BlockLibrary.ATLAS_COLS * BlockLibrary.TILE, "图集尺寸正确 %dx%d" % [BlockLibrary.ATLAS_COLS * BlockLibrary.TILE, BlockLibrary.ATLAS_ROWS * BlockLibrary.TILE])
	check(lib.material != null and lib.water_material != null, "材质已生成")
	check(lib.water_material is ShaderMaterial, "水面使用波纹 ShaderMaterial")
	check((lib.water_material as ShaderMaterial).get_shader_parameter("albedo_tex") == lib.atlas, "水面 shader 使用方块图集")
	check(float((lib.water_material as ShaderMaterial).get_shader_parameter("wave_strength")) > 0.0, "水面 shader 有轻微波纹")

	# 2) 方块属性
	check(lib.is_opaque(BlockLibrary.STONE), "石头不透明")
	check(not lib.is_opaque(BlockLibrary.GLASS), "玻璃可看穿")
	check(lib.is_collidable(BlockLibrary.GLASS), "玻璃有碰撞")
	check(not lib.is_collidable(BlockLibrary.WATER), "水无碰撞")
	check(lib.has_def(BlockLibrary.RED_MUSHROOM) and not lib.is_collidable(BlockLibrary.RED_MUSHROOM), "红蘑菇是无碰撞装饰")
	check(lib.has_def(BlockLibrary.REEDS) and not lib.is_collidable(BlockLibrary.REEDS), "芦苇是无碰撞装饰")
	check(lib.has_def(BlockLibrary.BLUE_CRYSTAL) and lib.is_collidable(BlockLibrary.BLUE_CRYSTAL), "蓝晶是可碰撞装饰块")
	check(lib.has_def(BlockLibrary.CLAY) and lib.is_opaque(BlockLibrary.CLAY), "黏土是实心建材")
	check(lib.has_def(BlockLibrary.MOONSTONE_LAMP) and lib.is_collidable(BlockLibrary.MOONSTONE_LAMP), "月石灯是可碰撞发光建材")
	check(not lib.is_opaque(BlockLibrary.MOONSTONE_LAMP), "月石灯带透明发光纹理")
	check(lib.creative_blocks().has(BlockLibrary.BLUE_CRYSTAL), "创造材料库包含蓝晶")
	check(lib.creative_blocks().has(BlockLibrary.MOONSTONE_LAMP), "创造材料库包含月石灯")
	var grass_preview := lib.preview_color(BlockLibrary.GRASS)
	var brick_preview := lib.preview_color(BlockLibrary.BRICK)
	var marble_preview := lib.preview_color(BlockLibrary.MARBLE)
	check(grass_preview.g > grass_preview.r, "草方块预览色偏绿色")
	check(brick_preview.r > brick_preview.g, "砖块预览色偏红色")
	check(marble_preview.r > brick_preview.r and marble_preview.g > brick_preview.g, "大理石预览色比砖块更明亮")

	# 3) 区块读写往返
	var c = Chunk.new(0, 0)
	c.set_block(3, 5, 7, BlockLibrary.STONE)
	check(c.get_block(3, 5, 7) == BlockLibrary.STONE, "set/get 往返")
	check(c.get_block(99, 0, 0) == 0, "越界读=空气")

	var water_chunk = Chunk.new(0, 0)
	water_chunk.set_block(1, 4, 1, BlockLibrary.WATER)
	var water_res = ChunkMesher.build(water_chunk, lib, null, null, null, null)
	var water_mesh: ArrayMesh = water_res["mesh"]
	var has_water_surface := false
	for surface in range(water_mesh.get_surface_count()):
		if water_mesh.surface_get_material(surface) == lib.water_material:
			has_water_surface = true
	check(has_water_surface, "水方块网格使用水面 shader 材质")
	check(water_res["shape"] == null, "水面不生成碰撞体")

	# 4) 填一小片地形：底部 18 层石头 + 1 层泥 + 1 层草
	for x in range(Chunk.SX):
		for z in range(Chunk.SZ):
			for y in range(18):
				c.set_block(x, y, z, BlockLibrary.STONE)
			c.set_block(x, 18, z, BlockLibrary.DIRT)
			c.set_block(x, 19, z, BlockLibrary.GRASS)

	var res = ChunkMesher.build(c, lib, null, null, null, null)
	var mesh: ArrayMesh = res["mesh"]
	check(mesh.get_surface_count() >= 1, "网格至少 1 个面组")
	var verts := mesh.surface_get_array_len(0) if mesh.get_surface_count() > 0 else 0
	print("  ..   表层网格顶点数 = ", verts)
	check(verts > 0, "造出了可见面")
	check(res["shape"] != null, "生成了碰撞体")
	if res["shape"] != null:
		print("  ..   碰撞三角形数 = ", res["shape"].get_faces().size() / 3)

	# 5) 隐藏面剔除：实心立方体内部不该有面。
	#    20×20×... 不行（超 16），改测：一个被四周石头包住的格子，其面应被邻居挡掉。
	#    这里用"顶层草只露顶面"间接验证：草层(256 格)若每格 6 面=1536 面*4 顶点；
	#    实际顶面只露 1 个/格 => 草贡献远小于 6 面。用总顶点数粗略 sanity check。
	var solid_only = Chunk.new(0, 0)
	for x in range(Chunk.SX):
		for z in range(Chunk.SZ):
			for y in range(Chunk.SY):
				solid_only.set_block(x, y, z, BlockLibrary.STONE)   # 填满整块
	var res2 = ChunkMesher.build(solid_only, lib, null, null, null, null)
	# 填满后，只有外壳 6 个面露出来；内部全被剔除。
	# 外壳面数 ≈ 2*(16*16) 顶底 + 4*(16*96) 侧 = 512 + 6144 = 6656 个四边形 = 26624 顶点。
	# 若没剔除内部，会是 16*16*96*6*4 = 589 万顶点。用上限断言它确实剔除了。
	var shell: int = res2["mesh"].surface_get_array_len(0)
	print("  ..   填满区块的外壳顶点数 = ", shell, "（没剔除的话会是 ", Chunk.SX * Chunk.SY * Chunk.SZ * 6 * 4, "）")
	check(shell < 40000, "内部隐藏面已被剔除")

	if failed == 0:
		print("✅ ALL MESHER TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个测试失败")
	quit(failed)
