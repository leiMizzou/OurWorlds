extends SceneTree
# 验证 i18n Locale 框架（运行时 JSON 字符串表 + 中英切换 + 持久化回退）：
#   godot --headless --path <项目> --script res://tests/test_locale.gd
# 直接实例化 Locale 脚本来测试 t/set_language/init/current/available，
# 避免依赖 autoload 单例在 --script SceneTree 下的就绪时序。

const Locale = preload("res://scripts/Locale.gd")
const GameSettings = preload("res://scripts/GameSettings.gd")

var failed := 0
var _path := "user://tests/locale/settings.json"

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	# 用独立设置文件，避免污染真实存档；同时验证 set_language 落盘。
	OS.set_environment("VC_SETTINGS_PATH", _path)
	_clean_settings()

	var loc = Locale.new()
	loc.load_strings()  # 从 res://i18n/ui_strings.json 装载

	# ---- t() 双语查表 ----
	loc.set_language("en")
	check(loc.current() == "en", "set_language(\"en\") 切到英文")
	var resume_en := loc.t("PAUSE_RESUME")
	check(resume_en == "Resume", "英文 PAUSE_RESUME = Resume（实得：%s）" % resume_en)

	loc.set_language("zh")
	check(loc.current() == "zh", "set_language(\"zh\") 切到中文")
	var resume_zh := loc.t("PAUSE_RESUME")
	check(resume_zh == "继续", "中文 PAUSE_RESUME = 继续（实得：%s）" % resume_zh)

	check(resume_en != resume_zh, "中英文案不同")

	# ---- 缺失 key 回退到 key 本身（可见而非崩溃）----
	check(loc.t("THIS_KEY_DOES_NOT_EXIST") == "THIS_KEY_DOES_NOT_EXIST", "缺失 key 返回 key 本身")

	# ---- 非法语言被夹紧（保持原值）----
	loc.set_language("zh")
	loc.set_language("fr")
	check(loc.current() == "zh", "非法语言 fr 被忽略，仍为 zh")

	# ---- 设置项确实存在双语条目（抽查几个关键 key）----
	for key in ["PAUSE_TITLE", "PAUSE_SAVE_WORLD", "SETTINGS_VIEW_DISTANCE", "SETTINGS_VOLUME", "SETTINGS_LANGUAGE", "LANG_ZH", "LANG_EN"]:
		loc.set_language("zh")
		var zh := loc.t(key)
		loc.set_language("en")
		var en := loc.t(key)
		check(zh != "" and zh != key, "%s 有中文文案（%s）" % [key, zh])
		check(en != "" and en != key, "%s 有英文文案（%s）" % [key, en])

	# ---- init()：显式 zh/en 生效，"" 回退到合法语言 ----
	var loc2 = Locale.new()
	loc2.load_strings()
	loc2.init("en")
	check(loc2.current() == "en", "init(\"en\") 设为英文")
	loc2.init("zh")
	check(loc2.current() == "zh", "init(\"zh\") 设为中文")
	loc2.init("")
	check(loc2.current() in loc2.available(), "init(\"\") 回退到合法语言（%s）" % loc2.current())
	check(loc2.available() == ["zh", "en"], "available() 返回 [zh, en]")

	# ---- 非法 saved 也回退（不应崩溃，不应保留非法值）----
	loc2.init("garbage")
	check(loc2.current() in loc2.available(), "init(非法) 回退到合法语言")

	# ---- set_language 持久化到 GameSettings 存档 ----
	loc.set_language("en")
	var saved := GameSettings.load_settings()
	check(str(saved.get("language", "")) == "en", "set_language 把 language 写入设置存档（实得：%s）" % str(saved.get("language", "")))

	# ---- 持久化值可被 init 读回 ----
	var loc3 = Locale.new()
	loc3.load_strings()
	loc3.init(str(GameSettings.load_settings().get("language", "")))
	check(loc3.current() == "en", "init 读回落盘的 language=en")

	_clean_settings()
	if failed == 0:
		print("✅ ALL LOCALE TESTS PASSED")
		quit(0)
	else:
		printerr("❌ ", failed, " 个 Locale 测试失败")
		quit(1)

func _clean_settings() -> void:
	var abs_dir := ProjectSettings.globalize_path(_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(abs_dir)
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_path))
