extends SceneTree
# 标题页：选"主题岛"后，new_world_requested 携带 kind=themed_island。
const TitleScreen = preload("res://scripts/TitleScreen.gd")

var failed := 0
var captured := []
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var ts := TitleScreen.new()
	root.add_child(ts)
	ts.setup([], 1337, 1337)
	ts.new_world_requested.connect(func(seed, kind): captured = [seed, kind])

	# 默认 infinite
	ts._on_new_world_pressed()
	check(captured.size() == 2 and captured[1] == "infinite", "默认新世界 kind=infinite")

	# 选主题岛后再创建
	ts.set_new_kind_for_test("themed_island")
	ts._on_new_world_pressed()
	check(captured[1] == "themed_island", "选主题岛后 kind=themed_island")

	if failed == 0: print("✅ ALL TITLE KIND TESTS PASSED")
	else: printerr("❌ ", failed, " 个标题 kind 测试失败")
	quit(0 if failed == 0 else 1)
