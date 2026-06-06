extends RefCounted
# ChatHub —— 本地大厅与聊天的纯逻辑核心（无节点依赖，可 headless 测试）。
# 维护在线实体注册表 + 消息环形缓冲；区分公共大厅（to == LOBBY）与私聊（to == 某实体 id）。
# 由 Main 创建并注入给 AgentBridge（agent 发言/收信）与 ChatPanel（玩家 UI）。

signal message_posted(msg: Dictionary)
signal presence_changed()

const LOBBY := ""            # to 为空字符串表示公共大厅
const MAX_MESSAGES := 200    # 环形缓冲上限（聊天为会话内临时，不跨重启持久化）

var _entities := {}          # id -> {id, name, kind, status}
var _messages := []          # [{seq, from, to, text, t}]
var _seq := 0

# ---------- presence ----------

func register(id: String, name: String, kind: String) -> void:
	_entities[id] = {"id": id, "name": name, "kind": kind, "status": ""}
	presence_changed.emit()

func unregister(id: String) -> void:
	if _entities.erase(id):
		presence_changed.emit()

func set_status(id: String, status: String) -> void:
	if _entities.has(id):
		_entities[id]["status"] = status
		presence_changed.emit()

func entities() -> Array:
	return _entities.values()

# 把名字解析成 id（say 的 to 可以传 id 或显示名）。
func resolve(id_or_name: String) -> String:
	if _entities.has(id_or_name):
		return id_or_name
	for e in _entities.values():
		if e["name"] == id_or_name:
			return e["id"]
	return id_or_name

# ---------- messages ----------

func post(from_id: String, to_id: String, text: String) -> int:
	_seq += 1
	var msg := {"seq": _seq, "from": from_id, "to": to_id, "text": text, "t": _now()}
	_messages.append(msg)
	if _messages.size() > MAX_MESSAGES:
		_messages = _messages.slice(_messages.size() - MAX_MESSAGES)
	message_posted.emit(msg)
	return _seq

func lobby_recent(limit: int) -> Array:
	var out := []
	for m in _messages:
		if m["to"] == LOBBY:
			out.append(m)
	if out.size() > limit:
		out = out.slice(out.size() - limit)
	return out

func thread(a_id: String, b_id: String, limit: int) -> Array:
	var out := []
	for m in _messages:
		if m["to"] == LOBBY:
			continue
		if (m["from"] == a_id and m["to"] == b_id) or (m["from"] == b_id and m["to"] == a_id):
			out.append(m)
	if out.size() > limit:
		out = out.slice(out.size() - limit)
	return out

# 自 since_seq 以来、对 id 可见的未读：别人发的大厅消息 + 指向 id 的私聊（排除自己发的）。
# 返回 last_seq = 当前最大 seq，调用方下次以此为 since 即只取更新的。
func unread_for(id: String, since_seq: int) -> Dictionary:
	var out := []
	for m in _messages:
		if m["seq"] <= since_seq:
			continue
		var visible: bool = (m["to"] == LOBBY and m["from"] != id) or (m["to"] == id)
		if visible:
			out.append(m)
	return {"messages": out, "last_seq": _seq}

func _now() -> int:
	return int(Time.get_unix_time_from_system())
