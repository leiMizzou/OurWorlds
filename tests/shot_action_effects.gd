extends SceneTree
# 截一张挖/放动作碎片反馈：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_action_effects.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _main = null
var _f := 0
var _gen := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_action_effects/settings.json")
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
		p.global_position = Vector3(base_x - 4.0, y + 2.4, base_z + 4.6)
		p.look_at(Vector3(base_x + 0.5, y + 0.7, base_z + 0.5), Vector3.UP)
		p.spring.rotation.x = deg_to_rad(-12)
	elif _f == 18:
		var p = _main.player
		var base_x := int(floor(p.global_position.x)) + 4
		var base_z := int(floor(p.global_position.z)) - 4
		var y: int = _main.world.surface_y(base_x, base_z) + 1
		p.placement_preview.visible = false
		_main.action_effects._on_world_feedback("place", Vector3i(base_x, y, base_z), BlockLibrary.COPPER_ORE)
		_main.action_effects._on_world_feedback("break", Vector3i(base_x + 1, y - 1, base_z), BlockLibrary.BRICK)
	elif _f >= 20:
		_main.player.placement_preview.visible = false
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_action_effects.png")
		print("SHOT saved: _shot_action_effects.png")
		return true
	return false
