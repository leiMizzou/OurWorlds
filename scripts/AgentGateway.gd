extends Node
# AgentGateway —— 远程代理（Agent Gateway）的 WebSocket 端点。
#
# 职责：
#   • 鉴权：每个连接先发 {tool:"auth", args:{token, name?}}；token 经 AgentTokenStore 校验。
#   • 落地：鉴权通过后，向 NetworkManager 注册一个"服务器权威的虚拟 peer 身体"（agent-N），
#     并 per-conn 造一个 AgentContext.ServerAgentContext，把后续 tool-call 经 AgentToolCore 分发到它。
#   • 退场：连接关闭 / WS 断开时，移除虚拟 peer（despawn）。
#   • 容量：超过 max_agents 的鉴权请求被拒（"server at capacity"）。
#   • 反刷：鉴权后对非 auth 调用做 per-conn 滑窗限流（默认关闭；生产可经 setup 注入）。
#
# 逻辑可独立单测（不经套接字）：handle_envelope(conn, env) + new_conn() / close_conn(conn)，
# 镜像 test_agent_bridge 直接喂 dispatch_line 的做法。真实 TCP/WebSocket 循环（start/_process）
# 调用这同一套方法，但本任务单测不跑套接字（由 Task 9 的 E2E 覆盖）。
#
# 调用方契约（后续任务把它接进无头服务器）：
#   gw.setup(net_manager, world_data, AgentTokenStore.new(OW_AGENT_TOKENS), OW_AGENT_MAX)
#   gw.start(8972)
# 注意：set_authority_data(...) 必须在 agent 注册"之前"对 NetworkManager 调过，否则散点 spawn 落在原点。

const AgentToolCore = preload("res://scripts/AgentToolCore.gd")
const AgentContext = preload("res://scripts/AgentContext.gd")

var _nm                              # NetworkManager（持权威 WorldData + 虚拟 peer）
var _data                            # WorldData（权威世界数据）
var _tokens                          # AgentTokenStore（is_valid / label_for）
var _max := 8                        # 最大在线 agent 数
var _rate_per_sec := 0               # 鉴权后非 auth 调用的 per-conn 限流（每秒）；<=0 表示不限（单测默认）

var _conns := {}                     # conn_id -> {authed:bool, eid:String, ctx, hits:Array[float]}
var _conn_seq := 0

var _server: TCPServer               # 真实套接字监听（仅 start/_process 用）
var _sockets := {}                   # conn_id -> WebSocketPeer

# ---- 配置 ----
# max_agents：在线 agent 上限。rate_per_sec：鉴权后非 auth 调用的每秒上限（<=0 不限，单测用）。
func setup(nm, data, tokens, max_agents: int = 8, rate_per_sec: int = 0) -> void:
	_nm = nm
	_data = data
	_tokens = tokens
	_max = max_agents
	_rate_per_sec = rate_per_sec

# 新建一条逻辑连接（未鉴权），返回 conn_id。
func new_conn() -> int:
	_conn_seq += 1
	_conns[_conn_seq] = {"authed": false, "eid": "", "ctx": null, "hits": []}
	return _conn_seq

# 当前已鉴权（占名额）的连接数。
func _active_agents() -> int:
	var n := 0
	for c in _conns.values():
		if bool(c.get("authed", false)):
			n += 1
	return n

# 处理一条来自该连接的请求信封。返回应答信封（含原 id）。
#   未鉴权：只接受 tool=="auth"，否则 {ok:false, error:"unauthenticated: ..."}；
#           token 无效 -> {ok:false, error:"unauthorized"}；满员 -> {ok:false, error:"server at capacity"}；
#           成功 -> 注册虚拟 peer + 建 ServerAgentContext，回 {ok:true, result:{eid, spawn:[x,y,z]}}。
#   已鉴权：限流通过则经 AgentToolCore.handle 分发；超限 -> {ok:false, error:"rate limited"}。
func handle_envelope(conn: int, env: Dictionary) -> Dictionary:
	var st: Dictionary = _conns.get(conn, {})
	var id = env.get("id", null)
	var tool := str(env.get("tool", ""))
	var raw_args = env.get("args", {})
	var args: Dictionary = raw_args if typeof(raw_args) == TYPE_DICTIONARY else {}

	# 未知连接（已关闭或从未 new_conn）：当作未鉴权处理，给出明确错误而非崩溃。
	if st.is_empty():
		return {"id": id, "ok": false, "error": "unauthenticated: unknown connection"}

	if not bool(st.get("authed", false)):
		if tool != "auth":
			return {"id": id, "ok": false, "error": "unauthenticated: send auth first"}
		var token := str(args.get("token", ""))
		if not _tokens.is_valid(token):
			return {"id": id, "ok": false, "error": "unauthorized"}
		if _active_agents() >= _max:
			return {"id": id, "ok": false, "error": "server at capacity"}
		var nm_name := str(args.get("name", ""))
		if nm_name == "":
			nm_name = str(_tokens.label_for(token))
		var eid := str(_nm.register_virtual_peer(nm_name))
		st["authed"] = true
		st["eid"] = eid
		st["ctx"] = AgentContext.ServerAgentContext.new(_nm, _data, eid, str(token.hash()))
		st["hits"] = []
		_conns[conn] = st
		var pos = _nm.peer_position(eid)
		return {"id": id, "ok": true, "result": {"eid": eid, "spawn": [pos.x, pos.y, pos.z], "protocol": _nm.PROTOCOL_VERSION}}

	# 已鉴权后的重复 auth：幂等回当前身体信息（不重复注册、不占新名额）。
	if tool == "auth":
		var cur_eid := str(st.get("eid", ""))
		var cur_pos = _nm.peer_position(cur_eid)
		return {"id": id, "ok": true, "result": {"eid": cur_eid, "spawn": [cur_pos.x, cur_pos.y, cur_pos.z], "protocol": _nm.PROTOCOL_VERSION}}

	# 反刷限流（仅作用于鉴权后的非 auth 调用；<=0 表示不限，单测默认走这条不受影响）。
	if _rate_per_sec > 0 and not _allow_hit(st):
		return {"id": id, "ok": false, "error": "rate limited"}

	var r := AgentToolCore.handle(tool, args, st["ctx"])
	r["id"] = id
	return r

# per-conn 滑动窗口：保留最近 1 秒内的命中时间戳，超过 _rate_per_sec 则拒绝。
func _allow_hit(st: Dictionary) -> bool:
	var now := float(Time.get_ticks_msec()) / 1000.0
	var hits: Array = st.get("hits", [])
	while not hits.is_empty() and now - float(hits[0]) >= 1.0:
		hits.pop_front()
	if hits.size() >= _rate_per_sec:
		st["hits"] = hits
		return false
	hits.append(now)
	st["hits"] = hits
	return true

# 关闭一条逻辑连接：若已鉴权则 despawn 虚拟 peer；并清理可能存在的真实套接字。
func close_conn(conn: int) -> void:
	var st: Dictionary = _conns.get(conn, {})
	if bool(st.get("authed", false)):
		_nm.remove_virtual_peer(str(st.get("eid", "")))
	_conns.erase(conn)
	if _sockets.has(conn):
		var ws: WebSocketPeer = _sockets[conn]
		ws.close()
		_sockets.erase(conn)

# ============================================================================
# 真实套接字循环（集成路径；本任务单测不跑，Task 9 的 E2E 覆盖）。
# ============================================================================

# 监听本机 port 的 WebSocket。成功返回 true。
func start(port: int) -> bool:
	_server = TCPServer.new()
	return _server.listen(port, "127.0.0.1") == OK

# 停止监听：先 despawn 所有逻辑连接（含虚拟 peer），再停服务器。
func stop() -> void:
	for cid in _conns.keys().duplicate():
		close_conn(cid)
	_sockets.clear()
	if _server != null:
		_server.stop()
		_server = null

func _process(_dt: float) -> void:
	if _server == null:
		return
	# 接受新连接：每个 TCP 连接做服务器侧 WS 握手，建一条逻辑连接。
	while _server.is_connection_available():
		var tcp := _server.take_connection()
		var ws := WebSocketPeer.new()
		ws.accept_stream(tcp)
		var cid := new_conn()
		_sockets[cid] = ws
	# 轮询每个套接字：读完整文本帧 -> 解析 JSON -> handle_envelope -> 回写应答。
	for cid in _sockets.keys():
		var ws: WebSocketPeer = _sockets[cid]
		ws.poll()
		var s := ws.get_ready_state()
		if s == WebSocketPeer.STATE_OPEN:
			while ws.get_available_packet_count() > 0:
				var line := ws.get_packet().get_string_from_utf8()
				var parsed = JSON.parse_string(line)
				var env: Dictionary = parsed if typeof(parsed) == TYPE_DICTIONARY else {}
				var resp := handle_envelope(cid, env)
				ws.send_text(JSON.stringify(resp))
		elif s == WebSocketPeer.STATE_CLOSED:
			close_conn(cid)
