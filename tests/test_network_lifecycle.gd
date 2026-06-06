extends SceneTree
# NetworkManager 连接生命周期 + 在线名册（直接调用 handler，不经真实 MultiplayerAPI）：
#   godot --headless --path . --script res://tests/test_network_lifecycle.gd
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
const ChatHub = preload("res://scripts/ChatHub.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var hub := ChatHub.new()
	hub.register("host", "房主", "human")
	var nm := NetworkManager.new()
	nm.mode = NetworkManager.Mode.SERVER
	nm.chat_hub = hub
	nm.set_authority_data(WorldData.new(5), 5, Vector3.ZERO)

	var e1 := nm.register_peer(11, "Alice")
	var e2 := nm.register_peer(12, "Bob")
	check(e1 != e2, "两个 peer 得到不同 eid")
	check(nm.peer_eids().size() == 2, "名册有 2 个联机玩家")
	# 进了 ChatHub 在线列表（human）
	var ids := []
	for e in hub.entities():
		ids.append(str((e as Dictionary).get("id", "")))
	check(e1 in ids and e2 in ids, "联机玩家进入 ChatHub 在线列表")

	nm.drop_peer(11)
	check(nm.peer_eids().size() == 1, "断开后名册剩 1")
	var ids2 := []
	for e in hub.entities():
		ids2.append(str((e as Dictionary).get("id", "")))
	check(not (e1 in ids2), "断开的玩家从在线列表移除")
	check(e2 in ids2, "其余玩家仍在线")

	if failed == 0: print("✅ ALL NETWORK LIFECYCLE TESTS PASSED")
	else: printerr("❌ ", failed, " 个生命周期测试失败")
	quit(0 if failed == 0 else 1)
