extends SceneTree
# NetMenu UI 逻辑自检（headless）：开关 + 提交信号。视觉/交互人工验收。
#   godot --headless --path . --script res://tests/test_net_menu.gd
const NetMenu = preload("res://scripts/NetMenu.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var m := NetMenu.new()
	root.add_child(m)
	m.setup()
	check(not m.is_open(), "默认关闭")
	m.open(); check(m.is_open(), "open 后打开")
	m.close(); check(not m.is_open(), "close 后关闭")
	# join 提交：带上地址（使用数组捕获引用，因 GDScript lambda 对基本类型按值捕获）
	var got_url := [""]
	m.join_requested.connect(func(u): got_url[0] = u)
	m.open()
	m.set_address("ws://10.0.0.5:8971")
	m.submit_join()
	check(got_url[0] == "ws://10.0.0.5:8971", "submit_join 发出带地址的 join_requested")
	check(not m.is_open(), "提交后菜单自动关闭")
	# 空地址回退到默认
	var got2 := [""]
	m.join_requested.connect(func(u): got2[0] = u)
	m.set_address("   ")
	m.submit_join()
	check(got2[0] == NetMenu.DEFAULT_URL, "空地址回退到默认 ws 地址")
	# host 提交
	var hosted := [false]
	m.host_requested.connect(func(): hosted[0] = true)
	m.submit_host()
	check(hosted[0], "submit_host 发出 host_requested")
	if failed == 0: print("✅ ALL NET MENU TESTS PASSED")
	else: printerr("❌ ", failed, " 个 NetMenu 测试失败")
	quit(0 if failed == 0 else 1)
