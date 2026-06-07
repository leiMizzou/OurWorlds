extends SceneTree
# 验证程序化音效反馈映射和主场景信号接线：
#   godot --headless --path <项目> --script res://tests/test_audio_feedback.gd

const AudioFeedback = preload("res://scripts/AudioFeedback.gd")
const WeatherSystem = preload("res://scripts/WeatherSystem.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const GameSettings = preload("res://scripts/GameSettings.gd")

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
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/audio_feedback/settings.json")
		# 预置 language=zh，使断言里的中文文案不受运行机 OS 语言影响（确定性回归）。
		_seed_language("zh")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		_run_unit_checks()
		_run_main_checks()
		if failed == 0:
			print("✅ ALL AUDIO FEEDBACK TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个音效反馈测试失败")
		return true
	return false

func _run_unit_checks() -> void:
	var audio := AudioFeedback.new()
	root.add_child(audio)
	audio.play_feedback("journey", "旅程完成：探索附近地形")
	check(audio.last_feedback_kind() == "journey", "旅程反馈会被音频层记录")
	check(audio.last_pattern().size() == 3, "旅程反馈使用三段上行音色")

	audio.play_block_feedback("place", BlockLibrary.LOG)
	var wood_place := audio.last_pattern()
	audio.play_block_feedback("place", BlockLibrary.GLASS)
	var glass_place := audio.last_pattern()
	check(_first_freq(glass_place) > _first_freq(wood_place), "玻璃放置音色比木头更明亮")
	audio.play_block_feedback("break", BlockLibrary.STONE)
	var stone_break := audio.last_pattern()
	audio.play_block_feedback("break", BlockLibrary.WILDFLOWER)
	var soft_break := audio.last_pattern()
	check(_first_freq(soft_break) > _first_freq(stone_break), "植物挖掘音色比石头更轻")

	audio._on_world_feedback("place", Vector3i(1, 40, 1), BlockLibrary.STONE)
	check(audio.last_feedback_label() == "block:%d" % BlockLibrary.STONE, "世界放置反馈记录首个材料")
	audio._on_world_feedback("place", Vector3i(2, 40, 1), BlockLibrary.GLASS)
	check(audio.last_feedback_label() == "block:%d" % BlockLibrary.STONE, "同帧批量放置只播放首个材料音")
	audio._on_world_feedback("campfire", Vector3i(3, 40, 1), BlockLibrary.LANTERN)
	check(audio.last_feedback_kind() == "campfire", "营火世界反馈有专属音色")
	audio._on_world_feedback("place", Vector3i(3, 40, 1), BlockLibrary.LANTERN)
	check(audio.last_feedback_kind() == "campfire", "营火同帧抑制普通放置音")
	audio._on_world_feedback("bulk_place", Vector3i(5, 40, 1), BlockLibrary.PLANKS)
	var bulk_pattern := audio.last_pattern()
	check(audio.last_feedback_kind() == "bulk_place" and audio.last_feedback_label().contains("木作"), "大模板世界反馈有结构放置音色")
	check(bulk_pattern.size() == 3 and _first_freq(bulk_pattern) < _first_freq(wood_place), "大模板放置音比单块木头更厚重")
	audio._on_world_feedback("place", Vector3i(5, 40, 1), BlockLibrary.PLANKS)
	check(audio.last_feedback_kind() == "bulk_place", "大模板同帧抑制普通逐格放置音")

	audio.play_feedback("weather", "阵雨")
	var rain_pattern := audio.last_pattern()
	check(audio.last_feedback_label() == "阵雨" and rain_pattern.size() == 2, "阵雨天气有专属音色")
	audio.play_feedback("weather", "飘雪")
	var snow_pattern := audio.last_pattern()
	check(audio.last_feedback_label() == "飘雪" and snow_pattern.size() == 2, "飘雪天气有专属音色")
	check(_first_freq(snow_pattern) > _first_freq(rain_pattern), "飘雪音色比阵雨更明亮")
	audio.play_feedback("weather", "山雪")
	check(audio.last_feedback_label() == "山雪" and _first_freq(audio.last_pattern()) == _first_freq(snow_pattern), "山雪沿用雪天气音色")

	var target := Node3D.new()
	root.add_child(target)
	var weather := WeatherSystem.new()
	root.add_child(weather)
	weather.setup(target, 24680, true)
	audio.bind_weather(weather)
	weather.force_weather("snow")
	check(audio.last_feedback_kind() == "weather" and audio.last_feedback_label() == "飘雪", "天气信号可直接绑定到音频层")
	weather.free()
	target.free()
	audio.free()

func _run_main_checks() -> void:
	_main.weather_system.force_weather("snow")
	check(_main.audio_feedback.last_feedback_kind() == "weather", "主场景天气变化接入音频反馈")
	check(_main.audio_feedback.last_feedback_label() == "飘雪", "主场景音频记录飘雪标签")

	_main._complete_journey_step("explore")
	check(_main.audio_feedback.last_feedback_kind() == "journey", "主场景旅程完成接入音频反馈")
	check(_main.audio_feedback.last_feedback_label().contains("探索附近地形"), "旅程音频记录完成目标名称")

	_main.player.world_feedback.emit("place", Vector3i(4, 40, 4), BlockLibrary.GLASS)
	check(_main.audio_feedback.last_feedback_kind() == "place", "主场景世界放置反馈接入音频层")
	check(_main.audio_feedback.last_feedback_label() == "block:%d" % BlockLibrary.GLASS, "主场景音频记录放置材料")
	check(_first_freq(_main.audio_feedback.last_pattern()) >= 700.0, "主场景玻璃放置使用明亮音色")
	_main.player.world_feedback.emit("bulk_place", Vector3i(6, 40, 4), BlockLibrary.PLANKS)
	check(_main.audio_feedback.last_feedback_kind() == "bulk_place", "主场景大模板放置接入结构音色")
	_main.player.world_feedback.emit("place", Vector3i(6, 40, 4), BlockLibrary.PLANKS)
	check(_main.audio_feedback.last_feedback_kind() == "bulk_place", "主场景大模板结构音色压过同帧普通放置音")

func _first_freq(pattern: Array) -> float:
	if pattern.is_empty():
		return 0.0
	var first: Array = pattern[0]
	return float(first[0]) if first.size() > 0 else 0.0

# 写入仅含 language 的设置文件；Main 启动会据此把界面语言定为该语言。
func _seed_language(lang: String) -> void:
	var settings := GameSettings.load_settings()
	settings["language"] = lang
	GameSettings.save_settings(settings)
