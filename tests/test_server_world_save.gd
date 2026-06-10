extends SceneTree
# 服务器世界存档：编辑 → 存盘 → 新实例（重启）载入 → 编辑仍在（世界重启不丢）。纯逻辑，无 Nakama。
#   godot --headless --path . --script res://tests/test_server_world_save.gd
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://tests"))
	var path := "user://tests/server_world_save.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	# 服务器 A：就近放一块石头，然后存盘
	var a := NetworkManager.new()
	a.mode = NetworkManager.Mode.SERVER
	var da := WorldData.new(77)
	a.set_authority_data(da, 77, Vector3.ZERO)
	a.register_peer(1, "s")
	var sy := da.surface_y(5, 5)
	a.set_peer_transform(1, Vector3(5, sy + 1, 5), 0.0)
	check(bool(a.authorize_edit(1, 5, sy + 1, 5, 3).get("ok", false)), "服务器接受就近编辑")
	check(da.get_block(5, sy + 1, 5) == 3, "权威世界已写入 stone")
	check(a.save_world(path), "存盘成功")

	# 服务器 B（模拟重启）：同种子、空世界 → 载入存档 → 编辑应仍在
	var b := NetworkManager.new()
	b.mode = NetworkManager.Mode.SERVER
	var db := WorldData.new(77)
	b.set_authority_data(db, 77, Vector3.ZERO)
	check(db.get_block(5, sy + 1, 5) != 3, "载入前：该格是基线（非 stone）")
	check(b.load_world(path), "载入存档成功")
	check(db.get_block(5, sy + 1, 5) == 3, "重启后编辑仍在（世界不丢）")

	# 缺文件 / 坏路径不崩
	check(not b.load_world("user://tests/__nope_missing__.json"), "缺文件 → load 返回 false（不崩）")

	# kind 轮回：存盘时写入 kind，重启后 load_world 还原 world_kind
	var kind_path := "user://tests/server_world_kind.json"
	if FileAccess.file_exists(kind_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(kind_path))
	var ka := NetworkManager.new()
	ka.mode = NetworkManager.Mode.SERVER
	ka.world_kind = "themed_island"
	var dka := WorldData.new(77, "themed_island")
	ka.set_authority_data(dka, 77, Vector3.ZERO)
	check(ka.save_world(kind_path), "kind 轮回：存盘成功")
	var kb := NetworkManager.new()
	kb.mode = NetworkManager.Mode.SERVER
	var dkb := WorldData.new(77)
	kb.set_authority_data(dkb, 77, Vector3.ZERO)
	check(kb.load_world(kind_path), "kind 轮回：载入成功")
	check(kb.world_kind == "themed_island", "kind 轮回：world_kind 还原为 themed_island")

	# ---- 原子写 + 轮转备份 + 损坏恢复（防"写一半崩溃 = 世界损坏"）----
	var ap := "user://tests/server_world_atomic.json"
	for ext in ["", ".tmp", ".bak1", ".bak2", ".bak3"]:
		var fp: String = ap + str(ext)
		if FileAccess.file_exists(fp):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(fp))
	var c := NetworkManager.new()
	c.mode = NetworkManager.Mode.SERVER
	var dc := WorldData.new(88)
	c.set_authority_data(dc, 88, Vector3.ZERO)
	c.register_peer(1, "s")
	var sy2 := dc.surface_y(3, 3)
	c.set_peer_transform(1, Vector3(3, sy2 + 1, 3), 0.0)
	check(bool(c.authorize_edit(1, 3, sy2 + 1, 3, 3).get("ok", false)), "原子段：编辑写入")
	check(c.save_world(ap), "原子段：存盘成功")
	check(not FileAccess.file_exists(ap + ".tmp"), "存盘后无 .tmp 残留（原子写）")
	check(not FileAccess.file_exists(ap + ".bak1"), "首次存盘无备份（无旧档可备）")
	var first_content := FileAccess.get_file_as_string(ap)
	check(bool(c.authorize_edit(1, 3, sy2 + 2, 3, 3).get("ok", false)), "原子段：第二笔编辑")
	check(c.save_world(ap), "第二次存盘成功")
	check(FileAccess.file_exists(ap + ".bak1"), "第二次存盘轮转出 bak1")
	check(FileAccess.get_file_as_string(ap + ".bak1") == first_content, "bak1 == 上一份存档内容")
	for i in range(NetworkManager.BACKUP_EVERY):
		c.save_world(ap)
	check(FileAccess.file_exists(ap + ".bak2"), "持续存盘后轮转出 bak2")
	# 主档写坏 → load_world 应从备份恢复（而不是返回 false 丢世界）
	var fbad := FileAccess.open(ap, FileAccess.WRITE)
	fbad.store_string("{corrupted!! not json")
	fbad.close()
	var r := NetworkManager.new()
	r.mode = NetworkManager.Mode.SERVER
	var dr := WorldData.new(88)
	r.set_authority_data(dr, 88, Vector3.ZERO)
	check(r.load_world(ap), "主档损坏 → 从备份恢复成功")
	check(dr.get_block(3, sy2 + 1, 3) == 3, "恢复后编辑仍在")

	if failed == 0: print("✅ ALL SERVER WORLD SAVE TESTS PASSED")
	else: printerr("❌ ", failed, " 个服务器存档测试失败")
	quit(0 if failed == 0 else 1)
