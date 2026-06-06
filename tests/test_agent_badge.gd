extends SceneTree
# 验证 HUD 的「🤖 agent 已连接」角标：
#   godot --headless --path <项目> --script res://tests/test_agent_badge.gd

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
		OS.set_environment("VC_SEED", "4242")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/agent_badge/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 24:
		var hud = _main.hud
		check(hud.has_method("set_agent_status"), "HUD 暴露 set_agent_status")
		check(hud._agent_badge_panel != null, "角标面板已创建")
		check(not hud._agent_badge_panel.visible, "初始未连接时角标隐藏")
		hud.set_agent_status(true, "建一座灯塔")
		check(hud._agent_badge_panel.visible, "agent 连接后角标显示")
		check(hud._agent_badge_label.text.contains("agent"), "角标文本含 agent")
		check(hud._agent_badge_label.text.contains("灯塔"), "角标文本含目标")
		hud.set_agent_status(false)
		check(not hud._agent_badge_panel.visible, "断开后角标隐藏")
	elif _f >= 30:
		if failed == 0:
			print("✅ ALL AGENT BADGE TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个 agent 角标测试失败")
		return true
	return false
