extends SceneTree
# 出生点散开（回归"大厅里互相看不见"）：多个玩家登记后各自出生点互不相同——不再叠在同一格，
# 一进场就能互相看见——且都在基准出生点附近、贴合地表。
#   godot --headless --path . --script res://tests/test_spawn_scatter.gd
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var nm := NetworkManager.new()
	nm.mode = NetworkManager.Mode.SERVER
	var data := WorldData.new(99)
	var base := Vector3(0.5, data.surface_y(0, 0) + 3, 0.5)
	nm.set_authority_data(data, 99, base)

	var spawns: Array[Vector3] = []
	for pid in [10, 11, 12, 13, 14]:
		nm.register_peer(pid, "p")
		var s: Array = nm.build_welcome(pid).get("spawn", [0, 0, 0])
		spawns.append(Vector3(float(s[0]), float(s[1]), float(s[2])))

	# 1) 出生点 XZ 互不相同（核心：不再叠在一起）
	var keys := {}
	for s in spawns:
		keys["%d_%d" % [roundi(s.x), roundi(s.z)]] = true
	check(keys.size() == spawns.size(), "5 个玩家出生点 XZ 互不相同")

	# 2) 任意两点至少相隔 1.5（不重叠到同一身位）
	var sep_ok := true
	for i in spawns.size():
		for j in range(i + 1, spawns.size()):
			if Vector2(spawns[i].x - spawns[j].x, spawns[i].z - spawns[j].z).length() < 1.5:
				sep_ok = false
	check(sep_ok, "任意两个出生点相隔 >=1.5")

	# 3) 都在基准点附近（<=12），不会被甩到很远而看不见
	var near_ok := true
	for s in spawns:
		if Vector2(s.x - base.x, s.z - base.z).length() > 12.0:
			near_ok = false
	check(near_ok, "出生点都在基准点附近(<=12)")

	# 4) 贴地：Y 在该 XZ 地表之上的合理范围（不卡进地里 / 不悬空太高）
	var ground_ok := true
	for s in spawns:
		var sy := data.surface_y(roundi(s.x), roundi(s.z))
		if s.y < float(sy) or s.y > float(sy) + 6.0:
			ground_ok = false
	check(ground_ok, "出生 Y 贴合地表(地表..地表+6)")

	if failed == 0: print("✅ ALL SPAWN SCATTER TESTS PASSED")
	else: printerr("❌ ", failed, " 个出生点散开测试失败")
	quit(0 if failed == 0 else 1)
