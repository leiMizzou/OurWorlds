extends SceneTree
# 验证动态天气系统：状态切换、雨线/雪粒实例和关闭开关。
#   godot --headless --path <项目> --script res://tests/test_weather.gd

const WeatherSystem = preload("res://scripts/WeatherSystem.gd")

var failed := 0
var _feedback := []

func _process(_delta: float) -> bool:
	return true

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _on_weather_changed(kind: String, label: String) -> void:
	_feedback.append({"kind": kind, "label": label})

func _initialize() -> void:
	var target := Node3D.new()
	target.name = "WeatherTarget"
	target.position = Vector3(10, 40, -8)
	root.add_child(target)

	var weather := WeatherSystem.new()
	root.add_child(weather)
	weather.weather_changed.connect(_on_weather_changed)
	weather.setup(target, 12345, true)

	weather.force_weather("rain")
	check(weather.weather_label() == "阵雨", "强制阵雨后标签正确")
	check(weather.intensity > 0.7, "强制阵雨立即产生雨量")
	check(weather._rain != null and weather._rain.visible, "阵雨时雨线可见")
	check(weather._rain.multimesh.visible_instance_count > 0, "阵雨时有可见雨线实例")
	check(weather._snow != null and not weather._snow.visible, "阵雨时雪粒隐藏")
	check(_last_feedback_label() == "阵雨", "阵雨状态发出 HUD 反馈")

	weather.set_region_label("雪峰")
	check(weather.weather_label() == "山雪", "雪峰中阵雨转换为山雪标签")
	check(not weather._rain.visible, "雪峰中阵雨不显示雨线")
	check(weather._snow.visible and weather._snow.multimesh.visible_instance_count > 0, "雪峰中阵雨改为雪粒显示")
	check(_last_feedback_label() == "山雪", "进入雪峰后天气标签发出更新反馈")
	weather.set_region_label("草原")
	check(weather.weather_label() == "阵雨", "离开雪峰后恢复阵雨标签")
	check(weather._rain.visible and not weather._snow.visible, "离开雪峰后恢复雨线显示")

	weather.force_weather("snow")
	check(weather.weather_label() == "飘雪", "强制飘雪后标签正确")
	check(weather.intensity > 0.5, "强制飘雪立即产生雪量")
	check(weather._snow != null and weather._snow.visible, "飘雪时雪粒可见")
	check(weather._snow.multimesh.visible_instance_count > 0, "飘雪时有可见雪粒实例")
	check(not weather._rain.visible, "飘雪时雨线隐藏")
	check(_last_feedback_label() == "飘雪", "飘雪状态发出 HUD 反馈")

	weather.force_weather("clear")
	check(weather.weather_label() == "晴朗", "强制晴朗后标签正确")
	check(weather.intensity == 0.0, "强制晴朗后雨量归零")
	check(not weather._rain.visible, "晴朗时雨线隐藏")
	check(not weather._snow.visible, "晴朗时雪粒隐藏")

	weather.set_enabled(false)
	check(not weather.enabled, "天气系统可关闭")
	check(weather.weather_label() == "天气关闭", "关闭后状态标签正确")
	check(weather.intensity == 0.0, "关闭后雨量归零")
	check(not weather._rain.visible, "关闭后雨线隐藏")
	check(not weather._snow.visible, "关闭后雪粒隐藏")

	weather.free()
	target.free()

	if failed == 0:
		print("✅ ALL WEATHER TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个天气测试失败")
	quit(failed)

func _last_feedback_label() -> String:
	if _feedback.is_empty():
		return ""
	var last: Dictionary = _feedback[_feedback.size() - 1]
	return str(last.get("label", ""))
