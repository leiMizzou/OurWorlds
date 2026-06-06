extends SceneTree
# 蓄力能量球可视化：飞行中聚一个发光蓝球在手前。
#   godot --path <项目> --script res://tests/shot_kame_charge.gd → _shot_kame_charge.png
var _main = null
var _gen := false
var _sf := 0
var _cam: Camera3D = null

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/kamecharge/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_d: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen = true
		return false
	_sf += 1
	var p = _main.player
	if _sf == 2:
		if _main.weather_system != null: _main.weather_system.set_enabled(false)
		if _main.hud != null: _main.hud.visible = false
		_main._time = 0.86   # 偏夜，能量球发光更明显
		p.set_physics_process(false)
		p.fly = true
		p.rotation.y = deg_to_rad(35)
		p.global_position += Vector3(0, 4, 0)
		p._toggle_view()
		_cam = Camera3D.new(); _cam.fov = 42; root.add_child(_cam)
	if _sf >= 4 and _cam != null:
		p._kame_charge = 5.6           # 蓄满
		p._charging = true             # 触发抱球手臂姿
		p._anim_t = 1.0
		p._fly_amount = 1.0
		p._animate_avatar(0.0, false, false)
		p._update_charge_ball()
		var origin: Vector3 = p.global_position
		var side: Vector3 = p.global_transform.basis.x
		var fwd: Vector3 = -p.global_transform.basis.z
		_cam.global_position = origin + side * 2.4 + fwd * 1.2 + Vector3(0, 1.2, 0)
		_cam.look_at(origin + fwd * 1.4 + Vector3(0, 1.0, 0), Vector3.UP)
		_cam.current = true
	if _sf >= 8:
		root.get_texture().get_image().save_png("res://_shot_kame_charge.png")
		print("SHOT saved: _shot_kame_charge.png  ball_visible=", p._charge_ball.visible)
		return true
	return false
