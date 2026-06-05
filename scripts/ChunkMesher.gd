extends RefCounted
# 体素的"心脏"：区块方块数据 → 网格 + 碰撞体，只生成"挨着空气/透明块"的面（隐藏面剔除）。
#
# build_arrays() 只吃【字节数组 + 数值查找表(LUT)】，完全不碰 Dictionary/资源 —— 可安全在后台线程跑。
# assemble() 把数组组装成 ArrayMesh/碰撞体（涉及资源），必须在主线程。

const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

const FACES := [
	{"n": Vector3(0, 1, 0),  "u": Vector3(1, 0, 0), "v": Vector3(0, 0, 1), "c": [Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(0, 1, 1)]},   # 顶 +Y
	{"n": Vector3(0, -1, 0), "u": Vector3(1, 0, 0), "v": Vector3(0, 0, 1), "c": [Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(1, 0, 0), Vector3(0, 0, 0)]},   # 底 -Y
	{"n": Vector3(1, 0, 0),  "u": Vector3(0, 1, 0), "v": Vector3(0, 0, 1), "c": [Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(1, 1, 0)]},   # +X
	{"n": Vector3(-1, 0, 0), "u": Vector3(0, 1, 0), "v": Vector3(0, 0, 1), "c": [Vector3(0, 0, 1), Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(0, 1, 1)]},   # -X
	{"n": Vector3(0, 0, 1),  "u": Vector3(1, 0, 0), "v": Vector3(0, 1, 0), "c": [Vector3(1, 0, 1), Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1)]},   # +Z
	{"n": Vector3(0, 0, -1), "u": Vector3(1, 0, 0), "v": Vector3(0, 1, 0), "c": [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(0, 1, 0)]},   # -Z
]

# 逐角环境光遮蔽(AO)：4 档亮度，0=最暗(被两侧+斜角夹住)，3=全开。乘到顶点色上让方块体积感立起来。
const _AO_LEVELS := [0.42, 0.63, 0.82, 1.0]
const _AO_FLAT := [1.0, 1.0, 1.0, 1.0]

# 后台线程安全：参数全是字节数组 / 数值表。
static func build_arrays(d, a_nx, a_px, a_nz, a_pz, solid, opaque, transp, water, t_top, t_side, t_bot, mat = null) -> Dictionary:
	# 不透明面按材质桶分流：[0]=哑光，[1]=自发光。各桶各自一组顶点流，assemble 时各成一个 surface。
	var v := [PackedVector3Array(), PackedVector3Array()]
	var nrm := [PackedVector3Array(), PackedVector3Array()]
	var uv := [PackedVector2Array(), PackedVector2Array()]
	var idx := [PackedInt32Array(), PackedInt32Array()]
	var vc := [PackedColorArray(), PackedColorArray()]
	var wv := PackedVector3Array()
	var wn := PackedVector3Array()
	var wuv := PackedVector2Array()
	var widx := PackedInt32Array()
	var col := PackedVector3Array()

	for y in range(Chunk.SY):
		for z in range(Chunk.SZ):
			var rowbase := (y * Chunk.SZ + z) * Chunk.SX
			for x in range(Chunk.SX):
				var id: int = d[rowbase + x]
				if id == 0:
					continue
				var is_w: bool = water[id] == 1
				var collidable: bool = solid[id] == 1
				var bucket: int = 0
				if mat != null and id < mat.size():
					bucket = mat[id]
				for face in FACES:
					var n: Vector3 = face["n"]
					var nb := _blk(d, a_nx, a_px, a_nz, a_pz, x + int(n.x), y + int(n.y), z + int(n.z))
					# 挡面剔除：邻居不透明=挡；空气=画；同种透明块紧挨=不画内面
					if nb != 0:
						if opaque[nb] == 1:
							continue
						if transp[id] == 1 and nb == id:
							continue
					var ny := int(n.y)
					var tile: int = t_top[id] if ny > 0 else (t_bot[id] if ny < 0 else t_side[id])
					var rect := _uv(tile)
					var corners: Array = face["c"]
					var base := Vector3(x, y, z)
					if is_w:
						_emit(wv, wn, wuv, widx, null, base, corners, n, rect, _AO_FLAT)
					else:
						var ao := _face_ao(d, a_nx, a_px, a_nz, a_pz, opaque, face, x, y, z, n)
						_emit(v[bucket], nrm[bucket], uv[bucket], idx[bucket], vc[bucket], base, corners, n, rect, ao)
						if collidable:
							_emit_collision(col, base, corners)

	return {"v": v, "n": nrm, "uv": uv, "idx": idx, "vc": vc, "wv": wv, "wn": wn, "wuv": wuv, "widx": widx, "col": col}

# 主线程：用数组组装出 Mesh + 碰撞体。
static func assemble(a: Dictionary, lib) -> Dictionary:
	var mesh := ArrayMesh.new()
	var v_buckets: Array = a["v"]
	var n_buckets: Array = a["n"]
	var uv_buckets: Array = a["uv"]
	var idx_buckets: Array = a["idx"]
	var vc_buckets: Array = a["vc"]
	for b in range(v_buckets.size()):
		var vb: PackedVector3Array = v_buckets[b]
		if vb.size() == 0:
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(vb, n_buckets[b], uv_buckets[b], idx_buckets[b], vc_buckets[b]))
		mesh.surface_set_material(mesh.get_surface_count() - 1, lib.bucket_material(b))
	var wv: PackedVector3Array = a["wv"]
	if wv.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _arrays(wv, a["wn"], a["wuv"], a["widx"]))
		mesh.surface_set_material(mesh.get_surface_count() - 1, lib.water_material)
	var shape = null
	var col: PackedVector3Array = a["col"]
	if col.size() > 0:
		shape = ConcavePolygonShape3D.new()
		shape.set_faces(col)
	return {"mesh": mesh, "shape": shape}

# 同步一把梭（开局/编辑用）
static func build(chunk, lib, nx, px, nz, pz) -> Dictionary:
	var d: PackedByteArray = chunk.blocks
	var a_nx = nx.blocks if nx != null else null
	var a_px = px.blocks if px != null else null
	var a_nz = nz.blocks if nz != null else null
	var a_pz = pz.blocks if pz != null else null
	var arrays := build_arrays(d, a_nx, a_px, a_nz, a_pz,
		lib.solid_lut, lib.opaque_lut, lib.transp_lut, lib.water_lut,
		lib.tile_top_lut, lib.tile_side_lut, lib.tile_bot_lut, lib.mat_bucket_lut)
	return assemble(arrays, lib)

# 某贴图格子的 UV（纯算术，无共享状态）
static func _uv(tile: int) -> Rect2:
	var col := tile % BlockLibrary.ATLAS_COLS
	var row := tile / BlockLibrary.ATLAS_COLS
	var inset := 0.5 / float(BlockLibrary.ATLAS_COLS * BlockLibrary.TILE)
	var u0 := float(col) / float(BlockLibrary.ATLAS_COLS) + inset
	var v0 := float(row) / float(BlockLibrary.ATLAS_ROWS) + inset
	var u1 := float(col + 1) / float(BlockLibrary.ATLAS_COLS) - inset
	var v1 := float(row + 1) / float(BlockLibrary.ATLAS_ROWS) - inset
	return Rect2(u0, v0, u1 - u0, v1 - v0)

static func _blk(d, anx, apx, anz, apz, x: int, y: int, z: int) -> int:
	if y < 0 or y >= Chunk.SY:
		return 0
	if x < 0:
		return anx[(y * Chunk.SZ + z) * Chunk.SX + (x + Chunk.SX)] if anx != null else 0
	if x >= Chunk.SX:
		return apx[(y * Chunk.SZ + z) * Chunk.SX + (x - Chunk.SX)] if apx != null else 0
	if z < 0:
		return anz[(y * Chunk.SZ + (z + Chunk.SZ)) * Chunk.SX + x] if anz != null else 0
	if z >= Chunk.SZ:
		return apz[(y * Chunk.SZ + (z - Chunk.SZ)) * Chunk.SX + x] if apz != null else 0
	return d[(y * Chunk.SZ + z) * Chunk.SX + x]

# 某格是否为“不透明遮挡块”（用于 AO 采样）。越界天空=0；同时跨两个区块边界的斜角不采（避免越界），按不遮挡处理。
static func _occ(d, anx, apx, anz, apz, opaque, x: int, y: int, z: int) -> int:
	if y < 0 or y >= Chunk.SY:
		return 0
	if (x < 0 or x >= Chunk.SX) and (z < 0 or z >= Chunk.SZ):
		return 0
	var id := _blk(d, anx, apx, anz, apz, x, y, z)
	return 1 if (id > 0 and id < opaque.size() and opaque[id] == 1) else 0

# 一个面 4 个角的 AO 亮度。对每个角，看它所贴的空气格在该面平面内的两侧块 + 斜角块。
static func _face_ao(d, anx, apx, anz, apz, opaque, face: Dictionary, x: int, y: int, z: int, n: Vector3) -> Array:
	var fu: Vector3 = face["u"]
	var fv: Vector3 = face["v"]
	var corners: Array = face["c"]
	var fc := Vector3(0.5, 0.5, 0.5) + n * 0.5
	var ax := x + int(n.x)
	var ay := y + int(n.y)
	var az := z + int(n.z)
	var out := [1.0, 1.0, 1.0, 1.0]
	for ci in 4:
		var rel: Vector3 = corners[ci] - fc
		var du := 1 if rel.dot(fu) > 0.0 else -1
		var dv := 1 if rel.dot(fv) > 0.0 else -1
		var s1 := _occ(d, anx, apx, anz, apz, opaque, ax + du * int(fu.x), ay + du * int(fu.y), az + du * int(fu.z))
		var s2 := _occ(d, anx, apx, anz, apz, opaque, ax + dv * int(fv.x), ay + dv * int(fv.y), az + dv * int(fv.z))
		var cc := _occ(d, anx, apx, anz, apz, opaque, ax + du * int(fu.x) + dv * int(fv.x), ay + du * int(fu.y) + dv * int(fv.y), az + du * int(fu.z) + dv * int(fv.z))
		var level := 0 if (s1 == 1 and s2 == 1) else (3 - (s1 + s2 + cc))
		out[ci] = _AO_LEVELS[level]
	return out

static func _emit(v: PackedVector3Array, n: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array, cols, base: Vector3, corners: Array, normal: Vector3, r: Rect2, ao: Array) -> void:
	var s := v.size()
	v.push_back(base + corners[0]); v.push_back(base + corners[1])
	v.push_back(base + corners[2]); v.push_back(base + corners[3])
	for i in 4:
		n.push_back(normal)
	uv.push_back(Vector2(r.position.x, r.position.y + r.size.y))
	uv.push_back(Vector2(r.position.x + r.size.x, r.position.y + r.size.y))
	uv.push_back(Vector2(r.position.x + r.size.x, r.position.y))
	uv.push_back(Vector2(r.position.x, r.position.y))
	if cols != null:
		cols.push_back(Color(ao[0], ao[0], ao[0]))
		cols.push_back(Color(ao[1], ao[1], ao[1]))
		cols.push_back(Color(ao[2], ao[2], ao[2]))
		cols.push_back(Color(ao[3], ao[3], ao[3]))
	# 翻转对角线：让两个暗角落在同一条对角线上，避免 AO 渐变出现“折痕”错位
	if ao[0] + ao[2] > ao[1] + ao[3]:
		idx.push_back(s + 0); idx.push_back(s + 1); idx.push_back(s + 3)
		idx.push_back(s + 1); idx.push_back(s + 2); idx.push_back(s + 3)
	else:
		idx.push_back(s + 0); idx.push_back(s + 1); idx.push_back(s + 2)
		idx.push_back(s + 0); idx.push_back(s + 2); idx.push_back(s + 3)

static func _emit_collision(col: PackedVector3Array, base: Vector3, corners: Array) -> void:
	var a: Vector3 = base + corners[0]
	var b: Vector3 = base + corners[1]
	var c: Vector3 = base + corners[2]
	var dd: Vector3 = base + corners[3]
	col.push_back(a); col.push_back(b); col.push_back(c)
	col.push_back(a); col.push_back(c); col.push_back(dd)

static func _arrays(v: PackedVector3Array, n: PackedVector3Array, uv: PackedVector2Array, idx: PackedInt32Array, cols = null) -> Array:
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	arr[Mesh.ARRAY_TEX_UV] = uv
	if cols != null and cols.size() == v.size():
		arr[Mesh.ARRAY_COLOR] = cols
	arr[Mesh.ARRAY_INDEX] = idx
	return arr
