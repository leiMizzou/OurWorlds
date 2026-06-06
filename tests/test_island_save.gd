extends SceneTree
# World 携带 kind 并写入存档；themed_island 世界数据用 IslandGenerator。
const World = preload("res://scripts/World.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var path := "user://tests/island_save.json"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://tests"))
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	var lib := BlockLibrary.new()
	var w := World.new()
	root.add_child(w)
	w.setup(lib, 1337, path, "themed_island")
	check(w.world_kind() == "themed_island", "World.world_kind == themed_island")
	# 岛外列为空气（证明确实用了 IslandGenerator）
	check(w.get_block(4000, 50, 4000) == 0, "岛外列空气（IslandGenerator 生效）")
	check(w.save_world(true), "save_world 成功")

	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	check(typeof(data) == TYPE_DICTIONARY and str((data as Dictionary).get("kind", "")) == "themed_island", "存档写入 kind=themed_island")

	if failed == 0: print("✅ ALL ISLAND SAVE TESTS PASSED")
	else: printerr("❌ ", failed, " 个存档测试失败")
	quit(0 if failed == 0 else 1)
