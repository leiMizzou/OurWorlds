extends SceneTree
# 验证灯笼/月石灯/蓝晶会随区块网格生成动态光源：
#   godot --headless --path <项目> --script res://tests/test_block_lights.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")
const World = preload("res://scripts/World.gd")

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
	var lib := BlockLibrary.new()
	var world := World.new()
	root.add_child(world)
	world.setup(lib, 2026, "")

	var cc := Vector2i(0, 0)
	var chunk := Chunk.new(0, 0)
	world._chunks[cc] = chunk
	for i in range(3):
		chunk.set_block(i, 20, 2, BlockLibrary.LANTERN)
	for i in range(3):
		chunk.set_block(i + 4, 20, 2, BlockLibrary.MOONSTONE_LAMP)
	for i in range(World.CHUNK_LIGHT_LIMIT):
		chunk.set_block(i % Chunk.SX, 24 + int(i / Chunk.SX), 4, BlockLibrary.BLUE_CRYSTAL)
	world._remesh_sync(cc)

	check(world._nodes.has(cc), "区块节点已生成")
	var entry: Dictionary = world._nodes[cc]
	check(entry.has("lights"), "区块带光源根节点")
	var lights: Node3D = entry["lights"]
	check(lights.get_child_count() == World.CHUNK_LIGHT_LIMIT, "区块光源数量受上限控制")
	check(lights.visible, "有发光方块时光源根节点可见")
	var first = lights.get_child(0)
	check(first is OmniLight3D, "发光方块生成 OmniLight3D")
	if first is OmniLight3D:
		var light := first as OmniLight3D
		check(light.light_energy > 1.0, "灯笼光源亮度较高")
		check(light.omni_range >= 7.0, "灯笼光源范围足够照亮遗迹")
		check(not light.shadow_enabled, "区块点光源不启用阴影以控制性能")
	check(_has_cool_lamp_light(lights), "月石灯生成冷色中强度光源")
	check(_has_blue_crystal_light(lights), "蓝晶生成较弱冷色光源")
	world._center = Vector2i(8, 8)
	world._refresh_all_chunk_light_visibility()
	check(not lights.visible, "远离玩家中心的区块光源会隐藏")
	world._center = cc
	world._refresh_all_chunk_light_visibility()
	check(lights.visible, "靠近玩家中心的区块光源会恢复可见")

	for y in range(Chunk.SY):
		for z in range(Chunk.SZ):
			for x in range(Chunk.SX):
				if chunk.get_block(x, y, z) == BlockLibrary.LANTERN \
						or chunk.get_block(x, y, z) == BlockLibrary.MOONSTONE_LAMP \
						or chunk.get_block(x, y, z) == BlockLibrary.BLUE_CRYSTAL:
					chunk.set_block(x, y, z, BlockLibrary.AIR)
	world._remesh_sync(cc)
	check(lights.get_child_count() == 0, "移除发光方块后光源刷新为空")
	check(not lights.visible, "无发光方块时光源根节点隐藏")

	world.free()

	if failed == 0:
		print("✅ ALL BLOCK LIGHT TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个区块光源测试失败")
	quit(failed)

func _has_cool_lamp_light(lights: Node3D) -> bool:
	for child in lights.get_children():
		if not (child is OmniLight3D):
			continue
		var light := child as OmniLight3D
		if light.light_color.b > light.light_color.r and light.light_energy > 0.9 and light.omni_range >= 6.0:
			return true
	return false

func _has_blue_crystal_light(lights: Node3D) -> bool:
	for child in lights.get_children():
		if not (child is OmniLight3D):
			continue
		var light := child as OmniLight3D
		if light.light_color.b > light.light_color.r and light.light_energy < 0.8:
			return true
	return false
