extends SceneTree
# Blueprint 蓝图：从 WorldData 捕获长方体区域 → 序列化 → 反序列化 → 生成"粘贴"编辑，round-trip 一致。
#   godot --headless --path . --script res://tests/test_blueprint.gd
const Blueprint = preload("res://scripts/Blueprint.gd")
const WorldData = preload("res://scripts/WorldData.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var w := WorldData.new(123)
	# 先把盒子清成空气（消除地形/结构干扰，结果与种子无关），再摆一个小建造
	for c in [[0, 80, 0], [1, 80, 0], [0, 81, 0], [1, 81, 0]]:
		w.apply_edit_local(c[0], c[1], c[2], 0)
	w.apply_edit_local(0, 80, 0, 3)   # stone
	w.apply_edit_local(1, 80, 0, 6)   # planks
	w.apply_edit_local(0, 81, 0, 3)   # stone
	# 捕获盒 [0,80,0]..[1,81,0]（含端点，2x2x1=4 格，其中 1 格是空气）
	var bp: Dictionary = Blueprint.capture(w, Vector3i(0, 80, 0), Vector3i(1, 81, 0))
	check((bp.get("size", []) as Array) == [2, 2, 1], "尺寸 [2,2,1]")
	check((bp.get("blocks", {}) as Dictionary).size() == 3, "只捕获 3 个非空气块")

	# 序列化 round-trip：反序列化后仍能粘出同样 3 块（用粘贴结果比，免受 JSON int/float 表示影响）
	var bp2: Dictionary = Blueprint.deserialize(Blueprint.serialize(bp))
	check(Blueprint.paste_edits(bp2, Vector3i.ZERO).size() == 3, "round-trip 后仍有 3 块")

	# 粘贴到锚点 (10,80,10) → 编辑列表
	var edits: Array = Blueprint.paste_edits(bp2, Vector3i(10, 80, 10))
	check(edits.size() == 3, "粘贴生成 3 条编辑")
	var found := false
	for e in edits:
		if (e.get("pos") as Vector3i) == Vector3i(11, 80, 10) and int(e.get("id", -1)) == 6:
			found = true
	check(found, "相对坐标 + 锚点换算正确、方块 id 保留")

	# 坏数据不崩
	check((Blueprint.deserialize("not json") as Dictionary).is_empty(), "坏 JSON → 空蓝图（不崩）")

	if failed == 0: print("✅ ALL BLUEPRINT TESTS PASSED")
	else: printerr("❌ ", failed, " 个 Blueprint 测试失败")
	quit(0 if failed == 0 else 1)
