extends RefCounted
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")
const TOWER_H := 14
const TOWER_R := 2
const BLADE_LEN := 6
const CROP_R := 18

static func stamp(chunk, anchor: Vector3i) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	var sx: int = maxi(anchor.x - CROP_R, cwx)
	var ex: int = mini(anchor.x + CROP_R, cwx + Chunk.SX - 1)
	var sz: int = maxi(anchor.z - CROP_R, cwz)
	var ez: int = mini(anchor.z + CROP_R, cwz + Chunk.SZ - 1)
	if sx <= ex and sz <= ez:
		for wx in range(sx, ex + 1):
			for wz in range(sz, ez + 1):
				var dx: int = absi(wx - anchor.x)
				var dz: int = absi(wz - anchor.z)
				if dx <= TOWER_R + 1 and dz <= TOWER_R + 1: continue
				var lx: int = wx - cwx
				var lz: int = wz - cwz
				var wy: int = anchor.y + 1
				if wy >= 0 and wy < Chunk.SY:
					if wz % 3 == 0: chunk.set_block(lx, wy, lz, BL.WATER)
					elif wx % 2 == 0: chunk.set_block(lx, wy, lz, BL.TALL_GRASS)
					else: chunk.set_block(lx, wy, lz, BL.REEDS)
	var tsx: int = maxi(anchor.x - TOWER_R, cwx)
	var tex: int = mini(anchor.x + TOWER_R, cwx + Chunk.SX - 1)
	var tsz: int = maxi(anchor.z - TOWER_R, cwz)
	var tez: int = mini(anchor.z + TOWER_R, cwz + Chunk.SZ - 1)
	if tsx <= tex and tsz <= tez:
		for wx in range(tsx, tex + 1):
			for wz in range(tsz, tez + 1):
				var lx: int = wx - cwx
				var lz: int = wz - cwz
				var dx: int = absi(wx - anchor.x)
				var dz: int = absi(wz - anchor.z)
				var on_edge := (dx == TOWER_R or dz == TOWER_R)
				for dy in range(1, TOWER_H + 1):
					var wy: int = anchor.y + dy
					if wy < 0 or wy >= Chunk.SY: continue
					if on_edge: chunk.set_block(lx, wy, lz, BL.PLANKS)
					elif dy == TOWER_H: chunk.set_block(lx, wy, lz, BL.LOG)
	for rl in range(3):
		var r := TOWER_R - rl
		var wy: int = anchor.y + TOWER_H + 1 + rl
		if wy < 0 or wy >= Chunk.SY: continue
		for ddx in range(-r, r + 1):
			for ddz in range(-r, r + 1):
				var lx: int = anchor.x + ddx - cwx
				var lz: int = anchor.z + ddz - cwz
				if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
					chunk.set_block(lx, wy, lz, BL.BRICK)
	var hub_y := anchor.y + TOWER_H
	for arm in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var ddx: int = arm[0]
		var ddz: int = arm[1]
		for dist in range(TOWER_R + 1, TOWER_R + 1 + BLADE_LEN):
			var lx: int = anchor.x + ddx * dist - cwx
			var lz: int = anchor.z + ddz * dist - cwz
			if lx < 0 or lx >= Chunk.SX or lz < 0 or lz >= Chunk.SZ: continue
			var wy: int = hub_y + ((dist - TOWER_R - 1) / 3)
			if wy >= 0 and wy < Chunk.SY:
				chunk.set_block(lx, wy, lz, BL.PLANKS)
