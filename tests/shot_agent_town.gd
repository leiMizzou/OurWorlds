extends SceneTree
# 重载 agent 正在建的世界(同 seed)，把镜头摆到它的建造群上空截图。
#   VC_SEED=<seed> godot --path <项目> --script res://tests/shot_agent_town.gd
var _main = null
var _gen := false
var _f := 0

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_d: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(_main.world.chunk_of(311, 365))
			_gen = true
		return false
	_f += 1
	if _f == 3:
		var p = _main.player
		var h: int = _main.world.surface_y(311, 365)
		p.fly = true
		p.spring.rotation.x = 0.0
		p.global_position = Vector3(336, h + 20, 392)
		p.look_at(Vector3(308, h + 1, 360), Vector3.UP)
	if _f >= 30:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_agent_town.png")
		print("SHOT saved _shot_agent_town.png ", img.get_width(), "x", img.get_height())
		return true
	return false
