extends SceneTree
# 无 HUD 的“美术成片”：用于确认太阳光晕、水面着色器、整体调性。
#   VC_RADIUS=6 godot --path <项目> --script res://tests/shot_beauty.gd
# 产出：_shot_beauty_hero.png（含太阳的英雄全景）+ _shot_beauty_water.png（水岸近景）。

var _main = null
var _gen_done := false
var _sf := 0
var _phase := 0
var _peak := Vector3.ZERO
var _water := Vector3.ZERO
var _have_water := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_beauty/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _hide_ui() -> void:
	if _main.hud != null:
		_main.hud.visible = false
	if _main.player != null and _main.player.has_method("set_overlays_visible"):
		_main.player.set_overlays_visible(false)

func _process(_delta: float) -> bool:
	if not _gen_done:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen_done = true
			if _main.weather_system != null:
				_main.weather_system.set_enabled(false)
			_main._time = 0.28   # 清晨低斜阳，长影 + 暖色
			_hide_ui()
			var best_h := -999
			for z in range(-90, 91, 5):
				for x in range(-90, 91, 5):
					var hh: int = _main.world.surface_y(x, z)
					if hh > best_h:
						best_h = hh
						_peak = Vector3(x, hh, z)
			# 找一处水面：扫描地表，水位以下取顶层水格
			for z in range(-70, 71, 3):
				for x in range(-70, 71, 3):
					var top := _water_top(x, z)
					if top.y > -999:
						_water = top
						_have_water = true
						break
				if _have_water:
					break
		return false

	_sf += 1
	_hide_ui()
	var p = _main.player
	if _phase == 0:
		if _sf == 2:
			p.fly = true
			# 站在山侧，朝东方低空（太阳方向）望出去，画面上半留天与太阳
			p.global_position = _peak + Vector3(40, 6, 16)
			p.spring.rotation.x = 0.0
			p.look_at(_peak + Vector3(-6, 10, -2), Vector3.UP)
		if _sf >= 26:
			root.get_texture().get_image().save_png("res://_shot_beauty_hero.png")
			print("SHOT hero: _shot_beauty_hero.png")
			_phase = 1
			_sf = 0
		return false
	else:
		if _sf == 2:
			p.fly = true
			var target = _water if _have_water else _peak
			p.global_position = target + Vector3(6, 3, 6)
			p.spring.rotation.x = 0.0
			p.look_at(target + Vector3(-3, -1, -3), Vector3.UP)
		if _sf >= 22:
			root.get_texture().get_image().save_png("res://_shot_beauty_water.png")
			print("SHOT water: _shot_beauty_water.png have_water=", _have_water)
			return true
		return false

# 返回 (x, 顶层水面y, z)，没有水返回 y=-999
func _water_top(x: int, z: int) -> Vector3:
	if _main == null or _main.world == null:
		return Vector3(0, -999, 0)
	var sy: int = _main.world.surface_y(x, z)
	# 在地表上下小范围找 WATER(=9) 顶面
	for y in range(sy + 2, sy - 4, -1):
		if _main.world.get_block(x, y, z) == 9 and _main.world.get_block(x, y + 1, z) == 0:
			return Vector3(x, y, z)
	return Vector3(0, -999, 0)
