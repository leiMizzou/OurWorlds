extends SceneTree
# 验证 AgentBridge 多客户端 + 聊天：identify / say(to) / observe.inbox（注入 ChatHub，不经 TCP）。
#   godot --headless --path <项目> --script res://tests/test_agent_bridge_multi.gd
const AgentBridge = preload("res://scripts/AgentBridge.gd")
const ChatHub = preload("res://scripts/ChatHub.gd")

var _f := 0
var _main = null
var _bridge: AgentBridge = null
var _hub: ChatHub = null
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
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/agent_multi/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		return false
	if _f < 30:
		return false
	if _f == 30:
		_run()
		if failed == 0:
			print("✅ ALL AGENT MULTI TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个多客户端测试失败")
		return true
	if _f > 200:
		printerr("❌ 多客户端测试超时")
		return true
	return false

func _ok(line: String, eid: String) -> Dictionary:
	var resp := _bridge.dispatch_line(line, eid)
	check(bool(resp.get("ok", false)), "ok: " + line.substr(0, 48))
	var r: Variant = resp.get("result", {})
	return r if typeof(r) == TYPE_DICTIONARY else {}

func _texts(arr: Array) -> Array:
	var out := []
	for m in arr:
		out.append(str((m as Dictionary).get("text", "")))
	return out

func _run() -> void:
	_hub = ChatHub.new()
	_hub.register("player", "你", "human")
	_bridge = AgentBridge.new()
	_bridge.world = _main.world
	_bridge.player = _main.player
	_bridge.hud = _main.hud
	_bridge.chat_hub = _hub
	_main.add_child(_bridge)

	# 两个 agent 各自 identify（不同实体 id）
	_ok('{"id":1,"tool":"identify","args":{"name":"Alice"}}', "agent-1")
	_ok('{"id":2,"tool":"identify","args":{"name":"Bob"}}', "agent-2")
	var names := {}
	for e in _hub.entities():
		names[e["id"]] = e["name"]
	check(names.get("agent-1", "") == "Alice" and names.get("agent-2", "") == "Bob", "两 agent identify 后名字登记")
	check(_hub.entities().size() == 3, "presence = 玩家 + 2 agent")

	# 大厅发言
	_ok('{"id":3,"tool":"say","args":{"text":"hello all"}}', "agent-1")
	var lobby := _hub.lobby_recent(10)
	check(lobby.size() >= 1 and str(lobby[-1]["text"]) == "hello all" and str(lobby[-1]["from"]) == "agent-1", "agent-1 大厅发言进 ChatHub")

	# 按名字私聊：agent-1 -> Bob(=agent-2)
	_ok('{"id":4,"tool":"say","args":{"text":"hi bob","to":"Bob"}}', "agent-1")
	check(_hub.lobby_recent(10).size() == 1, "私聊不进大厅")

	# 玩家发大厅
	_hub.post("player", "", "玩家好")

	# agent-2 的 inbox：含发给它的私聊 + 别人发的大厅，排除自己
	var ob2 := _ok('{"id":5,"tool":"observe","args":{}}', "agent-2")
	check(ob2.has("chat") and ob2.has("inbox"), "observe 含 chat + inbox")
	var in2 := _texts(ob2.get("inbox", []))
	check("hi bob" in in2, "agent-2 收到发给它的私聊")
	check("hello all" in in2 and "玩家好" in in2, "agent-2 收到大厅消息")

	# 再次 observe，inbox 为空（since 已推进）
	var ob2b := _ok('{"id":6,"tool":"observe","args":{}}', "agent-2")
	check((ob2b.get("inbox", []) as Array).is_empty(), "再次 observe inbox 为空（since 推进）")

	# agent-1 不收到自己发的消息，但收到玩家大厅消息
	var ob1 := _ok('{"id":7,"tool":"observe","args":{}}', "agent-1")
	var in1 := _texts(ob1.get("inbox", []))
	check("玩家好" in in1, "agent-1 收到玩家大厅消息")
	check(not ("hello all" in in1) and not ("hi bob" in in1), "agent-1 不收到自己发的消息")

	# set_goal 反映到 presence 状态
	_ok('{"id":8,"tool":"set_goal","args":{"text":"盖灯塔"}}', "agent-1")
	var st := ""
	for e in _hub.entities():
		if str(e["id"]) == "agent-1":
			st = str(e["status"])
	check(st == "盖灯塔", "set_goal 反映到该 agent 的 presence 状态")
