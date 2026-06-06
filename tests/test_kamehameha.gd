extends SceneTree
# 验证隐藏技能龟派气功波的蓄力门槛与清块：
#   godot --headless --path <项目> --script res://tests/test_kamehameha.gd

var _main = null
var _gen := false
var _sf := 0
var failed := 0

func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/kame/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_d: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen = true
		return false
	_sf += 1
	var p = _main.player
	if _sf == 3:
		p.fly = true
		p.input_enabled = true
		p.global_position += Vector3(0, 6, 0)
		p.rotation.y = 0.0
		p.pitch = deg_to_rad(-20)
		p.spring.rotation.x = p.pitch
		# 1) 蓄力不足(<5s)松手 → 不发射
		p._charging = true
		p._kame_charge = 3.0
		p._kame_cooldown = 0.0
		p._update_kame_charge(0.05)
		check(p._kame_cooldown == 0.0, "蓄力不足5秒松手不发射")
		check(p._kame_charge == 0.0, "松手后蓄力清零")
		# 2) 蓄满(≥5s)松手 → 发射并清空前方
		var aim: Vector3 = p._aim_dir()
		var from: Vector3 = p.spring.global_position + aim * 1.2
		p._charging = true
		p._kame_charge = 6.0
		p._kame_cooldown = 0.0
		p._update_kame_charge(0.05)
		check(p._kame_cooldown > 0.0, "蓄满松手发射并进入冷却")
		var cleared := 0
		var total := 0
		for tt in range(6, 40, 3):
			var c: Vector3 = from + aim * float(tt)
			total += 1
			if _main.world.get_block(int(floor(c.x)), int(floor(c.y)), int(floor(c.z))) == 0:
				cleared += 1
		check(cleared >= total - 2, "气功波清空前方中线 (%d/%d)" % [cleared, total])
	elif _sf >= 6:
		if failed == 0:
			print("✅ ALL KAMEHAMEHA TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个龟派气功波测试失败")
		return true
	return false
