extends SceneTree
# 验证昼夜天空主体：太阳、月亮、星空会随时间与天气切换。
#   godot --headless --path <项目> --script res://tests/test_celestial_sky.gd

var _f := 0
var _main = null
var failed := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.set_environment("VC_NO_SAVE", "1")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/celestial_sky/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		check(_main._sky_root != null, "天空视觉层已创建")
		check(_main._sun_disc != null and _main._moon_disc != null, "太阳和月亮节点已创建")
		check(_main._stars != null and _main._stars.multimesh.instance_count >= 100, "星空批量实例已创建")

		_main.weather_system.force_weather("clear")
		_main._time = 0.5
		_main._process(0.0)
		check(_main._sun_disc.visible, "正午太阳可见")
		check(_main._sun_disc_mat.albedo_color.a > 0.8, "正午太阳不透明度足够")
		check(not _main._stars.visible, "正午星空隐藏")
		check(_main._sun_disc.global_position.y > _main.player.global_position.y + 120.0, "正午太阳位于高空")
		var day_cloud_light: float = _luma(_main._cloud_mat.albedo_color)

		_main.player.global_position += Vector3(14, 3, -9)
		_main._process(0.0)
		check(_main._sky_root.global_position.distance_to(_main.player.global_position) < 0.01, "天空视觉层跟随玩家")

		_main._time = 0.0
		_main._process(0.0)
		var clear_star_alpha: float = _main._star_mat.albedo_color.a
		var night_cloud_light: float = _luma(_main._cloud_mat.albedo_color)
		check(_main._moon_disc.visible and _main._moon_disc_mat.albedo_color.a > 0.55, "午夜月亮可见")
		check(_main._stars.visible and clear_star_alpha > 0.55, "午夜星空可见")
		check(not _main._sun_disc.visible, "午夜太阳隐藏")
		check(night_cloud_light < day_cloud_light * 0.55, "夜间云层明显变暗")

		_main.weather_system.force_weather("rain")
		_main._process(0.0)
		check(_main._star_mat.albedo_color.a < clear_star_alpha, "阵雨会压低星空可见度")

		if failed == 0:
			print("✅ ALL CELESTIAL SKY TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个天空视觉测试失败")
		return true
	return false

func _luma(color: Color) -> float:
	return color.r * 0.2126 + color.g * 0.7152 + color.b * 0.0722
