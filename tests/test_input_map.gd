extends SceneTree
# 验证发布期输入映射：所有命名动作都注册进 InputMap 且物理键正确。
#   godot --headless --path <项目> --script res://tests/test_input_map.gd

const Player = preload("res://scripts/Player.gd")

func _initialize() -> void:
	var failed := 0
	var p = Player.new()
	p._ensure_input_map()
	var count := 0
	for action in Player.ACTION_KEYS:
		count += 1
		if not InputMap.has_action(action):
			failed += 1
			printerr("  FAIL InputMap 缺少动作 ", action)
			continue
		for code in Player.ACTION_KEYS[action]:
			var found := false
			for ev in InputMap.action_get_events(action):
				if ev is InputEventKey and int(ev.physical_keycode) == int(code):
					found = true
					break
			if not found:
				failed += 1
				printerr("  FAIL 动作 ", action, " 未注册物理键 ", code)
	# 幂等性：重复注册不应产生重复事件
	p._ensure_input_map()
	var fwd_events := InputMap.action_get_events("move_forward").size()
	if fwd_events != Player.ACTION_KEYS["move_forward"].size():
		failed += 1
		printerr("  FAIL 重复注册产生了多余事件：", fwd_events)
	p.free()
	if failed == 0:
		print("✅ ALL INPUT MAP TESTS PASSED (", count, " 个动作)")
	else:
		printerr("❌ ", failed, " 个输入映射测试失败")
	quit()
