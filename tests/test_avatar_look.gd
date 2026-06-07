extends SceneTree
# AvatarLook：从 eid 确定性派生"长相"（配色/发型/体型/配件），让每个联机小人一眼可区分。
# 同一 eid -> 完全一致；不同 eid -> （几乎总是）不同。RemoteAvatar 按它造身体。
#   godot --headless --path . --script res://tests/test_avatar_look.gd
const AvatarLook = preload("res://scripts/AvatarLook.gd")
const RemoteAvatar = preload("res://scripts/RemoteAvatar.gd")

var failed := 0
var _av: RemoteAvatar
var _plain: RemoteAvatar
var _f := 0

func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var look: Dictionary = AvatarLook.look_for("agent-1")

	# 1) 确定性：同一 eid 两次调用完全一致
	var look2: Dictionary = AvatarLook.look_for("agent-1")
	check(look == look2, "同一 eid 两次 look_for 完全一致（确定性）")

	# 2) 键齐全 + 类型正确
	for key in ["skin", "hair", "jacket", "accent", "pants"]:
		check(look.has(key), "含颜色键 %s" % key)
		check(look.get(key) is Color, "%s 是 Color" % key)
	check(look.has("hair_style"), "含 hair_style")
	check(str(look.get("hair_style", "")) in ["short", "long", "mohawk", "bun", "cap", "bald"], "hair_style 取值合法")
	check(look.has("build"), "含 build")
	check(str(look.get("build", "")) in ["slim", "broad"], "build 取值合法")
	check(look.has("accessory"), "含 accessory")
	check(str(look.get("accessory", "")) in ["none", "hardhat", "antenna", "visor"], "accessory 取值合法")

	# 3) 区分度：不同 eid 至少某个属性不同
	var a := AvatarLook.look_for("agent-1")
	var b := AvatarLook.look_for("agent-2")
	check(a != b, "agent-1 与 agent-2 的 look 不完全相同（可区分）")

	# 4) 多样性：agent-1..agent-6 的工装色不应全部相同
	var jackets := {}
	for i in range(1, 7):
		var lk: Dictionary = AvatarLook.look_for("agent-%d" % i)
		jackets[str(lk["jacket"])] = true
	check(jackets.size() >= 2, "agent-1..6 工装色出现多样性（>=2 种）")

	# 同理发型也应有多样性（弱断言：跨 12 个 eid 至少两种发型）
	var styles := {}
	for i in range(1, 13):
		var lk2: Dictionary = AvatarLook.look_for("p-%d" % i)
		styles[str(lk2["hair_style"])] = true
	check(styles.size() >= 2, "跨 12 个 eid 发型出现多样性（>=2 种）")

	# 5) 构造 RemoteAvatar，setLook 后进树应正常建造、且比默认多出网格（发型/配件）
	#    选一个一定有发型+配件的 eid，保证多出方块（用确定性属性枚举找）
	var rich_eid := _find_rich_eid()
	_plain = RemoteAvatar.new()
	root.add_child(_plain)                  # 不设 look，走默认造型
	_av = RemoteAvatar.new()
	_av.set_look(AvatarLook.look_for(rich_eid))   # _ready 前设 look
	root.add_child(_av)

func _find_rich_eid() -> String:
	# 找一个发型非 bald/cap 且配件非 none 的 eid，保证比默认（6 块、无发无配件）多出网格
	for i in range(1, 200):
		var e := "rich-%d" % i
		var lk: Dictionary = AvatarLook.look_for(e)
		if str(lk["hair_style"]) not in ["bald"] and str(lk["accessory"]) != "none":
			return e
	return "rich-1"

func _process(_delta: float) -> bool:
	_f += 1
	if _f < 2:
		return false                        # 等一帧让 _ready 跑完、子节点建好
	var plain_meshes := _count_meshes(_plain)
	var look_meshes := _count_meshes(_av)
	check(plain_meshes >= 6, "默认造型至少 6 个网格（头/身/双臂/双腿）")
	check(look_meshes > plain_meshes, "带 look 的造型比默认多出网格（发型/配件）")

	# set_color 向后兼容：未设 look 时仍作用于工装
	var c := RemoteAvatar.new()
	root.add_child(c)
	c.set_color(Color(1, 0, 0))
	check(c._color == Color(1, 0, 0), "set_color 向后兼容（仍可设工装色）")

	if failed == 0: print("✅ ALL AVATAR LOOK TESTS PASSED")
	else: printerr("❌ ", failed, " 个 AvatarLook 测试失败")
	quit(0 if failed == 0 else 1)
	return true

func _count_meshes(n: Node) -> int:
	var c := 0
	for child in n.get_children():
		if child is MeshInstance3D:
			c += 1
		c += _count_meshes(child)
	return c
