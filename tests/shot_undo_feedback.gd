extends SceneTree
# 截一张撤销反馈 HUD：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_undo_feedback.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _main = null
var _f := 0
var _gen := false
var _edit_cell := Vector3i.ZERO

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_undo_feedback/settings.json")
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
		var base_x := int(floor(p.global_position.x)) + 3
		var base_z := int(floor(p.global_position.z))
		var y: int = _main.world.surface_y(base_x, base_z) + 1
		while y < 95 and _main.world.get_block(base_x, y, base_z) != BlockLibrary.AIR:
			y += 1
		p.global_position = Vector3(base_x - 4.5, y + 2.0, base_z + 4.0)
		p.look_at(Vector3(base_x + 0.5, y + 0.5, base_z + 0.5), Vector3.UP)
		p.spring.rotation.x = deg_to_rad(-12)
		_edit_cell = Vector3i(base_x, y, base_z)
		_main.world.request_edit(_edit_cell.x, _edit_cell.y, _edit_cell.z, BlockLibrary.BRICK)
	elif _f == 24:
		_main.world.undo_last_edit()
	elif _f >= 26:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_undo_feedback.png")
		print("SHOT saved: _shot_undo_feedback.png")
		return true
	return false
