extends SceneTree
# 验证准星取材会选择目标方块，并同步最近材料：
#   godot --headless --path <项目> --script res://tests/test_pick_block.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const GameSettings = preload("res://scripts/GameSettings.gd")

var _f := 0
var _main = null
var failed := 0
var _last_kind := ""
var _last_label := ""
var _picked_id := -1

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
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/pick_block/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		var player = _main.player
		player.action_feedback.connect(func(kind: String, label: String) -> void:
			_last_kind = kind
			_last_label = label
		)
		player.material_picked.connect(func(block_id: int) -> void:
			_picked_id = block_id
		)

		var p: Vector3 = player.global_position
		var wx := int(floor(p.x)) + 3
		var wz := int(floor(p.z))
		var target := Vector3i(wx, _main.world.surface_y(wx, wz) + 1, wz)
		_main.world.set_block(target.x, target.y, target.z, BlockLibrary.COPPER_ORE)
		player._has_target = true
		player._target = target
		check(player.pick_target_block(), "准星取材返回成功")

		var expected_label := "拾取 %s" % _main.lib.block_name(BlockLibrary.COPPER_ORE)
		check(_picked_id == BlockLibrary.COPPER_ORE, "准星取材发出拾取信号")
		check(player.current_block() == BlockLibrary.COPPER_ORE, "准星取材切换为目标材料")
		check(_last_kind == "pick" and _last_label == expected_label, "准星取材发出拾取反馈")
		check(_main.hud._feedback_label.text == expected_label, "HUD 显示拾取反馈")
		check(_main.block_palette.recent_blocks().size() > 0 and int(_main.block_palette.recent_blocks()[0]) == BlockLibrary.COPPER_ORE, "材料库最近列表同步拾取材料")
		check(player.recent_block_ids.size() > 0 and int(player.recent_block_ids[0]) == BlockLibrary.COPPER_ORE, "玩家最近列表同步拾取材料")
		_main.hud._process(0.0)
		check(_main.hud._recent_slots.size() > 0 and int(_main.hud._recent_slots[0]["id"]) == BlockLibrary.COPPER_ORE, "HUD 最近材料条同步拾取材料")
		var saved := GameSettings.load_settings()
		var recent: Array = saved.get("recent_blocks", [])
		check(recent.size() > 0 and int(recent[0]) == BlockLibrary.COPPER_ORE, "拾取材料写入设置")

		_last_kind = ""
		_last_label = ""
		_picked_id = -1
		player._has_target = false
		check(not player.pick_target_block(), "没有目标时不会拾取")
		check(_last_kind == "blocked" and _last_label == "没有可拾取方块", "没有目标时给出明确反馈")
		check(_picked_id == -1, "失败拾取不发出拾取信号")

		if failed == 0:
			print("✅ ALL PICK BLOCK TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个准星取材测试失败")
		return true
	return false
