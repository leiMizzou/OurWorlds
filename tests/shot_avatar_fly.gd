extends SceneTree
# 第三人称小人飞行(超人)姿态 + 披风验证。
#   godot --path <项目> --script res://tests/shot_avatar_fly.gd → _shot_avatar_fly.png

var _main = null
var _gen := false
var _sf := 0
var _cam: Camera3D = null

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_avatar_fly/settings.json")
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
		p.set_physics_process(false)        # 停掉每帧重置，手动定姿
		p.fly = true
		p.rotation.y = deg_to_rad(20)
		p.global_position += Vector3(0, 5, 0) # 抬到空中显得在飞
		p._toggle_view()                    # 第三人称
		_cam = Camera3D.new()
		_cam.fov = 42
		root.add_child(_cam)
	if _sf >= 4 and _cam != null:
		# 手动定住超人飞行姿态
		p._fly_amount = 1.0
		p._anim_t = 1.2
		p._animate_avatar(0.0, false, false)
		# 侧后方略上，看清前倾身体 + 前伸手 + 后扬披风
		var origin: Vector3 = p.global_position
		var side: Vector3 = p.global_transform.basis.x
		var back: Vector3 = p.global_transform.basis.z
		_cam.global_position = origin + side * 2.6 + back * 1.4 + Vector3(0, 1.0, 0)
		_cam.look_at(origin + Vector3(0, 0.7, 0) - back * 0.5, Vector3.UP)
		_cam.current = true
	if _sf >= 8:
		root.get_texture().get_image().save_png("res://_shot_avatar_fly.png")
		print("SHOT saved: _shot_avatar_fly.png  pitch=", rad_to_deg(p.avatar.rotation.x), " armR=", rad_to_deg(p._arm_r.rotation.x), " cape=", rad_to_deg(p._cape.rotation.x))
		return true
	return false
