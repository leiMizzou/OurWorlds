extends SceneTree
# 高空俯瞰展示二维群系（草甸/沙漠/红土台地/雪峰/水岸）。
#   VC_SEED=... VC_RADIUS=7 godot --path <项目> --script res://tests/shot_biomes.gd → _shot_biomes.png

var _main = null
var _gen_done := false
var _sf := 0

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_biomes/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen_done:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen_done = true
			if _main.weather_system != null:
				_main.weather_system.set_enabled(false)
			_main._time = 0.33
			if _main.hud != null:
				_main.hud.visible = false
			if _main.player != null and _main.player.has_method("set_overlays_visible"):
				_main.player.set_overlays_visible(false)
		return false
	_sf += 1
	if _main.hud != null:
		_main.hud.visible = false
	if _sf == 3:
		var p = _main.player
		p.fly = true
		p.global_position = Vector3(-40, 145, 150)
		p.spring.rotation.x = 0.0
		p.look_at(Vector3(30, 20, -40), Vector3.UP)
		_main._time = 0.33
	if _sf >= 26:
		root.get_texture().get_image().save_png("res://_shot_biomes.png")
		print("SHOT biomes: _shot_biomes.png")
		return true
	return false
