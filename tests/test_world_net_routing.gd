extends SceneTree
# World 编辑路由：CLIENT 模式下 request_edit 转发给 net（不本地应用）；apply_remote_edit 本地应用。
#   godot --headless --path . --script res://tests/test_world_net_routing.gd
const World = preload("res://scripts/World.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

class NetStub:
	var forwarded := []
	var client := true
	func is_client() -> bool: return client
	func submit_edit(wx: int, wy: int, wz: int, id: int) -> void:
		forwarded.append([wx, wy, wz, id])

func _initialize() -> void:
	var w := World.new()
	w.setup(BlockLibrary.new(), 77, "")
	var sy := w.surface_y(2, 2)
	var base := w.get_block(2, sy, 2)

	# 无 net（单机）：request_edit 本地应用（保持原行为）
	check(w.request_edit(2, sy, 2, 0), "单机 request_edit 本地生效")
	check(w.get_block(2, sy, 2) == 0, "单机编辑后值改变")

	# 挂上 CLIENT net：request_edit 应转发、且不本地应用
	var stub := NetStub.new()
	w.net = stub
	var before := w.get_block(3, sy, 3)
	var ret := w.request_edit(3, sy, 3, 0)
	check(stub.forwarded.size() == 1, "CLIENT 模式 request_edit 转发给 net")
	check(w.get_block(3, sy, 3) == before, "CLIENT 模式不本地应用（等服务器广播）")

	# 服务器广播到来：apply_remote_edit 本地应用（无历史、无再转发）
	check(w.apply_remote_edit(3, sy, 3, 0), "apply_remote_edit 本地应用成功")
	check(w.get_block(3, sy, 3) == 0, "apply_remote_edit 后值改变")
	check(stub.forwarded.size() == 1, "apply_remote_edit 不再转发")

	if failed == 0: print("✅ ALL WORLD NET ROUTING TESTS PASSED")
	else: printerr("❌ ", failed, " 个 World 路由测试失败")
	quit(0 if failed == 0 else 1)
