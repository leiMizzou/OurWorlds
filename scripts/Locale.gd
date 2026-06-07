extends Node
# Locale —— 运行时 i18n 字符串表（中文 / English）。
# 自动加载单例 `Locale`（见 project.godot [autoload]）。
#
# 设计取舍：不用 Godot 编辑器导入的 CSV/.po（项目以 headless + --export 构建运行，
# 编辑器导入的翻译资源不可靠）。改为运行时读取 res://i18n/ui_strings.json，
# res:// 在编辑器、headless、以及导出的 .pck 内都可读。
#
# 用法：
#   Locale.t("PAUSE_RESUME")           -> 当前语言的文案（缺失时回退，详见 t()）
#   Locale.set_language("en")          -> 切换并落盘，发出 language_changed
#   Locale.current() / Locale.available()
#   Locale.init(saved)                 -> 启动时按落盘值/OS 语言确定初始语言（不发信号）
#
# 测试可直接 `Locale.gd.new()` 后调用 load_strings() / t / set_language / init，
# 无需依赖单例就绪时序。

const GameSettings = preload("res://scripts/GameSettings.gd")

const STRINGS_PATH := "res://i18n/ui_strings.json"
const SUPPORTED := ["zh", "en"]
const DEFAULT_LANG := "zh"

signal language_changed

var _strings := {}          # { KEY: { "zh": "...", "en": "..." } }
var _lang := DEFAULT_LANG
var _loaded := false

func _ready() -> void:
	# autoload 路径：装表 + 按落盘语言（或 OS 语言）确定初始语言。
	# Main 也会在设置加载后调用 init()，二次调用是幂等的。
	load_strings()
	init(str(GameSettings.load_settings().get("language", "")))

# 从 res://i18n/ui_strings.json 装载字符串表。
# 健壮性：文件缺失或 JSON 非法时，记录到 stderr，保持 _strings = {}，
# 这样 t() 退化为返回 key（界面显示 key 而不是崩溃）。
func load_strings() -> void:
	_loaded = true
	_strings = {}
	var f := FileAccess.open(STRINGS_PATH, FileAccess.READ)
	if f == null:
		printerr("[Locale] 无法打开 %s：%s" % [STRINGS_PATH, error_string(FileAccess.get_open_error())])
		return
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		printerr("[Locale] %s 不是合法的 JSON 对象，i18n 文案不可用" % STRINGS_PATH)
		return
	var data: Dictionary = parsed
	for key in data.keys():
		var entry: Variant = data[key]
		# 仅收录形如 { "zh": ..., "en": ... } 的条目（跳过 _comment 等说明字段）。
		if typeof(entry) == TYPE_DICTIONARY:
			_strings[str(key)] = entry

# 返回当前语言的文案。
# 回退链：当前语言 -> 另一语言（若有）-> key 本身（缺失可见，不崩溃）。
func t(key: String) -> String:
	if not _loaded:
		load_strings()
	if _strings.has(key):
		var entry: Dictionary = _strings[key]
		if entry.has(_lang):
			return str(entry[_lang])
		# 缺当前语言：退到另一语言（任意已有项），保证不返回空。
		for lang in SUPPORTED:
			if entry.has(lang):
				return str(entry[lang])
		for any_key in entry.keys():
			return str(entry[any_key])
	return key

# 切换语言：夹紧到 zh|en；变更时落盘 + 发出 language_changed。
func set_language(lang: String) -> void:
	if not SUPPORTED.has(lang):
		return
	if lang == _lang:
		return
	_lang = lang
	_persist(lang)
	emit_signal("language_changed")

func current() -> String:
	return _lang

func available() -> Array:
	return SUPPORTED.duplicate()

# 启动初始化：saved 是 zh/en 则用之；否则按 OS 语言（zh* -> zh，其余 -> en）。
# 不发 language_changed（UI 尚未构建/订阅，初始值无需广播）。
func init(saved: String = "") -> void:
	if not _loaded:
		load_strings()
	if SUPPORTED.has(saved):
		_lang = saved
		return
	_lang = "zh" if OS.get_locale().begins_with("zh") else "en"

# 把 language 写回 Main 所用的同一设置存档（GameSettings 是数据真相源）。
# 与 PauseMenu._persist_display() 写 fullscreen/resolution 的方式一致，
# Locale 因此与 Main 实例解耦，在测试与运行时都能落盘。
func _persist(lang: String) -> void:
	var settings := GameSettings.load_settings()
	settings["language"] = lang
	GameSettings.save_settings(settings)
