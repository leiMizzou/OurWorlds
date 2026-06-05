extends SceneTree
# 第三人称小人"真的在走"——模拟前进输入，侧面相机看清迈腿摆臂。
#   godot --path <项目> --script res://tests/shot_avatar_walk.gd → _shot_avatar_walk.png

var _main = null
var _gen := false
var _sf := 0
var _cam: Camera3D = null

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_avatar_walk/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen = true
		return false
	_sf += 1
	var p = _main.player
	if _sf == 2:
		if _main.weather_system != null:
			_main.weather_system.set_enabled(false)
		if _main.hud != null:
			_main.hud.visible = false
		_main._time = 0.32
		p.fly = false
		p.input_enabled = true
		p.rotation.y = deg_to_rad(20)
		p._toggle_view()                    # 第三人称，小人现身
		Input.action_press("move_forward")  # 往前走
		_cam = Camera3D.new()
		_cam.fov = 40
		root.add_child(_cam)
	if _sf >= 16 and _cam != null:
		# 侧面略斜 + 望远，紧贴小人，看清迈腿摆臂
		var origin: Vector3 = p.global_position
		var side: Vector3 = p.global_transform.basis.x
		var fwd: Vector3 = -p.global_transform.basis.z
		_cam.global_position = origin + side * 2.4 - fwd * 0.6 + Vector3(0, 1.05, 0)
		_cam.look_at(origin + Vector3(0, 0.85, 0), Vector3.UP)
		_cam.current = true
	if _sf >= 20:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_avatar_walk.png")
		Input.action_release("move_forward")
		print("SHOT saved: _shot_avatar_walk.png  _bob=", p._bob, " legL=", rad_to_deg(p._leg_l.rotation.x))
		return true
	return false
