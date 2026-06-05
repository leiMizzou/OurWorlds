extends SceneTree
# 验证世界内动作视觉反馈：
#   godot --headless --path <项目> --script res://tests/test_action_effects.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _f := 0
var _main = null
var failed := 0
var _events := []

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
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/action_effects/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		var effects = _main.action_effects
		var player = _main.player
		player.world_feedback.connect(func(kind: String, cell: Vector3i, block_id: int) -> void:
			_events.append({"kind": kind, "cell": cell, "block_id": block_id})
		)

		effects._on_world_feedback("place", Vector3i(1, 40, 1), BlockLibrary.COPPER_ORE)
		check(effects._items.size() == 9, "放置反馈生成 9 个碎片")
		effects._process(0.2)
		check(effects._items.size() > 0, "碎片生命周期中仍存在")
		effects._process(1.0)
		check(effects._items.is_empty(), "碎片生命周期结束后清理")
		check(effects._block_color(BlockLibrary.SNOW).b > effects._block_color(BlockLibrary.SNOW).r, "雪块碎片使用冷白色")
		check(effects._block_color(BlockLibrary.BLUE_CRYSTAL).b > 0.9 and effects._block_color(BlockLibrary.BLUE_CRYSTAL).g > 0.6, "蓝晶碎片使用亮蓝色")
		check(effects._block_color(BlockLibrary.PINE_LEAVES).g > effects._block_color(BlockLibrary.PINE_LEAVES).r, "针叶碎片使用绿色")
		check(effects._block_color(BlockLibrary.REEDS).g > effects._block_color(BlockLibrary.REEDS).r, "芦苇碎片使用草绿色")
		check(effects._block_color(BlockLibrary.CLAY) != Color(0.75, 0.78, 0.76), "黏土碎片不再使用默认颜色")
		effects.show_restoration(Vector3(2.5, 40.5, 2.5))
		check(effects._items.size() >= 50, "修复完成反馈生成丰富碎片")
		effects._process(1.3)
		check(effects._items.is_empty(), "修复完成碎片生命周期结束后清理")
		effects.show_campfire(Vector3(3.5, 40.5, 3.5))
		check(effects._items.size() == 34, "营火点燃反馈生成火花和轻烟")
		check(_has_upward_smoke(effects), "营火点燃反馈包含上升轻烟")
		effects._process(1.3)
		check(effects._items.is_empty(), "营火点燃反馈生命周期结束后清理")
		effects._on_world_feedback("campfire", Vector3i(4, 40, 4), BlockLibrary.LANTERN)
		var campfire_only: int = effects._items.size()
		effects._on_world_feedback("place", Vector3i(4, 40, 4), BlockLibrary.LANTERN)
		check(campfire_only == 34 and effects._items.size() == campfire_only, "营火专属反馈会抑制同帧普通放置碎片")
		effects._process(1.3)
		check(effects._items.is_empty(), "营火抑制测试后碎片会清理")
		effects._on_world_feedback("bulk_place", Vector3i(5, 40, 5), BlockLibrary.PLANKS)
		var bulk_only: int = effects._items.size()
		effects._on_world_feedback("place", Vector3i(5, 40, 5), BlockLibrary.PLANKS)
		check(bulk_only == 42 and effects._items.size() == bulk_only, "大模板聚合反馈会抑制同帧普通放置碎片")
		effects._process(1.0)
		check(effects._items.is_empty(), "大模板聚合碎片生命周期结束后清理")

		player._has_target = true
		var p: Vector3 = player.global_position
		var ok_x := int(floor(p.x)) + 4
		var ok_z := int(floor(p.z))
		var ok_y: int = _main.world.surface_y(ok_x, ok_z) + 1
		player._place = Vector3i(ok_x, ok_y, ok_z)
		check(player._try_place_current(), "成功放置会走真实放置路径")
		check(not _events.is_empty() and _events[-1]["kind"] == "place", "成功放置会发出 world_feedback")
		check(effects._items.size() > 0, "成功放置会生成世界内碎片")

		player._place = Vector3i(int(floor(p.x)), int(floor(p.y)), int(floor(p.z)))
		check(not player._try_place_current(), "阻挡放置失败")
		check(_events[-1]["kind"] == "blocked", "阻挡失败会发出 world_feedback")
		if failed == 0:
			print("✅ ALL ACTION EFFECTS TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个动作视觉反馈测试失败")
		return true
	return false

func _has_upward_smoke(effects) -> bool:
	for raw in effects._items:
		var entry: Dictionary = raw
		if float(entry.get("gravity", 5.5)) < 0.0:
			return true
	return false
