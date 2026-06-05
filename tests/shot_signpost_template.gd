extends SceneTree
# 截一张一键路标模板成品图：
#   VC_RADIUS=4 godot --path <项目> --script res://tests/shot_signpost_template.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _main = null
var _f := 0
var _gen := false
var _signpost := Vector3i.ZERO

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_signpost_template/settings.json")
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
		paused = false
		if _main.pause_menu != null:
			_main.pause_menu.close()
		if _main.title_screen != null:
			_main.title_screen.close()
		_main.weather_system.force_weather("clear")
		_select_template(p, "signpost")
		p.template_orientation_index = 0
		var base_x := int(floor(p.global_position.x)) + 8
		var base_z := int(floor(p.global_position.z)) - 2
		var y := _max_surface(base_x, base_z, 3) + 1
		_signpost = Vector3i(base_x, y, base_z)
		p._has_target = true
		p._target = _signpost - Vector3i.UP
		p._place = _signpost
		for cell in p._placement_cells():
			var c: Vector3i = cell
			_main.world.set_block(c.x, c.y, c.z, BlockLibrary.AIR)
		p._try_place_current()
		p.set_overlays_visible(false)
		p.fly = true
		var target := Vector3(_signpost) + Vector3(0.8, 2.2, 0.6)
		p.global_position = target + Vector3(-5.0, 2.7, -6.0)
		p.camera.current = false
		var cam := Camera3D.new()
		cam.name = "SignpostShotCamera"
		cam.fov = 42.0
		cam.far = 400.0
		_main.add_child(cam)
		cam.global_position = target + Vector3(-5.2, 2.8, -6.2)
		cam.look_at(target, Vector3.UP)
		cam.current = true
		if _main.hud != null:
			_main.hud.visible = false
		_main._time = 0.40
	elif _f >= 30:
		paused = false
		if _main.pause_menu != null:
			_main.pause_menu.close()
		if _main.title_screen != null:
			_main.title_screen.close()
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
		img.save_png("res://_shot_signpost_template.png")
		print("SHOT saved: _shot_signpost_template.png")
		return true
	return false

func _select_template(player, template_id: String) -> void:
	for i in range(player.build_template_count()):
		if player.build_template_id_at(i) == template_id:
			player.template_index = i
			return

func _max_surface(cx: int, cz: int, radius: int) -> int:
	var h := 0
	for z in range(cz - radius, cz + radius + 1):
		for x in range(cx - radius, cx + radius + 1):
			h = maxi(h, _main.world.surface_y(x, z))
	return h
