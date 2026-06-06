extends SceneTree
# AgentBridge capture_build / paste_build：捕获一处建造 → 异地粘贴 → 方块一致（分享建造）。
#   godot --headless --path . --script res://tests/test_agent_build_share.gd
const AgentBridge = preload("res://scripts/AgentBridge.gd")
var _f := 0
var _main = null
var _bridge: AgentBridge = null
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/build_share/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_f += 1
	if _f < 30:
		return false
	if _f == 30:
		_run()
		if failed == 0: print("✅ ALL AGENT BUILD SHARE TESTS PASSED")
		else: printerr("❌ ", failed, " 个 build-share 测试失败")
		return true
	if _f > 200:
		printerr("❌ build-share 测试超时"); return true
	return false

func _ok(tool: String, args: Dictionary) -> Dictionary:
	var resp := _bridge.dispatch(null, tool, args, "agent")
	check(bool(resp.get("ok", false)), "ok: " + tool)
	var r: Variant = resp.get("result", {})
	return r if typeof(r) == TYPE_DICTIONARY else {}

func _run() -> void:
	_bridge = AgentBridge.new()
	_bridge.world = _main.world
	_bridge.player = _main.player
	var w = _main.world
	# 摆一个小建造（高空，确保周围是空气、无地形干扰）
	w.request_block_edits([{"pos": Vector3i(0, 82, 0), "id": 3}, {"pos": Vector3i(1, 82, 0), "id": 6}])
	# 捕获成蓝图
	var cap := _ok("capture_build", {"name": "hut", "x1": 0, "y1": 82, "z1": 0, "x2": 1, "y2": 82, "z2": 0})
	check(int(cap.get("blocks", 0)) == 2, "捕获 2 块")
	# 异地粘贴
	var pst := _ok("paste_build", {"name": "hut", "x": 50, "y": 82, "z": 50})
	check(int(pst.get("changed", 0)) == 2, "粘贴改了 2 块")
	check(int(w.get_block(50, 82, 50)) == 3, "粘贴点 (50,82,50)=stone(3)")
	check(int(w.get_block(51, 82, 50)) == 6, "粘贴点 (51,82,50)=planks(6)")
	# 不存在的蓝图 → 报错（不崩）
	var bad := _bridge.dispatch(null, "paste_build", {"name": "nope", "x": 0, "y": 82, "z": 0}, "agent")
	check(not bool(bad.get("ok", true)), "粘贴不存在的蓝图 → 报错")
