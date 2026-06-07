extends SceneTree
# 验证 ChatPanel 与 Main 接线：在线列表、大厅/私聊渲染、开关、玩家提交。
#   godot --headless --path <项目> --script res://tests/test_chat_panel.gd

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
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/chat_panel/settings.json")
		# 预置 language=zh，使断言里的中文文案不受运行机 OS 语言影响（确定性回归）。
		_seed_language("zh")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		return false
	if _f < 30:
		return false
	if _f == 30:
		_run()
		if failed == 0:
			print("✅ ALL CHAT PANEL TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个 ChatPanel 测试失败")
		return true
	if _f > 200:
		printerr("❌ ChatPanel 测试超时")
		return true
	return false

func _run() -> void:
	var hub = _main.get("chat_hub")
	check(hub != null, "Main 创建了 chat_hub")
	var panel = _main.get("chat_panel")
	check(panel != null, "Main 创建了 chat_panel")
	if hub == null or panel == null:
		return

	# 玩家已登记进在线列表
	var has_player := false
	for e in hub.entities():
		if str(e["id"]) == "player":
			has_player = true
	check(has_player, "chat_hub 已登记玩家实体")

	# 一个 agent 出现在在线列表
	hub.register("agent-x", "Helper", "agent")
	var names: Array = panel.presence_names()
	check("Helper" in names and "你" in names, "在线列表含玩家 + agent")

	# 大厅频道渲染新消息
	panel.set_channel("")
	hub.post("agent-x", "", "hello world")
	check(str(panel.rendered_log()).contains("hello world"), "大厅频道渲染出新消息")

	# 开 / 关
	panel.open()
	check(panel.is_open(), "open 后面板可见")
	panel.close()
	check(not panel.is_open(), "close 后面板隐藏")

	# 玩家在大厅提交 -> 进大厅，from=player
	panel.set_channel("")
	panel.submit_text("玩家发言")
	var lob: Array = hub.lobby_recent(20)
	check(lob.size() > 0 and str(lob[-1]["from"]) == "player" and str(lob[-1]["text"]) == "玩家发言", "玩家提交进大厅（from=player）")

	# 切到私聊频道，渲染对应 thread
	panel.set_channel("agent-x")
	hub.post("agent-x", "player", "私聊给你")
	check(str(panel.rendered_log()).contains("私聊给你"), "私聊频道渲染对应 thread")

	# 私聊频道提交 -> 发给该 agent 的 DM
	panel.submit_text("回你私聊")
	var th: Array = hub.thread("player", "agent-x", 20)
	var found := false
	for m in th:
		if str(m["text"]) == "回你私聊" and str(m["from"]) == "player":
			found = true
	check(found, "私聊频道提交 -> 发给该 agent 的 DM")

# 写入仅含 language 的设置文件；Main 启动会据此把界面语言定为该语言。
func _seed_language(lang: String) -> void:
	var settings := GameSettings.load_settings()
	settings["language"] = lang
	GameSettings.save_settings(settings)
