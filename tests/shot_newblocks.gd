extends SceneTree
# 展示新增建材方块（精炼铁/铜面板/钢/鎏金/红沙/赤陶/暖光石）。
#   godot --path <项目> --script res://tests/shot_newblocks.gd → _shot_newblocks.png

var _main = null
var _gen_done := false
var _sf := 0
var _base := Vector3.ZERO
const NEW_IDS := [28, 29, 30, 31, 32, 33, 34]   # POLISHED_IRON..SUNSTONE

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_newblocks/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen_done:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen_done = true
			if _main.weather_system != null:
				_main.weather_system.set_enabled(false)
			_main._time = 0.30   # 清晨暖光，金属/赤陶质感好看
			if _main.hud != null:
				_main.hud.visible = false
			if _main.player != null and _main.player.has_method("set_overlays_visible"):
				_main.player.set_overlays_visible(false)
			var p = _main.player.global_position
			var bx := int(floor(p.x))
			var bz := int(floor(p.z)) - 5
			var gy: int = _main.world.surface_y(bx, bz)
			_base = Vector3(bx, gy, bz)
			# 一排新方块各起一根 2 高柱子
			for i in range(NEW_IDS.size()):
				var x := bx - 6 + i * 2
				_main.world.set_block(x, gy + 1, bz, NEW_IDS[i])
				_main.world.set_block(x, gy + 2, bz, NEW_IDS[i])
		return false
	_sf += 1
	if _main.hud != null:
		_main.hud.visible = false
	if _sf == 4:
		var p = _main.player
		p.fly = true
		p.global_position = _base + Vector3(0, 3, 9)
		p.spring.rotation.x = 0.0
		p.look_at(_base + Vector3(0, 1.5, 0), Vector3.UP)
		_main._time = 0.30
	if _sf >= 30:
		root.get_texture().get_image().save_png("res://_shot_newblocks.png")
		print("SHOT newblocks: _shot_newblocks.png")
		return true
	return false
