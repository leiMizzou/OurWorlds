extends SceneTree
# 隐藏技能验证：飞行中放龟派气功波，气化前方一大条方块 + 蓝色光波。
#   godot --path <项目> --script res://tests/shot_kamehameha.gd → _shot_kamehameha.png

var _main = null
var _gen := false
var _sf := 0
var _cam: Camera3D = null
var _from := Vector3.ZERO
var _aim := Vector3.ZERO

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_kame/settings.json")
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
		_main._time = 0.34
		p.fly = true
		p.input_enabled = true
		p.global_position += Vector3(0, 6, 0)
		p.rotation.y = 0.0
		p.pitch = deg_to_rad(-17)         # 朝前下方瞄准地形
		p.spring.rotation.x = p.pitch
		_cam = Camera3D.new()
		_cam.fov = 62
		root.add_child(_cam)
	if _sf == 4:
		_aim = p._aim_dir()
		_from = p.spring.global_position + _aim * 1.2
		p._fire_kamehameha()
	if _sf >= 4 and _cam != null:
		var mid := _from + _aim * (64.0 * 0.42)
		var side := _aim.cross(Vector3.UP).normalized()
		_cam.global_position = mid + side * 40.0 + Vector3(0, 14.0, 0)
		_cam.look_at(mid, Vector3.UP)
		_cam.current = true
	if _sf == 16:
		# 程序化确认：沿气功波中线采样，应已变成空气(0)
		var cleared := 0
		var total := 0
		for tt in range(6, 56, 3):
			var c: Vector3 = _from + _aim * float(tt)
			total += 1
			if _main.world.get_block(int(floor(c.x)), int(floor(c.y)), int(floor(c.z))) == 0:
				cleared += 1
		root.get_texture().get_image().save_png("res://_shot_kamehameha.png")
		print("SHOT saved: _shot_kamehameha.png  中线清空 ", cleared, "/", total)
		return true
	return false
