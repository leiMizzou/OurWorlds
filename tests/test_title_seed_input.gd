extends SceneTree
# 验证标题页的新世界种子输入、预览和信号：
#   godot --headless --path <项目> --script res://tests/test_title_seed_input.gd

const TitleScreen = preload("res://scripts/TitleScreen.gd")
const WorldCatalog = preload("res://scripts/WorldCatalog.gd")

var failed := 0
var _screen: TitleScreen
var _requested := []

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	_screen = TitleScreen.new()
	root.add_child(_screen)
	_screen.new_world_requested.connect(func(seed: int, _kind: String): _requested.append(seed))
	_screen.setup([], 1337, 1337)

	check(_screen._new_seed_edit != null, "标题页包含新世界种子输入")
	check(_screen._new_seed_edit.placeholder_text == "数字或文字种子", "标题页明确支持数字或文字种子")
	check(_screen._random_seed_button != null, "标题页包含随机种子按钮")
	check(_screen._fresh_button.text == "创建新世界", "标题页创建按钮使用发布向动作文案")
	check(not _node_has_text(_screen, "preview") and not _node_has_text(_screen, "v0.1"), "标题页不暴露预览版开发文案")
	check(_screen._world_cover != null, "标题页包含新世界封面")
	check(_screen._world_cover.is_empty_preview(), "无存档时封面使用新世界预览状态")
	check(_screen._new_world_seed() >= 1, "默认新世界种子有效")
	check(_screen._world_cover.current_seed() == _screen._new_world_seed(), "无存档时封面绑定当前新世界种子")
	check(_screen._new_seed_name_label.text.contains(WorldCatalog.world_name(_screen._new_world_seed())), "默认种子显示世界名预览")
	check(_screen._new_seed_name_label.text.contains(WorldCatalog.world_biome_label(_screen._new_world_seed())), "默认种子显示地貌预览")

	_screen._new_seed_edit.text = "424242"
	_screen._on_new_seed_changed("424242")
	check(_screen._new_world_seed() == 424242, "数字种子按输入使用")
	check(_screen._new_seed_name_label.text.contains(WorldCatalog.world_name(424242)), "数字种子更新世界名预览")
	check(_screen._new_seed_name_label.text.contains(WorldCatalog.world_biome_label(424242)), "数字种子更新地貌预览")
	check(_screen._world_cover.current_seed() == 424242, "数字种子同步刷新新世界封面")
	_screen._on_new_world_pressed()
	check(_requested.size() == 1 and int(_requested[0]) == 424242, "新世界信号携带输入种子")
	_screen._new_seed_edit.text_submitted.emit("515151")
	check(_requested.size() == 2 and int(_requested[1]) == 515151, "种子输入框回车会创建对应新世界")
	check(_screen._world_cover.current_seed() == 515151, "种子输入框回车前会刷新新世界封面")

	_screen._new_seed_edit.text = "-77"
	_screen._on_new_seed_changed("-77")
	check(_screen._new_world_seed() == 77, "负数种子转为正数")
	check(_screen._world_cover.current_seed() == 77, "负数种子同步刷新新世界封面")

	_screen._new_seed_edit.text = "blue valley"
	_screen._on_new_seed_changed("blue valley")
	var text_seed := _screen._new_world_seed()
	check(text_seed >= 1, "文本种子可稳定转为数字种子")
	check(_screen._seed_from_text("blue valley", 1) == text_seed, "文本种子转换稳定")
	check(_screen._world_cover.current_seed() == text_seed, "文本种子同步刷新新世界封面")

	var before := _screen._new_world_seed()
	_screen._randomize_new_seed()
	check(_screen._new_world_seed() >= 1000, "随机按钮生成有效种子")
	check(_screen._new_world_seed() != before or before >= 1000, "随机按钮刷新种子输入")
	check(_screen._new_seed_edit.text == str(_screen._new_world_seed()), "随机种子同步到输入框")
	check(_screen._world_cover.current_seed() == _screen._new_world_seed(), "随机种子同步刷新新世界封面")

	if failed == 0:
		print("✅ ALL TITLE SEED INPUT TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个标题种子输入测试失败")
	quit(failed)

func _node_has_text(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.contains(needle):
		return true
	if node is Button and (node as Button).text.contains(needle):
		return true
	if node is LineEdit and (node as LineEdit).placeholder_text.contains(needle):
		return true
	for child in node.get_children():
		if _node_has_text(child, needle):
			return true
	return false
