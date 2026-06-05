extends SceneTree
# 验证备份恢复世界进入游戏后的 HUD / 音频反馈：
#   godot --headless --path <项目> --script res://tests/test_backup_restore_feedback.gd

var _f := 0
var _main = null
var _main_skip = null
var failed := 0
var _title_path := "user://tests/backup_feedback/title/world.json"
var _skip_path := "user://tests/backup_feedback/skip/world.json"

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		_prepare_backup_save(_title_path, 7171)
		OS.unset_environment("VC_NO_SAVE")
		OS.unset_environment("VC_SKIP_TITLE")
		OS.set_environment("VC_SAVE_PATH", _title_path)
		OS.set_environment("VC_SEED", "7171")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/backup_feedback/title_settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		check(_main.title_screen.visible, "标题路径启动时标题层可见")
		check(_main.world.loaded_from_backup(), "标题路径世界从备份恢复")
		check(_main.world.has_unsaved_changes(), "标题路径备份恢复后标记有改动")
		check(not _main.hud.visible, "标题层显示期间 HUD 仍隐藏")
		check(not _main._backup_recovery_feedback_shown, "标题层显示期间暂不标记恢复反馈已展示")
		_main.set_title_active(false)
		check(_main.hud.visible, "标题路径继续后 HUD 可见")
		check(_main.hud._status_label.text.contains("有改动"), "标题路径继续后 HUD 显示需要保存")
		check(_main.hud._feedback_label.text.contains("备份恢复"), "标题路径继续后显示备份恢复反馈")
		check(_main.audio_feedback.last_feedback_kind() == "save", "标题路径备份恢复反馈接入音频层")
		check(_main.audio_feedback.last_feedback_label().contains("请保存"), "标题路径音频记录恢复提示")
		check(_main.world.save_world(), "标题路径备份恢复世界可重新保存")
		_main._sync_hud_save_state()
		check(not _main.world.loaded_from_backup(), "标题路径保存后清除备份恢复标记")
		check(not _main.world.has_unsaved_changes(), "标题路径保存后不再有改动")
		_main.queue_free()
		_main = null
	elif _f == 45:
		_prepare_backup_save(_skip_path, 8181)
		OS.unset_environment("VC_NO_SAVE")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SAVE_PATH", _skip_path)
		OS.set_environment("VC_SEED", "8181")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/backup_feedback/skip_settings.json")
		_main_skip = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main_skip)
	elif _f == 80:
		check(not _main_skip.title_screen.visible, "跳过标题路径直接进入世界")
		check(not paused, "跳过标题路径不会继承暂停状态")
		check(_main_skip.player.input_enabled, "跳过标题路径玩家输入启用")
		check(_main_skip.world.loaded_from_backup(), "跳过标题路径世界从备份恢复")
		check(_main_skip.hud._status_label.text.contains("有改动"), "跳过标题路径 HUD 显示需要保存")
		check(_main_skip.hud._feedback_label.text.contains("备份恢复"), "跳过标题路径即时显示恢复反馈")
		check(_main_skip.audio_feedback.last_feedback_kind() == "save", "跳过标题路径备份恢复反馈接入音频层")
		_main_skip.world.save_world()
		_main_skip._sync_hud_save_state()
		check(not _main_skip.world.loaded_from_backup(), "跳过标题路径保存后清除备份恢复标记")
		_main_skip.queue_free()
		_main_skip = null
	elif _f >= 95:
		_clean_save(_title_path)
		_clean_save(_skip_path)
		if failed == 0:
			print("✅ ALL BACKUP RESTORE FEEDBACK TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个备份恢复反馈测试失败")
		return true
	return false

func _prepare_backup_save(path: String, seed: int) -> void:
	_clean_save(path)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var data := {
		"version": 1,
		"seed": seed,
		"updated_at": 100,
		"cover_path": "",
		"edit_count": 0,
		"discovery_count": 0,
		"restored_count": 0,
		"best_restore_percent": 0,
		"journey_count": 0,
		"journey_steps": [],
		"edits": {},
		"discoveries": [],
	}
	_write_text(path + ".bak", JSON.stringify(data))
	_write_text(path, "{ broken primary")

func _clean_save(path: String) -> void:
	for suffix in ["", ".bak", ".tmp"]:
		var candidate: String = path + str(suffix)
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate))

func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
