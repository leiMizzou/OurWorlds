extends SceneTree
# 验证出生点归途信标、HUD 距离和手记归途摘要：
#   godot --headless --path <项目> --script res://tests/test_home_beacon.gd

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
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/home_beacon/settings.json")
		# 预置 language=zh，使断言里的中文文案不受运行机 OS 语言影响（确定性回归）。
		_seed_language("zh")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		check(_main.home_beacon != null, "主场景创建归途信标")
		check(_main.home_beacon.home_position.distance_to(_main._journey_start_pos) < 0.01, "归途信标绑定出生点")
		check(not _main.home_beacon.visible, "出生点附近信标隐藏")

		var start: Vector3 = _main._journey_start_pos
		_main.player.global_position = start + Vector3(34.0, 0.0, 0.0)
		_main.home_beacon._process(0.25)
		_main.hud._process(0.25)
		check(_main.home_beacon.visible, "离开出生点后信标可见")
		check(_main.home_beacon.distance_to_home() >= 33.0, "信标计算归途距离")
		check(_main.hud._status_label.text.contains("归途"), "HUD 状态栏显示归途")

		var data: Dictionary = _main._journal_data()
		check(int(data.get("home_distance", 0)) >= 33, "手记数据包含归途距离")
		check(str(data.get("home_direction", "")) != "", "手记数据包含归途方向")
		_main.travel_journal.open(data)
		check(_main.travel_journal._summary_label.text.contains("归途"), "手记摘要显示归途")

		if failed == 0:
			print("✅ ALL HOME BEACON TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个归途信标测试失败")
		return true
	return false

# 写入仅含 language 的设置文件；Main 启动会据此把界面语言定为该语言。
func _seed_language(lang: String) -> void:
	var settings := GameSettings.load_settings()
	settings["language"] = lang
	GameSettings.save_settings(settings)
