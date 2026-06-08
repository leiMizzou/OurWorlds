extends SceneTree
const AgentTokenStore = preload("res://scripts/AgentTokenStore.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

# 把一个 token 文件写到 user://，返回绝对(可被 FileAccess 打开)的路径。
func _write_token_file(fname: String, body: String) -> String:
	var path := "user://" + fname
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(body)
	f.close()
	return path

func _tokens_json(pairs: Array) -> String:
	# pairs: Array of [token, label]
	var toks := []
	for p in pairs:
		toks.append({"token": p[0], "label": p[1], "issued_at": 1700000000})
	return JSON.stringify({"version": 1, "tokens": toks})

func _initialize() -> void:
	# ---- 既有 env 行为（不能回归） ----
	# "label:token" pairs, comma-separated; bare token allowed (label == token).
	var store := AgentTokenStore.new("Alice:aaa111, Bob:bbb222 , ccc333")
	check(store.is_valid("aaa111"), "valid token accepted")
	check(store.label_for("aaa111") == "Alice", "label resolved")
	check(store.is_valid("ccc333") and store.label_for("ccc333") == "ccc333", "bare token uses itself as label")
	check(not store.is_valid("nope"), "unknown token rejected")
	check(not store.is_valid(""), "empty token rejected")
	check(AgentTokenStore.new("").count() == 0, "empty config -> no tokens")

	# ---- file-only：env 为空，token 来自文件 ----
	var p_file := _write_token_file("tok_fileonly.json", _tokens_json([["ow_file001", "FromFile"]]))
	var fstore := AgentTokenStore.new("", p_file)
	check(fstore.is_valid("ow_file001"), "file-only token validates")
	check(fstore.label_for("ow_file001") == "FromFile", "file-only label resolved")
	check(fstore.count() == 1, "file-only count == 1")
	check(not fstore.is_valid("nope"), "file-only: unknown rejected")

	# ---- env ∪ file 并集；env 标签在冲突时优先 ----
	var p_union := _write_token_file("tok_union.json", _tokens_json([["ow_file002", "FileLabel"], ["envtok", "ShouldLose"]]))
	var ustore := AgentTokenStore.new("EnvLabel:envtok", p_union)
	check(ustore.is_valid("envtok"), "union: env token valid")
	check(ustore.is_valid("ow_file002"), "union: file token valid")
	check(ustore.label_for("envtok") == "EnvLabel", "union: env label wins on conflict")
	check(ustore.count() == 2, "union: count dedups conflicting token == 2")

	# ---- mtime reload：往文件追加新 token，is_valid(new) 翻转为 true ----
	var p_reload := _write_token_file("tok_reload.json", _tokens_json([["ow_first", "First"]]))
	var rstore := AgentTokenStore.new("", p_reload)
	check(rstore.is_valid("ow_first"), "reload: initial token valid")
	check(not rstore.is_valid("ow_second"), "reload: new token not yet present")
	# 重写文件并把 mtime 往前推，强制 mtime 变化被检测到（同秒重写可能 mtime 不变）。
	_write_token_file("tok_reload.json", _tokens_json([["ow_first", "First"], ["ow_second", "Second"]]))
	_bump_mtime(p_reload)
	check(rstore.is_valid("ow_second"), "reload: appended token valid after mtime change")
	check(rstore.is_valid("ow_first"), "reload: original token still valid after reload")
	check(rstore.count() == 2, "reload: count == 2 after reload")

	# ---- 畸形 JSON 文件被忽略；env 仍然有效 ----
	var p_bad := _write_token_file("tok_bad.json", "{ this is not valid json ::: ")
	var bstore := AgentTokenStore.new("Keep:envok", p_bad)
	check(bstore.is_valid("envok"), "malformed file ignored, env still validates")
	check(not bstore.is_valid("ow_anything"), "malformed file contributes no tokens")
	check(bstore.count() == 1, "malformed file: count == env only")

	# ---- 缺失文件被容忍 ----
	var mstore := AgentTokenStore.new("Keep:envok2", "user://does_not_exist_xyz.json")
	check(mstore.is_valid("envok2"), "missing file tolerated, env validates")
	check(mstore.count() == 1, "missing file: count == env only")

	if failed == 0: print("✅ ALL AGENT TOKEN TESTS PASSED")
	else: printerr("❌ ", failed, " agent-token failures")
	quit(0 if failed == 0 else 1)

# 让文件的 mtime 明显变化：把它删掉重写不一定换秒；这里通过再写一次 + 触碰确保检测到。
func _bump_mtime(path: String) -> void:
	# 同一秒内重写，get_modified_time 可能返回相同秒值；用 OS 触碰把 mtime 推到未来。
	var abs := ProjectSettings.globalize_path(path)
	OS.execute("touch", ["-t", _future_touch_stamp(), abs])

func _future_touch_stamp() -> String:
	# touch -t 形式：[[CC]YY]MMDDhhmm[.SS]，取当前 unix 时间 +120s。
	var t := Time.get_unix_time_from_system() + 120.0
	var d := Time.get_datetime_dict_from_unix_time(int(t))
	return "%04d%02d%02d%02d%02d.%02d" % [d.year, d.month, d.day, d.hour, d.minute, d.second]
