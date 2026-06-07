extends RefCounted
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")
# [offset_x, offset_z, width, depth, wall_height, roof_height]
const HOUSES := [[-14,-10,7,6,4,3],[6,-12,6,5,4,2],[-12,8,6,6,4,3],[8,6,7,5,4,2],[0,-2,8,7,5,3]]

static func stamp(chunk: Chunk, anchor: Vector3i) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	var wy: int = anchor.y
	if wy >= 0 and wy < Chunk.SY:
		for ddx in range(-20, 21):
			for ddz in [0, 1]:
				var lx: int = anchor.x + ddx - cwx
				var lz: int = anchor.z + ddz - cwz
				if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
					chunk.set_block(lx, wy, lz, BL.COBBLE)
		for ddz in range(-20, 21):
			for ddx in [0, 1]:
				var lx: int = anchor.x + ddx - cwx
				var lz: int = anchor.z + ddz - cwz
				if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
					chunk.set_block(lx, wy, lz, BL.COBBLE)
	for h in HOUSES:
		_stamp_house(chunk, anchor, cwx, cwz, int(h[0]), int(h[1]), int(h[2]), int(h[3]), int(h[4]), int(h[5]))

static func _stamp_house(chunk: Chunk, anchor: Vector3i, cwx: int, cwz: int,
		hx: int, hz: int, w: int, d: int, h: int, rh: int) -> void:
	var base_x := anchor.x + hx
	var base_z := anchor.z + hz
	var base_y := anchor.y + 1
	var sx: int = maxi(base_x, cwx)
	var ex: int = mini(base_x + w - 1, cwx + Chunk.SX - 1)
	var sz: int = maxi(base_z, cwz)
	var ez: int = mini(base_z + d - 1, cwz + Chunk.SZ - 1)
	if sx > ex or sz > ez: return
	for wx in range(sx, ex + 1):
		for wz in range(sz, ez + 1):
			var lx: int = wx - cwx
			var lz: int = wz - cwz
			var rx: int = wx - base_x
			var rz: int = wz - base_z
			var on_wall := (rx == 0 or rx == w - 1 or rz == 0 or rz == d - 1)
			for dy in range(h):
				var wy: int = base_y + dy
				if wy < 0 or wy >= Chunk.SY: continue
				if on_wall:
					if rz == d - 1 and rx == w / 2 and dy < 2: continue
					if dy == 1 and (rx == 0 or rx == w - 1) and rz == d / 2:
						chunk.set_block(lx, wy, lz, BL.GLASS)
					elif (rx == 0 or rx == w - 1) and (rz == 0 or rz == d - 1):
						chunk.set_block(lx, wy, lz, BL.LOG)
					else:
						chunk.set_block(lx, wy, lz, BL.PLANKS)
				elif dy == 0:
					chunk.set_block(lx, wy, lz, BL.PLANKS)
			for ry in range(rh):
				var roof_y: int = base_y + h + ry
				if roof_y >= 0 and roof_y < Chunk.SY and rz >= ry and rz <= d - 1 - ry:
					chunk.set_block(lx, roof_y, lz, BL.BRICK)
	var chx: int = base_x + w - 2 - cwx
	var chz: int = base_z + 1 - cwz
	if chx >= 0 and chx < Chunk.SX and chz >= 0 and chz < Chunk.SZ:
		for dy in range(h + rh, h + rh + 3):
			var wy: int = base_y + dy
			if wy >= 0 and wy < Chunk.SY: chunk.set_block(chx, wy, chz, BL.COBBLE)
