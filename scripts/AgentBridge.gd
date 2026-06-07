extends Node
# OurWorlds 代理桥（Agent Control Contract v1）
# 让外部 LLM 代理（经 OpenClaw / MCP 桥）以"语义/高层"方式感知并操作运行中的游戏。
#
# 传输：纯 TCP（非 WebSocket/HTTP），换行分隔 JSON（NDJSON），单客户端，回环 127.0.0.1。
# 端口：环境变量 OW_AGENT_PORT，未设置则桥保持禁用（不监听）。
# 线程：TCP 轮询 + 行解析 + 分发 + 回写，全部在主线程 _process 里同步完成
#       —— 处理器直接触碰活节点(World/Player/场景树)是安全的。World.request_block_edits
#       内部已把造网格丢到 WorkerThreadPool，所以同步调用不卡主线程。
#
# 由 Main 注入 world / player(+hud) 引用；每个工具映射到这些节点上已存在的方法。

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")
const Blueprint = preload("res://scripts/Blueprint.gd")
const BLUEPRINT_DIR := "user://blueprints"

const DEFAULT_PORT := 8970
const MAX_CELLS := 4096
const RECENT_ACTIONS_CAP := 8
const MEMORY_PATH := "user://agent_memory.json"
const MEMORY_NOTE_CAP := 50
const SY := Chunk.SY                 # 96
const NEARBY_LANDMARK_CAP := 6
const NEARBY_LANDMARK_RANGE := 64.0
const DEFAULT_EID := "agent"         # 无实体上下文（如直接测试调用）时的默认实体 id
const LOBBY_CHAT_RECENT := 20        # observe.chat 返回的最近大厅消息条数

# 注入引用（Main 在 _ready 末尾设置）
var world
var player
var avatar                           # opc-ourworlds 的专属小人；有它就驱动它（而不是玩家）
var hud
var chat_hub                         # ChatHub（Main 注入；为空则无聊天/在线列表功能）

var _server: TCPServer
var _peers := []                     # [{sock, buf, eid}] —— 多客户端，每连接一个实体
var _entity_counter := 0
var _current_eid := DEFAULT_EID      # 当前正在分发请求的实体（dispatch 时设置）
var _since := {}                     # eid -> 已读到的聊天 seq（observe.inbox 增量用）
var _recent_actions := []            # 近期"动作型"调用环形缓冲（<=8），surface 进 observe
var _memory := {"version": 1, "goal": "", "notes": [], "updated_at": 0}
var _port := 0

# 方块名 <-> id 解析表（启动时建一次）
var _name_to_id := {}                # 小写英文别名 / 中文 -> id
var _id_to_alias := {}               # id -> 小写英文别名

# id -> 英文别名（固定表，契约 §3）
const BLOCK_ALIASES := {
	0: "air", 1: "grass", 2: "dirt", 3: "stone", 4: "cobblestone", 5: "log",
	6: "planks", 7: "sand", 8: "glass", 9: "water", 10: "leaves", 11: "snow",
	12: "coal_ore", 13: "iron_ore", 14: "brick", 15: "mossy_stone", 16: "basalt",
	17: "marble", 18: "lantern", 19: "wildflower", 20: "tall_grass", 21: "pine_leaves",
	22: "copper_ore", 23: "red_mushroom", 24: "reeds", 25: "blue_crystal", 26: "clay",
	27: "moonstone_lamp", 28: "polished_iron", 29: "copper_panel", 30: "steel_block",
	31: "gold_trim", 32: "red_sand", 33: "terracotta", 34: "sunstone",
	35: "neon_cyan", 36: "neon_magenta", 37: "neon_lime", 38: "rail",
}

# 中文地貌标签 -> 英文别名（契约 §6）
const REGION_ALIASES := {
	"草原": "meadow", "风草原": "windswept_plains", "花海草甸": "flower_meadow",
	"针叶林": "taiga", "苔林": "mossy_forest", "沙漠": "desert",
	"红土台地": "mesa", "岩岭": "rocky_ridge", "玄武岩岭": "basalt_ridge",
	"雪峰": "snow_peaks", "湿地": "wetland", "沙岸": "sandy_shore",
	"黏土滩": "clay_flat", "浅水湾": "shallow_cove",
	# 主题岛扇区
	"雪山": "snow_mountain", "热带海岸": "tropical_coast",
	"村庄": "village", "中央广场": "central_plaza",
	"霓虹城": "neon_city", "天文台": "observatory",
	"农田": "farmland", "海湾": "bay", "虚空": "void",
}

func _ready() -> void:
	_load_memory()
	_build_block_tables()
	if not OS.has_environment("OW_AGENT_PORT"):
		return   # 未启用：不监听（agent 控制是 opt-in）
	_port = int(OS.get_environment("OW_AGENT_PORT"))
	if _port <= 0:
		return
	_server = TCPServer.new()
	var err := _server.listen(_port, "127.0.0.1")
	if err != OK:
		push_warning("AgentBridge 监听失败 127.0.0.1:%d（err=%d）" % [_port, err])
		_server = null
		return
	print_verbose("AgentBridge 监听 127.0.0.1:%d" % _port)

func _exit_tree() -> void:
	for peer in _peers:
		if peer["sock"] != null:
			peer["sock"].disconnect_from_host()
	_peers.clear()
	if _server != null:
		_server.stop()
		_server = null

func _process(_delta: float) -> void:
	if _server == null:
		return
	# 接受新连接（多客户端）：每个连接 = 一个在线实体。
	while _server.is_connection_available():
		var sock := _server.take_connection()
		var eid := _next_eid()
		_peers.append({"sock": sock, "buf": PackedByteArray(), "eid": eid})
		if chat_hub != null:
			chat_hub.register(eid, eid, "agent")
		_notify_agent_status(true)
	var i := 0
	while i < _peers.size():
		var peer: Dictionary = _peers[i]
		var sock: StreamPeerTCP = peer["sock"]
		sock.poll()
		var status := sock.get_status()
		if status == StreamPeerTCP.STATUS_ERROR or status == StreamPeerTCP.STATUS_NONE:
			_drop_peer_at(i)
			continue
		if status != StreamPeerTCP.STATUS_CONNECTED:
			i += 1
			continue
		var available := sock.get_available_bytes()
		if available > 0:
			var chunk := sock.get_data(available)
			if int(chunk[0]) == OK:
				var b: PackedByteArray = peer["buf"]
				b.append_array(chunk[1] as PackedByteArray)
				peer["buf"] = b
		_process_peer_buffer(peer)
		i += 1

# 从某 peer 的读缓冲切出完整行（\n 分隔），以该 peer 的实体身份逐行分发并回写。残留半行留到下一帧。
func _process_peer_buffer(peer: Dictionary) -> void:
	var buf: PackedByteArray = peer["buf"]
	while true:
		var nl := buf.find(10)   # '\n'
		if nl < 0:
			break
		var line_bytes := buf.slice(0, nl)
		buf = buf.slice(nl + 1)
		var line := line_bytes.get_string_from_utf8().strip_edges()
		if line != "":
			_send_line(peer["sock"], dispatch_line(line, str(peer["eid"])))
	peer["buf"] = buf

func _send_line(sock: StreamPeerTCP, obj: Dictionary) -> void:
	if sock == null:
		return
	sock.put_data((JSON.stringify(obj) + "\n").to_utf8_buffer())

func _drop_peer_at(i: int) -> void:
	if i < 0 or i >= _peers.size():
		return
	var peer: Dictionary = _peers[i]
	if peer["sock"] != null:
		peer["sock"].disconnect_from_host()
	if chat_hub != null:
		chat_hub.unregister(str(peer["eid"]))
	_since.erase(str(peer["eid"]))
	_peers.remove_at(i)
	_notify_agent_status(not _peers.is_empty())

func _next_eid() -> String:
	_entity_counter += 1
	return "agent-%d" % _entity_counter

# 通知 HUD 显示/隐藏「agent 已连接」角标（hud 由 Main 注入；未注入则静默跳过）。
func _notify_agent_status(connected: bool) -> void:
	if hud != null and hud.has_method("set_agent_status"):
		hud.set_agent_status(connected, str(_memory.get("goal", "")))

# ---------- 分发（直接可测：测试不经 TCP，直接喂一行 JSON 文本）----------
func dispatch_line(line: String, eid: String = DEFAULT_EID) -> Dictionary:
	# 用 JSON 实例 parse()（返回错误码、不向 stderr 打印）—— 坏行只返回 bad json，流不断、日志不脏。
	var parser := JSON.new()
	var err := parser.parse(line)
	if err != OK:
		return {"id": null, "ok": false, "error": "bad json: " + parser.get_error_message()}
	var parsed: Variant = parser.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"id": null, "ok": false, "error": "bad json: expected object"}
	var req: Dictionary = parsed
	var rid: Variant = req.get("id", null)
	if not req.has("tool"):
		return {"id": rid, "ok": false, "error": "bad args: tool (missing)"}
	var tool := str(req.get("tool", ""))
	var args_raw: Variant = req.get("args", {})
	var args: Dictionary = args_raw if typeof(args_raw) == TYPE_DICTIONARY else {}
	return dispatch(rid, tool, args, eid)

# 直接分发（给测试 / TCP 共用）。eid = 调用方实体。返回完整响应信封。
func dispatch(rid: Variant, tool: String, args: Dictionary, eid: String = DEFAULT_EID) -> Dictionary:
	_current_eid = eid
	var result := _handle(tool, args)
	if result.has("__error"):
		return {"id": rid, "ok": false, "error": str(result["__error"])}
	return {"id": rid, "ok": true, "result": result}

func _err(msg: String) -> Dictionary:
	return {"__error": msg}

func _ready_for_acting() -> bool:
	return world != null and player != null

# 工具分发表。返回 result Dictionary，或 {"__error": "..."}。
func _handle(tool: String, args: Dictionary) -> Dictionary:
	match tool:
		"observe":
			return _tool_observe(args)
		"identify":
			return _tool_identify(args)
		"look":
			return _tool_look(args)
		"goto":
			return _tool_goto(args)
		"scan":
			return _tool_scan(args)
		"place":
			return _tool_place(args)
		"break":
			return _tool_break(args)
		"build":
			return _tool_build(args)
		"capture_build":
			return _tool_capture_build(args)
		"paste_build":
			return _tool_paste_build(args)
		"get_block":
			return _tool_get_block(args)
		"say":
			return _tool_say(args)
		"set_goal":
			return _tool_set_goal(args)
		"remember":
			return _tool_remember(args)
		"get_memory":
			return _tool_get_memory(args)
		_:
			return _err("unknown tool: " + tool)

# ============ 工具实现 ============

func _tool_observe(args: Dictionary) -> Dictionary:
	if not _ready_for_acting():
		return {"ready": false}
	var hsize := int(args.get("heightmap_size", 16))
	if hsize <= 0 or hsize > 16:
		hsize = 16
	if hsize % 2 != 0:
		hsize -= 1
	var pos := _player_cell()
	var yaw_deg := _player_yaw_deg()
	var pitch_deg := _player_pitch_deg()
	var region := str(world.region_label(pos.x, pos.z))
	var frac := _time_fraction()
	var half := int(hsize / 2)
	var origin_x := pos.x - half
	var origin_z := pos.z - half
	var rows := []
	for r in range(hsize):
		var row := []
		for c in range(hsize):
			row.append(int(world.surface_y(origin_x + c, origin_z + r)))
		rows.append(row)
	var result := {
		"pos": [pos.x, pos.y, pos.z],
		"facing": {
			"yaw_deg": yaw_deg,
			"pitch_deg": pitch_deg,
			"cardinal": _cardinal_from_yaw(yaw_deg),
		},
		"region": region,
		"region_en": _region_alias(region),
		"time_of_day": {
			"fraction": snappedf(frac, 0.01),
			"phase": _time_phase(frac),
			"clock": _time_clock(frac),
		},
		"selected_block": _alias_for(player.current_block()),
		"hotbar": _hotbar_aliases(),
		"heightmap": {
			"size": hsize,
			"origin": [origin_x, origin_z],
			"rows": rows,
		},
		"nearby_landmarks": _nearby_landmarks(),
		"recent_actions": _recent_actions.duplicate(true),
	}
	if chat_hub != null:
		result["chat"] = chat_hub.lobby_recent(LOBBY_CHAT_RECENT)
		var since := int(_since.get(_current_eid, 0))
		var unread: Dictionary = chat_hub.unread_for(_current_eid, since)
		result["inbox"] = unread["messages"]
		_since[_current_eid] = unread["last_seq"]
	return result

func _tool_look(args: Dictionary) -> Dictionary:
	if not _ready_for_acting():
		return _err("world not ready")
	if args.has("yaw_deg"):
		var yaw := fposmod(float(args["yaw_deg"]), 360.0)
		if avatar != null:
			avatar.rotation.y = deg_to_rad(yaw)
		else:
			player.rotation.y = deg_to_rad(yaw)
	if args.has("pitch_deg") and avatar == null:
		var pitch_deg := clampf(float(args["pitch_deg"]), -80.0, 80.0)
		player.pitch = clampf(deg_to_rad(pitch_deg), -1.4, 1.4)
		if player.spring != null:
			player.spring.rotation.x = player.pitch
	var yaw_now := _player_yaw_deg()
	var pitch_now := _player_pitch_deg()
	var facing := {"yaw_deg": yaw_now, "pitch_deg": pitch_now, "cardinal": _cardinal_from_yaw(yaw_now)}
	_record_action("look", "yaw %.0f pitch %.0f" % [yaw_now, pitch_now], true)
	return {"facing": facing}

func _tool_goto(args: Dictionary) -> Dictionary:
	if not _ready_for_acting():
		return _err("world not ready")
	if not args.has("x") or not args.has("z"):
		return _err("bad args: x/z (required)")
	var x := int(args["x"])
	var z := int(args["z"])
	var sy := int(world.surface_y(x, z))
	var place_y := sy + 1
	if args.has("y"):
		place_y = clampi(int(args["y"]), 0, SY - 1)
	# 让目标点立即可踩（同步生成该处区块）
	if world.has_method("prime") and world.has_method("chunk_of"):
		world.prime(world.chunk_of(x, z), 1)
	var dest := Vector3(float(x) + 0.5, float(place_y), float(z) + 0.5)
	if avatar != null:
		avatar.teleport_to(dest)              # 移动 AI 小人，不动玩家
	else:
		player.global_position = dest
		player.velocity = Vector3.ZERO
	var region := str(world.region_label(x, z))
	_record_action("goto", "-> (%d,%d,%d)" % [x, place_y, z], true)
	return {
		"pos": [x, place_y, z],
		"region": region,
		"region_en": _region_alias(region),
		"surface_y": sy,
	}

func _tool_scan(args: Dictionary) -> Dictionary:
	if not _ready_for_acting():
		return _err("world not ready")
	var radius := int(args.get("radius", 8))
	radius = clampi(radius, 1, 24)
	var center := _player_cell()
	var span := 2 * radius + 1
	var step := int(ceil(float(span) / 16.0))
	if step < 1:
		step = 1
	var origin_x := center.x - radius
	var origin_z := center.z - radius
	var heights := []
	var surface_blocks := []
	var histogram := {}
	var regions_seen := {}
	var min_y := 1 << 30
	var max_y := -(1 << 30)
	var sum_y := 0
	var count := 0
	var water_cols := 0
	# 平整度评估：记录每个采样列高度，找局部方差小的列做建议建造点
	var best_spot: Variant = null
	var best_variance := 1 << 30
	var z := origin_z
	while z <= center.z + radius:
		var hrow := []
		var brow := []
		var x := origin_x
		while x <= center.x + radius:
			var sy := int(world.surface_y(x, z))
			hrow.append(sy)
			min_y = mini(min_y, sy)
			max_y = maxi(max_y, sy)
			sum_y += sy
			count += 1
			var top_id := int(world.get_block(x, sy, z))
			var alias := _alias_for(top_id)
			brow.append(alias)
			histogram[alias] = int(histogram.get(alias, 0)) + 1
			if alias == "water":
				water_cols += 1
			var rlabel := str(world.region_label(x, z))
			if rlabel != "":
				regions_seen[rlabel] = true
			# 局部高度方差（与四个 step 邻居比），找平地
			var variance := absi(sy - int(world.surface_y(x + step, z))) \
				+ absi(sy - int(world.surface_y(x - step, z))) \
				+ absi(sy - int(world.surface_y(x, z + step))) \
				+ absi(sy - int(world.surface_y(x, z - step)))
			if variance < best_variance or (variance == best_variance and best_spot == null):
				best_variance = variance
				best_spot = [x, sy + 1, z]
			x += step
		heights.append(hrow)
		surface_blocks.append(brow)
		z += step
	var avg_y := int(round(float(sum_y) / float(maxi(1, count))))
	var regions_present := regions_seen.keys()
	regions_present.sort()
	return {
		"center": [center.x, center.z],
		"radius": radius,
		"surface_y": {"min": min_y, "max": max_y, "avg": avg_y},
		"columns": {
			"step": step,
			"origin": [origin_x, origin_z],
			"height": heights,
			"surface_block": surface_blocks,
		},
		"block_histogram": histogram,
		"regions_present": regions_present,
		"water_fraction": snappedf(float(water_cols) / float(maxi(1, count)), 0.01),
		"landmarks_in_range": _landmarks_in_range(center, float(radius)),
		"suggested_build_spot": best_spot,
	}

func _tool_place(args: Dictionary) -> Dictionary:
	if not _ready_for_acting():
		return _err("world not ready")
	if not args.has("block"):
		return _err("bad args: block (required)")
	var block_name := str(args["block"])
	var id := _resolve_block(block_name)
	if id < 0:
		return _err("unknown block: " + block_name)
	var cells_raw: Variant = args.get("cells", [])
	if typeof(cells_raw) != TYPE_ARRAY:
		return _err("bad args: cells (expected array)")
	var cells: Array = cells_raw
	if cells.size() > MAX_CELLS:
		return _err("too many cells: %d > %d" % [cells.size(), MAX_CELLS])
	var edits := _cells_to_edits(cells, id)
	var changed := 0
	if world.has_method("request_block_edits"):
		changed = int(world.request_block_edits(edits))
	_record_action("place", "%s x%d @ %d cells" % [_id_to_alias.get(id, block_name), changed, cells.size()], true)
	return {"requested": cells.size(), "changed": changed, "block": _id_to_alias.get(id, block_name)}

func _tool_break(args: Dictionary) -> Dictionary:
	if not _ready_for_acting():
		return _err("world not ready")
	var cells_raw: Variant = args.get("cells", [])
	if typeof(cells_raw) != TYPE_ARRAY:
		return _err("bad args: cells (expected array)")
	var cells: Array = cells_raw
	if cells.size() > MAX_CELLS:
		return _err("too many cells: %d > %d" % [cells.size(), MAX_CELLS])
	var edits := _cells_to_edits(cells, BlockLibrary.AIR)
	var changed := 0
	if world.has_method("request_block_edits"):
		changed = int(world.request_block_edits(edits))
	_record_action("break", "cleared %d / %d cells" % [changed, cells.size()], true)
	return {"requested": cells.size(), "changed": changed}

func _tool_build(args: Dictionary) -> Dictionary:
	if not _ready_for_acting():
		return _err("world not ready")
	if not args.has("template"):
		return _err("bad args: template (required)")
	var template := str(args["template"])
	if template == "off" or template == "":
		return _err("unknown template: " + template)
	if not player.has_method("apply_build_template"):
		return _err("world not ready")
	if not args.has("x") or not args.has("y") or not args.has("z"):
		return _err("bad args: x/y/z (required)")
	var x := int(args["x"])
	var y := int(args["y"])
	var z := int(args["z"])
	var rotation := _rotation_to_index(args.get("rotation", 0))
	var origin := Vector3i(x, y, z)
	var changed := int(player.apply_build_template(template, origin, rotation))
	if changed < 0:
		return _err("unknown template: " + template)
	if avatar != null:
		avatar.note_build()                  # 小人闪一下，表示"它在这儿盖的"
	_record_action("build", "%s @ (%d,%d,%d)" % [template, x, y, z], true)
	return {"template": template, "anchor": [x, y, z], "rotation": rotation, "changed": changed}

# 捕获一块长方体区域存成蓝图文件（可分享/异地重现）：args name + x1,y1,z1, x2,y2,z2
func _tool_capture_build(args: Dictionary) -> Dictionary:
	if not _ready_for_acting():
		return _err("world not ready")
	var name := str(args.get("name", "")).strip_edges()
	if name == "" or not name.is_valid_filename():
		return _err("bad args: name (required, 须为合法文件名)")
	for k in ["x1", "y1", "z1", "x2", "y2", "z2"]:
		if not args.has(k):
			return _err("bad args: x1/y1/z1/x2/y2/z2 (required)")
	var a := Vector3i(int(args["x1"]), int(args["y1"]), int(args["z1"]))
	var b := Vector3i(int(args["x2"]), int(args["y2"]), int(args["z2"]))
	var bp: Dictionary = Blueprint.capture(world, a, b)
	var n_blocks := int((bp.get("blocks", {}) as Dictionary).size())
	if n_blocks > MAX_CELLS:
		return _err("too big: %d > %d 块" % [n_blocks, MAX_CELLS])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BLUEPRINT_DIR))
	var path := "%s/%s.json" % [BLUEPRINT_DIR, name]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _err("write failed: " + path)
	f.store_string(Blueprint.serialize(bp))
	f.close()
	_record_action("capture_build", "%s (%d 块)" % [name, n_blocks], true)
	return {"name": name, "size": bp.get("size", []), "blocks": n_blocks}

# 把蓝图贴到锚点（走正常编辑链路，联机会广播）：args name + x,y,z
func _tool_paste_build(args: Dictionary) -> Dictionary:
	if not _ready_for_acting():
		return _err("world not ready")
	var name := str(args.get("name", "")).strip_edges()
	if name == "" or not name.is_valid_filename():
		return _err("bad args: name (required)")
	for k in ["x", "y", "z"]:
		if not args.has(k):
			return _err("bad args: x/y/z (required)")
	var path := "%s/%s.json" % [BLUEPRINT_DIR, name]
	if not FileAccess.file_exists(path):
		return _err("no such blueprint: " + name)
	var bp: Dictionary = Blueprint.deserialize(FileAccess.get_file_as_string(path))
	if bp.is_empty():
		return _err("bad blueprint file: " + name)
	var anchor := Vector3i(int(args["x"]), int(args["y"]), int(args["z"]))
	var edits: Array = Blueprint.paste_edits(bp, anchor)
	if edits.size() > MAX_CELLS:
		return _err("too big: %d > %d" % [edits.size(), MAX_CELLS])
	var changed := 0
	if world.has_method("request_block_edits"):
		changed = int(world.request_block_edits(edits))
	_record_action("paste_build", "%s @ (%d,%d,%d) -> %d 块" % [name, anchor.x, anchor.y, anchor.z, changed], true)
	return {"name": name, "anchor": [anchor.x, anchor.y, anchor.z], "changed": changed}

func _tool_get_block(args: Dictionary) -> Dictionary:
	if not _ready_for_acting():
		return _err("world not ready")
	if not args.has("x") or not args.has("y") or not args.has("z"):
		return _err("bad args: x/y/z (required)")
	var x := int(args["x"])
	var y := int(args["y"])
	var z := int(args["z"])
	var id := 0
	if y >= 0 and y < SY:
		id = int(world.get_block(x, y, z))
	var solid := false
	if world.lib != null:
		solid = bool(world.lib.is_solid(id))
	return {"pos": [x, y, z], "block": _alias_for(id), "solid": solid}

func _tool_say(args: Dictionary) -> Dictionary:
	var text := str(args.get("text", "")).strip_edges()
	if text.length() > 120:
		text = text.substr(0, 120)
	# 路由到聊天中枢（若注入）：to 省略=公共大厅；to=名字/id=私聊。
	var to_label := "lobby"
	if chat_hub != null:
		var to_raw := str(args.get("to", "")).strip_edges()
		if to_raw == "":
			chat_hub.post(_current_eid, "", text)
		else:
			chat_hub.post(_current_eid, chat_hub.resolve(to_raw), text)
			to_label = to_raw
	var shown := false
	if hud != null and hud.has_method("show_feedback"):
		hud.show_feedback("agent", text)
		shown = true
	elif player != null and player.has_signal("action_feedback"):
		player.action_feedback.emit("agent", text)
		shown = true
	_record_action("say", text, shown)
	return {"shown": shown, "to": to_label}

func _tool_set_goal(args: Dictionary) -> Dictionary:
	var text := str(args.get("text", "")).strip_edges()
	if text.length() > 200:
		text = text.substr(0, 200)
	_memory["goal"] = text
	_save_memory()
	if chat_hub != null:
		chat_hub.set_status(_current_eid, text)
	if not _peers.is_empty():
		_notify_agent_status(true)
	return {"goal": text}

func _tool_remember(args: Dictionary) -> Dictionary:
	var text := str(args.get("text", "")).strip_edges()
	if text.length() > 280:
		text = text.substr(0, 280)
	var notes: Array = _memory.get("notes", [])
	notes.append(text)
	while notes.size() > MEMORY_NOTE_CAP:
		notes.pop_front()
	_memory["notes"] = notes
	_save_memory()
	return {"remembered": true, "note_count": notes.size()}

func _tool_get_memory(_args: Dictionary) -> Dictionary:
	return {
		"goal": str(_memory.get("goal", "")),
		"notes": (_memory.get("notes", []) as Array).duplicate(),
		"updated_at": int(_memory.get("updated_at", 0)),
	}

# 报名：设置当前实体在在线列表里的显示名（连接后调用；默认名为 agent-N）。
func _tool_identify(args: Dictionary) -> Dictionary:
	var name := str(args.get("name", "")).strip_edges()
	if name.length() > 40:
		name = name.substr(0, 40)
	if chat_hub != null and name != "":
		chat_hub.register(_current_eid, name, "agent")
	return {"entity_id": _current_eid, "name": name}

# ============ 辅助：感知 ============

func _player_cell() -> Vector3i:
	var p: Vector3 = avatar.global_position if avatar != null else player.global_position
	return Vector3i(floori(p.x), floori(p.y), floori(p.z))

func _player_yaw_deg() -> float:
	var yaw: float = avatar.rotation.y if avatar != null else player.rotation.y
	return fposmod(rad_to_deg(yaw), 360.0)

func _player_pitch_deg() -> float:
	if avatar != null:
		return 0.0
	return rad_to_deg(player.pitch)

func _cardinal_from_yaw(yaw_deg: float) -> String:
	# yaw 0 = 面朝 -Z (北)。顺时针每 45° 一档。
	var labels := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var idx := int(round(yaw_deg / 45.0)) % 8
	return labels[idx]

func _time_fraction() -> float:
	var main := get_parent()
	if main != null:
		var t: Variant = main.get("_time")
		if typeof(t) == TYPE_FLOAT or typeof(t) == TYPE_INT:
			return fposmod(float(t), 1.0)
	return 0.30

func _time_phase(frac: float) -> String:
	if frac < 0.20 or frac >= 0.85:
		return "night"
	if frac < 0.28:
		return "dawn"
	if frac < 0.42:
		return "morning"
	if frac < 0.58:
		return "noon"
	if frac < 0.75:
		return "afternoon"
	return "dusk"

func _time_clock(frac: float) -> String:
	var total := fmod(frac * 24.0, 24.0)
	var h := int(total)
	var m := int((total - float(h)) * 60.0)
	return "%02d:%02d" % [h, m]

func _region_alias(label: String) -> String:
	return str(REGION_ALIASES.get(label, label))

func _hotbar_aliases() -> Array:
	var out := []
	if world.lib != null:
		for raw in world.lib.hotbar_blocks():
			out.append(_alias_for(int(raw)))
	return out

func _alias_for(id: int) -> String:
	return str(_id_to_alias.get(id, "air"))

# 附近地标（observe）：先取已发现地标，再补 DiscoveryTracker 的"附近提示" + 扫描周边区块里未发现锚点。
func _nearby_landmarks() -> Array:
	var tracker: Variant = _discovery_tracker()
	var origin: Vector3 = player.global_position
	var found := []
	var seen := {}
	# 已发现
	if tracker != null and tracker.has_method("discovered_entries"):
		for raw in tracker.discovered_entries():
			var entry: Dictionary = raw
			var pos := _entry_pos(entry)
			if pos.y < 0:
				continue
			var key := "%d,%d,%d" % [pos.x, pos.y, pos.z]
			if seen.has(key):
				continue
			seen[key] = true
			var restore := 0
			if world.has_method("landmark_restoration"):
				restore = int(world.landmark_restoration(pos).get("percent", 0))
			found.append(_landmark_dict(str(entry.get("label", "古遗迹")), pos, origin, true, restore))
	# 未发现：附近提示
	if tracker != null and tracker.has_method("nearby_hint_position") and tracker.has_method("nearby_hint_distance"):
		if int(tracker.nearby_hint_distance()) >= 0:
			var hint_pos: Vector3 = tracker.nearby_hint_position()
			var cell := Vector3i(floori(hint_pos.x), floori(hint_pos.y), floori(hint_pos.z))
			var key := "%d,%d,%d" % [cell.x, cell.y, cell.z]
			if not seen.has(key):
				seen[key] = true
				found.append(_landmark_dict("附近地标", cell, origin, false, 0))
	found.sort_custom(func(a, b) -> bool:
		return int(a.get("distance", 999999)) < int(b.get("distance", 999999))
	)
	if found.size() > NEARBY_LANDMARK_CAP:
		found.resize(NEARBY_LANDMARK_CAP)
	return found

func _landmarks_in_range(center: Vector3i, radius: float) -> Array:
	var tracker: Variant = _discovery_tracker()
	var origin: Vector3 = player.global_position
	var out := []
	if tracker != null and tracker.has_method("discovered_entries"):
		for raw in tracker.discovered_entries():
			var entry: Dictionary = raw
			var pos := _entry_pos(entry)
			if pos.y < 0:
				continue
			var dist := Vector2(float(pos.x - center.x), float(pos.z - center.z)).length()
			if dist > radius:
				continue
			var restore := 0
			if world.has_method("landmark_restoration"):
				restore = int(world.landmark_restoration(pos).get("percent", 0))
			var d := _landmark_dict(str(entry.get("label", "古遗迹")), pos, origin, true, restore)
			d.erase("restoration_percent")  # scan 口径只要 label/pos/distance/discovered
			d.erase("direction")
			out.append(d)
	out.sort_custom(func(a, b) -> bool:
		return int(a.get("distance", 999999)) < int(b.get("distance", 999999))
	)
	return out

func _landmark_dict(label: String, pos: Vector3i, origin: Vector3, discovered: bool, restore_percent: int) -> Dictionary:
	var center := Vector3(pos) + Vector3(0.5, 0.5, 0.5)
	var dist := int(round(center.distance_to(origin)))
	return {
		"label": label,
		"pos": [pos.x, pos.y, pos.z],
		"distance": dist,
		"direction": _compass_dir(center - origin),
		"discovered": discovered,
		"restoration_percent": restore_percent,
	}

func _compass_dir(delta: Vector3) -> String:
	var flat := Vector2(delta.x, delta.z)
	if flat.length_squared() < 0.001:
		return "N"
	# +X=east, +Z=south, -Z=north。angle 以北为 0，顺时针。
	var ang := rad_to_deg(atan2(delta.x, -delta.z))
	return _cardinal_from_yaw(fposmod(ang, 360.0))

func _entry_pos(entry: Dictionary) -> Vector3i:
	var raw_pos: Variant = entry.get("world_pos", null)
	if typeof(raw_pos) == TYPE_VECTOR3I:
		return raw_pos
	if typeof(raw_pos) == TYPE_VECTOR3:
		var p: Vector3 = raw_pos
		return Vector3i(int(round(p.x)), int(round(p.y)), int(round(p.z)))
	var pos_text := str(entry.get("pos", ""))
	var parts := pos_text.split(",")
	if parts.size() == 3:
		return Vector3i(int(parts[0].strip_edges()), int(parts[1].strip_edges()), int(parts[2].strip_edges()))
	return Vector3i(0, -1, 0)

func _discovery_tracker():
	var main := get_parent()
	if main == null:
		return null
	var dt: Variant = main.get("discovery_tracker")
	return dt

# ============ 辅助：动作 ============

func _cells_to_edits(cells: Array, id: int) -> Array:
	var edits := []
	for raw in cells:
		var cell: Variant = _to_vec3i(raw)
		if cell == null:
			continue
		var c: Vector3i = cell
		if c.y < 0 or c.y >= SY:
			continue
		edits.append({"pos": c, "id": id})
	return edits

func _to_vec3i(raw: Variant):
	if typeof(raw) == TYPE_ARRAY:
		var arr: Array = raw
		if arr.size() == 3:
			return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))
	if typeof(raw) == TYPE_VECTOR3I:
		return raw
	if typeof(raw) == TYPE_VECTOR3:
		var v: Vector3 = raw
		return Vector3i(int(v.x), int(v.y), int(v.z))
	return null

func _rotation_to_index(raw: Variant) -> int:
	var val := int(raw)
	# 接受 0/1，或角度 0/90/180/270（偶=0，奇=1）
	if val == 0 or val == 1:
		return val
	var steps := int(round(float(val) / 90.0))
	return posmod(steps, 2)

func _record_action(tool: String, summary: String, ok: bool) -> void:
	_recent_actions.append({"tool": tool, "summary": summary, "ok": ok})
	while _recent_actions.size() > RECENT_ACTIONS_CAP:
		_recent_actions.pop_front()

# ============ 方块名 <-> id ============

func _build_block_tables() -> void:
	# 别名表（契约固定）
	for id in BLOCK_ALIASES.keys():
		var alias := str(BLOCK_ALIASES[id])
		_id_to_alias[int(id)] = alias
		_name_to_id[alias] = int(id)
	# 从 BlockLibrary 补中文名（creative + hotbar），并校正 id->alias 仅对有定义的方块
	var lib_inst = world.lib if (world != null and world.lib != null) else BlockLibrary.new()
	var ids := {}
	ids[BlockLibrary.AIR] = true
	for raw in lib_inst.creative_blocks():
		ids[int(raw)] = true
	for raw in lib_inst.hotbar_blocks():
		ids[int(raw)] = true
	for id in ids.keys():
		var cn := ""
		if lib_inst.has_def(int(id)):
			cn = str(lib_inst.block_name(int(id)))
		elif int(id) == BlockLibrary.AIR:
			cn = "空气"
		if cn != "":
			_name_to_id[cn] = int(id)

# 返回 id，未知返回 -1。接受英文别名(大小写不敏感、去空格)或中文名。
func _resolve_block(name: String) -> int:
	var clean := name.strip_edges()
	if clean == "":
		return -1
	var lower := clean.to_lower()
	if _name_to_id.has(lower):
		return int(_name_to_id[lower])
	if _name_to_id.has(clean):
		return int(_name_to_id[clean])
	return -1

# ============ 记忆持久化 ============

func _load_memory() -> void:
	_memory = {"version": 1, "goal": "", "notes": [], "updated_at": 0}
	if not FileAccess.file_exists(MEMORY_PATH):
		return
	var text := FileAccess.get_file_as_string(MEMORY_PATH)
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	_memory["goal"] = str(data.get("goal", ""))
	var notes := []
	var raw_notes: Variant = data.get("notes", [])
	if typeof(raw_notes) == TYPE_ARRAY:
		for n in raw_notes:
			notes.append(str(n))
	while notes.size() > MEMORY_NOTE_CAP:
		notes.pop_front()
	_memory["notes"] = notes
	_memory["updated_at"] = int(data.get("updated_at", 0))

func _save_memory() -> void:
	_memory["updated_at"] = int(Time.get_unix_time_from_system())
	var text := JSON.stringify(_memory, "\t")
	# 原子写：临时文件 + 改名（镜像 World._write_save_text 的稳妥做法）
	var tmp := MEMORY_PATH + ".tmp"
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var abs_dst := ProjectSettings.globalize_path(MEMORY_PATH)
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(abs_tmp)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
	if FileAccess.file_exists(MEMORY_PATH):
		DirAccess.remove_absolute(abs_dst)
	DirAccess.rename_absolute(abs_tmp, abs_dst)
