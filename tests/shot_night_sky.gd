extends SceneTree
# 截一张夜空氛围图：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_night_sky.gd

var _main = null
var _f := 0
var _gen := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_night_sky/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen = true
		return false

	_f += 1
	if _f == 2:
		var p = _main.player
		var x := int(floor(p.global_position.x))
		var z := int(floor(p.global_position.z))
		p.global_position = Vector3(float(x) + 0.5, float(_main.world.surface_y(x, z)) + 24.0, float(z) + 0.5)
		p.rotation.y = deg_to_rad(-28)
		p.pitch = deg_to_rad(34)
		p.spring.rotation.x = p.pitch
		_main.weather_system.force_weather("clear")
		_main._time = 0.0
	elif _f < 36:
		_main._time = 0.0
	elif _f >= 36:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_night_sky.png")
		print("SHOT saved: _shot_night_sky.png")
		return true
	return false
