extends SceneTree
# 验证暂停菜单、设置项和恢复路径：
#   godot --headless --path <项目> --script res://tests/test_pause_menu.gd

const WorldCatalog = preload("res://scripts/WorldCatalog.gd")
const GameSettings = preload("res://scripts/GameSettings.gd")

var _f := 0
var _main = null
var failed := 0
var _saw_quality := false

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
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/pause_menu/settings.json")
		# 预置 language=zh 落盘，Main._ready 的 Locale.init 会读到它 ——
		# 这样断言里的中文文案与摘要不受运行机 OS 语言影响（确定性回归）。
		_seed_language("zh")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		_main.set_game_paused(true)
		check(paused, "暂停后 SceneTree.paused=true")
		check(_main.pause_menu.visible, "暂停菜单可见")
		check(not _main.player.input_enabled, "暂停后玩家输入禁用")
		check(_main.pause_menu._title_button != null and _main.pause_menu._title_button.visible, "暂停菜单包含返回标题入口")
		check(_main.pause_menu._summary_box.visible, "暂停菜单显示当前世界摘要")
		check(_main.pause_menu._world_summary_label.text.contains(WorldCatalog.world_name(1337)) and _main.pause_menu._world_summary_label.text.contains("#1337"), "世界摘要显示世界名和种子")
		check(_main.pause_menu._journey_summary_label.text.contains("旅程：0/8") and _main.pause_menu._journey_summary_label.text.contains("探索附近地形"), "世界摘要显示旅程进度和下个目标")
		check(_main.pause_menu._landmark_summary_label.text.contains("遗迹：发现 0") and _main.pause_menu._landmark_summary_label.text.contains("修复 0"), "世界摘要显示遗迹发现和修复概况")
		check(_main.pause_menu._summary_chips.get_child_count() == 4, "暂停菜单显示四项世界状态卡片")
		check(_node_has_text(_main.pause_menu._summary_chips, "旅程") and _node_has_text(_main.pause_menu._summary_chips, "0/8"), "世界状态卡片显示旅程进度")
		check(_node_has_text(_main.pause_menu._summary_chips, "遗迹") and _node_has_text(_main.pause_menu._summary_chips, "发现 0"), "世界状态卡片显示遗迹进度")
		check(_node_has_text(_main.pause_menu._summary_chips, "修复") and _node_has_text(_main.pause_menu._summary_chips, "暂无目标"), "世界状态卡片显示修复状态")
		check(_node_has_text(_main.pause_menu._summary_chips, "归途") and _node_has_text(_main.pause_menu._summary_chips, "附近"), "世界状态卡片显示归途状态")
		check(_main.pause_menu._location_summary_label.text.contains("位置：") and _main.pause_menu._location_summary_label.text.contains("本地会话"), "世界摘要显示位置与存档状态")
		check(_main.pause_menu._location_summary_label.text.contains(str(_main._pause_summary_data().get("region_detail", ""))), "世界摘要显示地貌描述")
		check(_main.pause_menu._location_summary_label.text.contains("区域："), "世界摘要显示区域探索进度")
		_main._on_view_radius_changed(2)
		check(_main.world.view_radius == 2, "菜单可调整视距")
		_main._on_volume_changed(0.25)
		check(abs(_main.audio_feedback.volume - 0.25) < 0.001, "菜单可调整音量")
		_main._on_sensitivity_changed(1.4)
		check(abs(_main.player.mouse_sensitivity - _main.player.DEFAULT_SENS * 1.4) < 0.00001, "菜单可调整灵敏度")
		_main._on_weather_enabled_changed(false)
		check(not _main.weather_system.enabled, "菜单可关闭动态天气")
		_main._on_weather_enabled_changed(true)
		check(_main.weather_system.enabled, "菜单可开启动态天气")
		_saw_quality = false
		_main.pause_menu.graphics_quality_changed.connect(func(value: String): _saw_quality = value == "performance")
		_main.pause_menu._quality_option.select(0)
		_main.pause_menu._on_quality_selected(0)
		check(_saw_quality, "菜单画质选项发出变更信号")
		check(_main._graphics_quality == "performance", "菜单可切换性能画质")
		check(not _main._sun.shadow_enabled, "性能画质关闭太阳阴影")
		check(not _main._env.glow_enabled, "性能画质关闭辉光")
		check(not _main._cloud_root.visible, "性能画质隐藏云层")
		check(_main._stars.multimesh.visible_instance_count < _main.STAR_COUNT, "性能画质减少星空实例")
		_main._on_graphics_quality_changed("balanced")
		check(_main._sun.shadow_enabled, "均衡画质恢复太阳阴影")
		check(_main._env.glow_enabled, "均衡画质恢复辉光")
		check(_main._cloud_root.visible, "均衡画质恢复云层")
		_main.pause_menu.title_requested.emit()
		check(paused, "返回标题后仍暂停世界")
		check(_main.title_screen.visible, "返回标题后标题层可见")
		check(not _main.pause_menu.visible, "返回标题后暂停菜单隐藏")
		check(not _main.hud.visible, "返回标题后 HUD 隐藏")
		check(not _main.player.input_enabled, "返回标题后玩家输入禁用")
		_main.set_title_active(false)
		check(not paused, "从返回后的标题层继续可恢复游戏")
		_main.set_game_paused(false)
		check(not paused, "恢复后 SceneTree.paused=false")
		check(not _main.pause_menu.visible, "恢复后菜单隐藏")
		check(_main.player.input_enabled, "恢复后玩家输入启用")
		if failed == 0:
			print("✅ ALL PAUSE MENU TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个暂停菜单测试失败")
		return true
	return false

# 写入仅含 language 的设置文件；Main 启动会据此把界面语言定为该语言。
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
