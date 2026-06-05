extends Node3D
# 世界 = 一堆区块。负责：生成、造网格+碰撞、读写方块、跟玩家流式加载/卸载。
#
# 性能核心：流式加载的造网格放到【后台线程】（WorkerThreadPool），主线程只负责
# 用算好的数组组装节点 —— 这样边走边加载时主线程不卡。
# 用 version 版本号保证：某区块若在后台计算期间被玩家挖/放过，旧结果会被丢弃。

const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const ChunkMesher = preload("res://scripts/ChunkMesher.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")

const MAX_INFLIGHT := 8        # 同时在后台算的区块上限（运行时由 _max_inflight 决定，见 setup）
const APPLY_PER_FRAME := 3     # 每帧最多组装几个（主线程）
const NEI := [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]
const SAVE_VERSION := 1
const MAX_EDIT_HISTORY := 256
const LANDMARK_RESTORE_RADIUS := 7
const LANDMARK_RESTORE_VERTICAL_RADIUS := 5
const LANDMARK_RESTORE_TARGET := 20
const JOURNEY_STEPS := [
	"explore",
	"select_material",
	"open_palette",
	"place_block",
	"use_template",
	"open_map",
	"discover_landmark",
	"save_world",
]
const CHUNK_LIGHT_LIMIT := 10
const LIGHT_ACTIVE_RADIUS := 3

signal save_feedback(kind: String, label: String)
signal edit_feedback(kind: String, label: String)

var view_radius := 4
var lib: BlockLibrary
var track_target: Node3D
var save_path := ""
var cover_path := ""

var _gen: WorldGenerator
var _world_seed := 1337
var _chunks := {}              # Vector2i -> Chunk(数据)   —— 仅主线程访问
var _deltas := {}              # "cx,cz" -> {"index": block_id}，玩家改动的本地增量
var _delta_dirty := false
var _discoveries := {}          # "x,y,z" -> true，已发现的世界地标
var _journey_steps := {}        # 已完成的新手旅程步骤
var _visited_regions := {}      # 已踏足的地貌区域
var _meta_dirty := false
var _loaded_from_backup := false
var _nodes := {}              # Vector2i -> {mesh, body, coll}
var _version := {}            # Vector2i -> int           —— 改一次+1，作废在途的后台结果
var _queue := []             # 待加载的区块
var _meshing := {}           # Vector2i -> true（在后台算中）
var _pending_apply := []     # 主线程待组装
var _center := Vector2i(999999, 0)
var _undo_stack := []
var _redo_stack := []

var _mutex := Mutex.new()
var _results := []           # 后台线程压入的成品 {cc, ver, arrays}  —— 用 _mutex 保护
var _tasks := {}             # task_id -> true，所有在途的 WorkerThreadPool 任务（退出时排空）—— 用 _mutex 保护
var _max_inflight := MAX_INFLIGHT
var _light_dirty := {}       # Vector2i -> true，该区块发光方块有增删、灯光需要重刷

# 造网格用的数值查找表（建一次、只读，传给后台线程）
var _solid; var _opaque; var _transp; var _water
var _ttop; var _tside; var _tbot; var _matbucket

func setup(block_lib: BlockLibrary, world_seed: int = 1337, save_file: String = "") -> void:
	lib = block_lib
	_world_seed = world_seed
	save_path = save_file
	_gen = WorldGenerator.new(world_seed)
	_solid = lib.solid_lut; _opaque = lib.opaque_lut; _transp = lib.transp_lut; _water = lib.water_lut
	_ttop = lib.tile_top_lut; _tside = lib.tile_side_lut; _tbot = lib.tile_bot_lut; _matbucket = lib.mat_bucket_lut
	_max_inflight = maxi(4, OS.get_processor_count() - 1)
	if save_path != "":
		load_world()

func set_view_radius(value: int) -> void:
	view_radius = clampi(value, 2, 6)
	_center = Vector2i(999999, 0)

# ---------- 坐标 ----------
func chunk_of(wx: int, wz: int) -> Vector2i:
	return Vector2i(floori(float(wx) / Chunk.SX), floori(float(wz) / Chunk.SZ))

func surface_y(wx: int, wz: int) -> int:
	return _gen.surface_height(wx, wz)

func region_label(wx: int, wz: int) -> String:
	return _gen.region_label(wx, wz)

func region_description(wx: int, wz: int) -> String:
	return _gen.region_description(wx, wz)

# ---------- 读写方块 ----------
func get_block(wx: int, wy: int, wz: int) -> int:
	var cc := chunk_of(wx, wz)
	if wy < 0 or wy >= Chunk.SY:
		return 0
	_ensure_data(cc)
	var ch: Chunk = _chunks[cc]
	return ch.get_block(wx - cc.x * Chunk.SX, wy, wz - cc.y * Chunk.SZ)

func request_edit(wx: int, wy: int, wz: int, id: int) -> bool:
	if wy < 0 or wy >= Chunk.SY:
		return false
	var before := get_block(wx, wy, wz)
	if before == id:
		return false
	var dirty := {}
	if not set_block_data(wx, wy, wz, id, dirty):
		return false
	flush_remesh(dirty)
	_push_history(Vector3i(wx, wy, wz), before, id)
	return true

func request_edits(cells: Array, id: int) -> int:
	var entries := []
	var seen := {}
	var dirty := {}
	for raw in cells:
		var pos: Vector3i = raw
		if pos.y < 0 or pos.y >= Chunk.SY:
			continue
		var key := _pos_key(pos)
		if seen.has(key):
			continue
		seen[key] = true
		var before := get_block(pos.x, pos.y, pos.z)
		if before == id:
			continue
		if set_block_data(pos.x, pos.y, pos.z, id, dirty):
			entries.append({"pos": pos, "before": before, "after": id})
	if entries.is_empty():
		return 0
	flush_remesh(dirty)           # 批量：所有数据写完后，每个脏区块只重建一次
	_push_history_entries(entries)
	return entries.size()

func request_block_edits(edits: Array) -> int:
	var entries := []
	var seen := {}
	var dirty := {}
	for raw in edits:
		var edit: Dictionary = raw
		var pos: Vector3i = edit.get("pos", Vector3i.ZERO)
		var id := int(edit.get("id", BlockLibrary.AIR))
		if pos.y < 0 or pos.y >= Chunk.SY:
			continue
		var key := _pos_key(pos)
		if seen.has(key):
			continue
		seen[key] = true
		var before := get_block(pos.x, pos.y, pos.z)
		if before == id:
			continue
		if set_block_data(pos.x, pos.y, pos.z, id, dirty):
			entries.append({"pos": pos, "before": before, "after": id})
	if entries.is_empty():
		return 0
	flush_remesh(dirty)           # 批量：所有数据写完后，每个脏区块只重建一次
	_push_history_entries(entries)
	return entries.size()

# 单格编辑（公共 API）：写数据 + 重建受影响区块（单块及跨界邻块）。
func set_block(wx: int, wy: int, wz: int, id: int) -> bool:
	if wy < 0 or wy >= Chunk.SY:
		return false
	var dirty := {}
	if not set_block_data(wx, wy, wz, id, dirty):
		return false
	flush_remesh(dirty)
	return true

# 只写数据 + 记录增量，不重建网格。把受影响的脏区块（本块 + 跨界邻块）塞进 dirty 集合。
# 返回 false 表示该格数据没变化（无需重建）。
func set_block_data(wx: int, wy: int, wz: int, id: int, dirty: Dictionary) -> bool:
	if wy < 0 or wy >= Chunk.SY:
		return false
	var cc := chunk_of(wx, wz)
	if not _chunks.has(cc):
		_ensure_data(cc)
	var lx := wx - cc.x * Chunk.SX
	var lz := wz - cc.y * Chunk.SZ
	var ch: Chunk = _chunks[cc]
	if ch.get_block(lx, wy, lz) == id:
		return false
	var was_light := _is_light_block(int(ch.get_block(lx, wy, lz)))
	ch.set_block(lx, wy, lz, id)
	_record_delta(cc, lx, wy, lz, id)
	dirty[cc] = true
	# 跨区块边界：邻块的网格也需要重建（剔除面会变）
	if lx == 0: dirty[cc + Vector2i(-1, 0)] = true
	elif lx == Chunk.SX - 1: dirty[cc + Vector2i(1, 0)] = true
	if lz == 0: dirty[cc + Vector2i(0, -1)] = true
	elif lz == Chunk.SZ - 1: dirty[cc + Vector2i(0, 1)] = true
	# 若本格涉及发光方块（增/删），标记该块需要刷新灯光
	if was_light or _is_light_block(id):
		_light_dirty[cc] = true
	return true

# 重建一批脏区块。在场景树内 -> 走后台线程（主线程只 assemble，不冻结）；
# 否则（直接 API 单测）-> 同步兜底，保持与旧行为一致。
func flush_remesh(chunk_set) -> void:
	var keys: Array
	if chunk_set is Dictionary:
		keys = chunk_set.keys()
	else:
		keys = chunk_set
	var background := is_inside_tree()
	for cc in keys:
		if not _chunks.has(cc):
			continue
		if background:
			_remesh_async(cc)
		else:
			_remesh_sync(cc)

func can_undo() -> bool:
	return not _undo_stack.is_empty()

func can_redo() -> bool:
	return not _redo_stack.is_empty()

func undo_last_edit() -> bool:
	if _undo_stack.is_empty():
		edit_feedback.emit("blocked", "没有可撤销的编辑")
		return false
	var entry: Dictionary = _undo_stack.pop_back()
	if not _apply_history_entry(entry, true):
		_undo_stack.append(entry)
		edit_feedback.emit("blocked", "撤销失败")
		return false
	_redo_stack.append(entry)
	edit_feedback.emit("undo", "撤销：" + _entry_action_label(entry))
	return true

func redo_last_edit() -> bool:
	if _redo_stack.is_empty():
		edit_feedback.emit("blocked", "没有可重做的编辑")
		return false
	var entry: Dictionary = _redo_stack.pop_back()
	if not _apply_history_entry(entry, false):
		_redo_stack.append(entry)
		edit_feedback.emit("blocked", "重做失败")
		return false
	_undo_stack.append(entry)
	edit_feedback.emit("redo", "重做：" + _entry_action_label(entry))
	return true

func clear_edit_history() -> void:
	_undo_stack.clear()
	_redo_stack.clear()

func _push_history(pos: Vector3i, before: int, after: int) -> void:
	_push_history_entry({"pos": pos, "before": before, "after": after})

func _push_history_entries(entries: Array) -> void:
	if entries.size() == 1:
		var single: Dictionary = entries[0]
		_push_history_entry(single)
	else:
		_push_history_entry({"edits": entries.duplicate()})

func _push_history_entry(entry: Dictionary) -> void:
	_undo_stack.append(entry)
	if _undo_stack.size() > MAX_EDIT_HISTORY:
		_undo_stack.pop_front()
	_redo_stack.clear()

func _apply_history_entry(entry: Dictionary, undo: bool) -> bool:
	if entry.has("edits"):
		var edits: Array = entry["edits"]
		var ordered := edits.duplicate()
		if undo:
			ordered.reverse()
		var ok := true
		for raw in ordered:
			var sub_entry: Dictionary = raw
			if not _apply_history_entry(sub_entry, undo):
				ok = false
		return ok
	var pos: Vector3i = entry["pos"]
	var id := int(entry["before"] if undo else entry["after"])
	return set_block(pos.x, pos.y, pos.z, id)

func _entry_action_label(entry: Dictionary) -> String:
	if entry.has("edits"):
		var edits: Array = entry["edits"]
		if edits.is_empty():
			return "批量编辑"
		var first: Dictionary = edits[0]
		var before := int(first.get("before", BlockLibrary.AIR))
		var after := int(first.get("after", BlockLibrary.AIR))
		if after == BlockLibrary.AIR:
			return "批量挖掘 %d 格" % edits.size()
		if before == BlockLibrary.AIR:
			return "批量放置 %s x%d" % [_block_label(after), edits.size()]
		return "批量编辑 %d 格" % edits.size()
	var before := int(entry["before"])
	var after := int(entry["after"])
	if after == BlockLibrary.AIR:
		return "挖掘 " + _block_label(before)
	if before == BlockLibrary.AIR:
		return "放置 " + _block_label(after)
	return "替换为 " + _block_label(after)

func _block_label(id: int) -> String:
	if lib != null and lib.has_def(id):
		return lib.block_name(id)
	return "方块"

# ---------- 数据生成 ----------
func _ensure_data(cc: Vector2i) -> void:
	if _chunks.has(cc):
		return
	var ch := Chunk.new(cc.x, cc.y)
	_gen.generate(ch)
	# 程序化基线快照（套用增量之前）—— _record_delta 用它做 O(1) 比较，省去每格整块重生。
	# 运行期缓存，不写存档。
	ch.base_blocks = ch.blocks.duplicate()
	_apply_deltas_to_chunk(cc, ch)
	_chunks[cc] = ch

func _chunk_key(cc: Vector2i) -> String:
	return "%d,%d" % [cc.x, cc.y]

func _chunk_from_key(key: String) -> Vector2i:
	var parts := key.split(",")
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))

func _world_pos_from_chunk_index(cc: Vector2i, idx: int) -> Vector3i:
	var lx := idx % Chunk.SX
	var yz := int(idx / Chunk.SX)
	var lz := yz % Chunk.SZ
	var y := int(yz / Chunk.SZ)
	return Vector3i(cc.x * Chunk.SX + lx, y, cc.y * Chunk.SZ + lz)

func _base_block(cc: Vector2i, lx: int, wy: int, lz: int) -> int:
	# 优先用 _ensure_data 存下的基线快照做 O(1) 查表。
	if _chunks.has(cc):
		var ch: Chunk = _chunks[cc]
		var idx := Chunk.index(lx, wy, lz)
		if idx >= 0 and idx < ch.base_blocks.size():
			return ch.base_blocks[idx]
	# 兜底：快照缺失（极少见，例如外部直接塞进来的 chunk）才整块重生。
	var base := Chunk.new(cc.x, cc.y)
	_gen.generate(base)
	return base.get_block(lx, wy, lz)

func _record_delta(cc: Vector2i, lx: int, wy: int, lz: int, id: int) -> void:
	var idx := Chunk.index(lx, wy, lz)
	var key := _chunk_key(cc)
	var base_id := _base_block(cc, lx, wy, lz)
	if id == base_id:
		if _deltas.has(key):
			var edits: Dictionary = _deltas[key]
			if edits.erase(str(idx)):
				_delta_dirty = true
				if edits.is_empty():
					_deltas.erase(key)
		return
	if not _deltas.has(key):
		_deltas[key] = {}
	var chunk_edits: Dictionary = _deltas[key]
	chunk_edits[str(idx)] = id
	_delta_dirty = true

func _apply_deltas_to_chunk(cc: Vector2i, chunk: Chunk) -> void:
	var key := _chunk_key(cc)
	if not _deltas.has(key):
		return
	var edits: Dictionary = _deltas[key]
	for idx_key in edits.keys():
		var idx := int(idx_key)
		if idx >= 0 and idx < chunk.blocks.size():
			chunk.blocks[idx] = int(edits[idx_key])
			chunk.dirty = true

func edit_count() -> int:
	var n := 0
	for key in _deltas.keys():
		var edits: Dictionary = _deltas[key]
		n += edits.size()
	return n

func edited_blocks_near(pos: Vector3i, radius: int = LANDMARK_RESTORE_RADIUS, vertical_radius: int = LANDMARK_RESTORE_VERTICAL_RADIUS) -> int:
	var count := 0
	for key in _deltas.keys():
		var cc := _chunk_from_key(str(key))
		if abs(cc.x * Chunk.SX - pos.x) > radius + Chunk.SX and abs((cc.x + 1) * Chunk.SX - pos.x) > radius:
			continue
		if abs(cc.y * Chunk.SZ - pos.z) > radius + Chunk.SZ and abs((cc.y + 1) * Chunk.SZ - pos.z) > radius:
			continue
		var edits: Dictionary = _deltas[key]
		for idx_key in edits.keys():
			var block_id := int(edits[idx_key])
			if block_id == BlockLibrary.AIR or (lib != null and not lib.is_renderable(block_id)):
				continue
			var world_pos := _world_pos_from_chunk_index(cc, int(idx_key))
			if abs(world_pos.x - pos.x) <= radius \
					and abs(world_pos.z - pos.z) <= radius \
					and abs(world_pos.y - pos.y) <= vertical_radius:
				count += 1
	return count

func landmark_restoration(pos: Vector3i) -> Dictionary:
	var edits := edited_blocks_near(pos)
	var percent := clampi(int(round(float(edits) * 100.0 / float(LANDMARK_RESTORE_TARGET))), 0, 100)
	return {
		"count": edits,
		"target": LANDMARK_RESTORE_TARGET,
		"percent": percent,
		"label": _restoration_label(percent),
		"complete": percent >= 100,
	}

func restored_landmark_count() -> int:
	var count := 0
	for raw_key in discovery_keys():
		var restoration := landmark_restoration(_pos_from_key(str(raw_key)))
		if bool(restoration.get("complete", false)):
			count += 1
	return count

func best_landmark_restoration_percent() -> int:
	var best := 0
	for raw_key in discovery_keys():
		var restoration := landmark_restoration(_pos_from_key(str(raw_key)))
		best = max(best, int(restoration.get("percent", 0)))
	return best

func _restoration_label(percent: int) -> String:
	if percent >= 100:
		return "修复完成"
	if percent >= 60:
		return "焕新中"
	if percent > 0:
		return "修复中"
	return "待修复"

func has_unsaved_changes() -> bool:
	return _delta_dirty or _meta_dirty

func loaded_from_backup() -> bool:
	return _loaded_from_backup

func set_cover_path(path: String) -> void:
	var clean := path.strip_edges()
	if cover_path == clean:
		return
	cover_path = clean
	_meta_dirty = true

func mark_landmark_discovered(pos: Vector3i) -> bool:
	var key := _pos_key(pos)
	if _discoveries.has(key):
		return false
	_discoveries[key] = true
	_meta_dirty = true
	return true

func is_landmark_discovered(pos: Vector3i) -> bool:
	return _discoveries.has(_pos_key(pos))

func discovery_count() -> int:
	return _discoveries.size()

func discovery_keys() -> Array:
	var keys := _discoveries.keys()
	keys.sort()
	return keys

func mark_journey_step(key: String) -> bool:
	if not JOURNEY_STEPS.has(key) or _journey_steps.has(key):
		return false
	_journey_steps[key] = true
	_meta_dirty = true
	return true

func is_journey_step_done(key: String) -> bool:
	return _journey_steps.has(key)

func journey_steps() -> Array:
	var keys := _journey_steps.keys()
	keys.sort_custom(func(a, b) -> bool:
		return JOURNEY_STEPS.find(str(a)) < JOURNEY_STEPS.find(str(b))
	)
	return keys

func journey_count() -> int:
	return _journey_steps.size()

func journey_total() -> int:
	return JOURNEY_STEPS.size()

func mark_region_visited(label: String, mark_dirty: bool = true) -> bool:
	var clean := label.strip_edges()
	if clean == "" or _visited_regions.has(clean):
		return false
	_visited_regions[clean] = true
	if mark_dirty:
		_meta_dirty = true
	return true

func visited_regions() -> Array:
	var labels := _visited_regions.keys()
	labels.sort_custom(func(a, b) -> bool:
		var ia := WorldGenerator.REGION_LABELS.find(str(a))
		var ib := WorldGenerator.REGION_LABELS.find(str(b))
		if ia == -1:
			ia = WorldGenerator.REGION_LABELS.size()
		if ib == -1:
			ib = WorldGenerator.REGION_LABELS.size()
		if ia != ib:
			return ia < ib
		return str(a) < str(b)
	)
	return labels

func region_count() -> int:
	return _visited_regions.size()

func region_total() -> int:
	return WorldGenerator.REGION_LABELS.size()

func load_world() -> bool:
	_loaded_from_backup = false
	if save_path == "" or (not FileAccess.file_exists(save_path) and not FileAccess.file_exists(_backup_save_path())):
		return false
	var loaded := _read_save_with_backup()
	if loaded.is_empty():
		return false
	var data: Dictionary = loaded["data"]
	var loaded_from_backup := bool(loaded.get("from_backup", false))
	cover_path = String(data.get("cover_path", ""))
	_deltas.clear()
	_discoveries.clear()
	_journey_steps.clear()
	_visited_regions.clear()
	clear_edit_history()
	var edits_raw: Variant = data.get("edits", {})
	if typeof(edits_raw) == TYPE_DICTIONARY:
		var raw_dict: Dictionary = edits_raw
		for key in raw_dict.keys():
			var raw_chunk: Variant = raw_dict[key]
			if typeof(raw_chunk) != TYPE_DICTIONARY:
				continue
			var clean := {}
			var raw_edits: Dictionary = raw_chunk
			for idx_key in raw_edits.keys():
				clean[str(idx_key)] = int(raw_edits[idx_key])
			if not clean.is_empty():
				_deltas[str(key)] = clean
	var discoveries_raw: Variant = data.get("discoveries", [])
	if typeof(discoveries_raw) == TYPE_ARRAY:
		for raw in discoveries_raw:
			var key := str(raw)
			if _is_valid_pos_key(key):
				_discoveries[key] = true
	var journey_raw: Variant = data.get("journey_steps", [])
	if typeof(journey_raw) == TYPE_ARRAY:
		for raw in journey_raw:
			var step := str(raw)
			if JOURNEY_STEPS.has(step):
				_journey_steps[step] = true
	var regions_raw: Variant = data.get("visited_regions", [])
	if typeof(regions_raw) == TYPE_ARRAY:
		for raw in regions_raw:
			var label := str(raw).strip_edges()
			if label != "":
				_visited_regions[label] = true
	_delta_dirty = false
	_meta_dirty = false
	_loaded_from_backup = loaded_from_backup
	if loaded_from_backup:
		_meta_dirty = true
		save_feedback.emit("save", "已从备份恢复世界")
	elif edit_count() > 0:
		save_feedback.emit("save", "已载入世界")
	return true

func save_world(force: bool = false) -> bool:
	if save_path == "":
		return false
	if not force and not has_unsaved_changes():
		return true
	var dir := save_path.get_base_dir()
	if dir != "":
		var abs_dir := ProjectSettings.globalize_path(dir)
		DirAccess.make_dir_recursive_absolute(abs_dir)
	var data := {
		"version": SAVE_VERSION,
		"seed": _world_seed,
		"updated_at": Time.get_unix_time_from_system(),
		"cover_path": cover_path,
		"edit_count": edit_count(),
		"discovery_count": discovery_count(),
		"restored_count": restored_landmark_count(),
		"best_restore_percent": best_landmark_restoration_percent(),
		"journey_count": journey_count(),
		"journey_steps": journey_steps(),
		"region_count": region_count(),
		"region_total": region_total(),
		"visited_regions": visited_regions(),
		"edits": _deltas,
		"discoveries": discovery_keys(),
	}
	if not _write_save_text(JSON.stringify(data, "\t")):
		return false
	_delta_dirty = false
	_meta_dirty = false
	_loaded_from_backup = false
	save_feedback.emit("save", "世界已保存")
	return true

func _read_save_with_backup() -> Dictionary:
	var primary := _read_save_file(save_path)
	if not primary.is_empty():
		return {"data": primary, "from_backup": false}
	var backup_path := _backup_save_path()
	if not FileAccess.file_exists(backup_path):
		return {}
	var backup := _read_save_file(backup_path)
	if backup.is_empty():
		return {}
	return {"data": backup, "from_backup": true}

func _read_save_file(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parser := JSON.new()
	var err := parser.parse(text)
	if err != OK:
		push_warning("存档读取失败：JSON 格式不正确 %s（%s，第 %d 行）" % [path, parser.get_error_message(), parser.get_error_line()])
		return {}
	var parsed: Variant = parser.data
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("存档读取失败：JSON 格式不正确 %s" % path)
		return {}
	return parsed

func _write_save_text(text: String) -> bool:
	var tmp_path := _temp_save_path()
	var backup_path := _backup_save_path()
	var abs_save := ProjectSettings.globalize_path(save_path)
	var abs_tmp := ProjectSettings.globalize_path(tmp_path)
	var abs_backup := ProjectSettings.globalize_path(backup_path)
	if FileAccess.file_exists(tmp_path):
		DirAccess.remove_absolute(abs_tmp)
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		push_warning("存档临时文件写入失败：%s" % tmp_path)
		return false
	f.store_string(text)
	f.close()
	var had_primary := FileAccess.file_exists(save_path)
	if had_primary:
		if FileAccess.file_exists(backup_path):
			var remove_err := DirAccess.remove_absolute(abs_backup)
			if remove_err != OK:
				DirAccess.remove_absolute(abs_tmp)
				push_warning("旧存档备份清理失败：%s" % backup_path)
				return false
		var backup_err := DirAccess.rename_absolute(abs_save, abs_backup)
		if backup_err != OK:
			DirAccess.remove_absolute(abs_tmp)
			push_warning("存档备份创建失败：%s" % backup_path)
			return false
	var final_err := DirAccess.rename_absolute(abs_tmp, abs_save)
	if final_err != OK:
		if had_primary and FileAccess.file_exists(backup_path) and not FileAccess.file_exists(save_path):
			DirAccess.rename_absolute(abs_backup, abs_save)
		push_warning("存档替换失败：%s" % save_path)
		return false
	return true

func _temp_save_path() -> String:
	return save_path + ".tmp"

func _backup_save_path() -> String:
	return save_path + ".bak"

func _pos_key(pos: Vector3i) -> String:
	return "%d,%d,%d" % [pos.x, pos.y, pos.z]

func _pos_from_key(key: String) -> Vector3i:
	var parts := key.split(",")
	if parts.size() != 3:
		return Vector3i.ZERO
	return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))

func _is_valid_pos_key(key: String) -> bool:
	var parts := key.split(",")
	if parts.size() != 3:
		return false
	for part in parts:
		if not String(part).is_valid_int():
			return false
	var y := int(parts[1])
	return y >= 0 and y < Chunk.SY

func _ensure_data_with_margin(cc: Vector2i) -> void:
	_ensure_data(cc)
	for d in NEI:
		_ensure_data(cc + d)

func _blocks_or_null(cc: Vector2i):
	return _chunks[cc].blocks if _chunks.has(cc) else null

# ---------- 同步重建（开局/编辑兜底）----------
# 同步一把梭：开局 prime/generate_initial 用；也作为"脚下必须立刻可见"的最小兜底
# （直接 API 单测、不在场景树时也走这里）。会无条件刷新该块灯光。
func _remesh_sync(cc: Vector2i) -> void:
	if not _chunks.has(cc):
		return
	_version[cc] = int(_version.get(cc, 0)) + 1   # 作废任何在途的后台结果
	var ch: Chunk = _chunks[cc]
	var built := ChunkMesher.build(ch, lib,
		_chunks.get(cc + Vector2i(-1, 0)), _chunks.get(cc + Vector2i(1, 0)),
		_chunks.get(cc + Vector2i(0, -1)), _chunks.get(cc + Vector2i(0, 1)))
	_light_dirty[cc] = true        # 同步路径无条件刷新灯光
	_apply_node(cc, built)

# 编辑后的后台重建：复用流式那套 _dispatch/_mesh_worker/_version 作废机制，
# 主线程不再做 build_arrays（大头），只在 _drain 里 assemble。
# _dispatch 会 bump 版本并重新拷贝当前最新数据，所以即便该块已在后台算，
# 再次派发也安全（旧在途结果版本对不上会被丢弃）。
func _remesh_async(cc: Vector2i) -> void:
	if not _chunks.has(cc):
		return
	_dispatch(cc)

func _apply_node(cc: Vector2i, built: Dictionary) -> void:
	var entry: Dictionary
	var is_new := false
	if _nodes.has(cc):
		entry = _nodes[cc]
	else:
		is_new = true
		var mi := MeshInstance3D.new()
		mi.position = Vector3(cc.x * Chunk.SX, 0, cc.y * Chunk.SZ)
		add_child(mi)
		var body := StaticBody3D.new()
		body.position = mi.position
		var coll := CollisionShape3D.new()
		body.add_child(coll)
		add_child(body)
		var lights := Node3D.new()
		lights.name = "ChunkLights_%d_%d" % [cc.x, cc.y]
		lights.position = mi.position
		add_child(lights)
		entry = {"mesh": mi, "body": body, "coll": coll, "lights": lights}
		_nodes[cc] = entry
	entry["mesh"].mesh = built["mesh"]
	entry["coll"].shape = built["shape"]
	# 灯光优化：仅在首次建块、或本块发光方块有增删时才重刷灯光（重刷会遍历整块）。
	if is_new or _light_dirty.has(cc):
		_refresh_chunk_lights(cc, entry)
		_light_dirty.erase(cc)
	_update_chunk_light_visibility(cc, entry)

func _is_light_block(id: int) -> bool:
	return id == BlockLibrary.LANTERN or id == BlockLibrary.MOONSTONE_LAMP or id == BlockLibrary.BLUE_CRYSTAL

func _refresh_chunk_lights(cc: Vector2i, entry: Dictionary) -> void:
	if not _chunks.has(cc):
		return
	var root: Node3D = entry.get("lights", null)
	if root == null:
		root = Node3D.new()
		root.name = "ChunkLights_%d_%d" % [cc.x, cc.y]
		root.position = Vector3(cc.x * Chunk.SX, 0, cc.y * Chunk.SZ)
		add_child(root)
		entry["lights"] = root
	# 先收集本块该亮哪些灯（位置+颜色+参数），再池化复用现有 OmniLight3D 节点，
	# 避免每次编辑都 free+new 一批节点（GC/节点开销）。
	var chunk: Chunk = _chunks[cc]
	var specs := []
	_collect_block_lights(chunk, specs, BlockLibrary.LANTERN, Color(1.0, 0.70, 0.30), 1.45, 7.5)
	_collect_block_lights(chunk, specs, BlockLibrary.MOONSTONE_LAMP, Color(0.58, 0.76, 1.0), 1.08, 6.8)
	_collect_block_lights(chunk, specs, BlockLibrary.BLUE_CRYSTAL, Color(0.30, 0.68, 1.0), 0.62, 5.2)
	if specs.size() > CHUNK_LIGHT_LIMIT:
		specs.resize(CHUNK_LIGHT_LIMIT)
	var pool := root.get_children()
	for i in range(specs.size()):
		var spec: Dictionary = specs[i]
		var light: OmniLight3D
		if i < pool.size():
			light = pool[i]                     # 复用已有节点
		else:
			light = OmniLight3D.new()
			light.shadow_enabled = false
			root.add_child(light)
		var pos: Vector3i = spec["pos"]
		light.position = Vector3(float(pos.x) + 0.5, float(pos.y) + 0.5, float(pos.z) + 0.5)
		light.light_color = spec["color"]
		light.light_energy = spec["energy"]
		light.omni_range = spec["radius"]
	# 释放多余的池节点
	for i in range(specs.size(), pool.size()):
		var extra: Node = pool[i]
		root.remove_child(extra)
		extra.free()
	root.visible = specs.size() > 0

func _refresh_all_chunk_light_visibility() -> void:
	for cc in _nodes.keys():
		var entry: Dictionary = _nodes[cc]
		_update_chunk_light_visibility(cc, entry)

func _update_chunk_light_visibility(cc: Vector2i, entry: Dictionary) -> void:
	if not entry.has("lights"):
		return
	var root: Node3D = entry["lights"]
	root.visible = root.get_child_count() > 0 and _chunk_lights_active(cc)

func _chunk_lights_active(cc: Vector2i) -> bool:
	if abs(_center.x) > 900000:
		return true
	return max(abs(cc.x - _center.x), abs(cc.y - _center.y)) <= LIGHT_ACTIVE_RADIUS

# 收集某发光方块在本块内的位置（最多到全局上限），追加到 specs。
func _collect_block_lights(chunk: Chunk, specs: Array, block_id: int, color: Color, energy: float, radius: float) -> void:
	if specs.size() >= CHUNK_LIGHT_LIMIT:
		return
	for y in range(Chunk.SY):
		for z in range(Chunk.SZ):
			for x in range(Chunk.SX):
				if chunk.get_block(x, y, z) != block_id:
					continue
				specs.append({"pos": Vector3i(x, y, z), "color": color, "energy": energy, "radius": radius})
				if specs.size() >= CHUNK_LIGHT_LIMIT:
					return

# ---------- 开局 ----------
func prime(center: Vector2i, r: int) -> void:
	for dz in range(-(r + 1), r + 2):
		for dx in range(-(r + 1), r + 2):
			_ensure_data(center + Vector2i(dx, dz))
	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			_remesh_sync(center + Vector2i(dx, dz))
	_center = Vector2i(999999, 0)

func generate_initial(center: Vector2i) -> void:
	_center = center
	for dz in range(-(view_radius + 1), view_radius + 2):
		for dx in range(-(view_radius + 1), view_radius + 2):
			_ensure_data(center + Vector2i(dx, dz))
	for dz in range(-view_radius, view_radius + 1):
		for dx in range(-view_radius, view_radius + 1):
			_remesh_sync(center + Vector2i(dx, dz))

# ---------- 流式（后台线程造网格）----------
func _process(_delta: float) -> void:
	if track_target == null:
		return
	var c := chunk_of(int(track_target.global_position.x), int(track_target.global_position.z))
	if c != _center:
		_center = c
		_rebuild_queue(c)
		_unload_far(c)
		_refresh_all_chunk_light_visibility()
	# 派发后台任务（派发很轻：拷贝数据 + 入池）
	var t0 := Time.get_ticks_msec()
	while not _queue.is_empty() and _meshing.size() < _max_inflight and Time.get_ticks_msec() - t0 < 3:
		var cc: Vector2i = _queue.pop_front()
		if _nodes.has(cc) or _meshing.has(cc):
			continue
		_dispatch(cc)
	_drain()

func _dispatch(cc: Vector2i) -> void:
	_ensure_data_with_margin(cc)               # 数据在主线程生成
	# 拷贝字节数组给后台线程，彻底避免数据竞争
	var d: PackedByteArray = _chunks[cc].blocks.duplicate()
	var a_nx = _dup(cc + Vector2i(-1, 0))
	var a_px = _dup(cc + Vector2i(1, 0))
	var a_nz = _dup(cc + Vector2i(0, -1))
	var a_pz = _dup(cc + Vector2i(0, 1))
	# 派发即 bump 版本：作废任何在途的旧结果（含编辑前的流式结果），保证只有最新一次会被采用。
	_version[cc] = int(_version.get(cc, 0)) + 1
	var ver: int = int(_version[cc])
	_meshing[cc] = true
	# 查找表只读、建好后不再改 -> 传引用即可（不再每任务 duplicate）。方块数组是私有拷贝。
	var task_id := WorkerThreadPool.add_task(_mesh_worker.bind(cc, ver, d, a_nx, a_px, a_nz, a_pz,
		_solid, _opaque, _transp, _water, _ttop, _tside, _tbot, _matbucket))
	_mutex.lock()
	_tasks[task_id] = true
	_mutex.unlock()

func _dup(cc: Vector2i):
	return _chunks[cc].blocks.duplicate() if _chunks.has(cc) else null

# 在后台线程跑：只算数组，不碰场景/资源/Dictionary（方块数组是私有拷贝；LUT 只读共享）
func _mesh_worker(cc: Vector2i, ver: int, d, a_nx, a_px, a_nz, a_pz, solid, opaque, transp, water, ttop, tside, tbot, matbucket) -> void:
	var arrays := ChunkMesher.build_arrays(d, a_nx, a_px, a_nz, a_pz, solid, opaque, transp, water, ttop, tside, tbot, matbucket)
	var task_id := WorkerThreadPool.get_caller_task_id()
	if _mutex == null:
		return   # 节点正在退出（关游戏），丢弃结果即可
	_mutex.lock()
	_results.append({"cc": cc, "ver": ver, "arrays": arrays})
	_tasks.erase(task_id)
	_mutex.unlock()

func _drain() -> void:
	_mutex.lock()
	var got := _results
	_results = []
	_mutex.unlock()
	for r in got:
		_pending_apply.append(r)
	var n := 0
	while not _pending_apply.is_empty() and n < APPLY_PER_FRAME:
		var r: Dictionary = _pending_apply.pop_front()
		var cc: Vector2i = r["cc"]
		n += 1
		# 只有当这条结果是该区块最新一次派发时才清除 in-flight 标记；
		# 否则（被后续编辑/卸载 bump 过版本）说明还有更新的任务在途，保留标记。
		var stale: bool = int(r["ver"]) != int(_version.get(cc, 0))
		if not stale:
			_meshing.erase(cc)
		if stale:
			continue   # 期间被编辑/卸载，丢弃
		if max(abs(cc.x - _center.x), abs(cc.y - _center.y)) > view_radius + 1:
			continue   # 已经走远，别建了
		_apply_node(cc, ChunkMesher.assemble(r["arrays"], lib))

func _rebuild_queue(c: Vector2i) -> void:
	_queue.clear()
	for r in range(0, view_radius + 1):
		for dz in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if max(abs(dx), abs(dz)) != r:
					continue
				var cc := c + Vector2i(dx, dz)
				if not _nodes.has(cc):
					_queue.append(cc)

func _unload_far(c: Vector2i) -> void:
	var drop := []
	for cc in _nodes.keys():
		if max(abs(cc.x - c.x), abs(cc.y - c.y)) > view_radius + 1:
			drop.append(cc)
	for cc in drop:
		var e: Dictionary = _nodes[cc]
		e["mesh"].queue_free()
		e["body"].queue_free()
		if e.has("lights"):
			e["lights"].queue_free()
		_nodes.erase(cc)
		_chunks.erase(cc)
		_light_dirty.erase(cc)
		_version[cc] = int(_version.get(cc, 0)) + 1   # 作废在途结果，免得又建回来
	# 清掉走远的 in-flight 标记，免得其结果被作废丢弃后标记残留、导致重回时不再重建。
	for cc in _meshing.keys():
		if max(abs(cc.x - c.x), abs(cc.y - c.y)) > view_radius + 1:
			_meshing.erase(cc)

# ---------- 线程安全收尾 ----------
# 退出/切换世界时：先把所有在途的 WorkerThreadPool 任务排空，再让本对象（含 _mutex）被释放。
# 这样不会有后台线程在对象释放后还去访问已失效的 _mutex / self。
func _exit_tree() -> void:
	_drain_all_tasks()

func _drain_all_tasks() -> void:
	if _mutex == null:
		return
	# 在锁内快照所有 task_id（完成的 worker 会自行从 _tasks 移除；快照后等待已完成的任务也安全）。
	_mutex.lock()
	var ids := _tasks.keys()
	_mutex.unlock()
	for task_id in ids:
		WorkerThreadPool.wait_for_task_completion(int(task_id))
	# 所有 worker 已返回，不会再触碰 _mutex。清空残留状态。
	_mutex.lock()
	_tasks.clear()
	_results.clear()
	_mutex.unlock()
	_meshing.clear()
	_pending_apply.clear()
