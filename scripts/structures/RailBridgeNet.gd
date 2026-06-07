extends RefCounted
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")
const HALF := 256
const ISLAND_SIZE := 512
const SECTORS := 3

# 与 IslandGenerator.sector_anchor 使用相同的浮点 span 计算，确保坐标一致。
static func _sector_center(cell: int) -> Vector2i:
	var col := cell % SECTORS
	var row := cell / SECTORS
	var span := float(ISLAND_SIZE) / float(SECTORS)
	var cx := int(round(float(-HALF) + span * 0.5 + float(col) * span))
	var cz := int(round(float(-HALF) + span * 0.5 + float(row) * span))
	return Vector2i(cx, cz)

const LINKS := [[0,1],[1,2],[3,4],[4,5],[6,7],[7,8],[0,3],[3,6],[1,4],[4,7],[2,5],[5,8]]

static func stamp(chunk: Chunk, anchor: Vector3i) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	for link in LINKS:
		var a := _sector_center(int(link[0]))
		var b := _sector_center(int(link[1]))
		var dx: int = b.x - a.x
		var dz: int = b.y - a.y
		var steps := maxi(absi(dx), absi(dz))
		if steps == 0: continue
		var fx := float(dx) / float(steps)
		var fz := float(dz) / float(steps)
		for i in range(steps + 1):
			var wx: int = a.x + roundi(fx * float(i))
			var wz: int = a.y + roundi(fz * float(i))
			var lx: int = wx - cwx
			var lz: int = wz - cwz
			if lx < 0 or lx >= Chunk.SX or lz < 0 or lz >= Chunk.SZ: continue
			var wy: int = anchor.y + 1
			if wy >= 0 and wy < Chunk.SY: chunk.set_block(lx, wy, lz, BL.RAIL)
			if wy - 1 >= 0 and wy - 1 < Chunk.SY: chunk.set_block(lx, wy - 1, lz, BL.PLANKS)
