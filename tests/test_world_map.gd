extends SceneTree
# 验证世界地图的打开/关闭、暂停状态和导航数据：
#   godot --headless --path <项目> --script res://tests/test_world_map.gd

const WorldCatalog = preload("res://scripts/WorldCatalog.gd")
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
		OS.set_environment("VC_SEED", "5151")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/world_map/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		_main.player.global_position = _main._journey_start_pos + Vector3(42, 0, -18)
		var landmark := Vector3i(8, 40, 8)
		var target_landmark := Vector3i(62, 40, -32)
		_main.world.mark_landmark_discovered(landmark)
		_main.world.mark_landmark_discovered(target_landmark)
		_raise_repair_to(_main.world, landmark, 20)
		_raise_repair_to(_main.world, target_landmark, 8)
		_main.discovery_tracker._nearby_hint_distance = 31
		_main.discovery_tracker._nearby_hint_direction = "右前"
		_main.discovery_tracker._nearby_hint_position = _main.player.global_position + Vector3(30, 0, -8)
		var data: Dictionary = _main._map_data()
		check(str(data.get("world_name", "")) == WorldCatalog.world_name(5151), "地图数据包含稳定世界名")
		check(str(data.get("region_detail", "")) != "", "地图数据包含当前地貌描述")
		check(int(data.get("region_count", 0)) >= 1 and int(data.get("region_total", 0)) > 1, "地图数据包含区域探索进度")
		var region_samples: Array = data.get("region_samples", [])
		check(region_samples.size() >= 80, "地图数据包含玩家周围地貌采样")
		check(_sampled_region_count(region_samples) >= 2, "地图地貌采样覆盖多个区域")
		check(int(data.get("home_distance", 0)) > 0, "地图数据包含归途距离")
		check(bool(data.get("nearby_valid", false)), "地图数据包含附近线索")
		var landmarks: Array = data.get("landmarks", [])
		check(landmarks.size() == 2, "地图数据包含已发现遗迹")
		check(typeof((landmarks[0] as Dictionary).get("world_pos")) == TYPE_VECTOR3, "遗迹记录包含世界坐标")
		check(int((landmarks[0] as Dictionary).get("restore_percent", 0)) > 0, "地图数据包含遗迹修复度")
		var target: Dictionary = data.get("restoration_target", {})
		check(not target.is_empty(), "地图数据包含当前修复目标")
		check(int(target.get("restore_percent", 0)) > 0 and int(target.get("restore_percent", 0)) < 100, "地图优先指向未完成修复目标")
		check(str(target.get("restore_label", "")).contains("修复"), "地图修复目标数据包含修复状态")

		_main.set_world_map_active(true)
		check(paused, "打开地图后暂停世界")
		check(_main._map_active, "地图状态标记开启")
		check(_main.world_map.visible, "地图面板可见")
		check(not _main.pause_menu.visible, "打开地图时暂停菜单隐藏")
		check(not _main.player.input_enabled, "打开地图后玩家输入禁用")
		check(_main.world_map._world_label.text.contains(WorldCatalog.world_name(5151)), "地图显示世界名")
		check(_main.world_map._summary_label.text.contains(str(data.get("region_detail", ""))), "地图摘要显示地貌描述")
		check(_main.world_map._summary_label.text.contains("区域"), "地图摘要显示区域探索进度")
		check(_main.world_map._summary_label.text.contains("归途"), "地图显示归途摘要")
		check(_main.world_map._summary_label.text.contains("已修复  1"), "地图摘要显示已修复遗迹数")
		check(_main.world_map._summary_label.text.contains("最佳  100%"), "地图摘要显示最佳修复度")
		check(_main.world_map._stats_label.text.contains("修复目标"), "地图统计显示当前修复目标")
		check(_main.world_map._stats_label.text.contains("修复中"), "地图统计显示当前目标修复状态")
		check(_main.world_map._nav_row.get_child_count() == 4, "地图显示四项导航卡片")
		check(_node_has_text(_main.world_map._nav_row, "坐标") and _node_has_text(_main.world_map._nav_row, "范围"), "地图导航卡片显示坐标和范围")
		check(_node_has_text(_main.world_map._nav_row, "修复目标") and _node_has_text(_main.world_map._nav_row, "修复中"), "地图导航卡片显示当前修复目标")
		check(_node_has_text(_main.world_map._nav_row, "附近线索") and _node_has_text(_main.world_map._nav_row, "右前"), "地图导航卡片显示附近线索")
		check(_main.world_map._map_canvas.landmark_count() == 2, "地图画布接收遗迹数量")
		check(_main.world_map._map_canvas.restored_count() == 1, "地图画布接收已修复遗迹数")
		check(_main.world_map._map_canvas.best_restoration_percent() > 0, "地图画布接收遗迹修复度")
		check(_main.world_map._map_canvas.has_nearby_hint(), "地图画布接收附近线索")
		check(_main.world_map._map_canvas.has_restoration_target(), "地图画布接收修复目标")
		check(_main.world_map._map_canvas.restoration_target_distance() > 0, "地图画布接收修复目标距离")
		check(_main.world_map._map_canvas.map_radius() >= 48.0, "地图画布半径有效")
		check(_main.world_map._map_canvas.region_sample_count() == region_samples.size(), "地图画布接收地貌采样")
		check(_main.world_map._map_canvas.sampled_region_count() >= 2, "地图画布识别多个地貌区域")

		_main.set_world_map_active(false)
		check(not paused, "关闭地图后恢复世界")
		check(not _main.world_map.visible, "关闭地图后面板隐藏")
		check(_main.player.input_enabled, "关闭地图后玩家输入恢复")
		check(not _main._map_return_to_pause, "游戏内关闭地图后不残留暂停返回标记")
		if not _is_headless_run():
			check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "游戏内关闭地图后鼠标恢复捕获")

		var m_event := InputEventKey.new()
		m_event.pressed = true
		m_event.keycode = KEY_M
		_main._unhandled_input(m_event)
		check(_main._map_active and _main.world_map.visible, "M 键可打开地图")
		var esc_event := InputEventKey.new()
		esc_event.pressed = true
		esc_event.keycode = KEY_ESCAPE
		_main._unhandled_input(esc_event)
		check(not _main._map_active and not _main.world_map.visible, "Esc 可关闭地图")

		_main.set_game_paused(true)
		_main.set_world_map_active(true)
		check(paused and _main.world_map.visible, "暂停菜单中可打开地图")
		_main.set_world_map_active(false)
		check(paused, "从暂停菜单打开的地图关闭后仍暂停")
		check(_main.pause_menu.visible, "从暂停菜单打开的地图关闭后回到暂停菜单")
		check(not _main._map_return_to_pause, "地图返回暂停菜单后清理返回标记")
		check(not _main.player.input_enabled, "地图返回暂停菜单后玩家输入仍禁用")
		if not _is_headless_run():
			check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "地图返回暂停菜单后鼠标保持可见")
		_main.set_game_paused(false)
		check(not paused, "最终可恢复游戏")
		check(_main.player.input_enabled, "最终恢复后玩家输入启用")
		if not _is_headless_run():
			check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "最终恢复后鼠标捕获")

		if failed == 0:
			print("✅ ALL WORLD MAP TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个世界地图测试失败")
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

func _sampled_region_count(samples: Array) -> int:
	var labels := {}
	for raw in samples:
		var entry: Dictionary = raw
		var label := String(entry.get("region", ""))
		if label != "":
			labels[label] = true
	return labels.size()

func _node_has_text(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.contains(needle):
		return true
	for child in node.get_children():
		if _node_has_text(child, needle):
			return true
	return false

func _is_headless_run() -> bool:
	if OS.has_feature("headless"):
		return true
	if DisplayServer.get_name().to_lower().contains("headless"):
		return true
	return OS.get_cmdline_args().has("--headless")
