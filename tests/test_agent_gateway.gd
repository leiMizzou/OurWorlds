extends SceneTree
# 验证 AgentGateway（远程代理网关的"逻辑层"）：直接驱动 handle_envelope / new_conn / close_conn
# （不经 TCP/WebSocket），断言鉴权门禁、spawn/despawn、auth 后分发、容量上限。
# 真实 socket 循环（start/_process）由 Task 9 的 E2E 覆盖，这里不跑套接字。
#   godot --headless --path <项目> --script res://tests/test_agent_gateway.gd
const AgentGateway = preload("res://scripts/AgentGateway.gd")
const AgentTokenStore = preload("res://scripts/AgentTokenStore.gd")
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var data := WorldData.new(1337)
	var nm := NetworkManager.new(); nm.mode = NetworkManager.Mode.SERVER
	nm.set_authority_data(data, 1337, Vector3(8, data.surface_y(8, 8) + 2, 8))   # BEFORE any register_virtual_peer
	var gw := AgentGateway.new()
	gw.setup(nm, data, AgentTokenStore.new("Alice:aaa"), 4)   # max 4 agents

	var conn := gw.new_conn()
	var pre := gw.handle_envelope(conn, {"id": 1, "tool": "observe", "args": {}})
	check(not bool(pre.get("ok", true)) and str(pre.get("error","")).contains("unauth"), "tool before auth rejected")

	var bad := gw.handle_envelope(conn, {"id": 0, "tool": "auth", "args": {"token": "nope"}})
	check(not bool(bad.get("ok", true)) and str(bad.get("error","")).contains("unauthorized"), "bad token rejected")

	var ok := gw.handle_envelope(conn, {"id": 0, "tool": "auth", "args": {"token": "aaa", "name": "Bot"}})
	check(bool(ok.get("ok", false)) and str((ok["result"] as Dictionary).get("eid","")).begins_with("agent-"), "auth spawns body")
	check(int((ok["result"] as Dictionary).get("protocol", -1)) == nm.PROTOCOL_VERSION, "auth 应答带协议版本号")
	check(nm.build_player_snapshot().size() == 1, "body in roster after auth")

	var ob := gw.handle_envelope(conn, {"id": 2, "tool": "observe", "args": {}})
	check(bool(ob.get("ok", false)), "observe works after auth")

	gw.close_conn(conn)
	check(nm.build_player_snapshot().size() == 0, "disconnect despawns body")

	var conns := []
	for i in range(4):
		var c := gw.new_conn(); gw.handle_envelope(c, {"id":0,"tool":"auth","args":{"token":"aaa"}}); conns.append(c)
	var full := gw.new_conn()
	var cap := gw.handle_envelope(full, {"id": 0, "tool": "auth", "args": {"token": "aaa"}})
	check(not bool(cap.get("ok", true)) and str(cap.get("error","")).contains("capacity"), "over capacity rejected")

	if failed == 0: print("✅ ALL AGENT GATEWAY TESTS PASSED")
	else: printerr("❌ ", failed, " agent-gateway failures")
	quit(0 if failed == 0 else 1)
