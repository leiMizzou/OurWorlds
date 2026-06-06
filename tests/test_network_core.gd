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

	# ---- 入场握手：服务器打包 welcome，客户端套用后地形增量一致 ----
	var srv := NetworkManager.new()
	srv.mode = NetworkManager.Mode.SERVER
	var sdata := WorldData.new(2024)
	srv.set_authority_data(sdata, 2024, Vector3(4, sdata.surface_y(4, 4) + 2, 4))
	var pe := srv.register_peer(20, "Carol")
	srv.set_peer_transform(20, Vector3(4, sdata.surface_y(4, 4) + 1, 4), 0.0)
	# 服务器上已有一处编辑
	srv.authorize_edit(20, 4, sdata.surface_y(4, 4) + 1, 4, 3)
	var welcome: Dictionary = srv.build_welcome(20)
	check(int(welcome.get("seed", 0)) == 2024, "welcome 带服务器种子")
	check(str(welcome.get("your_eid", "")) == pe, "welcome 带本端 eid")
	check((welcome.get("deltas", {}) as Dictionary).size() == 1, "welcome 带 1 个脏区块增量")

	# 客户端：用一个空 WorldData 套用 welcome 的增量，地形应一致
	var cdata := WorldData.new(int(welcome["seed"]))
	cdata.load_deltas(welcome["deltas"])
	check(int(cdata.get_block(4, sdata.surface_y(4, 4) + 1, 4)) == 3, "客户端套用 welcome 后看到已有编辑")

	# ---- 玩家快照：服务器打包所有人的位置，客户端套用后生成/更新/移除 RemoteAvatar ----
	var snap_srv := NetworkManager.new()
	snap_srv.mode = NetworkManager.Mode.SERVER
	snap_srv.set_authority_data(WorldData.new(1), 1, Vector3.ZERO)
	snap_srv.register_peer(31, "Dan")
	snap_srv.register_peer(32, "Eve")
	snap_srv.set_peer_transform(31, Vector3(10, 40, 10), 1.5)
	snap_srv.set_peer_transform(32, Vector3(20, 41, 22), 0.0)
	var snap: Array = snap_srv.build_player_snapshot()
	check(snap.size() == 2, "快照含 2 个玩家")

	# 客户端套用：用桩工厂生成假 avatar，验证 upsert/remove
	var client := NetworkManager.new()
	client.mode = NetworkManager.Mode.CLIENT
	client.avatar_factory = func() -> Node3D:
		var n := Node3D.new()
		return n
	client._self_eid = "me"     # 不给自己造分身
	# 第一次：生成两个 avatar
	client.apply_player_snapshot(snap)
	check(client.avatar_count() == 2, "首次快照生成 2 个 RemoteAvatar")
	# 再来一次（同样的人）：不应重复生成
	client.apply_player_snapshot(snap)
	check(client.avatar_count() == 2, "重复快照不重复生成")
	# 其中一人离开：快照里去掉 -> 移除其 avatar
	var snap2: Array = [snap[0]]
	client.apply_player_snapshot(snap2)
	check(client.avatar_count() == 1, "玩家离开后其 avatar 被移除")
	# 自己的 eid 不会生成分身
	var with_self: Array = snap2.duplicate()
	with_self.append({"eid": "me", "pos": [0, 40, 0], "yaw": 0.0})
	client.apply_player_snapshot(with_self)
	check(client.avatar_count() == 1, "不给本端自己生成 avatar")

	# 无 avatar 工厂（未注入）-> 不生成分身，也不崩
	var no_factory := NetworkManager.new()
	no_factory.mode = NetworkManager.Mode.CLIENT
	no_factory.apply_player_snapshot(snap)
	check(no_factory.avatar_count() == 0, "无工厂时不生成 avatar")

	if failed == 0: print("✅ ALL NETWORK CORE TESTS PASSED")
	else: printerr("❌ ", failed, " 个网络核心测试失败")
	quit(0 if failed == 0 else 1)
