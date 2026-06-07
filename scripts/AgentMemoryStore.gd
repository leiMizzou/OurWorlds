extends RefCounted
# AgentMemoryStore —— 服务器侧、按 token 隔离的代理记忆（goal + notes），持久化到本地 JSON。
#
# 每个连接的 agent 由其 token_hash 唯一标识；记忆存到 user://agent_mem/<token_hash>.json，
# 这样同一 token 跨连接/跨进程重启仍能记得目标与笔记。镜像 AgentBridge 的 LiveMemory 接口
# （get_goal/set_goal/notes/append_note/updated_at/save），让 AgentToolCore 的 ctx.memory.*
# 在服务器侧与 localhost 桥行为一致。
#
# 接口（ctx.memory.* —— AgentToolCore 实际调用的全集）：
#   get_goal()->String  set_goal(s)  notes()->Array  append_note(s)  updated_at()->int  save()
# 另：构造时自动读盘（内部 _load()，避免与全局内置 load() 撞名），目录不存在则建。

const MEM_DIR := "user://agent_mem"
const NOTE_CAP := 50                 # 与 AgentBridge.MEMORY_NOTE_CAP 一致
const VERSION := 1

var _token_hash: String
var _path: String
var _data := {"version": VERSION, "goal": "", "notes": [], "updated_at": 0}

func _init(token_hash: String) -> void:
	_token_hash = _sanitize(token_hash)
	_path = "%s/%s.json" % [MEM_DIR, _token_hash]
	_load()

# token_hash 直接进文件名：去掉路径分隔/非法字符，空则回退一个固定名，避免写到目录外。
func _sanitize(raw: String) -> String:
	var clean := raw.strip_edges()
	var out := ""
	for i in range(clean.length()):
		var c := clean[i]
		if (c >= "0" and c <= "9") or (c >= "a" and c <= "z") or (c >= "A" and c <= "Z") or c == "-" or c == "_":
			out += c
		else:
			out += "_"
	if out == "":
		out = "anon"
	return out

# ---- ctx.memory.* 接口 ----

func get_goal() -> String:
	return str(_data.get("goal", ""))

func set_goal(s: String) -> void:
	_data["goal"] = s

func notes() -> Array:
	return _data.get("notes", []) as Array

func append_note(s: String) -> void:
	var ns: Array = _data.get("notes", [])
	ns.append(s)
	while ns.size() > NOTE_CAP:
		ns.pop_front()
	_data["notes"] = ns

func updated_at() -> int:
	return int(_data.get("updated_at", 0))

# ---- 持久化 ----

# 读盘（构造时自动调用）。注意：方法名加下划线，避免与 GDScript 全局内置 load() 撞名导致解析错误。
func _load() -> void:
	_data = {"version": VERSION, "goal": "", "notes": [], "updated_at": 0}
	if not FileAccess.file_exists(_path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var raw: Dictionary = parsed
	_data["goal"] = str(raw.get("goal", ""))
	var notes := []
	var rn: Variant = raw.get("notes", [])
	if typeof(rn) == TYPE_ARRAY:
		for n in rn:
			notes.append(str(n))
	while notes.size() > NOTE_CAP:
		notes.pop_front()
	_data["notes"] = notes
	_data["updated_at"] = int(raw.get("updated_at", 0))

# 原子写：临时文件 + 改名（镜像 AgentBridge._save_memory / World 存档的稳妥做法）。
func save() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MEM_DIR))
	_data["updated_at"] = int(Time.get_unix_time_from_system())
	var text := JSON.stringify(_data, "\t")
	var tmp := _path + ".tmp"
	var abs_tmp := ProjectSettings.globalize_path(tmp)
	var abs_dst := ProjectSettings.globalize_path(_path)
	if FileAccess.file_exists(tmp):
		DirAccess.remove_absolute(abs_tmp)
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(text)
	f.close()
	if FileAccess.file_exists(_path):
		DirAccess.remove_absolute(abs_dst)
	DirAccess.rename_absolute(abs_tmp, abs_dst)
