extends RefCounted
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")
const TOWER_R := 3
const TOWER_H := 18
const DOCK_LEN := 16

static func stamp(chunk, _lib, anchor: Vector3i) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	var sx: int = maxi(anchor.x - TOWER_R, cwx)
	var ex: int = mini(anchor.x + TOWER_R, cwx + Chunk.SX - 1)
	var sz: int = maxi(anchor.z - TOWER_R, cwz)
	var ez: int = mini(anchor.z + TOWER_R, cwz + Chunk.SZ - 1)
	if sx <= ex and sz <= ez:
		for wx in range(sx, ex + 1):
			for wz in range(sz, ez + 1):
				var lx: int = wx - cwx
				var lz: int = wz - cwz
				var dx: int = wx - anchor.x
				var dz: int = wz - anchor.z
				var r2: int = dx * dx + dz * dz
				for dy in range(1, TOWER_H + 1):
					var wy: int = anchor.y + dy
					if wy < 0 or wy >= Chunk.SY: continue
					var on_shell := r2 <= TOWER_R * TOWER_R and r2 > (TOWER_R - 1) * (TOWER_R - 1)
					if on_shell:
						chunk.set_block(lx, wy, lz, BL.BRICK if (dy / 3) % 2 == 0 else BL.MARBLE)
					elif r2 < (TOWER_R - 1) * (TOWER_R - 1) and dy == 1:
						chunk.set_block(lx, wy, lz, BL.PLANKS)
					if dx == 0 and dz == -TOWER_R and dy >= 8 and dy <= 9:
						chunk.set_block(lx, wy, lz, BL.GLASS)
	for ddx in range(-1, 2):
		for ddz in range(-1, 2):
			var bx: int = anchor.x + ddx - cwx
			var bz: int = anchor.z + ddz - cwz
			if bx >= 0 and bx < Chunk.SX and bz >= 0 and bz < Chunk.SZ:
				for bdy in [TOWER_H + 1, TOWER_H + 2]:
					var by: int = anchor.y + bdy
					if by >= 0 and by < Chunk.SY:
						chunk.set_block(bx, by, bz, BL.SUNSTONE if ddx == 0 and ddz == 0 else BL.GLASS)
	var tx: int = anchor.x - cwx
	var tz: int = anchor.z - cwz
	var ty: int = anchor.y + TOWER_H + 3
	if tx >= 0 and tx < Chunk.SX and tz >= 0 and tz < Chunk.SZ and ty >= 0 and ty < Chunk.SY:
		chunk.set_block(tx, ty, tz, BL.BRICK)
	var dock_z := anchor.z + TOWER_R + 1
	for dist in range(DOCK_LEN):
		var wz: int = dock_z + dist
		var wy: int = anchor.y
		for ddx in [-1, 0, 1]:
			var lx: int = anchor.x + ddx - cwx
			var lz: int = wz - cwz
			if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ and wy >= 0 and wy < Chunk.SY:
				chunk.set_block(lx, wy, lz, BL.PLANKS)
		if dist % 4 == 0:
			for ddx in [-2, 2]:
				var lx: int = anchor.x + ddx - cwx
				var lz: int = wz - cwz
				if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
					if wy >= 0 and wy < Chunk.SY: chunk.set_block(lx, wy, lz, BL.LOG)
					if wy + 1 < Chunk.SY: chunk.set_block(lx, wy + 1, lz, BL.LANTERN)
