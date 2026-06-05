extends SceneTree
# 截一张标题页删除确认态：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_title_delete_confirm.gd

const WorldCatalog = preload("res://scripts/WorldCatalog.gd")

var _main = null
var _f := 0
var _shot_done := false
var _dir := "user://tests/title_delete_confirm_shot"

func _initialize() -> void:
	OS.unset_environment("VC_NO_SAVE")
	OS.unset_environment("VC_SAVE_PATH")
	OS.unset_environment("VC_SEED")
	OS.unset_environment("VC_SKIP_TITLE")
	OS.set_environment("VC_SAVE_DIR", _dir)
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_title_delete/settings.json")
	_clean_dir()
	var now := int(Time.get_unix_time_from_system())
	_write_world(4201, now - 300, 12)
	_write_world(4202, now - 1900, 5)
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 18:
		_main.title_screen._on_delete_pressed()
	elif not _shot_done and _f >= 28:
		if DisplayServer.get_name().to_lower().contains("headless"):
			print("SHOT skipped: viewport texture unavailable in headless")
			_clean_dir()
			_main.set_title_active(false)
			_shot_done = true
			return true
		var texture := root.get_texture()
		if texture == null:
			print("SHOT skipped: viewport texture unavailable")
			_clean_dir()
			_main.set_title_active(false)
			_shot_done = true
			return true
		var img := texture.get_image()
		if img == null or img.is_empty():
			print("SHOT skipped: viewport image unavailable")
			_clean_dir()
			_main.set_title_active(false)
			_shot_done = true
			return true
		img.save_png("res://_shot_title_delete_confirm.png")
		print("SHOT saved: _shot_title_delete_confirm.png")
		_main.set_title_active(false)
		_shot_done = true
	elif _shot_done and _f >= 80:
		_clean_dir()
		return true
	return false

func _write_world(seed: int, updated_at: int, edits: int) -> void:
	var path := WorldCatalog.save_path_for_seed(seed)
	var abs_dir := ProjectSettings.globalize_path(path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var edit_data := {}
	for i in range(edits):
		edit_data[str(i)] = 1
	var data := {"version": 1, "seed": seed, "updated_at": updated_at, "edit_count": edits, "edits": {"0,0": edit_data}}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()

func _clean_dir() -> void:
	var abs_dir := ProjectSettings.globalize_path(_dir)
	DirAccess.make_dir_recursive_absolute(abs_dir)
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
