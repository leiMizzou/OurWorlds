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
const AgentToolCore = preload("res://scripts/AgentToolCore.gd")
const AgentContext = preload("res://scripts/AgentContext.gd")

const DEFAULT_PORT := 8970
const RECENT_ACTIONS_CAP := 8
const MEMORY_PATH := "user://agent_memory.json"
const MEMORY_NOTE_CAP := 50
const NEARBY_LANDMARK_CAP := 6
const NEARBY_LANDMARK_RANGE := 64.0
const DEFAULT_EID := "agent"         # 无实体上下文（如直接测试调用）时的默认实体 id

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
# 注：中文地貌标签 -> 英文别名（REGION_ALIASES）已随工具逻辑迁入 AgentToolCore。

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
# 工具逻辑已抽到节点无关的 AgentToolCore；这里只负责构造活节点上下文(LiveAgentContext)、
# 委托执行、再补上响应信封的 id。bridge 仍是 localhost 的活适配器。
func dispatch(rid: Variant, tool: String, args: Dictionary, eid: String = DEFAULT_EID) -> Dictionary:
	_current_eid = eid
	var ctx := AgentContext.LiveAgentContext.new(self)
	var res := AgentToolCore.handle(tool, args, ctx)
	res["id"] = rid
	return res

# ============ 旧工具实现已迁移至 AgentToolCore；以下辅助由 LiveAgentContext 委托调用（仍是活节点适配器） ============

# ============ 辅助：感知（LiveAgentContext 用） ============

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

# ============ 辅助：动作（LiveAgentContext 用） ============

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
