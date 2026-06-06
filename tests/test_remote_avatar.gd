extends SceneTree
# RemoteAvatar：可设名字、设网络目标后朝目标插值移动（不瞬移）。
# 注意：global_position 需节点已进树，而 _initialize 里刚 add_child 的节点要等下一帧才在树内，
#       所以断言放在 _process（首帧之后）里跑。
#   godot --headless --path . --script res://tests/test_remote_avatar.gd
const RemoteAvatar = preload("res://scripts/RemoteAvatar.gd")
var failed := 0
var _a: RemoteAvatar
var _f := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	_a = RemoteAvatar.new()
	root.add_child(_a)
	_a.set_label("Alice")        # _ready 还没跑，先存 pending；进树后回填到名牌

func _process(_delta: float) -> bool:
	_f += 1
	if _f < 2:
		return false             # 等一帧，让 _a 进树（global_position 才有效，_ready 也已跑）
	_a.global_position = Vector3.ZERO
	_a.set_net_target(Vector3(10, 0, 0), 0.0)
	# 单步插值：朝目标靠近但不立刻到达（LERP_POS=10, delta=0.02 -> 系数 0.2）
	_a._net_step(0.02)
	check(_a.global_position.x > 0.0 and _a.global_position.x < 10.0, "设目标后朝目标插值（未瞬移）")
	# 足够多帧后收敛到目标附近
	for i in range(200):
		_a._net_step(0.02)
	check(_a.global_position.distance_to(Vector3(10, 0, 0)) < 0.2, "多帧后收敛到目标")
	check(str(_a.label_text()) == "Alice", "名牌文字可读")
	if failed == 0: print("✅ ALL REMOTE AVATAR TESTS PASSED")
	else: printerr("❌ ", failed, " 个 RemoteAvatar 测试失败")
	quit(0 if failed == 0 else 1)
	return true
