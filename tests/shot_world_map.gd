extends SceneTree
# 截一张带地貌底图、遗迹和线索的世界地图：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_world_map.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _main = null
var _f := 0
var _shot_done := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SEED", "5151")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_world_map/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_f += 1
	if not _shot_done and _f == 34:
		_seed_map_state()
		_main.set_world_map_active(true)
	elif not _shot_done and _f >= 44:
		if DisplayServer.get_name().to_lower().contains("headless"):
			print("SHOT skipped: viewport texture unavailable in headless")
			_main.set_world_map_active(false)
			_shot_done = true
			return true
		var texture := root.get_texture()
		if texture == null:
			print("SHOT skipped: viewport texture unavailable")
			_main.set_world_map_active(false)
			_shot_done = true
			return true
		var img := texture.get_image()
		if img == null or img.is_empty():
			print("SHOT skipped: viewport image unavailable")
			_main.set_world_map_active(false)
			_shot_done = true
			return true
		img.save_png("res://_shot_world_map.png")
		print("SHOT saved: _shot_world_map.png")
		_main.set_world_map_active(false)
		_shot_done = true
	elif _shot_done and _f >= 72:
		return true
	return false

func _seed_map_state() -> void:
	_main.player.global_position = _main._journey_start_pos + Vector3(42, 0, -18)
	var landmark := Vector3i(8, 40, 8)
	var target_landmark := Vector3i(62, 40, -32)
	_main.world.mark_landmark_discovered(landmark)
	_main.world.mark_landmark_discovered(target_landmark)
	_raise_repair_to(landmark, 20)
	_raise_repair_to(target_landmark, 8)
	_main.discovery_tracker._nearby_hint_distance = 31
	_main.discovery_tracker._nearby_hint_direction = "右前"
	_main.discovery_tracker._nearby_hint_position = _main.player.global_position + Vector3(30, 0, -8)

func _raise_repair_to(landmark: Vector3i, target_count: int) -> void:
	for dz in range(-4, 5):
		for dx in range(-4, 5):
			if dx == 0 and dz == 0:
				continue
			if int(_main.world.edited_blocks_near(landmark)) >= target_count:
				return
			_main.world.set_block(landmark.x + dx, landmark.y + 1, landmark.z + dz, BlockLibrary.MOONSTONE_LAMP)
