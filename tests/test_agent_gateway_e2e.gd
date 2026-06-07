extends SceneTree
# AgentGateway —— 真实 WebSocket 端到端自检（Task 9）。
# 两个"模拟 agent"（裸 WebSocketPeer 客户端）连到一个 *真实* 的 AgentGateway，
# 各自鉴权拿到独立身体，断开后身体退场——证明网关的套接字循环（start/_process）
# 在没有真实 LLM 的情况下也能跑通。逻辑层（handle_envelope/new_conn/close_conn）
# 已由 test_agent_gateway.gd 覆盖；这里只验证真实 TCP/WS 路径。
#   godot --headless --path <项目> --script res://tests/test_agent_gateway_e2e.gd
#
# 端口：用一个高位空闲端口（48972），绝不碰常驻服务器占用的 8971。
const AgentGateway = preload("res://scripts/AgentGateway.gd")
const AgentTokenStore = preload("res://scripts/AgentTokenStore.gd")
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")

const PORT := 48972

var failed := 0
var _gw
var _nm
var _data
var _a := WebSocketPeer.new()
var _b := WebSocketPeer.new()
var _f := 0
var _phase := 0

func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	_data = WorldData.new(1337)
	_nm = NetworkManager.new(); _nm.mode = NetworkManager.Mode.SERVER
	# set_authority_data 必须在任何 register_virtual_peer 之前调（否则散点 spawn 落原点）。
	_nm.set_authority_data(_data, 1337, Vector3(8, _data.surface_y(8, 8) + 2, 8))
	_gw = AgentGateway.new()
	_gw.setup(_nm, _data, AgentTokenStore.new("A:aaa,B:bbb"), 8)
	# 把网关挂进树：--script SceneTree 下 root 的子节点会被逐帧 _process 驱动套接字循环。
	root.add_child(_gw)
	if not _gw.start(PORT):
		printerr("❌ gateway failed to listen on ", PORT, " (port busy?)")
		failed += 1
		quit(1)
		return
	_a.connect_to_url("ws://127.0.0.1:%d" % PORT)
	_b.connect_to_url("ws://127.0.0.1:%d" % PORT)

func _finish(rc: int) -> void:
	# 干净停服：despawn 所有虚拟 peer 并释放端口，便于反复运行。
	if _gw != null and _gw.has_method("stop"):
		_gw.stop()
	quit(rc)

func _process(_d: float) -> bool:
	# 客户端每帧 poll；_gw 在树里，其 _process 会自动跑（不要再手动 _gw._process，避免双驱动）。
	_a.poll(); _b.poll(); _f += 1

	# 阶段 0：等两个客户端都 OPEN，然后各发一帧 auth。
	if _phase == 0 \
			and _a.get_ready_state() == WebSocketPeer.STATE_OPEN \
			and _b.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_a.send_text(JSON.stringify({"id": 0, "tool": "auth", "args": {"token": "aaa", "name": "Alpha"}}))
		_b.send_text(JSON.stringify({"id": 0, "tool": "auth", "args": {"token": "bbb", "name": "Beta"}}))
		_phase = 1; _f = 0

	# 阶段 1：等 auth 往返落地（给足帧数让握手+应答跑完），断言两个独立身体。
	if _phase == 1 and _f > 90:
		var snap: Array = _nm.build_player_snapshot()
		check(snap.size() == 2, "two agent bodies in shared roster")
		var eids := {}
		for raw in snap:
			eids[str((raw as Dictionary).get("eid", ""))] = true
		check(eids.size() == 2, "two distinct eids")
		_a.close()
		_phase = 2; _f = 0

	# 阶段 2：关掉一个客户端后，网关检测到 STATE_CLOSED 应 despawn 其身体。
	if _phase == 2 and _f > 90:
		check(_nm.build_player_snapshot().size() == 1, "closing one connection despawns its body")
		if failed == 0: print("✅ ALL AGENT GATEWAY E2E TESTS PASSED")
		else: printerr("❌ ", failed, " gateway-e2e failures")
		_finish(0 if failed == 0 else 1)
		return true

	# 兜底：任何阶段卡死都超时退出（避免无头进程挂死）。
	if _f > 1800:
		printerr("❌ gateway e2e timed out (phase ", _phase, \
			", a=", _a.get_ready_state(), ", b=", _b.get_ready_state(), ")")
		failed += 1
		_finish(1)
		return true

	return false
