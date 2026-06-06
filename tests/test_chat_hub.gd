extends SceneTree
# ChatHub 纯逻辑自检：
#   godot --headless --path . --script res://tests/test_chat_hub.gd
const ChatHub = preload("res://scripts/ChatHub.gd")

var failed := 0
func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	var hub = ChatHub.new()

	# presence
	hub.register("player", "你", "human")
	hub.register("agent-1", "OurWorlds", "agent")
	check(hub.entities().size() == 2, "注册后有 2 个实体")

	# 大厅消息（to 为空 = 大厅）
	var s1: int = hub.post("agent-1", "", "大家好")
	check(s1 > 0, "post 返回递增 seq")
	var lobby = hub.lobby_recent(10)
	check(lobby.size() == 1 and lobby[0]["text"] == "大家好", "大厅消息可读回")

	# 私聊消息：不进大厅，进 thread
	hub.post("player", "agent-1", "私聊你")
	check(hub.lobby_recent(10).size() == 1, "私聊不进大厅")
	var th = hub.thread("player", "agent-1", 10)
	check(th.size() == 1 and th[0]["text"] == "私聊你", "私聊在 thread 里")

	# agent-1 的未读：含发给它的私聊，排除它自己发的大厅消息
	var u = hub.unread_for("agent-1", 0)
	check(u["messages"].size() == 1 and u["messages"][0]["text"] == "私聊你",
		"未读只含发给本实体的（排除自己的大厅发言）")
	var u2 = hub.unread_for("agent-1", u["last_seq"])
	check(u2["messages"].size() == 0, "推进 since 后无新未读")

	# 玩家能在未读里看到别人发的大厅消息
	hub.post("agent-1", "", "我在盖塔")
	var up = hub.unread_for("player", 0)
	check(up["messages"].size() >= 1, "玩家能在未读里看到大厅消息")

	# 注销
	hub.unregister("agent-1")
	check(hub.entities().size() == 1, "注销后剩 1 个实体")

	# 信号
	var got := {"n": 0}
	hub.message_posted.connect(func(_m): got["n"] += 1)
	hub.post("player", "", "信号测试")
	check(got["n"] == 1, "post 触发 message_posted 信号")

	if failed == 0:
		print("✅ ALL CHATHUB TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个 ChatHub 测试失败")
	quit(0 if failed == 0 else 1)
