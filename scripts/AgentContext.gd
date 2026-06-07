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
