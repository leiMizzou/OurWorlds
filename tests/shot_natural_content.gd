extends SceneTree
# 截一张新增自然内容图：
#   VC_RADIUS=6 godot --path <项目> --script res://tests/shot_natural_content.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")

var _main = null
var _f := 0
var _gen := false
var _target := Vector3i.ZERO

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SEED", "1337")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_natural_content/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_target = _find_natural_content()
			_gen = true
		return false

	_f += 1
	if _f == 2:
		var p = _main.player
		var target := Vector3(_target) + Vector3(0.5, 0.5, 0.5)
		p.global_position = target + Vector3(13.0, 7.0, 15.0)
		_aim_player_at(p, target + Vector3(0.0, 0.8, 0.0))
		p.input_enabled = false
		_main.weather_system.force_weather("clear")
		_hide_player_overlays()
	elif _f >= 30:
		_hide_player_overlays()
		if DisplayServer.get_name().to_lower().contains("headless"):
			print("SHOT skipped: headless renderer")
			return true
		var texture := root.get_texture()
		var img := texture.get_image() if texture != null else null
		if img == null or img.is_empty():
			print("SHOT skipped: no rendered image")
			return true
		img.save_png("res://_shot_natural_content.png")
		print("SHOT saved: _shot_natural_content.png target=", _target, " id=", _main.world.get_block(_target.x, _target.y, _target.z))
		return true
	else:
		_hide_player_overlays()
	return false

func _find_natural_content() -> Vector3i:
	var spring := _find_spring_water()
	if spring.y >= 0:
		return spring
	var preferred := [BlockLibrary.REEDS, BlockLibrary.RED_MUSHROOM, BlockLibrary.CLAY, BlockLibrary.BLUE_CRYSTAL]
	for id in preferred:
		var pos := _find_block(id)
		if pos.y >= 0:
			return pos
	return Vector3i(0, _main.world.surface_y(0, 0) + 1, 0)

func _find_block(id: int) -> Vector3i:
	for cc in _main.world._chunks.keys():
		var chunk: Chunk = _main.world._chunks[cc]
		for y in range(Chunk.SY - 1, -1, -1):
			for z in range(Chunk.SZ):
				for x in range(Chunk.SX):
						if chunk.get_block(x, y, z) == id:
							return Vector3i(cc.x * Chunk.SX + x, y, cc.y * Chunk.SZ + z)
	return Vector3i(0, -1, 0)

func _find_spring_water() -> Vector3i:
	for cc in _main.world._chunks.keys():
		var chunk: Chunk = _main.world._chunks[cc]
		for y in range(Chunk.SY - 1, WorldGenerator.SEA_LEVEL + 2, -1):
			for z in range(Chunk.SZ):
				for x in range(Chunk.SX):
					if chunk.get_block(x, y, z) == BlockLibrary.WATER \
							and y > 0 \
							and chunk.get_block(x, y - 1, z) == BlockLibrary.CLAY:
						return Vector3i(cc.x * Chunk.SX + x, y, cc.y * Chunk.SZ + z)
	return Vector3i(0, -1, 0)

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
