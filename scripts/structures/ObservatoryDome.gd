extends RefCounted
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")
const BASE_R := 8
const BASE_H := 6
const DOME_R := 7

static func stamp(chunk, anchor: Vector3i) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	var sx: int = maxi(anchor.x - BASE_R, cwx)
	var ex: int = mini(anchor.x + BASE_R, cwx + Chunk.SX - 1)
	var sz: int = maxi(anchor.z - BASE_R, cwz)
	var ez: int = mini(anchor.z + BASE_R, cwz + Chunk.SZ - 1)
	if sx > ex or sz > ez: return
	for wx in range(sx, ex + 1):
		for wz in range(sz, ez + 1):
			var lx: int = wx - cwx
			var lz: int = wz - cwz
			var dx: int = wx - anchor.x
			var dz: int = wz - anchor.z
			var r2: int = dx * dx + dz * dz
			if r2 <= BASE_R * BASE_R:
				for dy in range(1, BASE_H + 1):
					var wy: int = anchor.y + dy
					if wy >= 0 and wy < Chunk.SY:
						var on_edge := r2 > (BASE_R - 1) * (BASE_R - 1)
						if dy == BASE_H and on_edge: chunk.set_block(lx, wy, lz, BL.GOLD_TRIM)
						elif on_edge: chunk.set_block(lx, wy, lz, BL.MARBLE)
						elif dy == 1: chunk.set_block(lx, wy, lz, BL.MARBLE)
			if r2 <= DOME_R * DOME_R:
				for dy in range(0, DOME_R + 1):
					var wy: int = anchor.y + BASE_H + 1 + dy
					if wy >= 0 and wy < Chunk.SY:
						var sr2 := dx * dx + dz * dz + dy * dy
						if sr2 <= DOME_R * DOME_R and sr2 > (DOME_R - 1) * (DOME_R - 1):
							var is_rib := (dx == 0 or dz == 0 or absi(dx) == absi(dz))
							chunk.set_block(lx, wy, lz, BL.STEEL_BLOCK if is_rib else BL.GLASS)
	var tx: int = anchor.x - cwx
	var tz: int = anchor.z - cwz
	if tx >= 0 and tx < Chunk.SX and tz >= 0 and tz < Chunk.SZ:
		for dy in range(1, BASE_H + DOME_R):
			var wy: int = anchor.y + dy
			if wy >= 0 and wy < Chunk.SY:
				chunk.set_block(tx, wy, tz, BL.POLISHED_IRON)
