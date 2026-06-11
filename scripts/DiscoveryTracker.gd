extends Node
# 探索发现：靠近世界内地标时发出一次性反馈。

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")

const DISCOVERY_RADIUS := 11.0
const HINT_RADIUS := 44.0
const SCAN_INTERVAL := 0.35

signal discovery_feedback(kind: String, label: String)
signal landmark_discovered(position: Vector3i, label: String)
signal nearby_hint_changed(distance: int, direction: String)

var world
var target: Node3D

var _discovered := {}
var _chunk_cache := {}            # 地表遗迹枚举缓存（外部 test/扫描遍历的口径，保持单一职责）
var _underground_cache := {}      # 地下祭坛枚举缓存（与地表分离，避免顺序/口径互相污染）
var _scan_t := 0.0
var _nearby_hint_distance := -1
var _nearby_hint_direction := ""
var _nearby_hint_position := Vector3.ZERO

# 矿物图鉴：玩家首次挖出每种矿石/蓝晶时，经现有 discovery_feedback 信号触发一次 HUD/手记反馈。
# 通过现有对 world 的引用，轮询 world 的玩家增量(_deltas)里"刚被挖空(AIR)且程序基线是该矿"的格子。
# 不改 Player/World：用 World 已有的 _base_block / _world_pos_from_chunk_index 接口。
var _first_mined := {}            # block_id -> true，已入图鉴的矿物
var _scanned_delta_keys := {}     # "ck#idx" -> true，已检视过的增量格，避免每帧重扫全部增量

func setup(world_node, target_node: Node3D) -> void:
	world = world_node
	target = target_node
	_load_discoveries_from_world()

func discovered_count() -> int:
	return _discovered.size()

func discovered_entries() -> Array:
	_load_discoveries_from_world()
	var entries := []
	var keys := _discovered.keys()
	keys.sort()
	for raw_key in keys:
		var key := str(raw_key)
		var pos := _pos_from_key(key)
		if pos.y < 0:
			continue
		var label := "古遗迹"
		if world != null:
			label = _landmark_label(pos).replace("发现", "")
		var restoration := _restoration_for(pos)
		var archive := _landmark_archive(pos, restoration)
		entries.append({
			"label": label,
			"type": _landmark_type_label(pos),
			"guardian": _landmark_guardian(pos),
			"archive": archive,
			"pos": "%d, %d, %d" % [pos.x, pos.y, pos.z],
			"world_pos": Vector3(pos.x, pos.y, pos.z),
			"restore_count": int(restoration.get("count", 0)),
			"restore_target": int(restoration.get("target", 20)),
			"restore_percent": int(restoration.get("percent", 0)),
			"restore_label": String(restoration.get("label", "待修复")),
			"restore_complete": bool(restoration.get("complete", false)),
			"key": key,
		})
	return entries

func _restoration_for(pos: Vector3i) -> Dictionary:
	if world != null and world.has_method("landmark_restoration"):
		return world.landmark_restoration(pos)
	return {"count": 0, "target": 20, "percent": 0, "label": "待修复", "complete": false}

func nearby_hint_distance() -> int:
	return _nearby_hint_distance

func nearby_hint_direction() -> String:
	return _nearby_hint_direction

func nearby_hint_position() -> Vector3:
	return _nearby_hint_position

func scan_now() -> int:
	if world == null or target == null:
		return 0
	var before := discovered_count()
	_scan_loaded_landmarks()
	return discovered_count() - before

func _process(delta: float) -> void:
	_scan_t -= delta
	if _scan_t > 0.0:
		return
	_scan_t = SCAN_INTERVAL
	scan_now()
	_scan_mineral_codex()

func _scan_loaded_landmarks() -> void:
	var origin := target.global_position if target.is_inside_tree() else target.position
	var nearest := INF
	var nearest_pos := Vector3.ZERO
	var has_nearest := false
	for cc in world._chunks.keys():
		for pos in _all_landmarks_for_chunk(cc):
			var landmark: Vector3i = pos
			var key := _pos_key(landmark)
			if _is_discovered(landmark, key):
				_discovered[key] = true
				continue
			if not _landmark_still_exists(landmark):
				continue
			var p := Vector3(landmark) + Vector3(0.5, 0.5, 0.5)
			var distance := p.distance_to(origin)
			if distance <= DISCOVERY_RADIUS:
				_remember_discovery(landmark, key)
				var label := _landmark_label(landmark)
				discovery_feedback.emit("discover", label)
				landmark_discovered.emit(landmark, label)
				continue
			if distance < nearest:
				nearest = distance
				nearest_pos = p
				has_nearest = true
	_update_nearby_hint(nearest, nearest_pos, origin, has_nearest)

func _update_nearby_hint(nearest: float, nearest_pos: Vector3, origin: Vector3, has_nearest: bool) -> void:
	var next := -1
	var direction := ""
	if has_nearest and nearest <= HINT_RADIUS:
		next = ceili(nearest)
		direction = _relative_direction_label(nearest_pos - origin)
		_nearby_hint_position = nearest_pos
	else:
		_nearby_hint_position = Vector3.ZERO
	if next == _nearby_hint_distance and direction == _nearby_hint_direction:
		return
	_nearby_hint_distance = next
	_nearby_hint_direction = direction
	nearby_hint_changed.emit(_nearby_hint_distance, _nearby_hint_direction)

func _landmarks_for_chunk(cc: Vector2i) -> Array:
	if _chunk_cache.has(cc):
		return _chunk_cache[cc]
	var found := []
	if world == null or not world._chunks.has(cc):
		return found
	var chunk: Chunk = world._chunks[cc]
	for y in range(1, Chunk.SY):
		for z in range(Chunk.SZ):
			for x in range(Chunk.SX):
				# 地表遗迹锚点：LANTERN 立于 MARBLE 基座之上。
				if chunk.get_block(x, y, z) != BlockLibrary.LANTERN:
					continue
				if chunk.get_block(x, y - 1, z) != BlockLibrary.MARBLE:
					continue
				if _local_ruin_score(chunk, x, y - 1, z) < 10:
					continue
				found.append(Vector3i(cc.x * Chunk.SX + x, y, cc.y * Chunk.SZ + z))
	_chunk_cache[cc] = found
	return found

# 地下祭坛锚点：SUNSTONE 立于 MARBLE 基座之上（与地表 LANTERN 锚区分，互不误判）。
# 单独枚举/缓存：让"发现+修复"循环延伸到地下，同时不污染地表遗迹枚举（外部按地表遗迹遍历的逻辑稳定）。
func _underground_landmarks_for_chunk(cc: Vector2i) -> Array:
	if _underground_cache.has(cc):
		return _underground_cache[cc]
	var found := []
	if world == null or not world._chunks.has(cc):
		return found
	var chunk: Chunk = world._chunks[cc]
	for y in range(2, Chunk.SY):
		for z in range(Chunk.SZ):
			for x in range(Chunk.SX):
				if chunk.get_block(x, y, z) != BlockLibrary.SUNSTONE:
					continue
				# 锚下两格皆 MARBLE 基座（区分四向 SUNSTONE 点缀），并需足够石质结构。
				if chunk.get_block(x, y - 1, z) != BlockLibrary.MARBLE:
					continue
				if chunk.get_block(x, y - 2, z) != BlockLibrary.MARBLE:
					continue
				if _local_ruin_score(chunk, x, y - 1, z) < 10:
					continue
				found.append(Vector3i(cc.x * Chunk.SX + x, y, cc.y * Chunk.SZ + z))
	_underground_cache[cc] = found
	return found

# 发现扫描用：地表遗迹 + 地下祭坛的合集（地表在前，保持外部地表枚举的既有顺序）。
func _all_landmarks_for_chunk(cc: Vector2i) -> Array:
	var out := _landmarks_for_chunk(cc).duplicate()
	out.append_array(_underground_landmarks_for_chunk(cc))
	return out

func _landmark_still_exists(pos: Vector3i) -> bool:
	var anchor: int = world.get_block(pos.x, pos.y, pos.z)
	return (anchor == BlockLibrary.LANTERN or anchor == BlockLibrary.SUNSTONE) \
		and world.get_block(pos.x, pos.y - 1, pos.z) == BlockLibrary.MARBLE

func _landmark_label(pos: Vector3i) -> String:
	var marker: int = world.get_block(pos.x, pos.y - 2, pos.z)
	var name := _landmark_name(pos)
	return _t("DISCOVERY_LANDMARK") % [name, _landmark_type_label(pos, marker)]

func _landmark_type_label(pos: Vector3i, marker: int = -999) -> String:
	# SUNSTONE 锚 -> 地下祭坛（地下地标）。其余按"锚下 2 格"的结构 marker 区分地表遗迹类型。
	if world != null and world.get_block(pos.x, pos.y, pos.z) == BlockLibrary.SUNSTONE:
		return _t("LANDMARK_TYPE_UNDERGROUND_ALTAR")
	if marker == -999 and world != null:
		marker = world.get_block(pos.x, pos.y - 2, pos.z)
	match marker:
		BlockLibrary.BRICK:
			return _t("LANDMARK_TYPE_WATCHTOWER")
		BlockLibrary.COBBLE:
			return _t("LANDMARK_TYPE_STONE_CIRCLE")
		_:
			return _t("LANDMARK_TYPE_ANCIENT_RELIC")

func _landmark_name(pos: Vector3i) -> String:
	var words := PackedStringArray([
		"晨雾", "星火", "青苔", "白石", "松影", "月湾",
		"风铃", "云脊", "蓝晶", "远山", "浅溪", "暮光",
	])
	var h: int = abs(pos.x * 73856093 ^ pos.y * 19349663 ^ pos.z * 83492791)
	return words[h % words.size()]

func _landmark_guardian(pos: Vector3i) -> String:
	var guardians := [
		"月石灯", "风化石阶", "青苔刻纹", "旧砖拱顶",
		"蓝晶碎片", "苔石基座", "铜色火盆", "白石残柱",
	]
	return String(guardians[_landmark_hash(pos, 11) % guardians.size()])

func _landmark_archive(pos: Vector3i, restoration: Dictionary) -> String:
	var state := _landmark_archive_state(int(restoration.get("percent", 0)), bool(restoration.get("complete", false)))
	return "%s · 守护物  %s · %s" % [_landmark_mood(pos), _landmark_guardian(pos), state]

func _landmark_mood(pos: Vector3i) -> String:
	var moods := [
		"薄雾仍绕着旧墙",
		"风声在石缝间回旋",
		"苔痕沿基座漫开",
		"残光落在高处砖沿",
		"浅溪声从远处传来",
		"云影缓慢掠过石面",
	]
	return String(moods[_landmark_hash(pos, 23) % moods.size()])

func _landmark_archive_state(percent: int, complete: bool) -> String:
	if complete or percent >= 100:
		return "灯火已经重新照亮遗迹"
	if percent > 0:
		return "新放置的方块正把断裂处接合"
	return "结构尚待修复"

func _landmark_hash(pos: Vector3i, salt: int = 0) -> int:
	return abs(pos.x * 73856093 ^ pos.y * 19349663 ^ pos.z * 83492791 ^ salt * 2654435761)

func _local_ruin_score(chunk: Chunk, cx: int, cy: int, cz: int) -> int:
	var score := 0
	for dz in range(-3, 4):
		for dx in range(-3, 4):
			for dy in range(-1, 4):
				var x := cx + dx
				var y := cy + dy
				var z := cz + dz
				if not chunk.in_bounds(x, y, z):
					continue
				var id := chunk.get_block(x, y, z)
				if id == BlockLibrary.COBBLE \
						or id == BlockLibrary.MOSSY_STONE \
						or id == BlockLibrary.BRICK \
						or id == BlockLibrary.MARBLE \
						or id == BlockLibrary.LANTERN:
					score += 1
	return score

func _pos_key(pos: Vector3i) -> String:
	return "%d,%d,%d" % [pos.x, pos.y, pos.z]

func _pos_from_key(key: String) -> Vector3i:
	var parts := key.split(",")
	if parts.size() != 3:
		return Vector3i(0, -1, 0)
	for part in parts:
		if not String(part).is_valid_int():
			return Vector3i(0, -1, 0)
	return Vector3i(int(parts[0]), int(parts[1]), int(parts[2]))

func _relative_direction_label(to_landmark: Vector3) -> String:
	var flat := Vector3(to_landmark.x, 0.0, to_landmark.z)
	if flat.length_squared() < 0.001:
		return _t("HUD_NAV_NEARBY")
	var basis := target.global_transform.basis if target.is_inside_tree() else target.transform.basis
	var forward := -basis.z
	var right := basis.x
	var angle := atan2(flat.normalized().dot(right), flat.normalized().dot(forward))
	var sector := int(round(angle / (PI / 4.0)))
	sector = posmod(sector, 8)
	match sector:
		0: return _t("DIR_REL_FRONT")
		1: return _t("DIR_REL_FRONT_RIGHT")
		2: return _t("DIR_REL_RIGHT")
		3: return _t("DIR_REL_BACK_RIGHT")
		4: return _t("DIR_REL_BACK")
		5: return _t("DIR_REL_BACK_LEFT")
		6: return _t("DIR_REL_LEFT")
		_: return _t("DIR_REL_FRONT_LEFT")

# 经节点路径取 Locale 自动加载单例（不要用裸标识符 `Locale`）：见 HUD/Player 同款注释。
# 仅相对方位词（前方/右前…）属于界面文案在此本地化；地标名称/类型仍为中文世界内容。
var _loc_cached: Node
func _loc() -> Node:
	if _loc_cached != null and is_instance_valid(_loc_cached):
		return _loc_cached
	var tree := get_tree() if is_inside_tree() else null
	if tree != null and tree.root != null:
		_loc_cached = tree.root.get_node_or_null("Locale")
	if _loc_cached == null:
		_loc_cached = (load("res://scripts/Locale.gd") as GDScript).new()
		_loc_cached.call("load_strings")
	return _loc_cached

func _t(key: String) -> String:
	var l := _loc()
	return l.t(key) if l != null else key

func _load_discoveries_from_world() -> void:
	_discovered.clear()
	if world == null or not world.has_method("discovery_keys"):
		return
	for raw in world.discovery_keys():
		_discovered[str(raw)] = true

func _is_discovered(pos: Vector3i, key: String) -> bool:
	if _discovered.has(key):
		return true
	return world != null and world.has_method("is_landmark_discovered") and world.is_landmark_discovered(pos)

func _remember_discovery(pos: Vector3i, key: String) -> void:
	_discovered[key] = true
	if world != null and world.has_method("mark_landmark_discovered"):
		world.mark_landmark_discovered(pos)

# ---------- 矿物图鉴（首次挖掘）----------
# 矿物图鉴收录的方块（矿石 + 蓝晶）。给地下探索一个明确目的：挖到新矿即解锁手记。
const CODEX_MINERALS := {
	BlockLibrary.COAL_ORE: "煤矿",
	BlockLibrary.IRON_ORE: "铁矿",
	BlockLibrary.COPPER_ORE: "铜矿",
	BlockLibrary.BLUE_CRYSTAL: "蓝晶",
}

func mineral_codex_count() -> int:
	return _first_mined.size()

func mineral_codex_total() -> int:
	return CODEX_MINERALS.size()

# 已收录矿物名（稳定顺序），供手记/HUD 读取（HUD 无需改动，靠 discovery_feedback 即可）。
func mineral_codex_entries() -> Array:
	var out := []
	for id in CODEX_MINERALS.keys():
		if _first_mined.has(id):
			out.append(String(CODEX_MINERALS[id]))
	return out

# 轮询玩家增量：找"刚被挖空(AIR)且程序基线为某矿"的格子，首次出现即经 discovery_feedback 触发反馈。
func _scan_mineral_codex() -> void:
	if world == null:
		return
	var deltas = world.get("_deltas")
	if typeof(deltas) != TYPE_DICTIONARY:
		return
	if not world.has_method("_world_pos_from_chunk_index"):
		return
	for chunk_key in deltas.keys():
		var edits = deltas[chunk_key]
		if typeof(edits) != TYPE_DICTIONARY:
			continue
		var cc := _chunk_key_to_vec(str(chunk_key))
		for idx_key in edits.keys():
			var scan_key := str(chunk_key) + "#" + str(idx_key)
			if _scanned_delta_keys.has(scan_key):
				continue
			# 只有"挖空(变 AIR)"才可能是挖矿；放置/替换不计入。标记已扫，避免反复检视。
			if int(edits[idx_key]) != BlockLibrary.AIR:
				_scanned_delta_keys[scan_key] = true
				continue
			var idx := int(idx_key)
			var wp: Vector3i = world._world_pos_from_chunk_index(cc, idx)
			var base_id := _procedural_block_at(cc, wp)
			_scanned_delta_keys[scan_key] = true
			if not CODEX_MINERALS.has(base_id):
				continue
			if _first_mined.has(base_id):
				continue
			_first_mined[base_id] = true
			var name := String(CODEX_MINERALS[base_id])
			discovery_feedback.emit("mineral", _t("DISCOVERY_MINERAL_CODEX") % name)

func _procedural_block_at(cc: Vector2i, wp: Vector3i) -> int:
	# 用 World 已有的程序基线查表（套用玩家增量之前的原始方块）。
	if world != null and world.has_method("_base_block"):
		var lx := wp.x - cc.x * Chunk.SX
		var lz := wp.z - cc.y * Chunk.SZ
		return int(world._base_block(cc, lx, wp.y, lz))
	if world != null and world.has_method("get_block"):
		return int(world.get_block(wp.x, wp.y, wp.z))
	return BlockLibrary.AIR

func _chunk_key_to_vec(key: String) -> Vector2i:
	var parts := key.split(",")
	if parts.size() != 2:
		return Vector2i.ZERO
	return Vector2i(int(parts[0]), int(parts[1]))
