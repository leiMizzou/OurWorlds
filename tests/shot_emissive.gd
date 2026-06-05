extends SceneTree
# 夜间发光验证：放置灯笼/月石灯/蓝晶，确认 emissive 材质 + 泛光让它们真的“会亮”。
#   godot --path <项目> --script res://tests/shot_emissive.gd  → _shot_emissive.png

var _main = null
var _gen_done := false
var _sf := 0
var _base := Vector3.ZERO

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_emissive/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen_done:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen_done = true
			if _main.weather_system != null:
				_main.weather_system.set_enabled(false)
			_main._time = 0.98   # 午夜，太阳近熄灭，凸显自发光
			if _main.hud != null:
				_main.hud.visible = false
			if _main.player != null and _main.player.has_method("set_overlays_visible"):
				_main.player.set_overlays_visible(false)
			var p = _main.player.global_position
			var bx := int(floor(p.x))
			var bz := int(floor(p.z)) - 6
			var gy: int = _main.world.surface_y(bx, bz)
			_base = Vector3(bx, gy, bz)
			# 一道石墙做背景，让灯光打在上面；嵌入三种发光块
			for dx in range(-3, 4):
				for dy in range(1, 4):
					_main.world.set_block(bx + dx, gy + dy, bz - 1, 3)  # STONE 背景墙
			_main.world.set_block(bx - 2, gy + 2, bz, 18)   # LANTERN 灯笼
			_main.world.set_block(bx, gy + 2, bz, 27)       # MOONSTONE_LAMP 月石灯
			_main.world.set_block(bx + 2, gy + 2, bz, 25)   # BLUE_CRYSTAL 蓝晶
			# 地面铺点石头放灯光
			for dx in range(-3, 4):
				_main.world.set_block(bx + dx, gy + 1, bz, 3)
		return false

	_sf += 1
	if _main.hud != null:
		_main.hud.visible = false
	if _sf == 4:
		var p = _main.player
		p.fly = true
		p.global_position = _base + Vector3(0, 3, 7)
		p.spring.rotation.x = 0.0
		p.look_at(_base + Vector3(0, 2, 0), Vector3.UP)
		_main._time = 0.98
	if _sf >= 30:
		root.get_texture().get_image().save_png("res://_shot_emissive.png")
		print("SHOT emissive: _shot_emissive.png")
		return true
	return false
