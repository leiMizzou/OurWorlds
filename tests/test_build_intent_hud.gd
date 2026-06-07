extends SceneTree
# 验证 HUD 建造意图面板：单格、画笔、模板、多材质和阻挡状态。
#   godot --headless --path <项目> --script res://tests/test_build_intent_hud.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const GameSettings = preload("res://scripts/GameSettings.gd")

var _f := 0
var _main = null
var failed := 0

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
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/build_intent_hud/settings.json")
		# 预置 language=zh，使断言里的中文文案不受运行机 OS 语言影响（确定性回归）。
		_seed_language("zh")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		var player = _main.player
		player.select_block_id(BlockLibrary.BRICK)
		player._has_target = false
		_main.hud._process(0.0)
		check(_main.hud._build_intent_panel.visible, "HUD 建造意图面板可见")
		check(_main.hud._build_mode_label.text == "单格", "未瞄准时显示默认单格模式")
		check(_main.hud._build_detail_label.text == "未瞄准方块", "未瞄准时显示等待目标详情")
		check(_main.hud._build_state_label.text == "等待目标", "未瞄准时显示等待状态")

		var p: Vector3 = player.global_position
		var base := Vector3i(int(floor(p.x)) + 8, int(floor(p.y)) + 7, int(floor(p.z)) + 8)
		player._has_target = true
		player._target_normal = Vector3i.UP
		player.template_index = 0
		player.brush_index = 0
		player._target = base - Vector3i.UP
		player._place = base
		_clear_cells(player._placement_cells())
		_main.hud._process(0.0)
		check(_main.hud._build_mode_label.text == "单格", "单格放置显示单格模式")
		check(_main.hud._build_detail_label.text.contains("砖块") and _main.hud._build_detail_label.text.contains("1 格"), "单格详情显示材料和数量")
		check(_main.hud._build_detail_label.text.contains("占地 1x1x1"), "单格详情显示占地")
		check(_main.hud._build_state_label.text == "可放置", "单格空位显示可放置")

		player.brush_index = 1
		var brush_cells: Array = player._placement_cells()
		_clear_cells(brush_cells)
		_main.hud._process(0.0)
		check(_main.hud._build_mode_label.text == "画笔 3x3", "3x3 画笔显示画笔模式")
		check(_main.hud._build_detail_label.text.contains("9 格"), "3x3 画笔详情显示格数")
		check(_main.hud._build_detail_label.text.contains("占地 3x1x3"), "3x3 画笔详情显示占地")
		check(_main.hud._build_state_label.text == "可放置", "3x3 空位显示可放置")

		var blocked: Vector3i = brush_cells[0]
		_main.world.set_block(blocked.x, blocked.y, blocked.z, BlockLibrary.STONE)
		_main.hud._process(0.0)
		check(_main.hud._build_state_label.text.contains("阻挡 1 格"), "阻挡时显示阻挡格数")
		check(_main.hud._build_state_label.text.contains("目标格已占用"), "阻挡时显示具体原因")
		check(_main.hud._build_state_label.modulate.r > _main.hud._build_state_label.modulate.g, "阻挡状态使用红色强调")
		_clear_cells(brush_cells)

		player.brush_index = 0
		player.template_index = 1
		player.template_orientation_index = 0
		player._place = base + Vector3i(8, 0, 0)
		player._target = player._place - Vector3i.UP
		var platform_cells: Array = player._placement_cells()
		_clear_cells(platform_cells)
		_main.hud._process(0.0)
		check(_main.hud._build_mode_label.text == "模板 平台 东西", "模板显示名称和朝向")
		check(_main.hud._build_detail_label.text.contains("砖块") and _main.hud._build_detail_label.text.contains("25 格"), "普通模板显示当前材料和格数")
		check(_main.hud._build_detail_label.text.contains("占地 5x1x5"), "普通模板显示占地")

		player.template_index = 7
		player._place = base + Vector3i(20, 0, 0)
		player._target = player._place - Vector3i.UP
		var cabin_cells: Array = player._placement_cells()
		_clear_cells(cabin_cells)
		_main.hud._process(0.0)
		check(_main.hud._build_mode_label.text == "模板 小屋 东西", "成品模板显示名称和朝向")
		check(_main.hud._build_detail_label.text.contains("多材质"), "成品模板显示多材质")
		check(_main.hud._build_detail_label.text.contains("占地"), "成品模板显示占地")
		check(_main.hud._build_state_label.text == "可放置", "成品模板空位显示可放置")

		if failed == 0:
			print("✅ ALL BUILD INTENT HUD TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个建造意图 HUD 测试失败")
		return true
	return false

func _clear_cells(cells: Array) -> void:
	for raw in cells:
		var c: Vector3i = raw
		_main.world.set_block(c.x, c.y, c.z, BlockLibrary.AIR)

# 写入仅含 language 的设置文件；Main 启动会据此把界面语言定为该语言。
func _seed_language(lang: String) -> void:
	var settings := GameSettings.load_settings()
	settings["language"] = lang
	GameSettings.save_settings(settings)
