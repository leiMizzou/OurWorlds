extends SceneTree
# 验证本地世界增量存档：
#   godot --headless --path <项目> --script res://tests/test_save.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const World = preload("res://scripts/World.gd")

var failed := 0

func _process(_delta: float) -> bool:
	return true

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	var path := "user://tests/ourworlds_save_test.json"
	_remove_file(path)
	_remove_file(path + ".bak")
	_remove_file(path + ".tmp")

	var lib := BlockLibrary.new()
	var w := World.new()
	w.setup(lib, 4242, path)

	var wx := 8
	var wz := 8
	var h: int = w.surface_y(wx, wz)
	var base_id: int = w.get_block(wx, h, wz)
	check(base_id != BlockLibrary.AIR, "测试点是生成出来的实心地表")

	check(w.request_edit(wx, h, wz, BlockLibrary.BRICK), "编辑地表为砖块")
	check(w.edit_count() == 1, "产生 1 条增量")
	check(w.has_unsaved_changes(), "编辑后标记为未保存")
	var landmark := Vector3i(wx, h + 1, wz)
	check(w.mark_landmark_discovered(landmark), "记录 1 个已发现地标")
	check(w.discovery_count() == 1, "发现地标计数为 1")
	check(w.mark_journey_step("explore"), "记录旅程：探索")
	check(w.mark_journey_step("select_material"), "记录旅程：选材")
	check(w.journey_count() == 2, "旅程计数为 2")
	check(w.mark_region_visited("草原"), "记录踏足区域：草原")
	check(w.mark_region_visited("湿地"), "记录踏足区域：湿地")
	check(w.region_count() == 2, "踏足区域计数为 2")

	var cc := w.chunk_of(wx, wz)
	w._chunks.erase(cc)
	check(w.get_block(wx, h, wz) == BlockLibrary.BRICK, "区块卸载再读仍套用内存增量")

	check(w.save_world(true), "保存世界成功")
	check(FileAccess.file_exists(path), "存档文件已写入")

	var w2 := World.new()
	w2.setup(lib, 4242, path)
	check(w2.edit_count() == 1, "新世界实例载入 1 条增量")
	check(w2.discovery_count() == 1, "新世界实例载入 1 个已发现地标")
	check(w2.is_landmark_discovered(landmark), "新世界实例恢复已发现地标")
	check(w2.journey_count() == 2, "新世界实例载入旅程进度")
	check(w2.is_journey_step_done("select_material"), "新世界实例恢复已完成选材")
	check(w2.region_count() == 2, "新世界实例载入踏足区域")
	check(w2.visited_regions().has("草原") and w2.visited_regions().has("湿地"), "新世界实例恢复踏足区域列表")
	check(w2.get_block(wx, h, wz) == BlockLibrary.BRICK, "新世界实例读到已保存的砖块")

	check(w2.request_edit(wx, h, wz, base_id), "改回生成值")
	check(w2.edit_count() == 0, "改回生成值后增量被压缩移除")
	check(w2.save_world(true), "保存压缩后的世界")

	var w3 := World.new()
	w3.setup(lib, 4242, path)
	check(w3.edit_count() == 0, "重新载入后没有冗余增量")
	check(w3.discovery_count() == 1, "重新载入后保留已发现地标")
	check(w3.journey_count() == 2, "重新载入后保留旅程进度")
	check(w3.region_count() == 2, "重新载入后保留踏足区域")
	check(w3.get_block(wx, h, wz) == base_id, "重新载入后恢复生成值")

	var landmark2 := landmark + Vector3i(1, 0, 0)
	check(w3.mark_landmark_discovered(landmark2), "仅记录新发现也会改变世界元数据")
	check(w3.mark_journey_step("place_block"), "仅记录新旅程也会改变世界元数据")
	var cover_path := "user://tests/ourworlds_cover.png"
	w3.set_cover_path(cover_path)
	check(w3.mark_region_visited("雪峰"), "仅记录新区域也会改变世界元数据")
	check(w3.cover_path == cover_path, "封面路径写入世界元数据")
	check(w3.has_unsaved_changes(), "仅元数据变更也标记为未保存")
	check(w3.save_world(), "非强制保存会写入仅元数据变更")

	var w4 := World.new()
	w4.setup(lib, 4242, path)
	check(w4.discovery_count() == 2, "重新载入后保留仅元数据保存的发现")
	check(w4.journey_count() == 3, "重新载入后保留仅元数据保存的旅程")
	check(w4.region_count() == 3, "重新载入后保留仅元数据保存的区域")
	check(w4.cover_path == cover_path, "重新载入后保留封面路径")
	check(w4.edit_count() == 0, "仅保存元数据不会产生方块增量")
	check(w4.save_world(true), "强制保存会刷新主存档")
	check(FileAccess.file_exists(path + ".bak"), "重复保存会保留上一版备份")

	var corrupt := FileAccess.open(path, FileAccess.WRITE)
	if corrupt != null:
		corrupt.store_string("{ broken save")
		corrupt.close()
	var w5 := World.new()
	w5.setup(lib, 4242, path)
	check(w5.discovery_count() == 2, "主存档损坏时从备份恢复发现记录")
	check(w5.journey_count() == 3, "主存档损坏时从备份恢复旅程进度")
	check(w5.region_count() == 3, "主存档损坏时从备份恢复区域进度")
	check(w5.cover_path == cover_path, "主存档损坏时从备份恢复封面路径")
	check(w5.has_unsaved_changes(), "从备份恢复后标记需要重新保存主存档")
	check(w5.save_world(), "从备份恢复后可重新写回主存档")
	var repaired: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(typeof(repaired) == TYPE_DICTIONARY, "备份恢复保存后主存档重新成为有效 JSON")

	w.free()
	w2.free()
	w3.free()
	w4.free()
	w5.free()

	_remove_file(path)
	_remove_file(path + ".bak")
	_remove_file(path + ".tmp")

	if failed == 0:
		print("✅ ALL SAVE TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个存档测试失败")
	quit(failed)

func _remove_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
