extends SceneTree
# 截一张波纹水面图：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_water_surface.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")

var _main = null
var _f := 0
var _gen := false
var _center := Vector3i.ZERO

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_water_surface/settings.json")
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
		_build_pool()
		var p = _main.player
		var target := Vector3(_center) + Vector3(0.5, 0.8, 0.5)
		p.global_position = target + Vector3(9.0, 5.5, 10.0)
		_aim_player_at(p, target)
		p.input_enabled = false
		_main.weather_system.force_weather("clear")
		_hide_player_overlays()
	elif _f >= 36:
		_hide_player_overlays()
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_water_surface.png")
		print("SHOT saved: _shot_water_surface.png center=", _center)
		return true
	else:
		_hide_player_overlays()
	return false

func _build_pool() -> void:
	var p = _main.player.global_position
	var cx := int(floor(p.x)) + 7
	var cz := int(floor(p.z)) + 8
	var base_y := _max_surface(cx, cz, 4) + 5
	_center = Vector3i(cx, base_y, cz)
	var touched := {}
	for dz in range(-4, 5):
		for dx in range(-4, 5):
			var x := cx + dx
			var z := cz + dz
			_raw_set(x, base_y - 2, z, BlockLibrary.DIRT, touched)
			_raw_set(x, base_y - 1, z, BlockLibrary.CLAY, touched)
			if abs(dx) <= 2 and abs(dz) <= 2:
				_raw_set(x, base_y, z, BlockLibrary.WATER, touched)
			else:
				_raw_set(x, base_y, z, BlockLibrary.CLAY if maxi(abs(dx), abs(dz)) <= 3 else BlockLibrary.GRASS, touched)
	for cc in touched.keys():
		_main.world._remesh_sync(cc)

func _max_surface(cx: int, cz: int, radius: int) -> int:
	var h := -999
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			h = maxi(h, _main.world.surface_y(cx + dx, cz + dz))
	return h

func _aim_player_at(player, target: Vector3) -> void:
	var dir: Vector3 = (target - player.global_position).normalized()
	var flat := Vector3(dir.x, 0.0, dir.z).normalized()
	player.rotation.y = atan2(-flat.x, -flat.z)
	player.pitch = asin(clampf(dir.y, -0.95, 0.95))
	player.spring.rotation.x = player.pitch

func _hide_player_overlays() -> void:
	for node in [_main.player.highlight, _main.player.placement_preview, _main.player.brush_preview_lines]:
		if node != null:
			node.visible = false

func _raw_set(wx: int, wy: int, wz: int, id: int, touched: Dictionary) -> void:
	var cc: Vector2i = _main.world.chunk_of(wx, wz)
	_main.world._ensure_data(cc)
	var chunk = _main.world._chunks[cc]
	chunk.set_block(wx - cc.x * Chunk.SX, wy, wz - cc.y * Chunk.SZ, id)
	touched[cc] = true
