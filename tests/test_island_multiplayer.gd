extends SceneTree
# 多人：welcome 携带 kind；客户端按 (seed,kind) 重生出与服务器一致的岛外列（空气）。
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")

var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var nm := NetworkManager.new()
	nm.mode = NetworkManager.Mode.SERVER
	nm.world_kind = "themed_island"
	var data := WorldData.new(2026, "themed_island")
	nm.set_authority_data(data, 2026, Vector3(0, 50, 0))
	nm.register_peer(7, "tester")
	var welcome := nm.build_welcome(7)
	check(str(welcome.get("kind", "")) == "themed_island", "welcome 携带 kind=themed_island")
	check(int(welcome.get("seed", 0)) == 2026, "welcome 携带 seed")

	# 客户端据 welcome 的 (seed,kind) 重建，岛外列与服务器一致（皆空气）
	var client := WorldData.new(int(welcome["seed"]), str(welcome["kind"]))
	check(client.get_block(4000, 50, 4000) == data.get_block(4000, 50, 4000), "客户端按 kind 重生与服务器一致")

	# apply_welcome（真实客户端路径）存下 kind
	var nm_client := NetworkManager.new()
	nm_client.apply_welcome(welcome)
	check(nm_client.world_kind == "themed_island", "apply_welcome 存储 kind=themed_island")

	if failed == 0: print("✅ ALL ISLAND MP TESTS PASSED")
	else: printerr("❌ ", failed, " 个多人测试失败")
	quit(0 if failed == 0 else 1)
