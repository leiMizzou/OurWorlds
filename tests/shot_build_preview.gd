extends SceneTree
# 截一张放置预览图：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_build_preview.gd

var _main = null
var _f := 0
var _gen := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_build_preview/settings.json")
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
		var base_x := int(floor(p.global_position.x)) + 2
		var base_z := int(floor(p.global_position.z))
		var y: int = _main.world.surface_y(base_x, base_z) + 1
		p.global_position = Vector3(base_x - 4.0, y + 2.2, base_z + 4.5)
		p.look_at(Vector3(base_x + 0.5, y + 0.5, base_z + 0.5), Vector3.UP)
		p._has_target = true
		p._target = Vector3i(base_x, y - 1, base_z)
		p._place = Vector3i(base_x, y, base_z)
		p._update_placement_preview()
		p.highlight.visible = true
		p.highlight.global_position = Vector3(p._target) + Vector3(0.5, 0.5, 0.5)
		p.spring.rotation.x = deg_to_rad(-14)
	elif _f >= 24:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_build_preview.png")
		print("SHOT saved: _shot_build_preview.png")
		return true
	return false
