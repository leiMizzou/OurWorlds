extends SceneTree
# 验证拍照/沉浸模式会隐藏 HUD 和建造叠层，恢复后不影响正常交互：
#   godot --headless --path <项目> --script res://tests/test_photo_mode.gd

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
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/photo_mode/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		var player = _main.player
		player.highlight.visible = true
		player.placement_preview.visible = true
		player.placement_blocked_preview.visible = true
		player.brush_preview_lines.visible = true
		check(_main.photo_overlay != null and not _main.photo_overlay.is_active(), "默认不显示拍照取景层")
		_main.set_photo_mode(true)
		check(_main._photo_mode, "拍照模式已开启")
		check(not _main.hud.visible, "拍照模式隐藏 HUD")
		check(not player.overlays_visible, "拍照模式关闭玩家叠层")
		check(_main.photo_overlay.is_active(), "拍照模式显示取景构图层")
		check(_main.photo_overlay.guide_line_count() >= 8, "取景层包含三分线和中心标记")
		check(_main.photo_overlay.has_frame(), "取景层包含安全边框")
		check(_main.photo_overlay.vignette_piece_count() == 4, "取景层包含四边暗角")
		check(not player.highlight.visible, "拍照模式隐藏准星高亮")
		check(not player.placement_preview.visible, "拍照模式隐藏放置预览")
		check(not player.placement_blocked_preview.visible, "拍照模式隐藏阻挡格预览")
		check(not player.brush_preview_lines.visible, "拍照模式隐藏画笔线框")
		_main.set_game_paused(true)
		check(not _main.photo_overlay.is_active(), "暂停菜单打开时隐藏拍照取景层")
		_main.set_game_paused(false)
		check(_main.photo_overlay.is_active(), "恢复游戏后取景层回到拍照状态")

		_main.set_photo_mode(false)
		check(not _main._photo_mode, "拍照模式可关闭")
		check(_main.hud.visible, "关闭拍照模式后 HUD 恢复")
		check(player.overlays_visible, "关闭拍照模式后玩家叠层恢复")
		check(not _main.photo_overlay.is_active(), "关闭拍照模式后隐藏取景层")

		_main.set_title_active(true)
		_main.set_photo_mode(false)
		check(not _main.hud.visible, "标题层显示时 HUD 仍由标题层隐藏")
		check(not _main.photo_overlay.is_active(), "标题层显示时取景层隐藏")
		_main.set_title_active(false)
		check(_main.hud.visible, "离开标题层后 HUD 恢复")

		var ev := InputEventKey.new()
		ev.pressed = true
		ev.keycode = KEY_F1
		_main._unhandled_input(ev)
		check(_main._photo_mode and not _main.hud.visible and _main.photo_overlay.is_active(), "F1 可开启拍照模式")
		_main._unhandled_input(ev)
		check(not _main._photo_mode and _main.hud.visible and not _main.photo_overlay.is_active(), "F1 可关闭拍照模式")
		var screenshot_path: String = _main._screenshot_path()
		check(screenshot_path.begins_with("user://screenshots/voxelcraft_") and screenshot_path.ends_with(".png"), "截图路径写入用户截图目录")
		var f2 := InputEventKey.new()
		f2.pressed = true
		f2.keycode = KEY_F2
		_main._unhandled_input(f2)
		check(_main.hud._feedback_label.text == "当前渲染驱动无法截图", "headless 下 F2 给出截图失败反馈")
		check(_main.save_screenshot() == "", "headless 下截图函数安全失败")
		_main.hud._feedback_label.text = ""
		_main.set_photo_mode(true)
		_main._unhandled_input(f2)
		check(not _main.hud.visible, "拍照模式截图反馈不会打断沉浸 HUD")
		check(_main.hud._feedback_label.text == "", "拍照模式截图反馈先延后显示")
		_main.set_photo_mode(false)
		check(_main.hud._feedback_label.text == "当前渲染驱动无法截图", "退出拍照模式后补显示截图反馈")

		if failed == 0:
			print("✅ ALL PHOTO MODE TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个拍照模式测试失败")
		return true
	return false
