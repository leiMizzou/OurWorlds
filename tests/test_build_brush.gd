extends SceneTree
# 验证创造模式 3x3 建造画笔：批量放置、预览和整组撤销。
#   godot --headless --path <项目> --script res://tests/test_build_brush.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _f := 0
var _main = null
var failed := 0
var _last_kind := ""
var _last_label := ""
var _edit_kind := ""
var _edit_label := ""

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.set_environment("VC_NO_SAVE", "1")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/build_brush/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		var player = _main.player
		player.action_feedback.connect(func(kind: String, label: String) -> void:
			_last_kind = kind
			_last_label = label
		)
		_main.world.edit_feedback.connect(func(kind: String, label: String) -> void:
			_edit_kind = kind
			_edit_label = label
		)

		player.select_block_id(BlockLibrary.BRICK)
		player.brush_index = 1
		player._has_target = true
		player._target_normal = Vector3i.UP
		var p: Vector3 = player.global_position
		var place := Vector3i(int(floor(p.x)) + 7, int(floor(p.y)) + 6, int(floor(p.z)) + 7)
		player._target = place - Vector3i.UP
		player._place = place
		var cells: Array = player._placement_cells()
		check(cells.size() == 9, "3x3 画笔生成 9 个放置格")

		for cell in cells:
			var c: Vector3i = cell
			_main.world.set_block(c.x, c.y, c.z, BlockLibrary.AIR)
		check(player._placement_blocked_reason(cells) == "", "空中 3x3 区域可放置")
		player._update_placement_preview()
		check(player.placement_preview.visible, "3x3 画笔预览可见")
		var preview_size := _preview_world_size(player)
		check(preview_size.x > 2.8 and preview_size.z > 2.8, "水平 3x3 预览覆盖整片区域")
		check(player.placement_preview.scale == Vector3.ONE, "3x3 预览使用真实网格尺寸")
		check(_preview_vertex_count(player) >= cells.size() * 36, "3x3 预览按每格生成幽灵方块")
		check(player.brush_preview_lines.visible and player.brush_preview_lines.mesh != null, "3x3 画笔显示范围线框")
		check(player._brush_line_material.albedo_color.g > player._brush_line_material.albedo_color.r, "可放置画笔线框为黄绿色")

		check(player._try_place_current(), "3x3 画笔可一次放置")
		check(_last_kind == "place" and _last_label.contains("x9"), "3x3 放置反馈包含数量")
		check(_all_cells_are(cells, BlockLibrary.BRICK), "3x3 区域全部变为当前材料")
		_main.hud._process(0.0)
		check(_main.hud._status_label.text.contains("画笔 3x3"), "HUD 状态栏显示当前画笔尺寸")

		check(_main.world.undo_last_edit(), "一次撤销可撤销整片画笔放置")
		check(_edit_kind == "undo" and _edit_label.contains("批量放置"), "撤销反馈说明批量放置")
		check(_all_cells_are(cells, BlockLibrary.AIR), "撤销后 3x3 区域恢复为空")
		check(_main.world.redo_last_edit(), "一次重做可恢复整片画笔放置")
		check(_edit_kind == "redo" and _edit_label.contains("批量放置"), "重做反馈说明批量放置")
		check(_all_cells_are(cells, BlockLibrary.BRICK), "重做后 3x3 区域恢复材料")

		player._target = place
		player._place = place + Vector3i.UP
		var break_cells: Array = player._break_cells()
		check(break_cells.size() == 9, "3x3 画笔生成 9 个挖掘格")
		check(player._try_break_target(), "3x3 画笔可一次挖掘")
		check(_last_kind == "break" and _last_label.contains("x9"), "3x3 挖掘反馈包含数量")
		check(_all_cells_are(cells, BlockLibrary.AIR), "3x3 挖掘后整片区域为空")
		check(_main.world.undo_last_edit(), "一次撤销可撤销整片画笔挖掘")
		check(_edit_kind == "undo" and _edit_label.contains("批量挖掘"), "撤销反馈说明批量挖掘")
		check(_all_cells_are(cells, BlockLibrary.BRICK), "撤销挖掘后 3x3 区域恢复材料")

		player._target = place - Vector3i.UP
		player._place = place
		for cell in cells:
			var c: Vector3i = cell
			_main.world.set_block(c.x, c.y, c.z, BlockLibrary.AIR)
		var blocked: Vector3i = cells[0]
		_main.world.set_block(blocked.x, blocked.y, blocked.z, BlockLibrary.STONE)
		player._update_placement_preview()
		check(player.placement_blocked_preview.visible, "阻挡时显示具体阻挡格预览")
		check(player._blocked_preview_material.albedo_color.r > player._blocked_preview_material.albedo_color.g, "阻挡格预览为红色")
		check(player._brush_line_material.albedo_color.r > player._brush_line_material.albedo_color.g, "阻挡时画笔线框为红色")
		check(not player._try_place_current(), "3x3 区域存在实体方块时整片放置失败")
		check(_last_kind == "blocked" and _last_label == "目标格已占用", "画笔阻挡反馈沿用具体原因")
		check(_main.world.get_block(blocked.x, blocked.y, blocked.z) == BlockLibrary.STONE, "失败放置不会改动阻挡格")
		check(_unchanged_empty_except(cells, blocked), "失败放置不会部分写入其它格")

		if failed == 0:
			print("✅ ALL BUILD BRUSH TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个建造画笔测试失败")
		return true
	return false

func _all_cells_are(cells: Array, id: int) -> bool:
	for cell in cells:
		var c: Vector3i = cell
		if _main.world.get_block(c.x, c.y, c.z) != id:
			return false
	return true

func _preview_world_size(player) -> Vector3:
	var local_size: Vector3 = player.placement_preview.get_aabb().size
	var scale: Vector3 = player.placement_preview.scale
	return Vector3(local_size.x * scale.x, local_size.y * scale.y, local_size.z * scale.z)

func _preview_vertex_count(player) -> int:
	if player.placement_preview.mesh == null or player.placement_preview.mesh.get_surface_count() == 0:
		return 0
	var arrays: Array = player.placement_preview.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return vertices.size()

func _unchanged_empty_except(cells: Array, blocked: Vector3i) -> bool:
	for cell in cells:
		var c: Vector3i = cell
		if c == blocked:
			continue
		if _main.world.get_block(c.x, c.y, c.z) != BlockLibrary.AIR:
			return false
	return true
