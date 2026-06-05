extends SceneTree
# 验证 HUD 紧凑导航罗盘会同步朝向、归途、线索和修复目标：
#   godot --headless --path <项目> --script res://tests/test_hud_compass.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _f := 0
var _main = null
var failed := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.set_environment("VC_NO_SAVE", "1")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SEED", "6161")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/hud_compass/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		_main.hud._process(0.1)
		var compass: String = _main.hud._compass_label.text
		check(_main.hud._compass_label != null, "HUD 创建导航罗盘文本")
		check(compass.contains("方位") and compass.contains("北"), "导航罗盘显示默认朝向")

		_main.player.global_position = _main._journey_start_pos + Vector3(34.0, 0.0, 0.0)
		_main.hud._process(0.1)
		compass = _main.hud._compass_label.text
		check(compass.contains("归途"), "导航罗盘离开出生点后显示归途")

		_main.hud.set_restoration_goal("", -1, false, 0, 0)
		_main.hud.set_nearby_landmark_hint(31, "右前")
		_main.hud._process(0.1)
		compass = _main.hud._compass_label.text
		check(compass.contains("线索") and compass.contains("31m") and compass.contains("右前"), "导航罗盘显示附近遗迹线索")

		var target_landmark := Vector3i(62, 40, -32)
		_main.world.mark_landmark_discovered(target_landmark)
		_raise_repair_to(_main.world, target_landmark, 8)
		for key in ["explore", "select_material", "open_palette", "place_block", "use_template", "open_map", "discover_landmark", "save_world"]:
			_main.world.mark_journey_step(key)
		_main._sync_hud_journey()
		_main._sync_hud_restoration()
		_main.hud._process(0.1)
		compass = _main.hud._compass_label.text
		check(compass.contains("修复") and compass.contains("m"), "导航罗盘优先显示当前修复目标")
		var guide: String = _main.hud._guide_label.text
		check(guide.contains("修复") and guide.contains("%") and (guide.contains("约") or guide.contains("附近")), "HUD 主目标显示修复目标进度与导航")

		if failed == 0:
			print("✅ ALL HUD COMPASS TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个 HUD 导航罗盘测试失败")
		return true
	return false

func _raise_repair_to(world, landmark: Vector3i, target_count: int) -> void:
	for dz in range(-4, 5):
		for dx in range(-4, 5):
			if dx == 0 and dz == 0:
				continue
			if int(world.edited_blocks_near(landmark)) >= target_count:
				return
			world.set_block(landmark.x + dx, landmark.y + 1, landmark.z + dz, BlockLibrary.MOONSTONE_LAMP)
