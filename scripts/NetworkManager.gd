extends Node
# OurWorlds 联机管理器（M1：本地权威联机）。
# 设计要点（详见 docs/superpowers/plans/2026-06-06-m1-local-coop.md）：
#   - 权威核心（校验/写入/打包）是纯方法，作用在注入的 WorldData 上，可无头单测；
#     真正的 socket/RPC 在 Phase B 接上，跟核心解耦（镜像 AgentBridge.dispatch 的可测性）。
#   - 服务器直接持有 WorldData（无 World 节点、不造网格）；HOST/CLIENT 用 World._data。
const WorldData = preload("res://scripts/WorldData.gd")
const Chunk = preload("res://scripts/Chunk.gd")

enum Mode { OFFLINE, SERVER, CLIENT, HOST }

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
var _self_eid := ""                # 本端自己的 eid（CLIENT/HOST）；快照里跳过它
var _avatars := {}                 # eid -> RemoteAvatar 节点（CLIENT）

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
	_peers[peer_id] = {"eid": eid, "name": nm, "pos": _spawn, "yaw": 0.0, "edits": []}
	if chat_hub != null:
		chat_hub.register(eid, nm, "human")
	return eid

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
func build_welcome(peer_id: int) -> Dictionary:
	var roster := []
	for pid in _peers:
		var p: Dictionary = _peers[pid]
		var pos: Vector3 = p["pos"]
		roster.append({"eid": p["eid"], "name": p["name"], "pos": [pos.x, pos.y, pos.z]})
	return {
		"seed": _seed,
		"spawn": [_spawn.x, _spawn.y, _spawn.z],
		"your_eid": str(_peers.get(peer_id, {}).get("eid", "")),
		"peers": roster,
		"deltas": _data.all_deltas(),
	}

# 客户端：套用 welcome —— 用服务器种子建世界并载入增量。world 由 Main 在 CLIENT 模式下注入。
func apply_welcome(payload: Dictionary) -> void:
	_seed = int(payload.get("seed", 1337))
	var sp: Array = payload.get("spawn", [0, 0, 0])
	if sp.size() == 3:
		_spawn = Vector3(float(sp[0]), float(sp[1]), float(sp[2]))
	if world != null and world.has_method("load_deltas_from_net"):
		world.load_deltas_from_net(payload.get("deltas", {}))

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
