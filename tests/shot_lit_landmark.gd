extends SceneTree
# 截一张夜间发光遗迹：
#   VC_RADIUS=6 godot --path <项目> --script res://tests/shot_lit_landmark.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")

var _main = null
var _f := 0
var _gen := false
var _landmark := Vector3i.ZERO

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SEED", "1337")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_lit_landmark/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_landmark = _find_lantern()
			_gen = true
		return false

	_f += 1
	if _f == 2:
		var p = _main.player
		p.fly = true
		if _landmark.y >= 0:
			var target := Vector3(_landmark) + Vector3(0.5, 0.45, 0.5)
			p.global_position = target + Vector3(-7.5, 3.6, -8.5)
			_aim_player_at(p, target)
		p.input_enabled = false
		_main.weather_system.force_weather("clear")
		if _main.landmark_marker != null:
			_main.landmark_marker.visible = false
		_hide_player_overlays()
	elif _f < 36:
		_main._time = 0.0
		if _main.landmark_marker != null:
			_main.landmark_marker.visible = false
		_hide_player_overlays()
	elif _f >= 36:
		if _main.landmark_marker != null:
			_main.landmark_marker.visible = false
		_hide_player_overlays()
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_lit_landmark.png")
		print("SHOT saved: _shot_lit_landmark.png lantern=", _landmark, " lights=", _count_chunk_lights(false), " visible=", _count_chunk_lights(true))
		return true
	return false

func _find_lantern() -> Vector3i:
	for cc in _main.world._chunks.keys():
		var chunk: Chunk = _main.world._chunks[cc]
		for y in range(Chunk.SY):
			for z in range(Chunk.SZ):
				for x in range(Chunk.SX):
					if chunk.get_block(x, y, z) == BlockLibrary.LANTERN:
						return Vector3i(cc.x * Chunk.SX + x, y, cc.y * Chunk.SZ + z)
	return Vector3i(0, -1, 0)

func _count_chunk_lights(visible_only: bool) -> int:
	var count := 0
	for entry in _main.world._nodes.values():
		var e: Dictionary = entry
		if e.has("lights"):
			var root := e["lights"] as Node3D
			if not visible_only or root.visible:
				count += root.get_child_count()
	return count

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
