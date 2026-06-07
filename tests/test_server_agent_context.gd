extends SceneTree
# 验证 ServerAgentContext（无头服务器适配器）：用真实 WorldData + NetworkManager 虚拟 peer
# 背后驱动同一套 AgentToolCore.handle(tool, args, ctx)——零场景树、零活节点。
# 这把 AgentToolCore 真正跑在服务器侧：下一个任务的 AgentGateway 会 per-token 造一个
# ServerAgentContext.new(nm, data, eid, token_hash) 再调 handle()。
#   godot --headless --path <项目> --script res://tests/test_server_agent_context.gd

const AgentToolCore = preload("res://scripts/AgentToolCore.gd")
const AgentContext = preload("res://scripts/AgentContext.gd")
const NetworkManager = preload("res://scripts/NetworkManager.gd")
const WorldData = preload("res://scripts/WorldData.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const ChatHub = preload("res://scripts/ChatHub.gd")

var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	# 每次跑前清掉 token 记忆文件，保证 "持久化跨上下文" 断言确定性。
	var mem_path := "user://agent_mem/tok-hash-1.json"
	if FileAccess.file_exists(mem_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(mem_path))

	var data := WorldData.new(1337)
	var nm := NetworkManager.new(); nm.mode = NetworkManager.Mode.SERVER
	nm.set_authority_data(data, 1337, Vector3(8, data.surface_y(8, 8) + 2, 8))
	var eid := nm.register_virtual_peer("Tester")
	var ctx = AgentContext.ServerAgentContext.new(nm, data, eid, "tok-hash-1")

	# ---- observe：ready + 含 region ----
	var ob: Dictionary = AgentToolCore.handle("observe", {}, ctx)
	check(bool(ob.get("ok", false)) and (ob["result"] as Dictionary).has("region"), "server observe ok")
	# observe 必带这些键（即便服务器无地标/聊天，键也要在或为空数组）
	var ob_r: Dictionary = ob.get("result", {})
	check(ob_r.has("nearby_landmarks") and (ob_r["nearby_landmarks"] as Array).is_empty(), "observe nearby_landmarks 空数组")
	check((ob_r.get("time_of_day", {}) as Dictionary).has("phase"), "observe time_of_day.phase 存在")
	check((ob_r.get("hotbar", []) as Array).size() > 0, "observe hotbar 非空")

	# ---- goto：移动虚拟 peer（必须写回 nm，否则 place 的 reach 会拒绝）----
	AgentToolCore.handle("goto", {"x": 30, "z": 30}, ctx)
	check(int(floor(nm.peer_position(eid).x)) == 30, "goto 把虚拟 peer 移到了 x=30")

	# ---- place：写真实 WorldData，reach 内接受 ----
	var bx := 30; var bz := 30; var by := data.surface_y(30, 30) + 1
	var pl: Dictionary = AgentToolCore.handle("place", {"block": "stone", "cells": [[bx, by, bz]]}, ctx)
	check(int((pl["result"] as Dictionary).get("changed", 0)) == 1, "server place changed 1")
	check(int(data.get_block(bx, by, bz)) == BlockLibrary.STONE, "server place wrote stone")
	check(str((pl["result"] as Dictionary).get("block", "")) == "stone", "place 回显别名 stone")

	# ---- 超出 reach 的 place 被服务器权威拒绝 ----
	var far: Dictionary = AgentToolCore.handle("place", {"block": "stone", "cells": [[600, by, 600]]}, ctx)
	check(int((far["result"] as Dictionary).get("changed", 0)) == 0, "far place rejected by reach")

	# ---- 未知块名被拒 ----
	var bad: Dictionary = AgentToolCore.handle("place", {"block": "unobtainium", "cells": [[bx, by + 1, bz]]}, ctx)
	check(not bool(bad.get("ok", true)) and str(bad.get("error", "")).contains("unknown block"), "未知块名被拒")

	# ---- build：模板写入真实世界（营火中心 == 月石灯）----
	var tbx := 34; var tbz := 34; var tby := data.surface_y(tbx, tbz) + 1
	AgentToolCore.handle("goto", {"x": tbx, "z": tbz}, ctx)
	var bd: Dictionary = AgentToolCore.handle("build", {"template": "campfire", "x": tbx, "y": tby, "z": tbz}, ctx)
	check(bool(bd.get("ok", false)) and int((bd["result"] as Dictionary).get("changed", 0)) > 0, "server build 放置方块")
	check(int(data.get_block(tbx, tby, tbz)) == BlockLibrary.MOONSTONE_LAMP, "build campfire 中心 == MOONSTONE_LAMP")

	# ---- get_block：读真实世界，含 alias + solid ----
	var gb: Dictionary = AgentToolCore.handle("get_block", {"x": bx, "y": by, "z": bz}, ctx)
	check(str((gb["result"] as Dictionary).get("block", "")) == "stone", "get_block 读到 stone")
	check(bool((gb["result"] as Dictionary).get("solid", false)), "get_block solid=true")

	# ---- scan：含 center + surface_y.min ----
	var sc: Dictionary = AgentToolCore.handle("scan", {"radius": 4}, ctx)
	var sc_r: Dictionary = sc.get("result", {})
	check(sc_r.has("center") and (sc_r["center"] as Array).size() == 2, "scan 含 center[2]")
	check((sc_r.get("surface_y", {}) as Dictionary).has("min"), "scan 含 surface_y.min")
	check((sc_r.get("landmarks_in_range", []) as Array).is_empty(), "scan landmarks_in_range 空")

	# ---- say：经 nm.virtual_say 路由到 chat_hub（注入后）----
	var hub := ChatHub.new()
	var nm2 := NetworkManager.new(); nm2.mode = NetworkManager.Mode.SERVER
	nm2.chat_hub = hub
	nm2.set_authority_data(data, 1337, Vector3(8, data.surface_y(8, 8) + 2, 8))
	var eid2 := nm2.register_virtual_peer("Talker")
	var ctx_say = AgentContext.ServerAgentContext.new(nm2, data, eid2, "tok-hash-say")
	var sa: Dictionary = AgentToolCore.handle("say", {"text": "hello from server"}, ctx_say)
	check(bool(sa.get("ok", false)) and str((sa["result"] as Dictionary).get("to", "")) == "lobby", "say -> lobby ok")
	var recent: Array = hub.lobby_recent(5)
	check(recent.size() >= 1 and str((recent[-1] as Dictionary).get("text", "")) == "hello from server", "say 进了 chat_hub 大厅")

	# ---- identify：设虚拟 peer 显示名（best-effort），回 {entity_id,name} ----
	var idr: Dictionary = AgentToolCore.handle("identify", {"name": "Builder42"}, ctx)
	check(str((idr["result"] as Dictionary).get("entity_id", "")) == eid, "identify 回 entity_id == eid")
	check(str((idr["result"] as Dictionary).get("name", "")) == "Builder42", "identify 回 name")

	# ---- remember：note_count 递增 ----
	var rm: Dictionary = AgentToolCore.handle("remember", {"text": "first server note"}, ctx)
	check(int((rm["result"] as Dictionary).get("note_count", 0)) == 1, "remember note_count == 1")

	# ---- set_goal + 跨上下文按 token 持久化（核心断言）----
	AgentToolCore.handle("set_goal", {"text": "Build a tower"}, ctx)
	var ctx2 = AgentContext.ServerAgentContext.new(nm, data, eid, "tok-hash-1")
	var gm: Dictionary = AgentToolCore.handle("get_memory", {}, ctx2)
	check(str((gm["result"] as Dictionary).get("goal", "")) == "Build a tower", "memory persists across context by token")
	# 同一 token 的 notes 也应被新上下文读到
	check((gm["result"] as Dictionary).get("notes", []).has("first server note"), "notes 也按 token 持久化")

	# ---- 不同 token 互不串记忆 ----
	var ctx_other = AgentContext.ServerAgentContext.new(nm, data, eid, "tok-hash-other")
	var gm_o: Dictionary = AgentToolCore.handle("get_memory", {}, ctx_other)
	check(str((gm_o["result"] as Dictionary).get("goal", "")) != "Build a tower", "不同 token 记忆隔离")

	if failed == 0: print("✅ ALL SERVER AGENT CONTEXT TESTS PASSED")
	else: printerr("❌ ", failed, " server-agent-context failures")
	quit(0 if failed == 0 else 1)
