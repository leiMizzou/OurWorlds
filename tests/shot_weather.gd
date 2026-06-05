extends SceneTree
# 截一张阵雨天气氛围图：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_weather.gd

var _main = null
var _f := 0
var _gen := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_weather/settings.json")
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
		p.global_position += Vector3(0, 3.0, 6.0)
		p.rotation.y = deg_to_rad(-18)
		p.spring.rotation.x = deg_to_rad(-10)
		_main.weather_system.force_weather("rain")
	elif _f >= 26:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_weather.png")
		print("SHOT saved: _shot_weather.png")
		return true
	return false
