extends SceneTree
# 一次性性能计时：证明"放置一个大模板/49格编辑"在主线程的耗时从秒级降到 <50ms。
#   godot --headless --path . --script res://tests/perf_edit.gd
# before = 复刻旧同步路径（每格整块重生 + 每格 _base_block 整块重生 + 每格全量 remesh）
# after  = 新批量 + 后台路径（request_block_edits：只写数据 + 攒脏区块 + 后台重建，主线程只 assemble）

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")
const ChunkMesher = preload("res://scripts/ChunkMesher.gd")
const World = preload("res://scripts/World.gd")

var _f := 0
var _main = null

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.set_environment("VC_NO_SAVE", "1")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/perf_edit/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 30:
		_run()
		return true
	return false

func _run() -> void:
	var world = _main.world
	var player = _main.player
	var p: Vector3 = player.global_position
	var bx := int(floor(p.x))
	var bz := int(floor(p.z))
	var top: int = world.surface_y(bx, bz) + 6   # 在空中放置，保证全是新写入
	world.generate_initial(world.chunk_of(bx, bz))

	# 构造一个 7x7=49 格的"大模板"编辑（横跨区块边界以触发邻块重建）
	var edits := []
	for dz in range(-3, 4):
		for dx in range(-3, 4):
			edits.append({"pos": Vector3i(bx + dx, top, bz + dz), "id": BlockLibrary.MARBLE})

	# ---------- BEFORE：复刻旧逐格同步路径 ----------
	var t0 := Time.get_ticks_msec()
	for raw in edits:
		var e: Dictionary = raw
		var pos: Vector3i = e["pos"]
		var id := int(e["id"])
		var cc: Vector2i = world.chunk_of(pos.x, pos.z)
		world._ensure_data(cc)
		var lx: int = pos.x - cc.x * Chunk.SX
		var lz: int = pos.z - cc.y * Chunk.SZ
		var ch = world._chunks[cc]
		ch.set_block(lx, pos.y, lz, id)
		# 旧 _record_delta 热点：每格靠整块 Chunk.new()+generate 求基线
		var base := Chunk.new(cc.x, cc.y)
		world._gen.generate(base)
		var _b: int = base.get_block(lx, pos.y, lz)
		# 旧 set_block：每格整块全量同步 remesh（含跨界邻块）
		world._remesh_sync(cc)
		if lx == 0: world._remesh_sync(cc + Vector2i(-1, 0))
		elif lx == Chunk.SX - 1: world._remesh_sync(cc + Vector2i(1, 0))
		if lz == 0: world._remesh_sync(cc + Vector2i(0, -1))
		elif lz == Chunk.SZ - 1: world._remesh_sync(cc + Vector2i(0, 1))
	var before_ms := Time.get_ticks_msec() - t0

	# 还原：把这 49 格抹回空气（用同样的旧路径，避免影响 after 的初值，不计时）
	for raw in edits:
		var e2: Dictionary = raw
		var pos2: Vector3i = e2["pos"]
		world.set_block(pos2.x, pos2.y, pos2.z, BlockLibrary.AIR)

	# ---------- AFTER：新批量 + 后台路径（主线程实际花费） ----------
	var t1 := Time.get_ticks_msec()
	var placed: int = world.request_block_edits(edits)
	var after_ms := Time.get_ticks_msec() - t1

	print("==== PERF: 49 格大模板编辑（主线程耗时） ====")
	print("  placed cells   = ", placed)
	print("  BEFORE (旧逐格同步整块重生+remesh) = ", before_ms, " ms")
	print("  AFTER  (新批量+后台，主线程只派发) = ", after_ms, " ms")
	if after_ms < 50:
		print("  ✅ 主线程编辑耗时 < 50ms，无秒级冻结")
	else:
		printerr("  ❌ 主线程编辑耗时仍偏高: ", after_ms, " ms")
