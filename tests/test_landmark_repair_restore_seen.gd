extends SceneTree
# 验证读档时已完成修复的遗迹不会在下一次附近放置时重复弹完成奖励：
#   godot --headless --path <项目> --script res://tests/test_landmark_repair_restore_seen.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const World = preload("res://scripts/World.gd")

var _f := 0
var _main = null
var failed := 0
var _path := "user://tests/landmark_repair_restore_seen/world.json"
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
		OS.set_environment("VC_SEED", "9090")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/landmark_repair_restore_seen/settings.json")
		_clean_save()
		_write_completed_landmark_save()
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		_main.discovery_tracker.set_process(false)
		var entries: Array = _main.discovery_tracker.discovered_entries()
		var restored := _entry_by_key(entries, "8,40,8")
		check(not restored.is_empty(), "读档恢复已发现遗迹")
		check(int(restored.get("restore_percent", 0)) == 100, "读档恢复满修复进度")
		check(int(_main._landmark_restore_seen.get("8,40,8", 0)) == 4, "读档初始化已见修复阶段")
		_main.discovery_tracker.set_process(false)
		_main.world._discoveries.clear()
		_main.discovery_tracker._discovered.clear()
		_main.world.mark_landmark_discovered(_landmark)
		_main.discovery_tracker._discovered["8,40,8"] = true
		_main._sync_hud_restoration()
		check(_main.landmark_marker.visible, "读档后满修复遗迹显示完成信标")
		check(_main.landmark_marker.marker_mode() == "complete", "读档后完成信标保持完成模式")
		_main.hud._feedback_label.text = ""
		_main.action_effects._items.clear()
		var cell := _landmark + Vector3i(6, 5, 6)
		_main.world.set_block(cell.x, cell.y, cell.z, BlockLibrary.MOONSTONE_LAMP)
		_main._on_player_world_feedback("place", cell, BlockLibrary.MOONSTONE_LAMP)
	elif _f == 37:
		check(not _main.hud._feedback_label.text.contains("遗迹修复完成"), "读档后满修复不重复弹完成 HUD")
		check(_main.action_effects._items.is_empty(), "读档后满修复不重复触发完成光效")
	elif _f >= 55:
		_clean_save()
		if failed == 0:
			print("✅ ALL LANDMARK REPAIR RESTORE-SEEN TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个遗迹修复读档反馈测试失败")
		return true
	return false

func _write_completed_landmark_save() -> void:
	var lib := BlockLibrary.new()
	var w := World.new()
	w.setup(lib, 9090, _path)
	w.mark_landmark_discovered(_landmark)
	_raise_repair_to(w, World.LANDMARK_RESTORE_TARGET)
	check(w.save_world(true), "写出满修复测试存档")
	var saved := _read_save()
	check(int(saved.get("restored_count", 0)) == 1, "存档写入修复完成数量")
	check(int(saved.get("best_restore_percent", 0)) == 100, "存档写入最佳修复度")
	w.free()

func _raise_repair_to(world, target_count: int) -> void:
	for dy in range(1, 5):
		for dz in range(-6, 7):
			for dx in range(-6, 7):
				if dx == 0 and dz == 0:
					continue
				if int(world.edited_blocks_near(_landmark)) >= target_count:
					return
				var cell := _landmark + Vector3i(dx, dy, dz)
				world.set_block(cell.x, cell.y, cell.z, BlockLibrary.MOONSTONE_LAMP)

func _entry_by_key(entries: Array, key: String) -> Dictionary:
	for raw in entries:
		var entry: Dictionary = raw
		if String(entry.get("key", "")) == key:
			return entry
	return {}

func _clean_save() -> void:
	var abs_dir := ProjectSettings.globalize_path(_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(abs_dir)
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))

func _read_save() -> Dictionary:
	if not FileAccess.file_exists(_path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path))
	return parsed as Dictionary if typeof(parsed) == TYPE_DICTIONARY else {}
