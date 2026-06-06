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

	if failed == 0: print("✅ ALL SERVER WORLD SAVE TESTS PASSED")
	else: printerr("❌ ", failed, " 个服务器存档测试失败")
	quit(0 if failed == 0 else 1)
