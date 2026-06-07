extends SceneTree
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var data := WorldData.new(1337)
	var nm := NetworkManager.new()
	nm.mode = NetworkManager.Mode.SERVER
	nm.set_authority_data(data, 1337, Vector3(8, data.surface_y(8, 8) + 2, 8))

	var pe := nm.register_peer(7, "Alice")
	var ae := nm.register_virtual_peer("BrutalistBot")
	check(ae.begins_with("agent-"), "virtual eid prefixed agent-")
	check(ae != pe, "agent eid != player eid")

	nm.update_virtual_peer(ae, Vector3(20, data.surface_y(20, 20) + 1, 20), 1.0)
	var snap: Array = nm.build_player_snapshot()
	var found := false
	for raw in snap:
		if str((raw as Dictionary)["eid"]) == ae: found = true
	check(found, "virtual peer in snapshot")
	var found_real := false
	for raw in snap:
		if str((raw as Dictionary)["eid"]) == pe: found_real = true
	check(found_real, "real peer also in snapshot alongside virtual peer")

	var ax := 20; var az := 20; var ay := data.surface_y(20, 20) + 1
	var ok1 := nm.apply_virtual_edit(ae, ax, ay, az, BlockLibrary.STONE)
	check(ok1 and int(data.get_block(ax, ay, az)) == BlockLibrary.STONE, "near edit accepted + written")
	check(not nm.apply_virtual_edit(ae, 500, data.surface_y(500, 500), 500, BlockLibrary.STONE), "far edit rejected")

	var rl := NetworkManager.new(); rl.mode = NetworkManager.Mode.SERVER
	var rd := WorldData.new(9); rl.set_authority_data(rd, 9, Vector3.ZERO)
	var re := rl.register_virtual_peer("Spammer")
	rl.update_virtual_peer(re, Vector3(0, rd.surface_y(0, 0) + 2, 0), 0.0)
	var sy := rd.surface_y(0, 0) + 1
	for i in range(NetworkManager.EDIT_RATE_MAX):
		rl.apply_virtual_edit_at(re, 0, sy, 0, (i % 2) + 1, 1000.0)
	check(not rl.apply_virtual_edit_at(re, 0, sy, 0, 3, 1000.0), "agent over-rate rejected")

	nm.remove_virtual_peer(ae)
	var gone := true
	for raw in nm.build_player_snapshot():
		if str((raw as Dictionary)["eid"]) == ae: gone = false
	check(gone, "removed virtual peer gone from snapshot")

	if failed == 0: print("✅ ALL VIRTUAL PEER TESTS PASSED")
	else: printerr("❌ ", failed, " virtual-peer failures")
	quit(0 if failed == 0 else 1)
