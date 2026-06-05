extends SceneTree
# 验证 HUD 状态栏显示保存状态：
#   godot --headless --path <项目> --script res://tests/test_save_status_hud.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _f := 0
var _main = null
var failed := 0
var _path := "user://tests/save_status/world.json"

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
		OS.set_environment("VC_SEED", "5151")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/save_status/settings.json")
		_clean_save()
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 24:
		check(_main.hud._status_label.text.contains("已保存"), "启动后 HUD 显示已保存")
		var p = _main.player.global_position
		var x := int(floor(p.x)) + 3
		var z := int(floor(p.z))
		var y: int = _main.world.surface_y(x, z) + 1
		check(_main.world.request_edit(x, y, z, BlockLibrary.LANTERN), "编辑世界产生未保存改动")
	elif _f == 28:
		check(_main.world.has_unsaved_changes(), "世界记录未保存改动")
		check(_main.hud._status_label.text.contains("有改动"), "编辑后 HUD 显示有改动")
		_main.set_game_paused(true)
		check(_main.pause_menu.visible, "保存前暂停菜单可见")
		check(_main.pause_menu._location_summary_label.text.contains("有改动"), "保存前暂停菜单摘要显示有改动")
		_main._save_from_menu()
	elif _f == 34:
		check(not _main.world.has_unsaved_changes(), "保存后世界不再有未保存改动")
		check(_main.hud._status_label.text.contains("已保存"), "保存后 HUD 回到已保存")
		check(_main.pause_menu._location_summary_label.text.contains("已保存"), "保存后暂停菜单摘要回到已保存")
		_main.set_game_paused(false)
		_main.world.save_path = ""
		_main._sync_hud_save_state()
	elif _f == 38:
		check(_main.hud._status_label.text.contains("本地会话"), "禁用存档时 HUD 显示本地会话")
	elif _f >= 64:
		_clean_save()
		if failed == 0:
			print("✅ ALL SAVE STATUS HUD TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个保存状态 HUD 测试失败")
		return true
	return false

func _clean_save() -> void:
	var abs_dir := ProjectSettings.globalize_path(_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(abs_dir)
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))
