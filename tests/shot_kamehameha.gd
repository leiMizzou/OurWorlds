extends SceneTree
# 龟派气功波：侧面运镜 + 圆柱光柱打向地面 + 清块。截的是放招时的电影机位画面。
#   godot --path <项目> --script res://tests/shot_kamehameha.gd → _shot_kamehameha.png

var _main = null
var _gen := false
var _sf := 0
var _from := Vector3.ZERO
var _aim := Vector3.ZERO

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_kame/settings.json")
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
		_main._time = 0.34
		p.fly = true
		p.input_enabled = true
		p.global_position += Vector3(0, 12, 0)
		p.rotation.y = deg_to_rad(40)
		p.pitch = deg_to_rad(-11)
		p.spring.rotation.x = p.pitch
	if _sf == 4:
		_aim = p._aim_dir()
		_from = p.spring.global_position + _aim * 1.2
		p._fire_kamehameha(7.5)      # 高蓄力大威力
	if _sf == 9:
		var cleared := 0
		var total := 0
		for tt in range(6, 44, 3):
			var c: Vector3 = _from + _aim * float(tt)
			total += 1
			if _main.world.get_block(int(floor(c.x)), int(floor(c.y)), int(floor(c.z))) == 0:
				cleared += 1
		root.get_texture().get_image().save_png("res://_shot_kamehameha.png")
		print("SHOT saved  中线清空 ", cleared, "/", total, "  cine_current=", p._cine_cam.current)
		return true
	return false
