extends RefCounted
# Agent 接入 token 校验。来源 = env 静态 token（OW_AGENT_TOKENS）∪ 文件签发 token。
# 文件由门户 serve_web 的 /api/agent-token 端点追加；本类在文件 mtime 变化时自动重载，
# 因此新签发的 token 几秒内即可通过鉴权，无需重启服务器。
# 冲突时 env 标签优先（运营者手配的覆盖文件自助签发的）。
var _env_by_token := {}     # token -> label（来自 env，固定）
var _file_by_token := {}    # token -> label（来自文件，随 mtime 重载刷新）
var _file_path := ""
var _file_mtime := -1

func _init(spec: String, token_file_path: String = "") -> void:
	for raw in spec.split(",", false):
		var part := raw.strip_edges()
		if part == "": continue
		var label := part
		var token := part
		var colon := part.find(":")
		if colon > 0:
			label = part.substr(0, colon).strip_edges()
			token = part.substr(colon + 1).strip_edges()
		if token != "":
			_env_by_token[token] = label
	_file_path = token_file_path.strip_edges()
	_reload_file_if_changed()

# 仅当文件存在且 mtime 较上次变化时才重读；缺失/空/畸形一律视作“无文件 token”，绝不崩。
func _reload_file_if_changed() -> void:
	if _file_path == "":
		return
	if not FileAccess.file_exists(_file_path):
		# 文件可能被删除（撤销全部签发 token）：清空文件来源并复位 mtime。
		if not _file_by_token.is_empty() or _file_mtime != -1:
			_file_by_token = {}
			_file_mtime = -1
		return
	var mtime := int(FileAccess.get_modified_time(_file_path))
	if mtime == _file_mtime:
		return
	_file_mtime = mtime
	_file_by_token = {}
	var f := FileAccess.open(_file_path, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	if text.strip_edges() == "":
		return
	# 用 JSON 实例的 parse()（返回错误码，不向 stderr 打印），避免畸形文件污染测试输出/日志。
	var json := JSON.new()
	if json.parse(text) != OK:
		return
	var parsed = json.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var toks = parsed.get("tokens", [])
	if typeof(toks) != TYPE_ARRAY:
		return
	for rec in toks:
		if typeof(rec) != TYPE_DICTIONARY:
			continue
		var token := str(rec.get("token", "")).strip_edges()
		if token == "":
			continue
		var label := str(rec.get("label", token)).strip_edges()
		if label == "":
			label = token
		_file_by_token[token] = label

func is_valid(token: String) -> bool:
	if token == "":
		return false
	_reload_file_if_changed()
	return _env_by_token.has(token) or _file_by_token.has(token)

func label_for(token: String) -> String:
	_reload_file_if_changed()
	if _env_by_token.has(token):   # env 标签优先
		return str(_env_by_token[token])
	return str(_file_by_token.get(token, ""))

func count() -> int:
	_reload_file_if_changed()
	# 并集去重（env 与文件中相同 token 只计一次）。
	var seen := {}
	for t in _env_by_token: seen[t] = true
	for t in _file_by_token: seen[t] = true
	return seen.size()
