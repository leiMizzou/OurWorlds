extends SceneTree
# 验证标题页会默认选择最近保存的世界：
#   godot --headless --path <项目> --script res://tests/test_title_world_catalog.gd

const WorldCatalog = preload("res://scripts/WorldCatalog.gd")
const GameSettings = preload("res://scripts/GameSettings.gd")

var _f := 0
var _main = null
var failed := 0
var _dir := "user://tests/title_catalog"
var _continued_seeds := []

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
		OS.unset_environment("VC_SEED")
		OS.unset_environment("VC_SKIP_TITLE")
		OS.set_environment("VC_SAVE_DIR", _dir)
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/title_catalog/settings.json")
		_clean_dir()
		# 预置 language=zh 落盘（须在 _clean_dir 之后，settings.json 就在 _dir 内），
		# Main._ready 的 Locale.init 会读到它 —— 断言里的中文文案不受运行机 OS 语言影响。
		_seed_language("zh")
		_write_world(1357, 11, 2, 1, 1)
		_write_world(2468, 44, 6, 4, 3, 2, 80, true, 5)
		_write_world(9753, 5, 4, 2, 2)
		var recovered_path := WorldCatalog.save_path_for_seed(9753)
		_write_text(recovered_path + ".bak", FileAccess.get_file_as_string(recovered_path))
		_write_text(recovered_path, "{ broken primary")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 24:
		check(_main._current_seed == 2468, "启动默认选择最近保存的世界")
		check(_main.title_screen.visible, "标题页可见")
		check(_main.title_screen._selected_seed() == 2468, "标题页选中最近世界")
		check(_main.title_screen._worlds.size() == 3, "标题页接收主存档和备份恢复世界条目")
		check(_has_seed(_main.title_screen._worlds, 9753), "标题页世界列表包含备份恢复世界")
		check(_main.title_screen._world_label.text.contains(WorldCatalog.world_name(2468)), "标题页显示最近世界名称")
		check(_main.title_screen._world_label.text.contains(WorldCatalog.world_biome_label(2468)), "标题页显示最近世界地貌标签")
		check(_main.title_screen._world_cover != null, "标题页包含世界封面")
		check(_main.title_screen._world_cover.current_seed() == 2468, "世界封面绑定最近世界")
		check(not _main.title_screen._world_cover.is_empty_preview(), "已有世界使用正式封面状态")
		check(_main.title_screen._world_cover.has_real_cover(), "最近世界优先显示真实封面")
		_main.title_screen._new_seed_edit.text = "9999"
		_main.title_screen._on_new_seed_changed("9999")
		check(_main.title_screen._world_cover.current_seed() == 2468, "已有世界封面不被新种子输入覆盖")
		check(_main.title_screen._world_stats_row.get_child_count() == 4, "标题页显示世界印记统计块")
		check(_title_stat(0).contains("6 格"), "标题页显示最近世界建造数量")
		check(_title_stat(1).contains("2 修") and _title_stat(1).contains("80%"), "标题页显示最近世界修复进度")
		check(_title_stat(2).contains("3/8"), "标题页显示最近世界旅程进度")
		check(_title_stat(3).contains("5/"), "标题页显示区域探索进度")
		check(_main.title_screen._meta_label.text.contains("上次"), "标题页保留最近保存时间")
		_send_key(KEY_RIGHT)
		check(_main.title_screen._selected_seed() == 1357, "标题页可用右方向键切换世界")
		check(_main.title_screen._world_label.text.contains(WorldCatalog.world_name(1357)), "切换世界后显示对应世界名称")
		check(_main.title_screen._world_label.text.contains(WorldCatalog.world_biome_label(1357)), "切换世界后更新地貌标签")
		check(_main.title_screen._world_cover.current_seed() == 1357, "切换世界后封面绑定对应世界")
		check(not _main.title_screen._world_cover.has_real_cover(), "切换到无封面世界时使用程序化兜底")
		check(_title_stat(1).contains("1 见") and _title_stat(1).contains("0 修"), "切换世界后更新发现和修复数量")
		check(_title_stat(2).contains("1/8"), "切换世界后更新旅程进度")
		_main.title_screen._new_seed_edit.grab_focus()
		_send_key(KEY_RIGHT)
		check(_main.title_screen._selected_seed() == 1357, "种子输入框聚焦时方向键不切换世界")
		_main.title_screen._new_seed_edit.release_focus()
		_send_key(KEY_RIGHT)
		check(_main.title_screen._selected_seed() == 9753, "标题页可用右方向键切到备份恢复世界")
		check(_main.title_screen._save_label.text.contains("备份恢复"), "备份恢复世界显示存档恢复状态")
		check(_main.title_screen._meta_label.text.contains("需保存"), "备份恢复世界提示进入后需要保存")
		_send_key(KEY_LEFT)
		check(_main.title_screen._selected_seed() == 1357, "标题页可用左方向键切回正常世界")
		var continue_handler := Callable(_main, "_continue_selected_world")
		if _main.title_screen.continue_requested.is_connected(continue_handler):
			_main.title_screen.continue_requested.disconnect(continue_handler)
		_main.title_screen.continue_requested.connect(func(seed: int): _continued_seeds.append(seed))
		var enter := InputEventKey.new()
		enter.pressed = true
		enter.keycode = KEY_ENTER
		_main._unhandled_input(enter)
		check(_continued_seeds.size() == 1 and int(_continued_seeds[0]) == 1357, "标题页回车继续当前选中的世界")
		_main.set_title_active(false)
	elif _f >= 80:
		_clean_dir()
		if failed == 0:
			print("✅ ALL TITLE CATALOG TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个标题目录集成测试失败")
		return true
	return false

func _write_world(seed: int, updated_at: int, edits: int, discoveries: int, journey: int, restored: int = 0, best_restore: int = 0, with_cover: bool = false, regions: int = 0) -> void:
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
		"journey_count": journey,
		"journey_steps": _journey_steps(journey),
		"region_count": regions,
		"visited_regions": _region_labels(regions),
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

func _has_seed(worlds: Array, seed: int) -> bool:
	for raw in worlds:
		var meta: Dictionary = raw
		if int(meta.get("seed", 0)) == seed:
			return true
	return false

func _seed_language(lang: String) -> void:
	var settings := GameSettings.load_settings()
	settings["language"] = lang
	GameSettings.save_settings(settings)

func _send_key(keycode: int) -> void:
	var event := InputEventKey.new()
	event.pressed = true
	event.keycode = keycode
	_main._unhandled_input(event)

func _title_stat(index: int) -> String:
	var row: GridContainer = _main.title_screen._world_stats_row
	if row == null or row.get_child_count() <= index:
		return ""
	return _collect_label_text(row.get_child(index))

func _collect_label_text(node: Node) -> String:
	var text := ""
	if node is Label:
		text += " " + (node as Label).text
	for child in node.get_children():
		text += _collect_label_text(child)
	return text

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
	var img := Image.create(64, 36, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.12, 0.42, 0.74, 1.0))
	img.save_png(path)
