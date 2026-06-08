extends RefCounted
# AgentContext —— 代理工具核心(AgentToolCore)的"上下文适配器"集合。
#
# AgentToolCore 的工具逻辑只认抽象 ctx；具体"世界从哪来、身体是谁、聊天/记忆走哪"由这里的
# 适配器实现。本文件提供 LiveAgentContext：包住活的 World/Player(或 AgentAvatar)/HUD/ChatHub +
# 桥持有的记忆，行为与重构前的 AgentBridge 完全一致（这是回归测试的基线）。
#
# 后续会在本文件再加 ServerAgentContext：背后是 WorldData + NetworkManager 虚拟 peer，无任何节点，
# 实现同一套接口即可让同一份工具逻辑跑在无头服务器上。设计这套接口时已确保它不依赖场景树。

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Blueprint = preload("res://scripts/Blueprint.gd")
const Chunk = preload("res://scripts/Chunk.gd")
const AgentMemoryStore = preload("res://scripts/AgentMemoryStore.gd")

const BLUEPRINT_DIR := "user://blueprints"
const MAX_CELLS := 4096
const LOBBY_CHAT_RECENT := 20
const NEARBY_LANDMARK_CAP := 6

# ============================================================================
# LiveAgentContext —— 活节点适配器（localhost 桥）。镜像重构前 AgentBridge 的每一处行为。
# ============================================================================
class LiveAgentContext extends RefCounted:
	var bridge                 # AgentBridge（用其别名表 / 记忆 / chat / discovery / _record_action）
	var world
	var player
	var avatar
	var hud
	var chat_hub
	var read                   # LiveReader
	var body                   # LiveBody
	var memory                 # LiveMemory

	func _init(p_bridge) -> void:
		bridge = p_bridge
		world = p_bridge.world
		player = p_bridge.player
		avatar = p_bridge.avatar
		hud = p_bridge.hud
		chat_hub = p_bridge.chat_hub
		read = LiveReader.new(world)
		body = LiveBody.new(p_bridge)
		memory = LiveMemory.new(p_bridge)

	func world_ready() -> bool:
		return world != null and player != null

	func apply_edits(edits: Array) -> int:
		if world != null and world.has_method("request_block_edits"):
			return int(world.request_block_edits(edits))
		return 0

	# 路由到聊天中枢（若注入）：to 省略=公共大厅；to=名字/id=私聊。再回显到 HUD/玩家反馈。
	func say(text: String, to: String) -> Dictionary:
		var to_label := "lobby"
		if chat_hub != null:
			if to == "":
				chat_hub.post(bridge._current_eid, "", text)
			else:
				chat_hub.post(bridge._current_eid, chat_hub.resolve(to), text)
				to_label = to
		var shown := false
		if hud != null and hud.has_method("show_feedback"):
			hud.show_feedback("agent", text)
			shown = true
		elif player != null and player.has_signal("action_feedback"):
			player.action_feedback.emit("agent", text)
			shown = true
		return {"shown": shown, "to": to_label}

	# 块名 <-> id：复用桥的别名表（启动时已建）。
	func resolve_block(name: String) -> int:
		return bridge._resolve_block(name)

	func alias_for(id: int) -> String:
		return bridge._alias_for(id)

	func hotbar_aliases() -> Array:
		var out := []
		if world != null and world.lib != null:
			for raw in world.lib.hotbar_blocks():
				out.append(bridge._alias_for(int(raw)))
		return out

	func time_info() -> Dictionary:
		var frac: float = bridge._time_fraction()
		return {"fraction": frac, "phase": bridge._time_phase(frac), "clock": bridge._time_clock(frac)}

	func nearby_landmarks() -> Array:
		return bridge._nearby_landmarks()

	func landmarks_in_range(center: Vector3i, radius: float) -> Array:
		return bridge._landmarks_in_range(center, radius)

	# observe 的聊天块：返回 {chat, inbox}（无 chat_hub 则空字典，observe 不带这两键）。
	func chat_observe() -> Dictionary:
		if chat_hub == null:
			return {}
		var eid: String = bridge._current_eid
		var since := int(bridge._since.get(eid, 0))
		var unread: Dictionary = chat_hub.unread_for(eid, since)
		bridge._since[eid] = unread["last_seq"]
		return {"chat": chat_hub.lobby_recent(LOBBY_CHAT_RECENT), "inbox": unread["messages"]}

	func record_action(tool: String, summary: String, ok: bool) -> void:
		bridge._record_action(tool, summary, ok)

	func recent_actions() -> Array:
		return bridge._recent_actions.duplicate(true)

	# goto：同步生成目标区块，让落点立即可踩。
	func prime(x: int, z: int) -> void:
		if world != null and world.has_method("prime") and world.has_method("chunk_of"):
			world.prime(world.chunk_of(x, z), 1)

	# build：AgentAvatar 闪一下，表示"它在这儿盖的"。
	func note_build() -> void:
		if avatar != null:
			avatar.note_build()

	# set_goal 后同步在线状态 + HUD 角标（镜像旧桥行为）。
	func set_goal_status(text: String) -> void:
		if chat_hub != null:
			chat_hub.set_status(bridge._current_eid, text)
		if not bridge._peers.is_empty():
			bridge._notify_agent_status(true)

	# 报名：设当前实体显示名（无 chat_hub 也回 {entity_id,name}）。
	func identify(name: String) -> Dictionary:
		if chat_hub != null and name != "":
			chat_hub.register(bridge._current_eid, name, "agent")
		return {"entity_id": bridge._current_eid, "name": name}

	# 蓝图捕获：长方体 -> 文件。返回 result 或 {"__error":...}。
	func capture_blueprint(a: Vector3i, b: Vector3i, name: String) -> Dictionary:
		var bp: Dictionary = Blueprint.capture(world, a, b)
		var n_blocks := int((bp.get("blocks", {}) as Dictionary).size())
		if n_blocks > MAX_CELLS:
			return {"__error": "too big: %d > %d 块" % [n_blocks, MAX_CELLS]}
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(BLUEPRINT_DIR))
		var path := "%s/%s.json" % [BLUEPRINT_DIR, name]
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			return {"__error": "write failed: " + path}
		f.store_string(Blueprint.serialize(bp))
		f.close()
		return {"name": name, "size": bp.get("size", []), "blocks": n_blocks}

	# 蓝图粘贴：文件 -> 锚点（走正常编辑链路，联机会广播）。返回 result 或 {"__error":...}。
	func paste_blueprint(name: String, anchor: Vector3i) -> Dictionary:
		var path := "%s/%s.json" % [BLUEPRINT_DIR, name]
		if not FileAccess.file_exists(path):
			return {"__error": "no such blueprint: " + name}
		var bp: Dictionary = Blueprint.deserialize(FileAccess.get_file_as_string(path))
		if bp.is_empty():
			return {"__error": "bad blueprint file: " + name}
		var edits: Array = Blueprint.paste_edits(bp, anchor)
		if edits.size() > MAX_CELLS:
			return {"__error": "too big: %d > %d" % [edits.size(), MAX_CELLS]}
		var changed := apply_edits(edits)
		return {"name": name, "anchor": [anchor.x, anchor.y, anchor.z], "changed": changed}


# ---- LiveReader：ctx.read.* -> 活 World ----
class LiveReader extends RefCounted:
	var world
	func _init(p_world) -> void:
		world = p_world
	func surface_y(x: int, z: int) -> int:
		return int(world.surface_y(x, z))
	func region_label(x: int, z: int) -> String:
		return str(world.region_label(x, z))
	func get_block(x: int, y: int, z: int) -> int:
		return int(world.get_block(x, y, z))
	func chunk_of(x: int, z: int) -> Vector2i:
		return world.chunk_of(x, z)
	func is_solid(id: int) -> bool:
		if world.lib != null:
			return bool(world.lib.is_solid(id))
		return false


# ---- LiveBody：ctx.body.* -> 活 AgentAvatar(优先) 或 Player ----
# 镜像旧桥：有 avatar 就驱动它（不动玩家），且 avatar 模式下不读/写俯仰（pitch 恒 0、写入忽略）。
class LiveBody extends RefCounted:
	var bridge
	var player
	var avatar
	func _init(p_bridge) -> void:
		bridge = p_bridge
		player = p_bridge.player
		avatar = p_bridge.avatar

	var eid: String:
		get:
			return str(bridge._current_eid)

	var selected_block_id: int:
		get:
			return int(player.current_block()) if player != null else BlockLibrary.GRASS

	func get_pos() -> Vector3:
		return avatar.global_position if avatar != null else player.global_position

	func set_pos(p: Vector3) -> void:
		if avatar != null:
			avatar.teleport_to(p)              # 移动 AI 小人，不动玩家
		else:
			player.global_position = p
			player.velocity = Vector3.ZERO

	func get_yaw() -> float:
		return avatar.rotation.y if avatar != null else player.rotation.y

	func set_yaw(y: float) -> void:
		if avatar != null:
			avatar.rotation.y = y
		else:
			player.rotation.y = y

	func get_pitch() -> float:
		if avatar != null:
			return 0.0
		return player.pitch

	func set_pitch(p: float) -> void:
		if avatar != null:
			return                              # avatar 模式不改俯仰（镜像旧桥）
		player.pitch = p
		if player.spring != null:
			player.spring.rotation.x = player.pitch


# ---- LiveMemory：ctx.memory.* -> 桥持有的 _memory 字典 + 原子存档 ----
class LiveMemory extends RefCounted:
	var bridge
	func _init(p_bridge) -> void:
		bridge = p_bridge
	func get_goal() -> String:
		return str(bridge._memory.get("goal", ""))
	func set_goal(s: String) -> void:
		bridge._memory["goal"] = s
	func notes() -> Array:
		return bridge._memory.get("notes", []) as Array
	func append_note(s: String) -> void:
		var ns: Array = bridge._memory.get("notes", [])
		ns.append(s)
		while ns.size() > bridge.MEMORY_NOTE_CAP:
			ns.pop_front()
		bridge._memory["notes"] = ns
	func updated_at() -> int:
		return int(bridge._memory.get("updated_at", 0))
	func save() -> void:
		bridge._save_memory()


# ============================================================================
# ServerAgentContext —— 无头服务器适配器：背后只有 WorldData + NetworkManager 虚拟 peer，
# 零场景树、零活节点。实现 AgentToolCore 用到的同一套 ctx 接口，让同一份工具逻辑跑在服务器侧。
# AgentGateway 会 per-token 造一个：ServerAgentContext.new(nm, data, eid, token_hash)。
#
# 与 LiveAgentContext 的对应（行为对齐）：
#   read   -> ServerReader（委托 WorldData + 一个 BlockLibrary 实例做 is_solid）
#   body   -> ServerBody（读写虚拟 peer 的位置/朝向；yaw/pitch/选中块存在 ctx 上）
#   memory -> AgentMemoryStore（按 token_hash 持久化到 user://agent_mem/<hash>.json）
#   say    -> nm.virtual_say  apply_edits -> nm.apply_virtual_edit（走服务器权威校验/reach）
#   landmarks/chat -> 服务器无 DiscoveryTracker；chat 走 nm.chat_hub（无则空）
# ============================================================================
class ServerAgentContext extends RefCounted:
	# id -> 英文别名（契约 §3 固定表，复制自 AgentBridge.BLOCK_ALIASES —— 不修改桥/活上下文）。
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
	const RECENT_ACTIONS_CAP := 8        # 与 AgentBridge.RECENT_ACTIONS_CAP 一致

	var nm                               # NetworkManager（持权威 WorldData + 虚拟 peer）
	var data                             # WorldData（权威世界数据）
	var eid: String                      # 本 agent 的虚拟 peer eid（agent-N）
	var lib                              # BlockLibrary 实例（仅用其纯数值判定，如 is_solid）
	var read                             # ServerReader
	var body                             # ServerBody
	var memory                           # AgentMemoryStore（按 token 持久化）

	var _name_to_id := {}                # 小写英文别名 / 中文 -> id
	var _id_to_alias := {}               # id -> 小写英文别名
	var _recent := []                    # 动作环形缓冲（cap 8），shape 同活桥
	var _display_name := ""              # identify 设定的显示名（best-effort 存这）
	var _time_fraction := 0.5            # 服务器无昼夜系统：默认正午，确定性
	var _chat_since := 0                 # chat_observe 增量游标（上次见过的最大 seq）

	func _init(p_nm, p_data, p_eid: String, token_hash: String) -> void:
		nm = p_nm
		data = p_data
		eid = p_eid
		lib = BlockLibrary.new()
		read = ServerReader.new(p_data, lib)
		body = ServerBody.new(self)
		memory = AgentMemoryStore.new(token_hash)
		_build_block_tables()

	func world_ready() -> bool:
		return data != null

	# 编辑走服务器权威：一次 tool-call 按批量请求限流；每格仍校验 reach / y / no-change。
	func apply_edits(edits: Array) -> int:
		if nm.has_method("apply_virtual_edits"):
			return int(nm.apply_virtual_edits(eid, edits))
		var changed := 0
		for raw in edits:
			var e: Dictionary = raw
			var pos: Vector3i = e["pos"]
			if nm.apply_virtual_edit(eid, pos.x, pos.y, pos.z, int(e["id"])):
				changed += 1
		return changed

	# 说话：经 nm.virtual_say 路由到 chat_hub（to 省略=大厅；否则私聊）。服务器无 HUD，shown 取决于有无 chat_hub。
	func say(text: String, to: String) -> Dictionary:
		var to_label := "lobby"
		var shown := false
		if nm.chat_hub != null:
			nm.virtual_say(eid, text, to)
			shown = true
			if to != "":
				to_label = to
		return {"shown": shown, "to": to_label}

	# 块名 <-> id：用契约固定表（+中文名）服务器侧解析，与活桥同源同语义。
	func resolve_block(name: String) -> int:
		var clean := name.strip_edges()
		if clean == "":
			return -1
		var lower := clean.to_lower()
		if _name_to_id.has(lower):
			return int(_name_to_id[lower])
		if _name_to_id.has(clean):
			return int(_name_to_id[clean])
		return -1

	func alias_for(id: int) -> String:
		return str(_id_to_alias.get(id, "air"))

	# 服务器 agent 无热栏：返回 BlockLibrary 的默认热栏别名（非空字符串数组）。
	func hotbar_aliases() -> Array:
		var out := []
		for raw in lib.hotbar_blocks():
			out.append(alias_for(int(raw)))
		return out

	# 时间：服务器无昼夜系统，用可注入的 fraction（默认正午）算出 {fraction,phase,clock}（三键齐全）。
	func time_info() -> Dictionary:
		var frac: float = fposmod(_time_fraction, 1.0)
		return {"fraction": frac, "phase": _phase_for(frac), "clock": _clock_for(frac)}

	# 服务器无 DiscoveryTracker：地标恒空（observe/scan 仍保留这些键，只是空数组）。
	func nearby_landmarks() -> Array:
		return []

	func landmarks_in_range(_center: Vector3i, _radius: float) -> Array:
		return []

	# observe 的聊天块：有 chat_hub 则返回 {chat, inbox}，否则空字典（observe 不带这两键）。
	func chat_observe() -> Dictionary:
		var hub = nm.chat_hub
		if hub == null:
			return {}
		var since := int(_chat_since)
		var unread: Dictionary = hub.unread_for(eid, since)
		_chat_since = int(unread.get("last_seq", since))
		return {"chat": hub.lobby_recent(LOBBY_CHAT_RECENT), "inbox": unread.get("messages", [])}

	func record_action(tool: String, summary: String, ok: bool) -> void:
		_recent.append({"tool": tool, "summary": summary, "ok": ok})
		while _recent.size() > RECENT_ACTIONS_CAP:
			_recent.pop_front()

	func recent_actions() -> Array:
		return _recent.duplicate(true)

	# goto 的"同步生成落点"：服务器 WorldData 按需即时生成，无需预热 -> no-op。
	func prime(_x: int, _z: int) -> void:
		pass

	# build 的"小人闪一下"：服务器无 avatar 节点 -> no-op。
	func note_build() -> void:
		pass

	# set_goal 后同步在线状态：服务器侧 best-effort 写到 chat_hub 状态（无则 no-op）。
	func set_goal_status(text: String) -> void:
		if nm.chat_hub != null and nm.chat_hub.has_method("set_status"):
			nm.chat_hub.set_status(eid, text)

	# 报名：设当前虚拟 peer 显示名（best-effort）。有 chat_hub 就登记；名字也存在 ctx 上。回 {entity_id,name}。
	func identify(name: String) -> Dictionary:
		_display_name = name
		if nm.chat_hub != null and name != "":
			nm.chat_hub.register(eid, name, "agent")
		return {"entity_id": eid, "name": name}

	# 注：不实现 capture_blueprint / paste_blueprint —— AgentToolCore 的 has_method 守卫会回
	# "not supported by this context"，v1 服务器侧可接受。

	# ---- 内部：块名表 / 时间相位（与活桥同语义）----

	func _build_block_tables() -> void:
		for id in BLOCK_ALIASES.keys():
			var alias := str(BLOCK_ALIASES[id])
			_id_to_alias[int(id)] = alias
			_name_to_id[alias] = int(id)
		# 从 BlockLibrary 补中文名（creative + hotbar），仅对有定义的方块
		var ids := {}
		ids[BlockLibrary.AIR] = true
		for raw in lib.creative_blocks():
			ids[int(raw)] = true
		for raw in lib.hotbar_blocks():
			ids[int(raw)] = true
		for id in ids.keys():
			var cn := ""
			if lib.has_def(int(id)):
				cn = str(lib.block_name(int(id)))
			elif int(id) == BlockLibrary.AIR:
				cn = "空气"
			if cn != "":
				_name_to_id[cn] = int(id)

	func _phase_for(frac: float) -> String:
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

	func _clock_for(frac: float) -> String:
		var total := fmod(frac * 24.0, 24.0)
		var h := int(total)
		var m := int((total - float(h)) * 60.0)
		return "%02d:%02d" % [h, m]


# ---- ServerReader：ctx.read.* -> WorldData（+ BlockLibrary 实例做 is_solid）----
class ServerReader extends RefCounted:
	var data
	var lib
	func _init(p_data, p_lib) -> void:
		data = p_data
		lib = p_lib
	func surface_y(x: int, z: int) -> int:
		return int(data.surface_y(x, z))
	func region_label(x: int, z: int) -> String:
		return str(data.region_label(x, z))
	func get_block(x: int, y: int, z: int) -> int:
		return int(data.get_block(x, y, z))
	func chunk_of(x: int, z: int) -> Vector2i:
		return data.chunk_of(x, z)
	func is_solid(id: int) -> bool:
		return bool(lib.is_solid(id))


# ---- ServerBody：ctx.body.* -> NetworkManager 虚拟 peer（位置写回 nm；yaw/pitch/选中块存 ctx）----
class ServerBody extends RefCounted:
	var ctx                              # ServerAgentContext（拿 nm/eid + 存 yaw/pitch/选中块）
	var selected_block_id: int = BlockLibrary.STONE
	var _yaw := 0.0
	var _pitch := 0.0
	func _init(p_ctx) -> void:
		ctx = p_ctx

	var eid: String:
		get:
			return str(ctx.eid)

	# 当前格：从 nm 读虚拟 peer 位置（peer_position 找不到回 INF 哨兵；此处由调用方保证 peer 在线）。
	func get_pos() -> Vector3:
		return ctx.nm.peer_position(ctx.eid)

	# 写位置：必须写回 nm —— 否则服务器权威按旧位置做 reach 校验会拒绝远处编辑（goto 后 place 的关键）。
	func set_pos(p: Vector3) -> void:
		ctx.nm.update_virtual_peer(ctx.eid, p, _yaw)

	func get_yaw() -> float:
		return _yaw

	func set_yaw(y: float) -> void:
		_yaw = y
		# yaw 同步到 nm（位置不变），让快照里别人看到 agent 转向
		ctx.nm.update_virtual_peer(ctx.eid, get_pos(), _yaw)

	func get_pitch() -> float:
		return _pitch

	func set_pitch(p: float) -> void:
		_pitch = p
