extends SceneTree
# 截一张"第三人称 + 方块小人"的图，验证 Avatar 和视角切换：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_avatar.gd

var _main = null
var _gen := false
var _sf := 0

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_avatar/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen = true
		return false
	_sf += 1
	if _sf == 2:
		var p = _main.player
		p.fly = false
		p.rotation.y = deg_to_rad(25)
		p._toggle_view()                       # -> 第三人称，小人现身
		p.spring.rotation.x = deg_to_rad(-22)  # 相机升到身后上方，俯看小人
	if _sf >= 24:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_avatar.png")
		print("SHOT saved: _shot_avatar.png")
		return true
	return false
