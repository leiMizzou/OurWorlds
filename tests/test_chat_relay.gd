extends SceneTree
# 聊天中继核心自检（无 socket，纯方法层）：
#   - build_player_snapshot 每条带 name（客户端据此重建在线 presence）。
#   - apply_player_snapshot 在客户端按快照登记/注销 presence（按 eid 前缀判 human/agent），
#     跳过本端自己，且不动本端 self id。
#   - _server_post_chat：大厅消息进大厅、私聊进 thread（权威 history，agent 服务端直读）。
#   - virtual_say 走统一路径，也写进 hub。
#   godot --headless --path . --script res://tests/test_chat_relay.gd
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
const ChatHub = preload("res://scripts/ChatHub.gd")

var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	# ---- 快照带 name ----
	var nm := NetworkManager.new()
	nm.mode = NetworkManager.Mode.SERVER
	var data := WorldData.new(1337)
	nm.set_authority_data(data, 1337, Vector3(8, data.surface_y(8, 8) + 2, 8))
	var hub := ChatHub.new()
	nm.chat_hub = hub
	var e1 := nm.register_peer(11, "Alice")
	var e2 := nm.register_peer(12, "Bob")
	var snap: Array = nm.build_player_snapshot()
	var name_ok := false
	for raw in snap:
		var e: Dictionary = raw
		if str(e.get("eid", "")) == e1:
			name_ok = (str(e.get("name", "")) == "Alice")
	check(name_ok, "build_player_snapshot 每条带 name")

	# ---- _server_post_chat：大厅 ----
	nm._server_post_chat(e1, "", "大家好")
	var lobby: Array = hub.lobby_recent(10)
	check(lobby.size() == 1 and str(lobby[0]["text"]) == "大家好" and str(lobby[0]["from"]) == e1,
		"_server_post_chat(from, \"\", ...) 进大厅")

	# ---- _server_post_chat：私聊（resolve 目标，进 thread 不进大厅）----
	nm._server_post_chat(e1, e2, "悄悄话")
	check(hub.lobby_recent(10).size() == 1, "私聊不进大厅")
	var th: Array = hub.thread(e1, e2, 10)
	check(th.size() == 1 and str(th[0]["text"]) == "悄悄话", "_server_post_chat DM 进 thread")

	# ---- virtual_say 走统一路径，写进 hub（大厅）----
	var ae := nm.register_virtual_peer("Botty")
	nm.virtual_say(ae, "我在盖塔")
	var found_agent := false
	for m in hub.lobby_recent(10):
		if str(m["from"]) == ae and str(m["text"]) == "我在盖塔":
			found_agent = true
	check(found_agent, "virtual_say 经统一路径写入 hub")

	# ============ 客户端 presence 重建 ============
	# 客户端 NetworkManager：自己是 player-9，收快照应为别人登记 presence、跳过自己。
	var cm := NetworkManager.new()
	cm.mode = NetworkManager.Mode.CLIENT
	var chub := ChatHub.new()
	cm.chat_hub = chub
	cm._self_eid = "player-9"
	chub.register("player-9", "你", "human")     # 本端自己（Main 会做；这里手动模拟）

	var s1: Array = [
		{"eid": "player-9", "name": "你", "pos": [0, 0, 0], "yaw": 0.0},   # 自己 → 跳过
		{"eid": "player-2", "name": "Carol", "pos": [1, 2, 3], "yaw": 0.0},
		{"eid": "agent-1", "name": "Helper", "pos": [4, 5, 6], "yaw": 0.0},
	]
	cm.apply_player_snapshot(s1)
	var ids := {}
	var kinds := {}
	for e in chub.entities():
		ids[str(e["id"])] = true
		kinds[str(e["id"])] = str(e["kind"])
	check(ids.has("player-2") and ids.has("agent-1"), "客户端按快照登记别人的 presence")
	check(kinds.get("player-2", "") == "human", "player- 前缀判 human")
	check(kinds.get("agent-1", "") == "agent", "agent- 前缀判 agent")
	check(ids.has("player-9"), "本端自己仍在 presence（未被重复处理破坏）")

	# 第二份快照里 player-2 掉线 → 应被注销；本端自己永不注销。
	var s2: Array = [
		{"eid": "player-9", "name": "你", "pos": [0, 0, 0], "yaw": 0.0},
		{"eid": "agent-1", "name": "Helper", "pos": [4, 5, 6], "yaw": 0.0},
	]
	cm.apply_player_snapshot(s2)
	var ids2 := {}
	for e in chub.entities():
		ids2[str(e["id"])] = true
	check(not ids2.has("player-2"), "掉出快照的 eid 从 presence 注销")
	check(ids2.has("agent-1"), "仍在快照的 eid 保留")
	check(ids2.has("player-9"), "本端 self id 永不被注销")

	# ---- 聊天限频：每 peer 滑动窗口，防刷屏（编辑早有限频，聊天此前没有）----
	var rl := NetworkManager.new()
	rl.mode = NetworkManager.Mode.SERVER
	rl.set_authority_data(WorldData.new(5), 5, Vector3.ZERO)
	var rhub := ChatHub.new()
	rl.chat_hub = rhub
	var re := str(rl.register_virtual_peer("Spammer"))
	for i in range(NetworkManager.CHAT_RATE_MAX + 3):
		rl.virtual_say(re, "msg %d" % i, "", 1000.0)
	check(rhub.lobby_recent(50).size() == NetworkManager.CHAT_RATE_MAX,
		"窗口内只收 CHAT_RATE_MAX 条（超出被丢弃）")
	rl.virtual_say(re, "later", "", 1000.0 + NetworkManager.CHAT_RATE_WINDOW + 0.1)
	check(rhub.lobby_recent(50).size() == NetworkManager.CHAT_RATE_MAX + 1,
		"窗口滑过后恢复接收")

	# ---- presence 文件：服务器写人数/agent 数（居民"无人跳班"省 token 的数据源）----
	var pp := "user://tests/presence_test.json"
	if FileAccess.file_exists(pp):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(pp))
	var pn := NetworkManager.new()
	pn.mode = NetworkManager.Mode.SERVER
	pn.set_authority_data(WorldData.new(6), 6, Vector3.ZERO)
	pn.register_peer(1, "h1")
	pn.register_peer(2, "h2")
	pn.register_virtual_peer("bot")
	pn.write_presence(pp)
	var pj := JSON.new()
	check(pj.parse(FileAccess.get_file_as_string(pp)) == OK, "presence 文件是合法 JSON")
	var pd: Dictionary = pj.data
	check(int(pd.get("humans", -1)) == 2 and int(pd.get("agents", -1)) == 1,
		"presence 统计正确（humans=2, agents=1）")
	check(int(pd.get("t", 0)) > 0, "presence 带时间戳")

	if failed == 0: print("✅ ALL CHAT RELAY TESTS PASSED")
	else: printerr("❌ ", failed, " 个 chat-relay 测试失败")
	quit(0 if failed == 0 else 1)
