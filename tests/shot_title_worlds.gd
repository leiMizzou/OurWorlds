extends SceneTree
# 截一张带多个本地世界条目的标题页：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_title_worlds.gd

const WorldCatalog = preload("res://scripts/WorldCatalog.gd")

var _main = null
var _f := 0
var _shot_done := false
var _dir := "user://tests/title_worlds_shot"

func _initialize() -> void:
	OS.unset_environment("VC_NO_SAVE")
	OS.unset_environment("VC_SAVE_PATH")
	OS.unset_environment("VC_SEED")
	OS.unset_environment("VC_SKIP_TITLE")
	OS.set_environment("VC_SAVE_DIR", _dir)
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_title_worlds/settings.json")
	_clean_dir()
	var now := int(Time.get_unix_time_from_system())
	_write_world(1001, now - 9000, 3, 1, 2, 0, 35, 2)
	_write_world(2002, now - 360, 8, 5, 4, 2, 82, 6)
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_f += 1
	if not _shot_done and _f >= 24:
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
		img.save_png("res://_shot_title_worlds.png")
		print("SHOT saved: _shot_title_worlds.png")
		_main.set_title_active(false)
		_shot_done = true
	elif _shot_done and _f >= 80:
		_clean_dir()
		return true
	return false

func _write_world(seed: int, updated_at: int, edits: int, discoveries: int, journey: int, restored: int, best_restore: int, regions: int) -> void:
	var path := WorldCatalog.save_path_for_seed(seed)
	var abs_dir := ProjectSettings.globalize_path(path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(abs_dir)
	var edit_data := {}
	for i in range(edits):
		edit_data[str(i)] = 1
	var data := {
		"version": 1,
		"seed": seed,
		"updated_at": updated_at,
		"edit_count": edits,
		"discovery_count": discoveries,
		"restored_count": restored,
		"best_restore_percent": best_restore,
		"journey_count": journey,
		"journey_steps": _journey_steps(journey),
		"region_count": regions,
		"visited_regions": _region_labels(regions),
		"edits": {"0,0": edit_data},
		"discoveries": _discovery_keys(discoveries),
	}
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()

func _discovery_keys(count: int) -> Array:
	var out := []
	for i in range(count):
		out.append("%d,40,%d" % [i, i])
	return out

func _journey_steps(count: int) -> Array:
	var all := ["explore", "select_material", "open_palette", "place_block", "use_template", "open_map", "discover_landmark", "save_world"]
	return all.slice(0, clampi(count, 0, all.size()))

func _region_labels(count: int) -> Array:
	var all := ["草原", "风草原", "针叶林", "苔林", "岩岭", "玄武岩岭", "雪峰", "湿地", "沙岸", "黏土滩", "浅水湾"]
	return all.slice(0, clampi(count, 0, all.size()))

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
