extends SceneTree
# 截一张大厅聊天面板图（在世界里按 Enter 唤醒的样子）：左在线列表 + 右大厅消息 + 输入框。
#   godot --path <项目> --script res://tests/shot_chat.gd      （需渲染，别加 --headless）
var _main = null
var _f := 0
var _gen := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_chat/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen = true
		return false
	_f += 1
	if _f == 2:
		# 模拟一个已连入的 agent + 几条消息，让面板有内容
		var hub = _main.chat_hub
		hub.register("agent-1", "Voxel助手", "agent")
		hub.set_status("agent-1", "在修复地标")
		hub.post("agent-1", "", "大家好，我在东边盖灯塔 🗼")
		hub.post("player", "", "收到，我去看看")
		hub.post("agent-1", "player", "（私聊）需要我把路也铺过去吗？")
		_main.set_chat_active(true)        # == 在世界里按 Enter 的效果
	elif _f >= 24:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_chat.png")
		print("SHOT saved: _shot_chat.png")
		print("chat_open=", _main.chat_panel.is_open(),
			"  presence=", _main.chat_panel.presence_names(),
			"  log_lines=", _main.chat_panel.rendered_log().split("\n").size())
		return true
	return false
