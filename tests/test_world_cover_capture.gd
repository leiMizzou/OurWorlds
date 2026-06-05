extends SceneTree
# 验证主场景能把世界封面图片落盘，并写入存档/标题目录：
#   godot --headless --path <项目> --script res://tests/test_world_cover_capture.gd

const WorldCatalog = preload("res://scripts/WorldCatalog.gd")

var _f := 0
var _main = null
var failed := 0
var _dir := "user://tests/world_cover_capture"

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.unset_environment("VC_NO_SAVE")
		OS.unset_environment("VC_SAVE_PATH")
		OS.set_environment("VC_SEED", "60604")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SAVE_DIR", _dir)
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/world_cover_capture/settings.json")
		_clean_dir()
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 24:
		if _main == null or not _main.has_method("_store_world_cover_from_image"):
			check(false, "主场景加载封面写入方法")
			_clean_dir()
			return true
		var img := Image.create(1024, 512, false, Image.FORMAT_RGBA8)
		img.fill(Color(0.18, 0.44, 0.78, 1.0))
		var path: String = _main._store_world_cover_from_image(img)
		check(path == WorldCatalog.cover_path_for_seed(60604), "封面写入当前世界标准路径")
		check(FileAccess.file_exists(path), "封面 PNG 文件已写入")
		check(_main.world.cover_path == path, "主世界记录封面路径")
		var saved := _read_save()
		check(String(saved.get("cover_path", "")) == path, "存档 JSON 写入封面路径")
		var loaded_img := Image.new()
		check(loaded_img.load(path) == OK, "封面 PNG 可重新读取")
		check(loaded_img.get_width() == 512 and loaded_img.get_height() == 288, "封面图保存为统一尺寸")
		var worlds := WorldCatalog.list_worlds()
		check(worlds.size() == 1, "标题目录扫描到封面测试世界")
		check(str(worlds[0].get("cover_path", "")) == path, "标题目录读取封面路径")
		check(bool(worlds[0].get("cover_exists", false)), "标题目录识别封面文件存在")
		_main.set_title_active(true)
		check(_main.title_screen.visible, "标题层可在封面写入后打开")
		check(_main.title_screen._world_cover.current_seed() == 60604, "标题封面绑定当前世界")
		var img2 := Image.create(640, 360, false, Image.FORMAT_RGBA8)
		img2.fill(Color(0.46, 0.34, 0.78, 1.0))
		var path2: String = _main._store_world_cover_from_image(img2)
		check(path2 == path, "标题层打开时封面仍写入标准路径")
		check(_main.title_screen._worlds.size() == 1, "标题层打开时封面写入会刷新世界目录")
		check(_main.title_screen._world_cover.has_real_cover(), "标题层打开时封面写入会刷新真实封面")
		_main.set_title_active(false)
	elif _f >= 80:
		_clean_dir()
		if failed == 0:
			print("✅ ALL WORLD COVER CAPTURE TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个世界封面捕获测试失败")
		return true
	return false

func _read_save() -> Dictionary:
	var path := WorldCatalog.save_path_for_seed(60604)
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed as Dictionary if typeof(parsed) == TYPE_DICTIONARY else {}

func _clean_dir() -> void:
	var abs_dir := ProjectSettings.globalize_path(_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var cover_dir := WorldCatalog.cover_dir()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(cover_dir))
	var covers := DirAccess.open(cover_dir)
	if covers != null:
		covers.list_dir_begin()
		var cover_name := covers.get_next()
		while cover_name != "":
			if not covers.current_is_dir():
				DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [cover_dir, cover_name]))
			cover_name = covers.get_next()
		covers.list_dir_end()
	var d := DirAccess.open(_dir)
	if d == null:
		return
	d.list_dir_begin()
	var file_name := d.get_next()
	while file_name != "":
		if not d.current_is_dir():
			DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [_dir, file_name]))
		file_name = d.get_next()
	d.list_dir_end()
