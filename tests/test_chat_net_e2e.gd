extends SceneTree
# 聊天网络端到端自检（*真实* WebSocket + Godot 高层 RPC）。
# 在同一进程里跑 1 个 SERVER + 2 个 CLIENT 的 NetworkManager —— 每个挂在各自子树下、
# 用 SceneTree.set_multiplayer() 绑定独立的 MultiplayerAPI（官方"同进程跑 client+server"做法）。
# 验证：客户端 A local_say 大厅消息后，客户端 B 的 chat_hub 收到该大厅消息，A 也看到自己的回显；
# 再让一个虚拟 agent virtual_say，断言人类客户端 B 收到 agent 的发言。
#   godot --headless --path . --script res://tests/test_chat_net_e2e.gd
#
# 注意：节点必须在 SceneTree *活起来后*（首个 _process 帧）才在树里、其 .multiplayer 才解析到
# 我们配的子树 API；故所有 add_child / set_multiplayer / start_* 都放进 _setup()（phase -1）。
# 端口：高位空闲端口（48973），绝不碰常驻服务器占用的 8971。
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
const ChatHub = preload("res://scripts/ChatHub.gd")

const PORT := 48973

var failed := 0
var _server
var _ca
var _cb
var _hub_s
var _hub_a
var _hub_b
var _data
var _f := 0
var _phase := -1            # -1 = 未建（首帧建）；0.. = 运行阶段
var _eid_a := ""
var _agent_eid := ""

func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

# 在 root 下挂一个独立子树节点，给该子树路径配一套自己的 MultiplayerAPI（独立 peer/RPC 路由），
# 再把一个 NetworkManager（带自己的 ChatHub）放进去。返回 NetworkManager。
func _spawn_nm(branch: String, m: int, hub) -> Object:
	var holder := Node.new()
	holder.name = branch
	root.add_child(holder)
	set_multiplayer(MultiplayerAPI.create_default_interface(), NodePath("/root/%s" % branch))
	var nm = NetworkManager.new()
	nm.name = "NetworkManager"
	nm.mode = m
	nm.chat_hub = hub
	holder.add_child(nm)
	return nm

func _setup() -> bool:
	_data = WorldData.new(1337)

	# ---- SERVER ----
	_hub_s = ChatHub.new()
	_server = _spawn_nm("Srv", NetworkManager.Mode.SERVER, _hub_s)
	_server.set_authority_data(_data, 1337, Vector3(8, _data.surface_y(8, 8) + 2, 8))
	if _server.start_server(PORT) != OK:
		printerr("❌ chat-e2e: server failed to listen on ", PORT, " (port busy?)")
		failed += 1
		return false

	# ---- CLIENT A ----
	_hub_a = ChatHub.new()
	_ca = _spawn_nm("Cla", NetworkManager.Mode.CLIENT, _hub_a)
	_ca.welcomed.connect(_on_a_welcomed)
	_ca.start_client("ws://127.0.0.1:%d" % PORT)

	# ---- CLIENT B ----
	_hub_b = ChatHub.new()
	_cb = _spawn_nm("Clb", NetworkManager.Mode.CLIENT, _hub_b)
	_cb.start_client("ws://127.0.0.1:%d" % PORT)
	return true

func _on_a_welcomed(payload: Dictionary) -> void:
	_eid_a = str(payload.get("your_eid", ""))
	# 模拟 Main 的客户端接线：本端 chat 身份 = 网络 eid。
	if _hub_a != null and _eid_a != "":
		_hub_a.register(_eid_a, "你", "human")

func _lobby_has(hub, text: String) -> bool:
	for m in hub.lobby_recent(20):
		if str(m["text"]) == text:
			return true
	return false

func _process(_d: float) -> bool:
	_f += 1

	# 阶段 -1：树已活，建服务器 + 两个客户端（见文件头注释）。
	if _phase == -1:
		if not _setup():
			quit(1)
			return true
		_phase = 0; _f = 0
		return false

	# 阶段 0：等两个客户端都拿到 welcome（self_eid 非空）+ 服务器名册有 2 个真实 peer。
	if _phase == 0 and _f > 30:
		var real_peers := 0
		for e in _hub_s.entities():
			if str(e["kind"]) == "human":
				real_peers += 1
		if _ca.self_eid() != "" and _cb.self_eid() != "" and real_peers >= 2:
			_ca.local_say("", "hello")        # 客户端 A 发一条大厅消息
			_phase = 1; _f = 0

	# 阶段 1：等中继落地 —— B 与 A（回显）都应收到 "hello"，服务器权威 history 也有。
	if _phase == 1 and _f > 90:
		check(_lobby_has(_hub_b, "hello"), "client B received lobby message 'hello'")
		check(_lobby_has(_hub_a, "hello"), "client A sees its own echo 'hello'")
		check(_lobby_has(_hub_s, "hello"), "server authoritative hub has 'hello'")
		# 注册一个虚拟 agent 并让它发言（应广播给人类客户端）。
		_agent_eid = _server.register_virtual_peer("Helper")
		_server.virtual_say(_agent_eid, "agent here")
		_phase = 2; _f = 0

	# 阶段 2：等 agent 发言中继到人类客户端 B。
	if _phase == 2 and _f > 90:
		check(_lobby_has(_hub_b, "agent here"), "human client B received agent speech 'agent here'")
		check(_lobby_has(_hub_s, "agent here"), "server hub has agent speech (agents read this directly)")
		if failed == 0:
			print("✅ ALL CHAT NET E2E TESTS PASSED")
		else:
			printerr("❌ ", failed, " chat-net-e2e failures")
		quit(0 if failed == 0 else 1)
		return true

	# 兜底超时：避免无头进程挂死。
	if _f > 2400:
		printerr("❌ chat e2e timed out (phase ", _phase, \
			", a_eid=", (_ca.self_eid() if _ca != null else "?"), \
			", b_eid=", (_cb.self_eid() if _cb != null else "?"), \
			", real_peers=", (_hub_s.entities().size() if _hub_s != null else -1), ")")
		failed += 1
		quit(1)
		return true

	return false
