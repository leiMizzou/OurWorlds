extends SceneTree
# WorldData 纯数据核心自检（无 SceneTree/节点依赖 —— 证明无头服务器可直接拥有世界）：
#   godot --headless --path . --script res://tests/test_world_data.gd
const WorldData = preload("res://scripts/WorldData.gd")

var failed := 0
func check(c: bool, m: String) -> void:
	if c:
		print("  ok   ", m)
	else:
		failed += 1
		printerr("  FAIL ", m)

func _initialize() -> void:
	# 确定性生成：同种子 -> 同方块 / 同地表
	var a := WorldData.new(1337)
	var b := WorldData.new(1337)
	check(a.surface_y(8, 8) == b.surface_y(8, 8), "同种子 surface_y 一致")
	var sy := a.surface_y(8, 8)
	check(a.get_block(8, sy, 8) == b.get_block(8, sy, 8), "同种子 get_block 确定性一致")
	check(a.get_block(0, -1, 0) == 0 and a.get_block(0, 9999, 0) == 0, "越界 y 返回 air")
	check(str(a.region_label(8, 8)) != "", "region_label 非空")

	# 编辑：写值 + 返回受影响区块 + revision 递增
	var w := WorldData.new(42)
	var y := w.surface_y(3, 3)
	var base := w.get_block(3, y, 3)
	var target := 3 if base != 3 else 6
	var affected: Array = w.apply_edit_local(3, y, 3, target)
	check(affected.size() >= 1 and (w.chunk_of(3, 3) in affected), "apply_edit_local 返回受影响区块")
	check(w.get_block(3, y, 3) == target, "编辑后 get_block 反映新值")
	check(w.chunk_revision(w.chunk_of(3, 3)) >= 1, "编辑后该区块 revision 递增")

	# 无变化的编辑 -> 返回空
	check(w.apply_edit_local(3, y, 3, target).is_empty(), "值未变 -> 返回空")

	# 卸载该区块再读 -> 编辑仍在（delta 重套）
	w.unload_chunk(w.chunk_of(3, 3))
	check(w.get_block(3, y, 3) == target, "卸载区块后重载，编辑仍在")

	# 改回生成值 -> 该格 delta 被移除
	w.apply_edit_local(3, y, 3, base)
	check(w.chunk_delta(w.chunk_of(3, 3)).is_empty(), "改回生成值 -> delta 被移除")

	# 序列化往返
	var w2 := WorldData.new(7)
	var y2 := w2.surface_y(5, 5)
	w2.apply_edit_local(5, y2 + 1, 5, 3)
	check(w2.edit_count() == 1, "edit_count == 1")
	var dump: Dictionary = w2.all_deltas()
	check(dump.size() == 1, "all_deltas 导出 1 个脏区块")
	var w3 := WorldData.new(7)
	w3.load_deltas(dump)
	check(w3.get_block(5, y2 + 1, 5) == 3, "load_deltas 还原编辑")

	# 无头压力：200 次跨区块编辑 + 卸载 + 重载样本仍在
	var srv := WorldData.new(99)
	for i in range(200):
		var x := i * 3
		srv.apply_edit_local(x, srv.surface_y(x, 0) + 1, 0, 6)
	srv.unload_chunk(srv.chunk_of(0, 0))
	check(srv.get_block(0, srv.surface_y(0, 0) + 1, 0) == 6, "200 跨区块编辑 + 卸载重载后样本仍在")

	if failed == 0:
		print("✅ ALL WORLDDATA TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个 WorldData 测试失败")
	quit(0 if failed == 0 else 1)
