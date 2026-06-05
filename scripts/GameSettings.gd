extends RefCounted
# 用户设置：保存发布版需要跨启动保留的轻量偏好。

const SETTINGS_VERSION := 1
const DEFAULT_PATH := "user://settings.json"
# 窗口分辨率合法选项（窗口模式下生效；全屏时跟随显示器原生分辨率）。
const RESOLUTIONS := ["1280x720", "1600x900", "1920x1080"]
const DEFAULTS := {
	"view_radius": 4,
	"volume": 0.65,
	"sensitivity": 1.0,
	"recent_blocks": [],
	"weather_enabled": true,
	"graphics_quality": "balanced",
	"fullscreen": false,
	"resolution": "1280x720",
}

static func settings_path() -> String:
	if OS.has_environment("VC_SETTINGS_PATH"):
		return OS.get_environment("VC_SETTINGS_PATH")
	return DEFAULT_PATH

static func load_settings() -> Dictionary:
	var settings := DEFAULTS.duplicate()
	var path := settings_path()
	if path == "" or not FileAccess.file_exists(path):
		return settings
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return settings
	var data: Dictionary = parsed
	for key in DEFAULTS.keys():
		if data.has(key):
			settings[key] = data[key]
	return sanitize(settings)

static func save_settings(settings: Dictionary) -> bool:
	var clean := sanitize(settings)
	var path := settings_path()
	if path == "":
		return false
	var dir := path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var data := clean.duplicate()
	data["version"] = SETTINGS_VERSION
	data["updated_at"] = Time.get_unix_time_from_system()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("设置写入失败：%s" % path)
		return false
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return true

static func sanitize(settings: Dictionary) -> Dictionary:
	var out := DEFAULTS.duplicate()
	out["view_radius"] = clampi(int(settings.get("view_radius", DEFAULTS["view_radius"])), 2, 6)
	out["volume"] = clampf(float(settings.get("volume", DEFAULTS["volume"])), 0.0, 1.0)
	out["sensitivity"] = clampf(float(settings.get("sensitivity", DEFAULTS["sensitivity"])), 0.2, 1.6)
	out["recent_blocks"] = _sanitize_recent(settings.get("recent_blocks", []))
	out["weather_enabled"] = bool(settings.get("weather_enabled", DEFAULTS["weather_enabled"]))
	out["graphics_quality"] = _sanitize_graphics_quality(settings.get("graphics_quality", DEFAULTS["graphics_quality"]))
	out["fullscreen"] = _to_bool(settings.get("fullscreen", DEFAULTS["fullscreen"]))
	out["resolution"] = _sanitize_resolution(settings.get("resolution", DEFAULTS["resolution"]))
	return out

# 宽松布尔解析：兼容手改 settings.json 里写成字符串/数字的情况。
static func _to_bool(value: Variant) -> bool:
	match typeof(value):
		TYPE_BOOL:
			return value
		TYPE_INT, TYPE_FLOAT:
			return float(value) != 0.0
		TYPE_STRING, TYPE_STRING_NAME:
			var s := str(value).strip_edges().to_lower()
			return s == "true" or s == "1" or s == "yes" or s == "on"
		_:
			return false

static func _sanitize_recent(value: Variant) -> Array:
	var out := []
	if typeof(value) != TYPE_ARRAY:
		return out
	for raw in value:
		var id := int(raw)
		if id <= 0 or id > 255 or out.has(id):
			continue
		out.append(id)
		if out.size() >= 8:
			break
	return out

static func _sanitize_graphics_quality(value: Variant) -> String:
	var id := str(value)
	if id == "performance" or id == "balanced" or id == "cinematic":
		return id
	return str(DEFAULTS["graphics_quality"])

static func _sanitize_resolution(value: Variant) -> String:
	var id := str(value)
	if RESOLUTIONS.has(id):
		return id
	return str(DEFAULTS["resolution"])

# 把 "1280x720" 解析成 Vector2i，供后续窗口设置应用使用（非法时回退到默认分辨率）。
static func resolution_size(value: Variant) -> Vector2i:
	var parts := _sanitize_resolution(value).split("x")
	if parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_int():
		return Vector2i(int(parts[0]), int(parts[1]))
	var fallback: PackedStringArray = str(DEFAULTS["resolution"]).split("x")
	return Vector2i(int(fallback[0]), int(fallback[1]))
