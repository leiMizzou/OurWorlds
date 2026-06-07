extends SceneTree
# 验证入门旅程进度会随玩家行为推进，并写入世界存档：
#   godot --headless --path <项目> --script res://tests/test_journey_progress.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const GameSettings = preload("res://scripts/GameSettings.gd")

var _f := 0
var _main = null
var failed := 0
var _path := "user://tests/journey_progress/world.json"
var _landmark := Vector3i(8, 40, 8)

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.unset_environment("VC_NO_SAVE")
		OS.set_environment("VC_SAVE_PATH", _path)
		OS.set_environment("VC_SEED", "8642")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/journey_progress/settings.json")
		# 预置 language=zh，使断言里的中文文案不受运行机 OS 语言影响（确定性回归）。
		_seed_language("zh")
		_clean_save()
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		_main.discovery_tracker.set_process(false)
	elif _f == 24:
		check(_main.world.journey_count() == 0, "新世界旅程从 0 开始")
		check(_main.world.journey_total() == 8, "新世界旅程扩展为 8 个目标")
		check(_main.hud._guide_label.text.contains("探索附近地形"), "HUD 初始目标提示探索")
		check(_main.hud._guide_label.text.contains("WASD"), "HUD 初始目标带移动入口提示")
		_main.player.global_position += Vector3(8.0, 0.0, 0.0)
	elif _f == 30:
		check(_main.world.is_journey_step_done("explore"), "移动后完成探索目标")
		check(_main.hud._guide_label.text.contains("选择一种材料"), "探索后提示选择材料")
		_main.player.action_feedback.emit("select", "草方块")
	elif _f == 34:
		check(_main.world.is_journey_step_done("select_material"), "选择材料后记录旅程")
		check(_main.hud._guide_label.text.contains("打开材料库"), "选材后提示打开材料库")
		check(_main.hud._guide_label.text.contains("E"), "材料库目标带快捷键提示")
		_main.set_palette_active(true)
	elif _f == 38:
		check(_main.world.is_journey_step_done("open_palette"), "打开材料库后记录旅程")
		check(_main.block_palette.visible, "材料库目标会打开材料库界面")
		check(_main.hud._guide_label.text.contains("放置一个方块"), "材料库后提示放置")
		_main.set_palette_active(false)
		_main.player.action_feedback.emit("place", "草方块")
	elif _f == 42:
		check(_main.world.is_journey_step_done("place_block"), "放置后记录旅程")
		check(_main.hud._guide_label.text.contains("使用建造模板"), "放置后提示使用模板")
		_main.player.template_index = 1
		_main.player.action_feedback.emit("place", "平台 草方块 x9")
	elif _f == 46:
		check(_main.world.is_journey_step_done("use_template"), "模板放置后记录旅程")
		check(_main.hud._guide_label.text.contains("查看世界地图"), "模板后提示查看地图")
		check(_main.hud._guide_label.text.contains("M"), "地图目标带快捷键提示")
		_main.set_world_map_active(true)
	elif _f == 50:
		check(_main.world.is_journey_step_done("open_map"), "打开地图后记录旅程")
		check(_main.world_map.visible, "地图目标会打开世界地图")
		check(_main.hud._guide_label.text.contains("记录一处遗迹"), "地图后提示记录遗迹")
		_main.set_world_map_active(false)
		_main.discovery_tracker._remember_discovery(_landmark, "8,40,8")
		_main.hud.set_last_discovery_label("发现晨雾石环")
		_main._on_landmark_discovered(_landmark, "发现晨雾石环")
	elif _f == 54:
		check(_main.world.is_journey_step_done("discover_landmark"), "发现遗迹后记录旅程")
		check(_main.landmark_marker.visible, "发现后世界内显示修复信标")
		check(_main.landmark_marker.marker_mode() == "repair", "发现后信标切换为修复模式")
		check(_main.landmark_marker.marker_progress() == 0, "修复信标初始进度为 0")
		check(_main.hud._guide_label.text.contains("保存世界"), "发现后提示保存世界")
		_main._save_from_menu()
	elif _f == 60:
		check(_main.world.is_journey_step_done("save_world"), "保存后完成保存目标")
		check(_main.world.journey_count() == 8, "八个发布向旅程全部完成")
		check(FileAccess.file_exists(_path), "旅程完成后世界存档已写入")
		check(_main.hud._guide_label.text.contains("晨雾石环") or _main.hud._guide_label.text.contains("遗迹"), "完成后 HUD 进入开放目标")
		check(_main.hud._guide_label.text.contains("0%"), "开放目标显示当前修复百分比")
		_main.hud.set_discovery_count(1)
		_main.hud.set_last_discovery_label("发现晨雾石环")
		_main.hud._process(0.0)
		check(_main.hud._guide_label.text.contains("晨雾石环"), "发现后 HUD 开放目标指向具名遗迹")
		check(_main.hud._guide_label.text.contains("右键"), "修复目标带建造入口提示")
		_emit_places(_raise_repair_to(5))
	elif _f == 64:
		check(_main.hud._guide_label.text.contains("25%"), "开放目标随修复进度更新")
		check(_main.landmark_marker.visible, "修复中保持世界内信标")
		check(_main.landmark_marker.marker_progress() == 25, "修复信标随进度更新")
		_emit_places(_raise_repair_to(20))
	elif _f == 68:
		check(_main.hud._guide_label.text.contains("已修复 1"), "修复完成后开放目标转向下一处遗迹")
		check(_main.hud._guide_label.text.contains("最佳 100%"), "开放目标保留最佳修复度")
		# 修复完成后世界内信标转为“完成模式”留作纪念（与 test_landmark_repair_feedback /
		# test_landmark_repair_restore_seen 的完成信标设计一致：完成态保留、读档后仍在）。
		check(_main.landmark_marker.visible and _main.landmark_marker.marker_mode() == "complete", "修复完成后信标转为完成纪念模式")
	elif _f >= 78:
		_clean_save()
		if failed == 0:
			print("✅ ALL JOURNEY PROGRESS TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个旅程进度测试失败")
		return true
	return false

func _clean_save() -> void:
	var abs_dir := ProjectSettings.globalize_path(_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(abs_dir)
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))

func _raise_repair_to(target_count: int) -> Array:
	var placed := []
	for dy in range(1, 5):
		for dz in range(-6, 7):
			for dx in range(-6, 7):
				if dx == 0 and dz == 0:
					continue
				if int(_main.world.edited_blocks_near(_landmark)) >= target_count:
					return placed
				var cell := _landmark + Vector3i(dx, dy, dz)
				_main.world.set_block(cell.x, cell.y, cell.z, BlockLibrary.MOONSTONE_LAMP)
				placed.append(cell)
	return placed

func _emit_places(cells: Array) -> void:
	for raw in cells:
		var cell: Vector3i = raw
		_main._on_player_world_feedback("place", cell, BlockLibrary.MOONSTONE_LAMP)

# 写入仅含 language 的设置文件；Main 启动会据此把界面语言定为该语言。
func _seed_language(lang: String) -> void:
	var settings := GameSettings.load_settings()
	settings["language"] = lang
	GameSettings.save_settings(settings)
