extends SceneTree
# 验证本地世界目录扫描/排序/删除：
#   godot --headless --path <项目> --script res://tests/test_world_catalog.gd

const WorldCatalog = preload("res://scripts/WorldCatalog.gd")

var failed := 0
var _dir := "user://tests/catalog"

func _process(_delta: float) -> bool:
	return true

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	OS.unset_environment("VC_NO_SAVE")
	OS.unset_environment("VC_SAVE_PATH")
	OS.set_environment("VC_SAVE_DIR", _dir)
	_clean_dir()
	_write_world(111, 10, 2, 0)
	_write_world(222, 30, 5, 3, 2, 80, true)
	_write_world(333, 20, 1, 1)
	_write_world(444, 40, 7, 4, 1, 50)
	var recovered_path := WorldCatalog.save_path_for_seed(444)
	_write_text(recovered_path + ".bak", FileAccess.get_file_as_string(recovered_path))
	_write_text(recovered_path, "{ broken primary")
	_write_world(555, 25, 3, 2)
	var backup_only_path := WorldCatalog.save_path_for_seed(555)
	_write_text(backup_only_path + ".bak", FileAccess.get_file_as_string(backup_only_path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(backup_only_path))
	var cover_path := WorldCatalog.cover_path_for_seed(222)
	var save_path := WorldCatalog.save_path_for_seed(222)
	_write_text(save_path + ".bak", "{\"seed\":222}")
	_write_text(save_path + ".tmp", "{\"seed\":222}")

	var worlds := WorldCatalog.list_worlds()
	check(worlds.size() == 5, "扫描到主存档和备份可恢复世界")
	check(int(worlds[0].get("seed", 0)) == 444, "备份恢复世界参与更新时间排序")
	check(WorldCatalog.latest_seed(999) == 444, "latest_seed 可取备份恢复世界")
	check(WorldCatalog.has_world(111), "has_world 识别已有世界")
	check(WorldCatalog.has_world(444), "has_world 识别主存档损坏但备份可用的世界")
	check(WorldCatalog.has_world(555), "has_world 识别只有备份的世界")
	check(bool(worlds[0].get("from_backup", false)), "目录标记主存档损坏时来自备份")
	check(_meta_for_seed(worlds, 555).get("from_backup", false), "目录标记备份独立世界来自备份")
	var cover_meta := _meta_for_seed(worlds, 222)
	check(int(cover_meta.get("edit_count", 0)) == 5, "读取 edit_count")
	check(int(cover_meta.get("discovery_count", 0)) == 3, "读取 discovery_count")
	check(int(cover_meta.get("restored_count", 0)) == 2, "读取 restored_count")
	check(int(cover_meta.get("best_restore_percent", 0)) == 80, "读取 best_restore_percent")
	check(str(cover_meta.get("name", "")) == WorldCatalog.world_name(222), "目录元数据包含稳定世界名")
	check(str(cover_meta.get("biome_label", "")) == WorldCatalog.world_biome_label(222), "目录元数据包含稳定地貌标签")
	check(str(cover_meta.get("cover_path", "")) == cover_path, "目录元数据包含封面路径")
	check(bool(cover_meta.get("cover_exists", false)), "目录元数据识别真实封面存在")
	check(WorldCatalog.world_name(222) == WorldCatalog.world_name(222), "同一种子世界名稳定")
	check(WorldCatalog.world_biome_label(222) == WorldCatalog.world_biome_label(222), "同一种子地貌标签稳定")

	check(WorldCatalog.delete_world(222), "删除最新世界")
	check(not WorldCatalog.has_world(222), "删除后文件不存在")
	check(not FileAccess.file_exists(save_path + ".bak"), "删除世界时清理备份存档")
	check(not FileAccess.file_exists(save_path + ".tmp"), "删除世界时清理临时存档")
	check(not FileAccess.file_exists(cover_path), "删除世界时清理自有封面")
	var after := WorldCatalog.list_worlds()
	check(after.size() == 4, "删除后剩余世界数量正确")
	check(int(after[0].get("seed", 0)) == 444, "删除后最新世界仍可来自备份恢复")
	check(WorldCatalog.delete_world(555), "可删除只有备份的世界")
	check(not WorldCatalog.has_world(555), "删除只有备份的世界后不再识别")

	_clean_dir()
	if failed == 0:
		print("✅ ALL WORLD CATALOG TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个世界目录测试失败")
	quit(failed)

func _write_world(seed: int, updated_at: int, edits: int, discoveries: int, restored: int = 0, best_restore: int = 0, with_cover: bool = false) -> void:
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
		"cover_path": WorldCatalog.cover_path_for_seed(seed) if with_cover else "",
		"edit_count": edits,
		"discovery_count": discoveries,
		"restored_count": restored,
		"best_restore_percent": best_restore,
		"edits": {"0,0": edit_data},
		"discoveries": _discovery_keys(discoveries),
	}
	if with_cover:
		_write_cover_png(WorldCatalog.cover_path_for_seed(seed))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data))
	f.close()

func _write_text(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()

func _meta_for_seed(worlds: Array, seed: int) -> Dictionary:
	for raw in worlds:
		var meta: Dictionary = raw
		if int(meta.get("seed", 0)) == seed:
			return meta
	return {}

func _discovery_keys(count: int) -> Array:
	var out := []
	for i in range(count):
		out.append("%d,40,%d" % [i, i])
	return out

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

func _write_cover_png(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var img := Image.create(32, 18, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.1, 0.35, 0.75, 1.0))
	img.save_png(path)
