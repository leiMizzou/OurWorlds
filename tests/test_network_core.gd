extends SceneTree
# NetworkManager 权威核心自检（纯逻辑，无 socket / 无 MultiplayerAPI）：
#   godot --headless --path . --script res://tests/test_network_core.gd
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var data := WorldData.new(1337)
	var nm := NetworkManager.new()
	nm.mode = NetworkManager.Mode.SERVER
	nm.set_authority_data(data, 1337, Vector3(8, data.surface_y(8, 8) + 2, 8))
	var eid := nm.register_peer(7, "Alice")
	check(eid != "", "register_peer 返回非空 eid")
	# 把该玩家放到编辑点附近（服务器才允许就近编辑）
	var sy := data.surface_y(8, 8)
	nm.set_peer_transform(7, Vector3(8, sy + 1, 8), 0.0)

	# 合法编辑：就近、y 合法、值有变化 -> 接受
	var r: Dictionary = nm.authorize_edit(7, 8, sy, 8, 0)
	check(bool(r.get("ok", false)), "就近合法编辑被接受")
	check(int(data.get_block(8, sy, 8)) == 0, "权威数据已写入新值")
	check(int(r.get("revision", 0)) >= 1, "返回的 revision 递增")
	check((r.get("affected", []) as Array).size() >= 1, "返回受影响区块")

	# 越界 y -> 拒绝
	check(not bool(nm.authorize_edit(7, 8, -1, 8, 3).get("ok", true)), "y 越界被拒绝")
	check(not bool(nm.authorize_edit(7, 8, 100000, 8, 3).get("ok", true)), "y 超高被拒绝")

	# 太远 -> 拒绝（玩家在 (8,*,8)，编辑 (500,*,500)）
	var far: Dictionary = nm.authorize_edit(7, 500, data.surface_y(500, 500), 500, 0)
	check(not bool(far.get("ok", true)), "超出可及距离的编辑被拒绝")
	check(str(far.get("reason", "")) != "", "拒绝带原因")

	# 未注册的 peer -> 拒绝
	check(not bool(nm.authorize_edit(999, 8, sy, 8, 0).get("ok", true)), "未注册 peer 被拒绝")

	# 值未变（已是 air）-> 视为无变化（ok=false 或 changed=false）
	var noop: Dictionary = nm.authorize_edit(7, 8, sy, 8, 0)
	check(not bool(noop.get("ok", true)), "重复挖空气=无变化被拒绝")

	# ---- 频率限制：同一窗口内超过 EDIT_RATE_MAX 次 -> 拒绝；窗口滑过后恢复 ----
	var rl := WorldData.new(321)
	var rlnm := NetworkManager.new()
	rlnm.mode = NetworkManager.Mode.SERVER
	rlnm.set_authority_data(rl, 321, Vector3.ZERO)
	rlnm.register_peer(50, "Spammer")
	var rsy := rl.surface_y(0, 0)
	rlnm.set_peer_transform(50, Vector3(0, rsy + 2, 0), 0.0)
	for i in range(NetworkManager.EDIT_RATE_MAX):
		rlnm.authorize_edit(50, 0, rsy + 1, 0, 3, 1000.0)   # 同一窗口(now 固定)占满配额
	var over: Dictionary = rlnm.authorize_edit(50, 0, rsy + 1, 0, 3, 1000.0)
	check(not bool(over.get("ok", true)), "同窗口超额编辑被拒绝")
	check(str(over.get("reason", "")) == "rate limited", "频率拒绝带 reason=rate limited")
	# now 前进超过窗口 -> 旧时间戳全部过期 -> 恢复
	var after: Dictionary = rlnm.authorize_edit(50, 0, rsy + 1, 0, 0, 1000.0 + NetworkManager.EDIT_RATE_WINDOW + 0.5)
	check(bool(after.get("ok", false)), "窗口滑过后频率恢复")

	if failed == 0: print("✅ ALL NETWORK CORE TESTS PASSED")
	else: printerr("❌ ", failed, " 个网络核心测试失败")
	quit(0 if failed == 0 else 1)
