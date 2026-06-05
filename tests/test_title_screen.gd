extends SceneTree
# 验证首屏标题入口：
#   godot --headless --path <项目> --script res://tests/test_title_screen.gd

var _f := 0
var _main = null
var failed := 0
var _checked := false

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
		OS.unset_environment("VC_SKIP_TITLE")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/title_screen/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 20:
		check(paused, "标题层显示时游戏暂停")
		check(_main.title_screen.visible, "标题层可见")
		check(not _main.hud.visible, "标题层显示时 HUD 隐藏")
		check(not _main.player.input_enabled, "标题层显示时玩家输入禁用")
		check(_main.title_screen._settings_button != null, "标题层包含设置入口")
		_main.title_screen._settings_button.pressed.emit()
		check(paused, "标题设置打开后仍保持暂停")
		check(_main.title_screen.visible, "标题设置打开后标题层仍可见")
		check(_main.pause_menu.visible, "标题设置打开暂停菜单设置面板")
		check(_main.pause_menu._resume_button.text == "返回标题", "标题设置按钮文案为返回标题")
		check(not _main.pause_menu._save_button.visible, "标题设置隐藏游戏内保存入口")
		check(not _main.pause_menu._palette_button.visible, "标题设置隐藏材料库入口")
		check(not _main.pause_menu._title_button.visible, "标题设置隐藏返回标题入口")
		_main.pause_menu._quality_option.select(2)
		_main.pause_menu._on_quality_selected(2)
		check(_main._graphics_quality == "cinematic", "标题设置可切换画质")
		_main.pause_menu.resume_requested.emit()
		check(paused, "关闭标题设置后仍保持标题暂停")
		check(_main.title_screen.visible, "关闭标题设置后回到标题层")
		check(not _main.pause_menu.visible, "关闭标题设置后设置面板隐藏")
		_main.title_screen._on_background_gui_input(_left_click())
		check(not paused, "点击标题背景后游戏恢复")
		check(not _main.title_screen.visible, "点击标题背景后标题层隐藏")
		check(_main.hud.visible, "点击标题背景后 HUD 可见")
		check(_main.player.input_enabled, "点击标题背景后玩家输入启用")
		if not _is_headless_run():
			check(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED, "进入游戏后鼠标立即捕获")
		_checked = true
	elif _checked and _f >= 80:
		if failed == 0:
			print("✅ ALL TITLE SCREEN TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个标题层测试失败")
		return true
	return false

func _left_click() -> InputEventMouseButton:
	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_LEFT
	event.pressed = true
	return event

func _is_headless_run() -> bool:
	if OS.has_feature("headless"):
		return true
	if DisplayServer.get_name().to_lower().contains("headless"):
		return true
	return OS.get_cmdline_args().has("--headless")
