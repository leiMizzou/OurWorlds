extends SceneTree
# 验证标题页删除世界需要二次确认：
#   godot --headless --path <项目> --script res://tests/test_title_delete_confirm.gd

const TitleScreen = preload("res://scripts/TitleScreen.gd")
const Locale = preload("res://scripts/Locale.gd")

var _screen: TitleScreen
var _f := 0
var _deleted := []
var failed := 0
var _loc                  # i18n：种到 /root/Locale（zh），断言用 _loc.t(key) 与 UI 文案对齐

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		# 直接构造 TitleScreen（不经 Main.tscn）时不会注入 Locale 自动加载；
		# 手动种一个 /root/Locale（固定 zh）让界面 _loc() 找到它，断言对照同一文案表。
		_loc = Locale.new()
		_loc.name = "Locale"
		root.add_child(_loc)
		_loc.load_strings()
		_loc.set_language("zh")
		_screen = TitleScreen.new()
		root.add_child(_screen)
		_screen.delete_world_requested.connect(func(seed: int): _deleted.append(seed))
		_screen.setup([
			{"seed": 101, "updated_at": 1000, "edit_count": 4},
			{"seed": 202, "updated_at": 900, "edit_count": 1},
		], 101, 101)
	elif _f == 2:
		_screen._on_delete_pressed()
		check(_deleted.is_empty(), "第一次点击删除不会立即发出删除请求")
		check(_screen._delete_pending, "第一次点击进入确认状态")
		check(_screen._delete_hint.visible, "确认提示可见")
		check(_screen._delete_button.text == _loc.t("TITLE_DELETE_CONFIRM"), "删除按钮切换为确认文案")
		_screen._move_selection(1)
		check(not _screen._delete_pending, "切换世界会取消确认状态")
		_screen._on_delete_pressed()
		_screen._on_delete_pressed()
		check(_deleted.size() == 1 and int(_deleted[0]) == 202, "第二次点击才发出选中世界删除请求")
		if failed == 0:
			print("✅ ALL TITLE DELETE CONFIRM TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个删除确认测试失败")
		return true
	return false
