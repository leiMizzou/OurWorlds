extends SceneTree
# 验证 OurWorlds 代理桥（AgentBridge）：直接喂 NDJSON 行 / 调 dispatch（不经 TCP），
# 跑 observe/look/goto/scan/place/break/build/get_block/say/set_goal/remember/get_memory，
# 断言结果信封与字段合理。
#   godot --headless --path <项目> --script res://tests/test_agent_bridge.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const AgentBridge = preload("res://scripts/AgentBridge.gd")

var _f := 0
var _main = null
var _bridge: AgentBridge = null
var failed := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

# 无挂起兜底：即便永不返回 true 也不会卡死全套自检（run_all 有外层超时，但这里再保一层）。
func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.set_environment("VC_NO_SAVE", "1")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/agent_bridge/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
		return false
	if _f < 30:
		return false   # 让世界/玩家落地、区块流式加载若干帧
	if _f == 30:
		_run_tests()
		if failed == 0:
			print("✅ ALL AGENT BRIDGE TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个代理桥测试失败")
		return true
	if _f > 200:
		printerr("❌ 代理桥测试超时未完成")
		return true
	return false

func _run_tests() -> void:
	# 记忆持久化跨运行存活；清掉旧文件让记忆断言确定（note_count 从 0 起）。
	var mem_path := "user://agent_memory.json"
	if FileAccess.file_exists(mem_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(mem_path))
	# 直接构造桥并注入引用（不依赖 OW_AGENT_PORT / TCP）
	_bridge = AgentBridge.new()
	_bridge.name = "AgentBridgeTest"
	_bridge.world = _main.world
	_bridge.player = _main.player
	_bridge.hud = _main.hud
	_main.add_child(_bridge)   # 触发 _ready：建方块名表 + 载入记忆

	_test_envelope_errors()
	_test_observe()
	_test_get_block_and_place()
	_test_break()
	_test_build()
	_test_goto_scan()
	_test_look_say()
	_test_memory()
	_test_recent_actions()

func _ok_result(line: String) -> Dictionary:
	var resp := _bridge.dispatch_line(line)
	check(bool(resp.get("ok", false)), "响应 ok: " + line.substr(0, 60))
	var result: Variant = resp.get("result", {})
	return result if typeof(result) == TYPE_DICTIONARY else {}

# ---------- 协议信封 / 错误 ----------
func _test_envelope_errors() -> void:
	var bad := _bridge.dispatch_line("not json at all")
	check(bad.get("id", 1) == null and not bool(bad.get("ok", true)) and str(bad.get("error", "")).begins_with("bad json"), "坏 JSON -> id:null ok:false bad json")

	var unknown := _bridge.dispatch_line('{"id":1,"tool":"fooberry","args":{}}')
	check(unknown.get("id", null) == 1 and not bool(unknown.get("ok", true)) and str(unknown.get("error", "")).contains("unknown tool"), "未知 tool -> ok:false unknown tool，回显 id")

	var echo_str := _bridge.dispatch_line('{"id":"abc","tool":"get_memory","args":{}}')
	check(str(echo_str.get("id", "")) == "abc" and bool(echo_str.get("ok", false)), "字符串 id 原样回显")

	var bad_block := _bridge.dispatch_line('{"id":2,"tool":"place","args":{"block":"plutonium","cells":[]}}')
	check(not bool(bad_block.get("ok", true)) and str(bad_block.get("error", "")).contains("unknown block"), "未知方块名 -> unknown block")

	var bad_tpl := _bridge.dispatch_line('{"id":3,"tool":"build","args":{"template":"off","x":0,"y":40,"z":0}}')
	check(not bool(bad_tpl.get("ok", true)) and str(bad_tpl.get("error", "")).contains("unknown template"), "off 不是可建模板 -> unknown template")

	# too many cells
	var many := []
	for i in range(5000):
		many.append([0, 40, 0])
	var big_req := {"id": 4, "tool": "place", "args": {"block": "stone", "cells": many}}
	var big := _bridge.dispatch_line(JSON.stringify(big_req))
	check(not bool(big.get("ok", true)) and str(big.get("error", "")).contains("too many cells"), "超 4096 格 -> too many cells")

# ---------- observe ----------
func _test_observe() -> void:
	var r := _ok_result('{"id":10,"tool":"observe","args":{}}')
	check(r.has("pos") and (r["pos"] as Array).size() == 3, "observe 含 pos[3]")
	check(r.has("facing") and (r["facing"] as Dictionary).has("cardinal"), "observe.facing 含 cardinal")
	check(r.has("region") and r.has("region_en"), "observe 含 region + region_en")
	var tod: Dictionary = r.get("time_of_day", {})
	check(tod.has("phase") and tod.has("clock") and tod.has("fraction"), "observe.time_of_day 含 phase/clock/fraction")
	check(r.has("selected_block") and str(r["selected_block"]) != "", "observe.selected_block 为英文别名")
	check((r.get("hotbar", []) as Array).size() == 16, "observe.hotbar 长度 16")
	var hm: Dictionary = r.get("heightmap", {})
	check(int(hm.get("size", 0)) == 16, "observe.heightmap.size == 16")
	var rows: Array = hm.get("rows", [])
	check(rows.size() == 16 and (rows[0] as Array).size() == 16, "observe.heightmap rows 16x16")
	check(r.has("nearby_landmarks") and typeof(r["nearby_landmarks"]) == TYPE_ARRAY, "observe.nearby_landmarks 为数组")
	check(r.has("recent_actions") and typeof(r["recent_actions"]) == TYPE_ARRAY, "observe.recent_actions 为数组")
	# heightmap 中心列应等于 surface_y
	var origin: Array = hm.get("origin", [0, 0])
	var pos: Array = r["pos"]
	var center_col := int(pos[0]) - int(origin[0])
	var center_row := int(pos[2]) - int(origin[1])
	if center_col >= 0 and center_col < 16 and center_row >= 0 and center_row < 16:
		var sy_map := int((rows[center_row] as Array)[center_col])
		var sy_world := int(_main.world.surface_y(int(pos[0]), int(pos[2])))
		check(sy_map == sy_world, "observe.heightmap 中心列 == surface_y")

# ---------- get_block + place ----------
func _test_get_block_and_place() -> void:
	# 在玩家头顶高空选一处空旷的 cell（不挡玩家），放置石头并回读
	var p: Vector3 = _main.player.global_position
	var bx := int(floor(p.x)) + 5
	var by := int(floor(p.y)) + 6
	var bz := int(floor(p.z)) + 5
	_main.world.set_block(bx, by, bz, BlockLibrary.AIR)

	var before := _ok_result('{"id":20,"tool":"get_block","args":{"x":%d,"y":%d,"z":%d}}' % [bx, by, bz])
	check(str(before.get("block", "")) == "air", "放置前 get_block 读到 air")

	var place_args := {"id": 21, "tool": "place", "args": {"block": "stone", "cells": [[bx, by, bz]]}}
	var pr := _ok_result(JSON.stringify(place_args))
	check(int(pr.get("changed", 0)) == 1, "place 1 格 -> changed 1")
	check(str(pr.get("block", "")) == "stone", "place 回显英文别名 stone")
	check(int(_main.world.get_block(bx, by, bz)) == BlockLibrary.STONE, "世界里确实写入 stone")

	var after := _ok_result('{"id":22,"tool":"get_block","args":{"x":%d,"y":%d,"z":%d}}' % [bx, by, bz])
	check(str(after.get("block", "")) == "stone" and bool(after.get("solid", false)), "放置后 get_block 读到 solid stone")

	# 接受中文名
	var cn_args := {"id": 23, "tool": "place", "args": {"block": "玻璃", "cells": [[bx, by + 1, bz]]}}
	var cnr := _ok_result(JSON.stringify(cn_args))
	check(int(cnr.get("changed", 0)) == 1 and int(_main.world.get_block(bx, by + 1, bz)) == BlockLibrary.GLASS, "place 接受中文方块名（玻璃）")

	# 越界 y 被跳过（不计入 changed）
	var oob := {"id": 24, "tool": "place", "args": {"block": "stone", "cells": [[bx, 200, bz]]}}
	var oobr := _ok_result(JSON.stringify(oob))
	check(int(oobr.get("changed", 0)) == 0 and int(oobr.get("requested", -1)) == 1, "越界 y 不计入 changed")

# ---------- break ----------
func _test_break() -> void:
	var p: Vector3 = _main.player.global_position
	var bx := int(floor(p.x)) + 5
	var by := int(floor(p.y)) + 6
	var bz := int(floor(p.z)) + 5
	# 上面 place 已把 (bx,by,bz)=stone, (bx,by+1,bz)=glass
	var br := {"id": 30, "tool": "break", "args": {"cells": [[bx, by, bz], [bx, by + 1, bz]]}}
	var brr := _ok_result(JSON.stringify(br))
	check(int(brr.get("changed", 0)) == 2, "break 2 格 -> changed 2")
	check(int(_main.world.get_block(bx, by, bz)) == BlockLibrary.AIR, "break 后该格为 air")

# ---------- build ----------
func _test_build() -> void:
	var p: Vector3 = _main.player.global_position
	var ax := int(floor(p.x)) + 20
	var az := int(floor(p.z)) + 20
	var ay := int(_main.world.surface_y(ax, az)) + 1
	var args := {"id": 40, "tool": "build", "args": {"template": "campfire", "x": ax, "y": ay, "z": az, "rotation": 0}}
	var r := _ok_result(JSON.stringify(args))
	check(str(r.get("template", "")) == "campfire", "build 回显 template")
	check((r.get("anchor", []) as Array).size() == 3, "build.anchor[3]")
	check(int(r.get("changed", 0)) > 0, "build campfire 放置了方块 (changed>0)")
	# 营火中心应为月石灯（与游戏内模板一致）
	check(int(_main.world.get_block(ax, ay, az)) == BlockLibrary.MOONSTONE_LAMP, "build campfire 中心 == 月石灯（与游戏内模板一致）")
	# build 不应永久改动玩家的模板上下文
	check(_main.player.build_template_id() != "campfire" or _main.player.template_index == 0, "build 后玩家模板上下文已还原")

	var unknown := _bridge.dispatch_line('{"id":41,"tool":"build","args":{"template":"nope","x":0,"y":40,"z":0}}')
	check(not bool(unknown.get("ok", true)) and str(unknown.get("error", "")).contains("unknown template"), "未知模板 -> unknown template")

# ---------- goto + scan ----------
func _test_goto_scan() -> void:
	var p: Vector3 = _main.player.global_position
	var tx := int(floor(p.x)) + 8
	var tz := int(floor(p.z)) - 8
	var gr := _ok_result('{"id":50,"tool":"goto","args":{"x":%d,"z":%d}}' % [tx, tz])
	var gpos: Array = gr.get("pos", [])
	check(gpos.size() == 3 and int(gpos[0]) == tx and int(gpos[2]) == tz, "goto 落点 x/z 命中")
	check(gr.has("surface_y") and gr.has("region_en"), "goto 含 surface_y + region_en")
	# 玩家确实被传送
	check(int(floor(_main.player.global_position.x)) == tx, "goto 后玩家 x 已更新")

	var sr := _ok_result('{"id":51,"tool":"scan","args":{"radius":12}}')
	check((sr.get("center", []) as Array).size() == 2, "scan.center[2]")
	check(int(sr.get("radius", 0)) == 12, "scan.radius==12")
	var sy: Dictionary = sr.get("surface_y", {})
	check(sy.has("min") and sy.has("max") and sy.has("avg") and int(sy["min"]) <= int(sy["max"]), "scan.surface_y min<=max")
	var cols: Dictionary = sr.get("columns", {})
	check(int(cols.get("step", 0)) >= 1, "scan.columns.step>=1")
	var heights: Array = cols.get("height", [])
	check(heights.size() > 0 and heights.size() <= 16, "scan 降采样后网格 <=16 行")
	check(typeof(sr.get("block_histogram", null)) == TYPE_DICTIONARY, "scan.block_histogram 为字典")
	check(typeof(sr.get("regions_present", null)) == TYPE_ARRAY, "scan.regions_present 为数组")
	check(sr.has("water_fraction"), "scan 含 water_fraction")
	# suggested_build_spot 可能为 [x,y,z] 或 null，但应存在键
	check(sr.has("suggested_build_spot"), "scan 含 suggested_build_spot 键")
	# scan radius 上限钳制
	var clamp_r := _ok_result('{"id":52,"tool":"scan","args":{"radius":999}}')
	check(int(clamp_r.get("radius", 0)) == 24, "scan radius 钳制到 24")

# ---------- look + say ----------
func _test_look_say() -> void:
	var lr := _ok_result('{"id":60,"tool":"look","args":{"yaw_deg":90,"pitch_deg":-10}}')
	var facing: Dictionary = lr.get("facing", {})
	check(abs(float(facing.get("yaw_deg", 0)) - 90.0) < 1.0, "look 设置 yaw≈90")
	check(str(facing.get("cardinal", "")) == "E", "yaw 90 -> 朝东 E")
	check(abs(float(facing.get("pitch_deg", 0)) + 10.0) < 1.0, "look 设置 pitch≈-10")
	# pitch 钳制
	var clamp_l := _ok_result('{"id":61,"tool":"look","args":{"pitch_deg":200}}')
	check(float((clamp_l.get("facing", {}) as Dictionary).get("pitch_deg", 0)) <= 80.5, "look pitch 钳制 <=80")

	var say := _ok_result('{"id":62,"tool":"say","args":{"text":"Building a campfire."}}')
	check(bool(say.get("shown", false)), "say -> shown true（经 HUD）")

# ---------- memory ----------
func _test_memory() -> void:
	var sg := _ok_result('{"id":70,"tool":"set_goal","args":{"text":"Restore the shrine."}}')
	check(str(sg.get("goal", "")) == "Restore the shrine.", "set_goal 回显 goal")

	var r1 := _ok_result('{"id":71,"tool":"remember","args":{"text":"Shrine NE near lake."}}')
	check(bool(r1.get("remembered", false)) and int(r1.get("note_count", 0)) == 1, "remember 第 1 条 -> note_count 1")
	var r2 := _ok_result('{"id":72,"tool":"remember","args":{"text":"Built beacon."}}')
	check(int(r2.get("note_count", 0)) == 2, "remember 第 2 条 -> note_count 2")

	var gm := _ok_result('{"id":73,"tool":"get_memory","args":{}}')
	check(str(gm.get("goal", "")) == "Restore the shrine.", "get_memory.goal 一致")
	check((gm.get("notes", []) as Array).size() == 2, "get_memory.notes 含 2 条")
	check(int(gm.get("updated_at", 0)) > 0, "get_memory.updated_at 已写入")

# ---------- recent_actions ----------
func _test_recent_actions() -> void:
	# 前面跑过若干动作型调用（place/break/build/goto/look/say），observe 应能 surface
	var r := _ok_result('{"id":80,"tool":"observe","args":{}}')
	var recent: Array = r.get("recent_actions", [])
	check(recent.size() > 0 and recent.size() <= 8, "observe.recent_actions 在 (0,8] 区间")
	var has_build := false
	for raw in recent:
		var e: Dictionary = raw
		if str(e.get("tool", "")) == "build":
			has_build = true
	check(has_build, "recent_actions 记录了 build 动作")
