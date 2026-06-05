extends SceneTree
# 干净的美术对比截图（清空天气、定住中午光照），用于评判 AO/SSAO/材质观感。
#   VC_RADIUS=5 godot --path <项目> --script res://tests/shot_quality.gd
# 产出：_shot_q_vista.png（3/4 俯瞰远景）+ _shot_q_ground.png（贴地近景看方块体积感）。

var _main = null
var _gen_done := false
var _sf := 0
var _phase := 0   # 0=vista, 1=ground
var _peak := Vector3.ZERO
var _green := Vector3.ZERO

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_quality/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen_done:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen_done = true
			# 关天气，定住清爽中午
			if _main.weather_system != null:
				_main.weather_system.set_enabled(false)
			_main._time = 0.34
			# 找最高峰 + 找一处中等高度的“绿地/混合地形”做近景
			var best_h := -999
			var mid_best := 9999
			for z in range(-80, 81, 4):
				for x in range(-80, 81, 4):
					var hh: int = _main.world.surface_y(x, z)
					if hh > best_h:
						best_h = hh
						_peak = Vector3(x, hh, z)
					var score: int = abs(hh - 40) + int(Vector2(x, z).length() * 0.05)
					if hh >= 33 and hh <= 52 and score < mid_best:
						mid_best = score
						_green = Vector3(x, hh, z)
		return false

	_sf += 1
	var p = _main.player
	if _phase == 0:
		if _sf == 2:
			p.fly = true
			p.global_position = _peak + Vector3(-34, 18, -34)
			p.spring.rotation.x = 0.0
			p.look_at(_peak + Vector3(0, 1, 0), Vector3.UP)
			_main._time = 0.34
		if _sf >= 22:
			var img := root.get_texture().get_image()
			img.save_png("res://_shot_q_vista.png")
			print("SHOT vista: _shot_q_vista.png")
			_phase = 1
			_sf = 0
		return false
	else:
		if _sf == 2:
			p.fly = true
			# 贴近绿地，低角度平视：方块边缘的 AO 接触阴影最清楚
			p.global_position = _green + Vector3(7, 4, 7)
			p.spring.rotation.x = 0.0
			p.look_at(_green + Vector3(-2, 0, -2), Vector3.UP)
			_main._time = 0.34
		if _sf >= 22:
			var img := root.get_texture().get_image()
			img.save_png("res://_shot_q_ground.png")
			print("SHOT ground: _shot_q_ground.png")
			return true
		return false
