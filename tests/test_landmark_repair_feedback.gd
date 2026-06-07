extends SceneTree
# 验证遗迹修复在玩家实际编辑后会给出即时 HUD 反馈：
#   godot --headless --path <项目> --script res://tests/test_landmark_repair_feedback.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const GameSettings = preload("res://scripts/GameSettings.gd")

var _f := 0
var _main = null
var failed := 0
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
		OS.set_environment("VC_NO_SAVE", "1")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SEED", "9090")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/landmark_repair_feedback/settings.json")
		# 预置 language=zh，使断言里的中文文案不受运行机 OS 语言影响（确定性回归）。
		_seed_language("zh")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		_main.discovery_tracker.set_process(false)
		_main.world._discoveries.clear()
		_main.discovery_tracker._discovered.clear()
		_main.world.mark_landmark_discovered(_landmark)
		_main.hud._feedback_label.text = ""
		_emit_places(_raise_repair_to(4))
	elif _f == 37:
		check(not _main.hud._feedback_label.text.contains("遗迹修复"), "低于 25% 不打断提示")
		_emit_places(_raise_repair_to(5))
	elif _f == 39:
		check(_main.hud._feedback_label.text.contains("遗迹修复"), "跨过阶段后显示遗迹修复反馈")
		check(_main.hud._feedback_label.text.contains("25%"), "首次阶段反馈显示 25%")
		_main.hud._feedback_label.text = ""
		_emit_places(_raise_repair_to(6))
	elif _f == 41:
		check(not _main.hud._feedback_label.text.contains("遗迹修复"), "同一修复阶段不重复刷反馈")
		_main.action_effects._items.clear()
		_emit_places(_raise_repair_to(20))
	elif _f == 43:
		check(_main.hud._feedback_label.text.contains("遗迹修复完成"), "满修复显示完成反馈")
		check(_main.hud._feedback_label.text.contains("古遗迹") or _main.hud._feedback_label.text.contains("石环") or _main.hud._feedback_label.text.contains("高塔"), "完成反馈包含遗迹名称")
		check(_main.action_effects._items.size() >= 50, "满修复触发世界内完成光效")
		check(_main.landmark_marker.visible, "满修复后世界内保留完成信标")
		check(_main.landmark_marker.marker_mode() == "complete", "满修复后信标切换为完成模式")
		check(_main.landmark_marker.marker_progress() == 100, "满修复后信标保持满进度")
		check(_main.landmark_marker.active_progress_ticks() == _main.landmark_marker.progress_tick_count(), "满修复后信标点亮全部刻度")
	elif _f >= 60:
		if failed == 0:
			print("✅ ALL LANDMARK REPAIR FEEDBACK TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个遗迹修复反馈测试失败")
		return true
	return false

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
