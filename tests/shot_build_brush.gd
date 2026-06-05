extends SceneTree
# 截一张 3x3 建造画笔预览：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_build_brush.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _main = null
var _f := 0
var _gen := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_build_brush/settings.json")
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
		_main.weather_system.force_weather("clear")
		p.select_block_id(BlockLibrary.BRICK)
		p.brush_index = 1
		p.input_enabled = false
		var base_x := int(floor(p.global_position.x)) + 5
		var base_z := int(floor(p.global_position.z)) - 4
		var y := _max_surface(base_x, base_z, 1) + 5
		var target := Vector3(base_x + 0.5, y + 1.2, base_z + 0.5)
		p.global_position = target + Vector3(-3.5, 1.5, 10.0)
		p.look_at(target, Vector3.UP)
		p.spring.rotation.x = deg_to_rad(-8)
		_pin_preview_target(base_x, y, base_z)
	elif _f > 2 and _f < 24:
		var p = _main.player
		_pin_preview_target(int(p._place.x), int(p._place.y), int(p._place.z))
	elif _f >= 24:
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
		img.save_png("res://_shot_build_brush.png")
		print("SHOT saved: _shot_build_brush.png")
		return true
	return false

func _max_surface(cx: int, cz: int, radius: int) -> int:
	var h := 0
	for z in range(cz - radius, cz + radius + 1):
		for x in range(cx - radius, cx + radius + 1):
			h = maxi(h, _main.world.surface_y(x, z))
	return h

func _pin_preview_target(base_x: int, y: int, base_z: int) -> void:
	var p = _main.player
	p._has_target = true
	p._target = Vector3i(base_x, y, base_z - 1)
	p._place = Vector3i(base_x, y, base_z)
	p._target_normal = Vector3i(0, 0, 1)
	for cell in p._placement_cells():
		var c: Vector3i = cell
		_main.world.set_block(c.x, c.y, c.z, BlockLibrary.AIR)
	p._update_placement_preview()
	p.highlight.visible = true
	p.highlight.global_position = Vector3(p._target) + Vector3(0.5, 0.5, 0.5)
	_main.hud._process(0.0)
