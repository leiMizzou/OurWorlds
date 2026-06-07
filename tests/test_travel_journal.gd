extends SceneTree
# 验证旅行手记的打开/关闭、暂停状态和内容同步：
#   godot --headless --path <项目> --script res://tests/test_travel_journal.gd

const WorldCatalog = preload("res://scripts/WorldCatalog.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const GameSettings = preload("res://scripts/GameSettings.gd")

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
		OS.set_environment("VC_SEED", "4242")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/travel_journal/settings.json")
		# 预置 language=zh 落盘，Main._ready 的 Locale.init 会读到它 ——
		# 这样断言里的中文文案不受运行机 OS 语言影响（确定性回归，同 test_pause_menu）。
		_seed_language("zh")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		_main.world.mark_journey_step("explore")
		_main.world.mark_journey_step("select_material")
		_main.world.mark_region_visited("湿地")
		_main.world.mark_region_visited("雪峰")
		var landmark := Vector3i(8, 40, 8)
		var target_landmark := Vector3i(32, 40, -14)
		_main.world.mark_landmark_discovered(landmark)
		_main.world.mark_landmark_discovered(target_landmark)
		_raise_repair_to(_main.world, landmark, 20)
		_raise_repair_to(_main.world, target_landmark, 8)
		var data: Dictionary = _main._journal_data()
		check(str(data.get("world_name", "")) == WorldCatalog.world_name(4242), "手记数据包含稳定世界名")
		check(str(data.get("region_detail", "")) != "", "手记数据包含当前地貌描述")
		check(int(data.get("region_count", 0)) >= 1 and int(data.get("region_total", 0)) > 1, "手记数据包含区域探索进度")
		check(int(data.get("journey_total", 0)) == 8, "手记数据包含旅程总数")
		var landmarks: Array = data.get("landmarks", [])
		check(landmarks.size() == 2, "手记数据包含已发现遗迹")
		check(int((landmarks[0] as Dictionary).get("restore_percent", 0)) > 0, "手记数据包含遗迹修复度")
		check(int((landmarks[0] as Dictionary).get("distance", -1)) >= 0, "手记遗迹记录包含导航距离")
		check(str((landmarks[0] as Dictionary).get("archive", "")).contains("守护物"), "手记遗迹记录包含档案短句")
		var target: Dictionary = data.get("restoration_target", {})
		check(not target.is_empty(), "手记数据包含当前修复目标")
		check(int(target.get("restore_percent", 0)) > 0 and int(target.get("restore_percent", 0)) < 100, "手记优先指向未完成修复目标")

		_main.set_journal_active(true)
		check(paused, "打开手记后暂停世界")
		check(_main._journal_active, "手记状态标记开启")
		check(_main.travel_journal.visible, "手记面板可见")
		check(not _main.pause_menu.visible, "打开手记时暂停菜单隐藏")
		check(not _main.player.input_enabled, "打开手记后玩家输入禁用")
		check(_main.travel_journal._world_label.text.contains(WorldCatalog.world_name(4242)), "手记显示世界名")
		check(_main.travel_journal._summary_label.text.contains(str(data.get("region_detail", ""))), "手记摘要显示地貌描述")
		check(_main.travel_journal._summary_label.text.contains("区域"), "手记摘要显示区域探索进度")
		check(_main.travel_journal._legacy_row.get_child_count() == 4, "手记显示四项世界印记")
		check(_node_has_text(_main.travel_journal._legacy_row, "建造") and _node_has_text(_main.travel_journal._legacy_row, "格"), "世界印记显示建造规模")
		check(_node_has_text(_main.travel_journal._legacy_row, "区域") and _node_has_text(_main.travel_journal._legacy_row, "2/"), "世界印记显示区域足迹")
		check(_node_has_text(_main.travel_journal._legacy_row, "旅程") and _node_has_text(_main.travel_journal._legacy_row, "2/8"), "世界印记显示旅程进度")
		check(_node_has_text(_main.travel_journal._legacy_row, "修复") and _node_has_text(_main.travel_journal._legacy_row, "最佳 100%"), "世界印记显示修复成果")
		check(_main.travel_journal._region_label.text.contains("区域足迹") and _main.travel_journal._region_label.text.contains("/"), "手记显示区域足迹标题")
		check(_node_has_text(_main.travel_journal._region_row, "湿地"), "手记区域足迹显示已踏足湿地")
		check(_node_has_text(_main.travel_journal._region_row, "雪峰"), "手记区域足迹显示已踏足雪峰")
		check(_node_has_text(_main.travel_journal._region_row, "未踏足"), "手记区域足迹显示剩余区域数量")
		check(_main.travel_journal._summary_label.text.contains("本地会话"), "手记显示存档状态")
		check(_main.travel_journal._summary_label.text.contains("归途"), "手记显示归途摘要")
		check(_main.travel_journal._journey_label.text.contains("2/8"), "手记显示旅程进度")
		check(_main.travel_journal._restoration_target_label.text.contains("修复目标"), "手记显示当前修复目标")
		check(_main.travel_journal._restoration_target_label.text.contains("%"), "手记目标显示修复进度")
		check(_main.travel_journal._landmark_count_label.text.contains("2"), "手记显示遗迹记录数")
		check(_main.travel_journal._landmark_count_label.text.contains("已修复  1"), "手记显示已修复遗迹数")
		check(_node_has_text(_main.travel_journal._landmark_list, "目标"), "手记遗迹列表高亮当前目标")
		check(_node_has_text(_main.travel_journal._landmark_list, "修复"), "手记遗迹列表显示修复状态")
		check(_node_has_text(_main.travel_journal._landmark_list, "100%"), "手记遗迹列表显示满修复百分比")
		check(_node_has_text(_main.travel_journal._landmark_list, "守护物"), "手记遗迹列表显示档案短句")

		_main.set_journal_active(false)
		check(not paused, "关闭手记后恢复世界")
		check(not _main.travel_journal.visible, "关闭手记后面板隐藏")
		check(_main.player.input_enabled, "关闭手记后玩家输入恢复")
		check(not _main._journal_return_to_pause, "游戏内关闭手记后不残留暂停返回标记")
		if not _is_headless_run():
			check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "游戏内关闭手记后鼠标恢复捕获")

		_main.set_game_paused(true)
		_main.set_journal_active(true)
		check(paused and _main.travel_journal.visible, "暂停菜单中可打开手记")
		_main.set_journal_active(false)
		check(paused, "从暂停菜单打开的手记关闭后仍暂停")
		check(_main.pause_menu.visible, "从暂停菜单打开的手记关闭后回到暂停菜单")
		check(not _main._journal_return_to_pause, "手记返回暂停菜单后清理返回标记")
		check(not _main.player.input_enabled, "手记返回暂停菜单后玩家输入仍禁用")
		if not _is_headless_run():
			check(Input.mouse_mode == Input.MOUSE_MODE_VISIBLE, "手记返回暂停菜单后鼠标保持可见")
		_main.set_game_paused(false)
		check(not paused, "最终可恢复游戏")
		check(_main.player.input_enabled, "最终恢复后玩家输入启用")
		if not _is_headless_run():
			check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "最终恢复后鼠标捕获")

		if failed == 0:
			print("✅ ALL TRAVEL JOURNAL TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个旅行手记测试失败")
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

func _seed_language(lang: String) -> void:
	var settings := GameSettings.load_settings()
	settings["language"] = lang
	GameSettings.save_settings(settings)

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
