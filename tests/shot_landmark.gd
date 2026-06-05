extends SceneTree
# 截一张程序化遗迹地标：
#   VC_RADIUS=6 godot --path <项目> --script res://tests/shot_landmark.gd

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
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_landmark/settings.json")
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
			var target := Vector3(_landmark) + Vector3(0.5, 0.4, 0.5)
			p.global_position = target + Vector3(-8.0, 5.0, -9.0)
			p.look_at(target, Vector3.UP)
			p.spring.rotation.x = deg_to_rad(-6)
		_main._time = 0.35
		_main.weather_system.force_weather("clear")
	elif _f >= 28:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_landmark.png")
		print("SHOT saved: _shot_landmark.png")
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
