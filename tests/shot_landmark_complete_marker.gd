extends SceneTree
# 截一张满修复遗迹完成信标：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_landmark_complete_marker.gd

var _main = null
var _f := 0
var _gen := false
var _marker_pos := Vector3.ZERO

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_landmark_complete_marker/settings.json")
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
		p.input_enabled = false
		_main.weather_system.force_weather("clear")
		var base_x := int(floor(p.global_position.x)) + 6
		var base_z := int(floor(p.global_position.z)) - 2
		var y: int = _main.world.surface_y(base_x, base_z) + 1
		_marker_pos = Vector3(base_x + 0.5, y, base_z + 0.5)
		p.global_position = _marker_pos + Vector3(-4.5, 2.2, 8.5)
		p.look_at(_marker_pos + Vector3(0.0, 2.2, 0.0), Vector3.UP)
		p.spring.rotation.x = deg_to_rad(-10)
		_main.hud.visible = false
		_pin_marker()
	elif _f > 2 and _f < 26:
		_pin_marker()
	elif _f >= 26:
		if DisplayServer.get_name().to_lower().contains("headless"):
			print("SHOT skipped: viewport texture unavailable in headless")
			return true
		var tex := root.get_texture()
		if tex == null:
			print("SHOT skipped: viewport texture unavailable")
			return true
		var img := tex.get_image()
		if img == null:
			print("SHOT skipped: viewport image unavailable")
			return true
		img.save_png("res://_shot_landmark_complete_marker.png")
		print("SHOT saved: _shot_landmark_complete_marker.png")
		return true
	return false

func _pin_marker() -> void:
	if _main == null or _main.landmark_marker == null:
		return
	_main.landmark_marker.set_marker(_marker_pos, true, "complete", 100)
