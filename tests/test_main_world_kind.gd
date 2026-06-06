extends SceneTree
# 验证：env VC_WORLD_KIND=themed_island 时，Main 进入世界后 world.world_kind()==themed_island。
var _f := 0
var _main = null
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.set_environment("VC_NO_SAVE", "1")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/main_kind/settings.json")
		OS.set_environment("VC_SEED", "778899")
		OS.set_environment("VC_WORLD_KIND", "themed_island")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		return false
	if _f < 30:
		return false
	if _f == 30:
		check(_main.world != null, "Main 已建立 world")
		check(_main.world != null and _main.world.world_kind() == "themed_island", "world.world_kind()==themed_island")
		if failed == 0: print("✅ ALL MAIN KIND TESTS PASSED")
		else: printerr("❌ ", failed, " 个 Main kind 测试失败")
		return true
	if _f > 200:
		printerr("❌ Main kind 测试超时")
		return true
	return false
