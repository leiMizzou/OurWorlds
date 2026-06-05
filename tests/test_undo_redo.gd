extends SceneTree
# 验证世界编辑历史：玩家式 request_edit 可以撤销/重做，且继续复用增量存档压缩。
#   godot --headless --path <项目> --script res://tests/test_undo_redo.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")
const World = preload("res://scripts/World.gd")

var failed := 0
var _feedback := []

func _process(_delta: float) -> bool:
	return true

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _on_edit_feedback(kind: String, label: String) -> void:
	_feedback.append({"kind": kind, "label": label})

func _initialize() -> void:
	var lib := BlockLibrary.new()
	var w := World.new()
	w.setup(lib, 777, "")
	w.edit_feedback.connect(_on_edit_feedback)

	var wx := 8
	var wz := 8
	var wy: int = w.surface_y(wx, wz) + 1
	while wy < Chunk.SY and w.get_block(wx, wy, wz) != BlockLibrary.AIR:
		wy += 1
	check(wy < Chunk.SY, "找到一个可放置的空气格")

	check(w.request_edit(wx, wy, wz, BlockLibrary.BRICK), "玩家式编辑放置砖块")
	check(w.get_block(wx, wy, wz) == BlockLibrary.BRICK, "砖块写入世界")
	check(w.edit_count() == 1, "产生 1 条存档增量")
	check(w.can_undo(), "放置后可以撤销")
	check(not w.can_redo(), "新编辑后没有可重做项")

	check(w.undo_last_edit(), "撤销成功")
	check(w.get_block(wx, wy, wz) == BlockLibrary.AIR, "撤销后恢复为空气")
	check(w.edit_count() == 0, "撤销到生成值后增量被压缩移除")
	check(not w.can_undo(), "撤销栈已空")
	check(w.can_redo(), "撤销后可以重做")
	check(_last_feedback_kind() == "undo", "撤销发出 HUD/音效反馈")

	check(w.redo_last_edit(), "重做成功")
	check(w.get_block(wx, wy, wz) == BlockLibrary.BRICK, "重做后砖块恢复")
	check(w.edit_count() == 1, "重做后增量恢复")
	check(w.can_undo(), "重做后可以再次撤销")
	check(not w.can_redo(), "重做栈已空")
	check(_last_feedback_kind() == "redo", "重做发出 HUD/音效反馈")

	check(not w.request_edit(wx, wy, wz, BlockLibrary.BRICK), "重复写入相同方块不会新增历史")
	check(w.undo_last_edit(), "最后一次撤销成功")
	check(not w.undo_last_edit(), "空撤销栈返回失败")
	check(_last_feedback_kind() == "blocked", "空撤销栈给出阻止反馈")

	w.free()

	if failed == 0:
		print("✅ ALL UNDO/REDO TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个撤销/重做测试失败")
	quit(failed)

func _last_feedback_kind() -> String:
	if _feedback.is_empty():
		return ""
	var last: Dictionary = _feedback[_feedback.size() - 1]
	return str(last.get("kind", ""))
