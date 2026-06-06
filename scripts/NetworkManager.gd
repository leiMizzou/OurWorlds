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
