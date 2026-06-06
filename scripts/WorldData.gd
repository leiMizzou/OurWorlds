extends RefCounted
# WorldData —— 可无头运行的世界数据核心（无节点 / 无渲染 / 无线程）。
# 拥有：种子、WorldGenerator、区块数据字典、玩家增量(delta)、每区块 revision。
# 服务端(M1+)可直接持有它而不背任何渲染开销；客户端(World)持有它做唯一数据真相。
# 地形靠种子确定性生成；只存"增量"——某格被改成非生成值才记一条；改回生成值即移除。
const Chunk = preload("res://scripts/Chunk.gd")
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")

var _gen: WorldGenerator
var _world_seed := 1337
var _chunks := {}              # Vector2i -> Chunk（数据；含 base_blocks 基线快照）
var _deltas := {}              # "cx,cz" -> {str(index) -> block_id}
var _revisions := {}           # "cx,cz" -> int（每次编辑 +1，供联机同步增量）

func _init(world_seed: int = 1337) -> void:
	_world_seed = world_seed
	_gen = WorldGenerator.new(world_seed)

func world_seed() -> int:
	return _world_seed

# 区块数据字典（按引用返回）—— World 可让自己的 _chunks 指向同一个，复用现有读取。
func chunks() -> Dictionary:
	return _chunks

# ---------- 坐标 / 生成查询（委托确定性生成器）----------
func chunk_of(wx: int, wz: int) -> Vector2i:
	return Vector2i(floori(float(wx) / Chunk.SX), floori(float(wz) / Chunk.SZ))

func surface_y(wx: int, wz: int) -> int:
	return _gen.surface_height(wx, wz)

func region_label(wx: int, wz: int) -> String:
	return _gen.region_label(wx, wz)

func region_description(wx: int, wz: int) -> String:
	return _gen.region_description(wx, wz)

# ---------- 读方块 ----------
func get_block(wx: int, wy: int, wz: int) -> int:
	if wy < 0 or wy >= Chunk.SY:
		return 0
	var cc := chunk_of(wx, wz)
	var ch := ensure_data(cc)
	return ch.get_block(wx - cc.x * Chunk.SX, wy, wz - cc.y * Chunk.SZ)

# 生成（或取回）某区块数据：生成基线 -> 快照 base_blocks -> 套用已有增量。
func ensure_data(cc: Vector2i) -> Chunk:
	if _chunks.has(cc):
		return _chunks[cc]
	var ch := Chunk.new(cc.x, cc.y)
	_gen.generate(ch)
	ch.base_blocks = ch.blocks.duplicate()   # 运行期缓存，不写存档
	_apply_deltas_to_chunk(cc, ch)
	_chunks[cc] = ch
	return ch

# 卸载区块数据（释放内存）；增量与 revision 保留，重载时 ensure_data 会重套。
func unload_chunk(cc: Vector2i) -> void:
	_chunks.erase(cc)

# ---------- 编辑（数据层权威应用）----------
# 写一格 + 记增量 + 递增 revision。返回受影响区块坐标数组（含跨界邻块，供调用方重建网格）；
# 空数组表示该格值未变（无需任何处理）。
func apply_edit_local(wx: int, wy: int, wz: int, id: int) -> Array:
	if wy < 0 or wy >= Chunk.SY:
		return []
	var cc := chunk_of(wx, wz)
	var ch := ensure_data(cc)
	var lx := wx - cc.x * Chunk.SX
	var lz := wz - cc.y * Chunk.SZ
	if ch.get_block(lx, wy, lz) == id:
		return []
	ch.set_block(lx, wy, lz, id)
	_record_delta(cc, lx, wy, lz, id)
	var key := _chunk_key(cc)
	_revisions[key] = int(_revisions.get(key, 0)) + 1
	var affected := [cc]
	if lx == 0: affected.append(cc + Vector2i(-1, 0))
	elif lx == Chunk.SX - 1: affected.append(cc + Vector2i(1, 0))
	if lz == 0: affected.append(cc + Vector2i(0, -1))
	elif lz == Chunk.SZ - 1: affected.append(cc + Vector2i(0, 1))
	return affected

func chunk_revision(cc: Vector2i) -> int:
	return int(_revisions.get(_chunk_key(cc), 0))

func chunk_delta(cc: Vector2i) -> Dictionary:
	return (_deltas.get(_chunk_key(cc), {}) as Dictionary).duplicate()

# ---------- 增量序列化 / 查询 ----------
func all_deltas() -> Dictionary:
	return _deltas.duplicate(true)

func load_deltas(d: Dictionary) -> void:
	_deltas = d.duplicate(true)
	_chunks.clear()          # 强制重载时按 seed 重生 + 重套新增量
	_revisions.clear()
	for key in _deltas.keys():
		_revisions[key] = 1

func edit_count() -> int:
	var n := 0
	for key in _deltas.keys():
		n += (_deltas[key] as Dictionary).size()
	return n

# ---------- 内部：增量记录（与 World 旧实现等价，键为 str(index)）----------
func _chunk_key(cc: Vector2i) -> String:
	return "%d,%d" % [cc.x, cc.y]

func _base_block(cc: Vector2i, lx: int, wy: int, lz: int) -> int:
	if _chunks.has(cc):
		var ch: Chunk = _chunks[cc]
		var idx := Chunk.index(lx, wy, lz)
		if idx >= 0 and idx < ch.base_blocks.size():
			return ch.base_blocks[idx]
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
			if edits.erase(str(idx)) and edits.is_empty():
				_deltas.erase(key)
		return
	if not _deltas.has(key):
		_deltas[key] = {}
	(_deltas[key] as Dictionary)[str(idx)] = id

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
