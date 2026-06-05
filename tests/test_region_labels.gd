extends SceneTree
# 验证地形区域标签稳定、可区分，并能同步到 HUD：
#   godot --headless --path <项目> --script res://tests/test_region_labels.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")

var _f := 0
var _main = null
var failed := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	var gen := WorldGenerator.new(1337)
	var labels := {}
	for z in range(-192, 193, 12):
		for x in range(-192, 193, 12):
			labels[gen.region_label(x, z)] = true
	check(labels.size() >= 5, "固定种子附近可识别多个区域")
	check(labels.has("草原") or labels.has("风草原"), "区域标签包含草地型地貌")
	check(labels.has("湿地") or labels.has("浅水湾") or labels.has("沙岸") or labels.has("黏土滩"), "区域标签包含水岸/湿地地貌")
	check(labels.has("岩岭") or labels.has("玄武岩岭") or labels.has("雪峰"), "区域标签包含山地地貌")
	_check_region_descriptions(labels.keys())
	_check_surface_consistency(gen)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.set_environment("VC_NO_SAVE", "1")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/region_labels/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 36:
		var p: Vector3 = _main.player.global_position
		var label: String = _main.world.region_label(int(floor(p.x)), int(floor(p.z)))
		var detail: String = _main.world.region_description(int(floor(p.x)), int(floor(p.z)))
		check(label != "", "World 返回玩家所在区域标签")
		check(detail != "", "World 返回玩家所在区域描述")
		_main._sync_hud_region(false)
		_main.hud._process(0.0)
		check(_main.hud._status_label.text.contains(label), "HUD 状态栏显示当前区域")
		check(_main.world.region_count() >= 1 and _main.world.visited_regions().has(label), "初始区域会记录为已踏足")
		check(_main.ambient_motes.current_region_label() == label, "环境微光同步当前区域")
		var old_label: String = _main._last_region_label
		var old_region_count: int = _main.world.region_count()
		_main.player.global_position = _find_different_region(_main.world, p, old_label)
		_main._sync_hud_region(true)
		check(_main._last_region_label != old_label, "跨区域后 Main 更新当前区域")
		var new_detail: String = _main.world.region_description(int(floor(_main.player.global_position.x)), int(floor(_main.player.global_position.z)))
		check(_main.world.region_count() > old_region_count, "首次跨入新区域会增加区域进度")
		check(_main.hud._feedback_label.text.begins_with("发现新地貌") and _main.hud._feedback_label.text.contains(new_detail), "首次跨区域后 HUD 给出带地貌描述的新地貌反馈")
		check(_main.ambient_motes.current_region_label() == _main._last_region_label, "跨区域后环境微光同步新区域")
		if failed == 0:
			print("✅ ALL REGION LABEL TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个区域标签测试失败")
		return true
	return false

func _check_region_descriptions(labels: Array) -> void:
	var descriptions := {}
	for raw in labels:
		var label := String(raw)
		var detail := WorldGenerator.region_description_for_label(label)
		check(detail != "" and detail != "地貌变化，留意资源", "%s 有专属地貌描述" % label)
		descriptions[detail] = true
	check(descriptions.size() >= min(5, labels.size()), "区域描述可区分")
	check(WorldGenerator.region_description_for_label("未知地貌") != "", "未知区域也有兜底描述")

func _check_surface_consistency(gen: WorldGenerator) -> void:
	for z in range(-160, 161, 8):
		for x in range(-160, 161, 8):
			var h := gen.surface_height(x, z)
			var label := gen.region_label(x, z)
			if h < WorldGenerator.SEA_LEVEL:
				check(label == "浅水湾", "海平面以下标记为浅水湾")
				return
			if label == "沙岸" or label == "黏土滩":
				check(h <= WorldGenerator.SEA_LEVEL + 1, "岸线区域贴近海平面")
				return
			if label == "湿地":
				check(h <= WorldGenerator.SEA_LEVEL + 12, "湿地区域处于低地范围")
				return
	check(false, "固定范围内找到可校验的水岸/湿地区域")

func _find_different_region(world, start: Vector3, old_label: String) -> Vector3:
	var sx := int(floor(start.x))
	var sz := int(floor(start.z))
	for r in range(16, 256, 16):
		for raw_dz in [-r, 0, r]:
			for raw_dx in [-r, 0, r]:
				var dx := int(raw_dx)
				var dz := int(raw_dz)
				var x := sx + dx
				var z := sz + dz
				if world.region_label(x, z) == old_label:
					continue
				return Vector3(x + 0.5, world.surface_y(x, z) + 3.0, z + 0.5)
	return start + Vector3(96, 0, 0)
