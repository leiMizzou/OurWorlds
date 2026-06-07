extends Node
# OurWorlds 联机管理器（M1：本地权威联机）。
# 设计要点（详见 docs/superpowers/plans/2026-06-06-m1-local-coop.md）：
#   - 权威核心（校验/写入/打包）是纯方法，作用在注入的 WorldData 上，可无头单测；
#     真正的 socket/RPC 在 Phase B 接上，跟核心解耦（镜像 AgentBridge.dispatch 的可测性）。
#   - 服务器直接持有 WorldData（无 World 节点、不造网格）；HOST/CLIENT 用 World._data。
const WorldData = preload("res://scripts/WorldData.gd")
const Chunk = preload("res://scripts/Chunk.gd")

enum Mode { OFFLINE, SERVER, CLIENT, HOST }

signal welcomed(payload: Dictionary)

const DEFAULT_PORT := 8971
const PLAYER_REACH := 8.0          # 服务器校验：编辑点离该玩家的最大水平+垂直距离（基础防作弊）
const PLAYER_REACH_MARGIN := 1.0   # 手臂/视角补偿：允许编辑脚下/眼前紧邻一格
const EDIT_RATE_WINDOW := 1.0      # 频率限制窗口（秒）
const EDIT_RATE_MAX := 96          # 每窗口每 peer 最多接受的编辑次数

var mode: Mode = Mode.OFFLINE
var world                          # World 节点（CLIENT/HOST）；SERVER 为空
var player                         # 本地玩家（CLIENT/HOST）；SERVER 为空
var chat_hub                       # ChatHub（可空）
var avatar_factory: Callable = Callable()   # () -> Node3D，生成 RemoteAvatar；测试用桩

var _data: WorldData               # 权威数据（SERVER/HOST）
var _seed: int = 1337
var _spawn: Vector3 = Vector3.ZERO
var _peers := {}                   # peer_id:int -> {eid, name, pos:Vector3, yaw:float, edits:Array[float]}
var _eid_counter := 0
var _vpeer_counter := 0            # 虚拟 peer 计数器（负 id 占位）
var _self_eid := ""                # 本端自己的 eid（CLIENT/HOST）；快照里跳过它
var _avatars := {}                 # eid -> RemoteAvatar 节点（CLIENT）
var report_node: Node3D = null     # 客户端上报哪个节点的位置：默认玩家；agent-client 设成 agent 小人，
                                   # 这样服务器按 agent 实际位置校验编辑、别人也看见 agent 走动

func set_authority_data(data: WorldData, world_seed: int, spawn: Vector3) -> void:
	_data = data
	_seed = world_seed
	_spawn = spawn

func register_peer(peer_id: int, display_name: String) -> String:
	_eid_counter += 1
	var eid := "player-%d" % _eid_counter
	var nm := display_name.strip_edges()
	if nm == "":
		nm = eid
	_peers[peer_id] = {"eid": eid, "name": nm, "pos": _scatter_spawn(_eid_counter), "yaw": 0.0, "edits": []}
	if chat_hub != null:
		chat_hub.register(eid, nm, "human")
	return eid

# 给第 index 个登记的玩家一个绕基准出生点散开的落点——避免大家叠在同一格而"互相看不见"。
# 黄金角均匀铺开 + 贴合该处地表；无权威数据时退回基准点。
func _scatter_spawn(index: int) -> Vector3:
	if _data == null or index <= 0:
		return _spawn
	var slot := index % 16                          # 循环槽位，避免长期运行越散越远
	var golden := 2.39996323                        # 黄金角(rad)，均匀不扎堆
	var radius := 2.5 + 0.9 * sqrt(float(slot))
	var sx := _spawn.x + cos(golden * float(slot)) * radius
	var sz := _spawn.z + sin(golden * float(slot)) * radius
	var sy := float(_data.surface_y(roundi(sx), roundi(sz))) + 2.0
	return Vector3(sx, sy, sz)

func drop_peer(peer_id: int) -> void:
	if not _peers.has(peer_id):
		return
	var eid := str(_peers[peer_id]["eid"])
	if chat_hub != null:
		chat_hub.unregister(eid)
	_peers.erase(peer_id)

func set_peer_transform(peer_id: int, pos: Vector3, yaw: float) -> void:
	if not _peers.has(peer_id):
		return
	_peers[peer_id]["pos"] = pos
	_peers[peer_id]["yaw"] = yaw

# 某玩家当前位置（"去找ta"用）。客户端从收到的快照 avatar 取；服务器/HOST 从 _peers 取。
# 找不到返回 INF 哨兵（调用方据此判断该 eid 是否在线）。
func peer_position(eid: String) -> Vector3:
	if _avatars.has(eid) and is_instance_valid(_avatars[eid]):
		return (_avatars[eid] as Node3D).global_position
	for pid in _peers:
		if str(_peers[pid]["eid"]) == eid:
			return _peers[pid]["pos"]
	return Vector3(INF, INF, INF)

func peer_eids() -> Array:
	var out := []
	for pid in _peers:
		out.append(str(_peers[pid]["eid"]))
	out.sort()
	return out

# 服务器权威：校验一条编辑请求，合法则写入 WorldData 并返回广播载荷。
# now<0 时用真实时钟（运行时）；测试可显式传 now 以测频率限制。
func authorize_edit(peer_id: int, wx: int, wy: int, wz: int, id: int, now: float = -1.0) -> Dictionary:
	if not _peers.has(peer_id):
		return {"ok": false, "reason": "unknown peer"}
	if wy < 0 or wy >= Chunk.SY:
		return {"ok": false, "reason": "y out of range"}
	var ppos: Vector3 = _peers[peer_id]["pos"]
	var d := Vector3(float(wx) + 0.5, float(wy) + 0.5, float(wz) + 0.5) - ppos
	if absf(d.x) > PLAYER_REACH + PLAYER_REACH_MARGIN or absf(d.y) > PLAYER_REACH + PLAYER_REACH_MARGIN or absf(d.z) > PLAYER_REACH + PLAYER_REACH_MARGIN:
		return {"ok": false, "reason": "out of reach"}
	if not _accept_rate(peer_id, now):
		return {"ok": false, "reason": "rate limited"}
	var affected: Array = _data.apply_edit_local(wx, wy, wz, id)
	if affected.is_empty():
		return {"ok": false, "reason": "no change"}
	var cc := _data.chunk_of(wx, wz)
	var aff_out := []
	for c in affected:
		aff_out.append([c.x, c.y])
	# 注：revision 仅为主区块 cc；客户端 apply_remote_edit 会自行重算邻块，跨区块 revision 同步留到 M5。
	return {
		"ok": true,
		"pos": [wx, wy, wz],
		"id": id,
		"revision": _data.chunk_revision(cc),
		"affected": aff_out,
	}

# 每 peer 的滑动窗口频率限制。now<0 用真实时钟。
func _accept_rate(peer_id: int, now: float) -> bool:
	var t := now
	if t < 0.0:
		t = float(Time.get_ticks_msec()) / 1000.0
	var edits: Array = _peers[peer_id]["edits"]
	var keep := []
	for ts in edits:
		if t - float(ts) < EDIT_RATE_WINDOW:
			keep.append(ts)
	if keep.size() >= EDIT_RATE_MAX:
		_peers[peer_id]["edits"] = keep
		return false
	keep.append(t)
	_peers[peer_id]["edits"] = keep
	return true

# 服务器：给一个刚连进来的 peer 打包入场信息（种子+出生点+本端 eid+在线名册+全部增量）。
# M1 世界小，直接发全部 delta；兴趣管理（按区块按需发）是 M5。
# ---- 服务器世界存档（本地文件，JSON 增量；世界重启不丢。按种子另存）----
func save_world(path: String) -> bool:
	if _data == null or path == "":
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": SAVE_VERSION, "kind": world_kind, "seed": _seed, "edits": _data.all_deltas()}))
	f.close()
	return true

func load_world(path: String) -> bool:
	if _data == null or path == "" or not FileAccess.file_exists(path):
		return false
	var p := JSON.new()
	if p.parse(FileAccess.get_file_as_string(path)) != OK:
		return false
	var raw: Variant = p.data
	if typeof(raw) != TYPE_DICTIONARY:
		return false
	world_kind = str((raw as Dictionary).get("kind", world_kind))
	var edits: Variant = (raw as Dictionary).get("edits", {})
	if typeof(edits) == TYPE_DICTIONARY:
		_data.load_deltas(edits)
	return true

func build_welcome(peer_id: int) -> Dictionary:
	var roster := []
	for pid in _peers:
		var p: Dictionary = _peers[pid]
		var pos: Vector3 = p["pos"]
		roster.append({"eid": p["eid"], "name": p["name"], "pos": [pos.x, pos.y, pos.z]})
	var sp: Vector3 = _peers[peer_id]["pos"] if _peers.has(peer_id) else _spawn
	return {
		"seed": _seed,
		"kind": world_kind,
		"spawn": [sp.x, sp.y, sp.z],
		"your_eid": str(_peers.get(peer_id, {}).get("eid", "")),
		"peers": roster,
		"deltas": _data.all_deltas(),
	}

# 客户端：套用 welcome —— 用服务器种子建世界并载入增量。world 由 Main 在 CLIENT 模式下注入。
func apply_welcome(payload: Dictionary) -> void:
	_seed = int(payload.get("seed", 1337))
	world_kind = str(payload.get("kind", "infinite"))
	var sp: Array = payload.get("spawn", [0, 0, 0])
	if sp.size() == 3:
		_spawn = Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
	# 增量不在这里加载：客户端收到 welcome 时世界还没 setup（world._data 仍为 null）。
	# 真正的加载在 Main._on_welcomed 里 _enter_world 之后调用 world.load_deltas_from_net(deltas)。

# 服务器：打包所有联机玩家的位置/朝向（HOST 下也含房主自己——房主也是一个 peer）。
func build_player_snapshot() -> Array:
	var out := []
	for pid in _peers:
		var p: Dictionary = _peers[pid]
		var pos: Vector3 = p["pos"]
		out.append({"eid": p["eid"], "pos": [pos.x, pos.y, pos.z], "yaw": p["yaw"]})
	return out

# 客户端：按快照增量更新 avatar —— 缺的生成、有的更新目标、走了的移除。跳过本端自己。
func apply_player_snapshot(snapshot: Array) -> void:
	var seen := {}
	for raw in snapshot:
		var e: Dictionary = raw
		var eid := str(e.get("eid", ""))
		if eid == "" or eid == _self_eid:
			continue
		seen[eid] = true
		var ap: Array = e.get("pos", [0, 0, 0])
		var pos := Vector3(float(ap[0]), float(ap[1]), float(ap[2]))
		var yaw := float(e.get("yaw", 0.0))
		if not _avatars.has(eid):
			var node: Node3D = _spawn_avatar(eid)
			if node == null:
				continue
			_avatars[eid] = node
		var av: Node3D = _avatars[eid]
		if av.has_method("set_net_target"):
			av.set_net_target(pos, yaw)
		else:
			av.position = pos
	# 移除快照里不再出现的
	for eid in _avatars.keys():
		if not seen.has(eid):
			var node: Node3D = _avatars[eid]
			if is_instance_valid(node):
				node.queue_free()
			_avatars.erase(eid)

func avatar_count() -> int:
	return _avatars.size()

# 生成一个 RemoteAvatar：优先用注入的工厂（测试桩 / Main 真身），否则返回 null。
func _spawn_avatar(eid: String) -> Node3D:
	if not avatar_factory.is_valid():
		return null
	var node: Node3D = avatar_factory.call()
	if node == null:
		return null
	if node.has_method("set_label"):
		var nm := eid
		var found := _peers_name_for(eid)
		if found != "":
			nm = found
		node.set_label(nm)
	if world != null:
		world.add_child(node)
	else:
		add_child(node)
	return node

func _peers_name_for(eid: String) -> String:
	for pid in _peers:
		if str(_peers[pid]["eid"]) == eid:
			return str(_peers[pid]["name"])
	return ""

# ============ 实时层（Phase B：WebSocketMultiplayerPeer + 高层 RPC）============
# 服务器恒为 peer 1。CLIENT 用 rpc_id(1, ...) 把编辑请求发给服务器；
# 服务器校验后用 rpc(...) 把 apply_edit 广播给所有客户端。玩家快照由服务器 ~15Hz 广播。

const SNAPSHOT_HZ := 15.0
var _snap_accum := 0.0
var _self_sync_accum := 0.0
var world_save_path := ""            # 服务器：非空则定期把权威世界增量存到此本地文件（世界重启不丢）
var world_kind := "infinite"         # 权威世界类型；随 welcome 下发给客户端
var _save_accum := 0.0
const AUTOSAVE_SEC := 30.0
const SAVE_VERSION := 1

func is_server() -> bool:
	return mode == Mode.SERVER or mode == Mode.HOST

func is_client() -> bool:
	return mode == Mode.CLIENT

func start_server(port: int) -> int:
	if mode == Mode.OFFLINE:
		mode = Mode.SERVER          # 默认作为权威服务器；HOST 已先设好 HOST，不覆盖
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_server(port)
	if err != OK:
		push_warning("联机服务器监听失败 :%d (err=%d)" % [port, err])
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	print_verbose("OurWorlds 联机服务器监听 :%d（权威，无渲染）" % port)
	return OK

func start_client(url: String) -> int:
	mode = Mode.CLIENT
	var peer := WebSocketMultiplayerPeer.new()
	var err := peer.create_client(url)
	if err != OK:
		push_warning("联机连接失败 %s (err=%d)" % [url, err])
		return err
	multiplayer.multiplayer_peer = peer
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	print_verbose("OurWorlds 客户端连接中 %s ..." % url)
	return OK

func start_host(port: int) -> int:
	# HOST = 服务器 + 本地玩家。把房主自己也登记成一个 peer（id=1），这样快照/名册统一处理。
	mode = Mode.HOST          # 必须在 start_server 之前设，使其保留 HOST（start_server 只在 OFFLINE 时设 SERVER）
	var r := start_server(port)
	if r != OK:
		return r
	var eid := register_peer(1, "房主")
	_self_eid = eid
	if player != null:
		set_peer_transform(1, player.global_position, player.rotation.y)
	return OK

# ---- 服务器侧信号 ----
func _on_peer_connected(_id: int) -> void:
	# peer 连上后等它先 rpc 报名（_rpc_hello）；正式注册在 _rpc_hello。
	pass

func _on_peer_disconnected(id: int) -> void:
	if _peers.has(id):
		drop_peer(id)

# ---- 客户端侧信号 ----
func _on_connected_to_server() -> void:
	# 连上后向服务器报名（带本机玩家名）；服务器回 _rpc_welcome。
	_rpc_hello.rpc_id(1, _local_player_name())
	print_verbose("已连上服务器，等待入场 ...")

func _on_server_disconnected() -> void:
	push_warning("与服务器断开。")

func _local_player_name() -> String:
	return "玩家"   # M1 先用固定名；连接界面任务可让玩家填名

# ---- RPC：客户端->服务器 ----
@rpc("any_peer", "reliable")
func _rpc_hello(display_name: String) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	if _peers.has(sender):
		return                    # 重复 hello：已注册则忽略，避免 eid 泄漏 / 重复 welcome
	register_peer(sender, display_name)
	_rpc_welcome.rpc_id(sender, build_welcome(sender))

@rpc("any_peer", "reliable")
func _rpc_request_edit(wx: int, wy: int, wz: int, id: int) -> void:
	if not is_server():
		return
	var sender := multiplayer.get_remote_sender_id()
	var res := authorize_edit(sender, wx, wy, wz, id)
	if not bool(res.get("ok", false)):
		return
	_rpc_apply_edit.rpc(wx, wy, wz, id)

@rpc("any_peer", "reliable")
func _rpc_update_self(px: float, py: float, pz: float, yaw: float) -> void:
	if not is_server():
		return
	set_peer_transform(multiplayer.get_remote_sender_id(), Vector3(px, py, pz), yaw)

# ---- RPC：服务器->客户端 ----
@rpc("authority", "reliable")
func _rpc_welcome(payload: Dictionary) -> void:
	_self_eid = str(payload.get("your_eid", ""))
	apply_welcome(payload)
	welcomed.emit(payload)        # Main 在 CLIENT 模式下接它来建世界/玩家

@rpc("authority", "call_local", "reliable")
func _rpc_apply_edit(wx: int, wy: int, wz: int, id: int) -> void:
	if world != null and world.has_method("apply_remote_edit"):
		world.apply_remote_edit(wx, wy, wz, id)

@rpc("authority", "call_local", "reliable")
func _rpc_sync_players(snapshot: Array) -> void:
	# call_local：HOST 既是服务器又在本地游玩，需对自己也套用快照才能看见别人的小人
	#（apply_player_snapshot 会跳过 _self_eid，故不会给房主自己造分身）；
	# 纯 SERVER 无 avatar_factory，_spawn_avatar 返回 null，相当于空操作。
	apply_player_snapshot(snapshot)

# ---- 编辑出入口（World.net 调用）----
func submit_edit(wx: int, wy: int, wz: int, id: int) -> void:
	_rpc_request_edit.rpc_id(1, wx, wy, wz, id)     # 客户端：请求发给服务器

func broadcast_edit(wx: int, wy: int, wz: int, id: int) -> void:
	_rpc_apply_edit.rpc(wx, wy, wz, id)             # HOST：本地已应用，广播给客户端

# ---- 帧循环：服务器广播玩家快照；客户端上报自身位置（~15Hz）----
func _process(delta: float) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	if is_server():
		if mode == Mode.HOST and player != null and _peers.has(1):
			set_peer_transform(1, player.global_position, player.rotation.y)
		_snap_accum += delta
		if _snap_accum >= 1.0 / SNAPSHOT_HZ:
			_snap_accum = 0.0
			if not _peers.is_empty():
				_rpc_sync_players.rpc(build_player_snapshot())
		if world_save_path != "":          # 定期自动存盘（按住建造，重启不丢）
			_save_accum += delta
			if _save_accum >= AUTOSAVE_SEC:
				_save_accum = 0.0
				save_world(world_save_path)
	elif is_client():
		_self_sync_accum += delta
		if _self_sync_accum >= 1.0 / SNAPSHOT_HZ:
			_self_sync_accum = 0.0
			var rn: Node3D = report_node if report_node != null else player
			if rn != null:
				_rpc_update_self.rpc_id(1, rn.global_position.x, rn.global_position.y, rn.global_position.z, rn.rotation.y)

# ============ 虚拟 Peer（Agent Gateway 用）============
# 虚拟 peer 复用 _peers，用负整数 id 作键（agent-N eid）。
# 负 id 确保 Godot 的 RPC 广播路径不会向它们发包（Godot MultiplayerPeer 只有正 id 的真实连接）。
# authorize_edit / _accept_rate / build_player_snapshot 等核心方法对正负 id 均透明。

func register_virtual_peer(display_name: String) -> String:
	_vpeer_counter += 1
	var pid := -_vpeer_counter
	var eid := "agent-%d" % _vpeer_counter
	var nm := display_name.strip_edges()
	if nm == "": nm = eid
	_peers[pid] = {"eid": eid, "name": nm, "pos": _scatter_spawn(_vpeer_counter), "yaw": 0.0, "edits": []}
	if chat_hub != null:
		chat_hub.register(eid, nm, "agent")
	return eid

func _vpid_for(eid: String) -> int:
	for pid in _peers:
		if pid < 0 and str(_peers[pid]["eid"]) == eid: return pid
	return 0

func update_virtual_peer(eid: String, pos: Vector3, yaw: float) -> void:
	var pid := _vpid_for(eid)
	if pid != 0: set_peer_transform(pid, pos, yaw)

func virtual_say(eid: String, text: String, to: String = "") -> void:
	if chat_hub == null: return
	if to == "": chat_hub.post(eid, "", text)
	else: chat_hub.post(eid, chat_hub.resolve(to), text)

func remove_virtual_peer(eid: String) -> void:
	var pid := _vpid_for(eid)
	if pid != 0: drop_peer(pid)

func apply_virtual_edit(eid: String, wx: int, wy: int, wz: int, id: int) -> bool:
	return apply_virtual_edit_at(eid, wx, wy, wz, id, -1.0)

func apply_virtual_edit_at(eid: String, wx: int, wy: int, wz: int, id: int, now: float) -> bool:
	var pid := _vpid_for(eid)
	if pid == 0: return false
	var r := authorize_edit(pid, wx, wy, wz, id, now)
	if not bool(r.get("ok", false)): return false
	if mode == Mode.SERVER and multiplayer != null and multiplayer.has_multiplayer_peer():
		_rpc_apply_edit.rpc(wx, wy, wz, id)
	return true

func _exit_tree() -> void:
	# 服务器优雅退出时存一次盘（定期自动存盘兜底强杀丢的 ≤30s）
	if is_server() and world_save_path != "":
		save_world(world_save_path)
