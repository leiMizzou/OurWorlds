extends SceneTree
# LoginScreen UI 逻辑自检（用 NakamaClient 桩，无需真 Nakama → suite 安全）：
#   godot --headless --path . --script res://tests/test_login_screen.gd
const LoginScreen = preload("res://scripts/LoginScreen.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

class NakamaStub:
	extends Node
	signal authenticated(session: Dictionary)
	signal auth_failed(message: String)
	var calls := []
	func authenticate_email(e: String, p: String, c: bool) -> int:
		calls.append([e, p, c]); return 0

func _initialize() -> void:
	var stub := NakamaStub.new()
	root.add_child(stub)
	var ls := LoginScreen.new()
	root.add_child(ls)
	ls.setup(stub)

	# 空字段不提交
	ls.submit(false)
	check(stub.calls.size() == 0, "空字段不调用认证")
	# 填好 → 调用 authenticate_email（带 create 标志）
	ls.set_credentials("a@b.com", "pw123456")
	ls.submit(true)
	check(stub.calls.size() == 1 and str(stub.calls[0][0]) == "a@b.com" and bool(stub.calls[0][2]) == true, "注册：authenticate_email(email, pw, create=true)")
	# 认证成功 → logged_in + 关闭
	var got := [false]
	ls.logged_in.connect(func(_s): got[0] = true)
	stub.authenticated.emit({"token": "t", "user_id": "u"})
	check(got[0], "认证成功 → 发出 logged_in")
	check(not ls.is_open(), "登录成功后面板关闭")
	# 失败 → 不发 logged_in（只更新状态）
	var got2 := [false]
	ls.logged_in.connect(func(_s): got2[0] = true)
	stub.auth_failed.emit("bad password")
	check(not got2[0], "认证失败不发 logged_in")
	# 游客 → guest_chosen
	var guested := [false]
	ls.guest_chosen.connect(func(): guested[0] = true)
	ls.choose_guest()
	check(guested[0], "游客进入 → 发出 guest_chosen")

	if failed == 0: print("✅ ALL LOGIN SCREEN TESTS PASSED")
	else: printerr("❌ ", failed, " 个登录界面测试失败")
	quit(0 if failed == 0 else 1)
