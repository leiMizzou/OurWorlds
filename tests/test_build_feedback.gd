extends SceneTree
# 验证建造放置预览和无效放置反馈：
#   godot --headless --path <项目> --script res://tests/test_build_feedback.gd

const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _f := 0
var _main = null
var failed := 0
var _last_kind := ""
var _last_label := ""

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
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/build_feedback/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		var player = _main.player
		player.action_feedback.connect(func(kind: String, label: String) -> void:
			_last_kind = kind
			_last_label = label
		)

		var p: Vector3 = player.global_position
		var ok_cell := Vector3i(int(floor(p.x)) + 3, _main.world.surface_y(int(floor(p.x)) + 3, int(floor(p.z))) + 1, int(floor(p.z)))
		check(player._can_place_at(ok_cell), "空地可放置")
		player._place = ok_cell
		player._update_placement_preview()
		check(player.placement_preview.visible, "可放置时预览可见")
		check(player.placement_preview.global_position == Vector3(ok_cell) + Vector3(0.5, 0.5, 0.5), "预览位于放置格中心")
		check(player._preview_material.albedo_color.g > player._preview_material.albedo_color.r, "可放置预览为绿色系")
		player.select_block_id(BlockLibrary.BRICK)
		player._update_placement_preview()
		check(player._preview_material.albedo_color.r > player._preview_material.albedo_color.g, "砖块预览呈红色系")
		var brick_preview: Color = player._preview_material.albedo_color
		player.select_block_id(BlockLibrary.MARBLE)
		player._update_placement_preview()
		check(player._preview_material.albedo_color.r > brick_preview.r and player._preview_material.albedo_color.g > brick_preview.g, "大理石预览比砖块更明亮")

		var blocked_cell := Vector3i(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
		check(not player._can_place_at(blocked_cell), "身体占用格不可放置")
		check(player._place_blocked_reason(blocked_cell) == "会卡住玩家", "身体占用会给出具体原因")
		player._place = blocked_cell
		player._update_placement_preview()
		check(player.placement_blocked_preview.visible, "不可放置时显示红色阻挡预览")
		check(player._blocked_preview_material.albedo_color.r > player._blocked_preview_material.albedo_color.g, "不可放置阻挡预览为红色系")

		var solid_x := int(floor(p.x)) + 3
		var solid_z := int(floor(p.z))
		var solid_cell := Vector3i(solid_x, _main.world.surface_y(solid_x, solid_z), solid_z)
		check(player._place_blocked_reason(solid_cell) == "目标格已占用", "已有实体方块会给出占用原因")
		check(player._place_blocked_reason(Vector3i(0, Chunk.SY, 0)) == "超出建造高度", "超出高度会给出具体原因")

		player._has_target = true
		player._try_place_current()
		check(_last_kind == "blocked" and _last_label == "会卡住玩家", "右键无效放置会发出具体反馈")
		check(_main.hud._feedback_label.text == "会卡住玩家", "HUD 显示具体无效放置提示")
		if failed == 0:
			print("✅ ALL BUILD FEEDBACK TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个建造反馈测试失败")
		return true
	return false
