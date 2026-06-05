extends SceneTree
# 验证发布向设置会落盘，并在下一次启动时恢复：
#   godot --headless --path <项目> --script res://tests/test_settings.gd

const GameSettings = preload("res://scripts/GameSettings.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _f := 0
var _main = null
var failed := 0
var _path := "user://tests/settings/settings.json"

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", _path)
	_clean_settings()

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		var defaults := GameSettings.load_settings()
		check(int(defaults.get("view_radius", 0)) == 4, "默认视距为 4")
		check(abs(float(defaults.get("volume", 0.0)) - 0.65) < 0.001, "默认音量为 65%")
		check(Array(defaults.get("recent_blocks", [])).is_empty(), "默认最近材料为空")
		check(bool(defaults.get("weather_enabled", false)), "默认启用动态天气")
		check(str(defaults.get("graphics_quality", "")) == "balanced", "默认画质为均衡")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 32:
		_main._on_view_radius_changed(2)
		_main._on_volume_changed(0.25)
		_main._on_sensitivity_changed(1.4)
		_main._on_weather_enabled_changed(false)
		_main._on_graphics_quality_changed("cinematic")
		_main.set_palette_active(true)
		_main.block_palette._select_block(BlockLibrary.COPPER_ORE)
		var saved := GameSettings.load_settings()
		check(int(saved.get("view_radius", 0)) == 2, "设置变更后保存视距")
		check(abs(float(saved.get("volume", 0.0)) - 0.25) < 0.001, "设置变更后保存音量")
		check(abs(float(saved.get("sensitivity", 0.0)) - 1.4) < 0.001, "设置变更后保存灵敏度")
		check(not bool(saved.get("weather_enabled", true)), "设置变更后保存动态天气开关")
		check(str(saved.get("graphics_quality", "")) == "cinematic", "设置变更后保存画质档位")
		var recent: Array = saved.get("recent_blocks", [])
		check(not recent.is_empty() and int(recent[0]) == BlockLibrary.COPPER_ORE, "设置变更后保存最近材料")
		_main.queue_free()
	elif _f == 50:
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 82:
		check(_main.world.view_radius == 2, "重启后恢复视距")
		check(abs(_main.audio_feedback.volume - 0.25) < 0.001, "重启后恢复音量")
		check(abs(_main.player.mouse_sensitivity - _main.player.DEFAULT_SENS * 1.4) < 0.00001, "重启后恢复灵敏度")
		check(not _main.weather_system.enabled, "重启后恢复动态天气开关")
		check(_main._graphics_quality == "cinematic", "重启后恢复画质档位")
		check(_main._sun.shadow_enabled and _main._sun.directional_shadow_max_distance >= 179.0, "精美画质启用更远阴影")
		check(_main._env.glow_enabled and _main._env.glow_intensity >= 0.15, "精美画质启用更强辉光")
		check(_main._stars.multimesh.visible_instance_count == _main.STAR_COUNT, "精美画质保留完整星空")
		check(not _main.block_palette.recent_blocks().is_empty() and int(_main.block_palette.recent_blocks()[0]) == BlockLibrary.COPPER_ORE, "重启后恢复最近材料")
		_clean_settings()
		if failed == 0:
			print("✅ ALL SETTINGS TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个设置测试失败")
		return true
	return false

func _clean_settings() -> void:
	var abs_dir := ProjectSettings.globalize_path(_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(abs_dir)
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))
