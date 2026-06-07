extends SceneTree
# 验证 AgentToolCore（节点无关的工具核心）：用一个 FakeCtx（背后是真实 WorldData + 内存小人）
# 驱动 AgentToolCore.handle(tool, args, ctx)，断言真实行为——不经任何场景树/活节点。
# 这正是 Agent Gateway 的关键：同一套工具逻辑既能跑在 localhost 桥（活 World/Player/HUD），
# 也能跑在无头服务器（WorldData + 虚拟 peer，无节点）。
#   godot --headless --path <项目> --script res://tests/test_agent_tool_core.gd

const AgentToolCore = preload("res://scripts/AgentToolCore.gd")
const WorldData = preload("res://scripts/WorldData.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const BuildTemplates = preload("res://scripts/BuildTemplates.gd")

var failed := 0

func check(c: bool, m: String) -> void:
	if c:
		print("  ok   ", m)
	else:
		failed += 1
		printerr("  FAIL ", m)

# ---------------- FakeReader：把 ctx.read.* 委托到真实 WorldData ----------------
class FakeReader extends RefCounted:
	var data
	var lib
	func _init(d, l) -> void:
		data = d
		lib = l
	func surface_y(x: int, z: int) -> int:
		return data.surface_y(x, z)
	func region_label(x: int, z: int) -> String:
		return data.region_label(x, z)
	func get_block(x: int, y: int, z: int) -> int:
		return data.get_block(x, y, z)
	func chunk_of(x: int, z: int) -> Vector2i:
		return data.chunk_of(x, z)
	func is_solid(id: int) -> bool:
		return lib.is_solid(id)

# ---------------- FakeBody：内存小人（无节点）----------------
class FakeBody extends RefCounted:
	var eid := "fake-agent"
	var selected_block_id := BlockLibrary.GRASS
	var _pos := Vector3(0.5, 40.0, 0.5)
	var _yaw := 0.0
	var _pitch := 0.0
	func get_pos() -> Vector3:
		return _pos
	func set_pos(p: Vector3) -> void:
		_pos = p
	func get_yaw() -> float:
		return _yaw
	func set_yaw(y: float) -> void:
		_yaw = y
	func get_pitch() -> float:
		return _pitch
	func set_pitch(p: float) -> void:
		_pitch = p

# ---------------- FakeMemory：内存记忆（无文件）----------------
class FakeMemory extends RefCounted:
	var _goal := ""
	var _notes := []
	var saved := false
	func get_goal() -> String:
		return _goal
	func set_goal(s: String) -> void:
		_goal = s
	func notes() -> Array:
		return _notes
	func append_note(s: String) -> void:
		_notes.append(s)
	func updated_at() -> int:
		return 0
	func save() -> void:
		saved = true

# ---------------- FakeCtx：实现 AgentToolCore 期望的上下文接口 ----------------
class FakeCtx extends RefCounted:
	var read
	var body
	var memory
	var lib
	var data
	var said := []                       # say 路由记录
	var _recent := []
	func _init(d, l) -> void:
		data = d
		lib = l
		read = FakeReader.new(d, l)
		body = FakeBody.new()
		memory = FakeMemory.new()
	func world_ready() -> bool:
		return true
	func apply_edits(edits: Array) -> int:
		var n := 0
		for raw in edits:
			var e: Dictionary = raw
			var pos: Vector3i = e["pos"]
			if data.apply_edit_local(pos.x, pos.y, pos.z, int(e["id"])).size() > 0:
				n += 1
		return n
	func say(text: String, to: String) -> Dictionary:
		said.append({"text": text, "to": to})
		return {"shown": true, "to": (to if to != "" else "lobby")}
	# ---- 块名解析（活桥里走别名表；这里直接用 BlockLibrary） ----
	func resolve_block(name: String) -> int:
		var clean := name.strip_edges().to_lower()
		var table := {
			"air": 0, "grass": 1, "dirt": 2, "stone": 3, "cobblestone": 4, "log": 5,
			"planks": 6, "sand": 7, "glass": 8, "water": 9,
		}
		return int(table.get(clean, -1))
	func alias_for(id: int) -> String:
		var table := {
			0: "air", 1: "grass", 2: "dirt", 3: "stone", 4: "cobblestone", 5: "log",
			6: "planks", 7: "sand", 8: "glass", 9: "water",
		}
		return str(table.get(id, "air"))
	func hotbar_aliases() -> Array:
		return ["grass", "dirt", "stone"]
	# ---- observe 的"活场景"信息：服务器/测试给确定性桩 ----
	func time_info() -> Dictionary:
		return {"fraction": 0.30, "phase": "morning", "clock": "07:12"}
	func nearby_landmarks() -> Array:
		return []
	func landmarks_in_range(_center: Vector3i, _radius: float) -> Array:
		return []
	func chat_observe() -> Dictionary:
		return {}
	# ---- 动作环形缓冲（活桥里在 bridge 上；这里本地存） ----
	func record_action(tool: String, summary: String, ok: bool) -> void:
		_recent.append({"tool": tool, "summary": summary, "ok": ok})
		while _recent.size() > 8:
			_recent.pop_front()
	func recent_actions() -> Array:
		return _recent.duplicate(true)
	# ---- goto 同步生成 / avatar 提示：服务器/测试为 no-op ----
	func prime(_x: int, _z: int) -> void:
		pass
	func note_build() -> void:
		pass

func _initialize() -> void:
	var data := WorldData.new(1337, "infinite")
	var lib := BlockLibrary.new()
	var ctx := FakeCtx.new(data, lib)

	# observe: ok + 含 pos
	var obs := AgentToolCore.handle("observe", {}, ctx)
	check(bool(obs.get("ok", false)), "observe ok")
	var obs_r: Dictionary = obs.get("result", {})
	check(obs_r.has("pos") and (obs_r["pos"] as Array).size() == 3, "observe 含 pos[3]")

	# goto: 移动小人
	var gx := 12
	var gz := -7
	var go := AgentToolCore.handle("goto", {"x": gx, "z": gz}, ctx)
	check(bool(go.get("ok", false)), "goto ok")
	check(int(floor(ctx.body.get_pos().x)) == gx and int(floor(ctx.body.get_pos().z)) == gz, "goto 移动了 body")

	# place: 写世界（在高空选空格）
	var px := 4
	var py := int(data.surface_y(px, 4)) + 8
	var pz := 4
	var pl := AgentToolCore.handle("place", {"block": "stone", "cells": [[px, py, pz]]}, ctx)
	check(bool(pl.get("ok", false)), "place ok")
	check(int((pl.get("result", {}) as Dictionary).get("changed", 0)) == 1, "place changed 1")
	check(int(data.get_block(px, py, pz)) == BlockLibrary.STONE, "place 写入了 stone 到 WorldData")

	# build: 营火中心 == 月石灯
	var bx := 30
	var bz := 30
	var by := int(data.surface_y(bx, bz)) + 1
	var bd := AgentToolCore.handle("build", {"template": "campfire", "x": bx, "y": by, "z": bz}, ctx)
	check(bool(bd.get("ok", false)), "build ok")
	check(int((bd.get("result", {}) as Dictionary).get("changed", 0)) > 0, "build 放置了方块")
	check(int(data.get_block(bx, by, bz)) == BlockLibrary.MOONSTONE_LAMP, "build campfire 中心 == MOONSTONE_LAMP")

	# say: 路由到 ctx
	var sy := AgentToolCore.handle("say", {"text": "hello world"}, ctx)
	check(bool(sy.get("ok", false)), "say ok")
	check(ctx.said.size() == 1 and str(ctx.said[0]["text"]) == "hello world", "say 路由到了 ctx")

	# unknown tool 被拒
	var unk := AgentToolCore.handle("fooberry", {}, ctx)
	check(not bool(unk.get("ok", true)) and str(unk.get("error", "")).contains("unknown tool"), "未知 tool 被拒")

	# set_goal: echoes goal text
	var sg := AgentToolCore.handle("set_goal", {"text": "build a tower"}, ctx)
	check(bool(sg.get("ok", false)), "set_goal ok")
	check(str((sg.get("result", {}) as Dictionary).get("goal", "")) == "build a tower", "set_goal 回显 goal")

	# remember: note_count increments
	var rm := AgentToolCore.handle("remember", {"text": "first note"}, ctx)
	check(bool(rm.get("ok", false)), "remember ok")
	check(int((rm.get("result", {}) as Dictionary).get("note_count", 0)) == 1, "remember note_count == 1")

	# get_memory: returns goal + notes
	var gm := AgentToolCore.handle("get_memory", {}, ctx)
	check(bool(gm.get("ok", false)), "get_memory ok")
	var gm_r: Dictionary = gm.get("result", {})
	check(str(gm_r.get("goal", "")) == "build a tower", "get_memory 含 goal")
	check((gm_r.get("notes", []) as Array).size() == 1, "get_memory notes.size == 1")

	# scan: returns center and surface_y shape
	var sc := AgentToolCore.handle("scan", {"radius": 4}, ctx)
	check(bool(sc.get("ok", false)), "scan ok")
	var sc_r: Dictionary = sc.get("result", {})
	check(sc_r.has("center") and (sc_r["center"] as Array).size() == 2, "scan 含 center[2]")
	check(sc_r.has("surface_y") and (sc_r["surface_y"] as Dictionary).has("min"), "scan 含 surface_y.min")

	# break: clears a placed cell to air
	var brk := AgentToolCore.handle("break", {"cells": [[px, py, pz]]}, ctx)
	check(bool(brk.get("ok", false)), "break ok")
	check(int((brk.get("result", {}) as Dictionary).get("changed", 0)) == 1, "break changed 1")
	check(int(data.get_block(px, py, pz)) == BlockLibrary.AIR, "break 清除了方块")

	# get_block: returns block alias + solid flag
	var gb := AgentToolCore.handle("get_block", {"x": px, "y": py, "z": pz}, ctx)
	check(bool(gb.get("ok", false)), "get_block ok")
	var gb_r: Dictionary = gb.get("result", {})
	check(str(gb_r.get("block", "")) == "air", "get_block alias == air (after break)")
	check(gb_r.has("solid"), "get_block 含 solid")

	# look: sets and clamps yaw/pitch
	var lk := AgentToolCore.handle("look", {"yaw_deg": 90.0, "pitch_deg": 45.0}, ctx)
	check(bool(lk.get("ok", false)), "look ok")
	var lk_r: Dictionary = lk.get("result", {})
	var facing: Dictionary = lk_r.get("facing", {})
	check(absf(float(facing.get("yaw_deg", -1.0)) - 90.0) < 1.0, "look yaw ~= 90")
	check(float(facing.get("pitch_deg", 0.0)) <= 80.0, "look pitch clamp <= 80")

	if failed == 0:
		print("✅ ALL AGENT TOOL CORE TESTS PASSED")
	else:
		printerr("❌ ", failed, " agent-tool-core failures")
	quit(0 if failed == 0 else 1)
