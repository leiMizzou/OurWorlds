extends RefCounted
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")
const W := 8
const D := 6
const H := 4
const ROOF_H := 3

static func stamp(chunk, anchor: Vector3i) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	var bx := anchor.x - W / 2
	var bz := anchor.z - D / 2
	var by := anchor.y + 1
	var sx: int = maxi(bx, cwx)
	var ex: int = mini(bx + W - 1, cwx + Chunk.SX - 1)
	var sz: int = maxi(bz, cwz)
	var ez: int = mini(bz + D - 1, cwz + Chunk.SZ - 1)
	if sx <= ex and sz <= ez:
		for wx in range(sx, ex + 1):
			for wz in range(sz, ez + 1):
				var lx: int = wx - cwx
				var lz: int = wz - cwz
				var rx: int = wx - bx
				var rz: int = wz - bz
				var on_wall := (rx == 0 or rx == W - 1 or rz == 0 or rz == D - 1)
				var corner := (rx == 0 or rx == W - 1) and (rz == 0 or rz == D - 1)
				for dy in range(H):
					var wy: int = by + dy
					if wy < 0 or wy >= Chunk.SY: continue
					if on_wall:
						if rz == D - 1 and (rx == W / 2 or rx == W / 2 - 1) and dy < 2: continue
						if dy == 1 and rx == W / 2 and rz == 0: chunk.set_block(lx, wy, lz, BL.GLASS)
						elif corner: chunk.set_block(lx, wy, lz, BL.LOG)
						else: chunk.set_block(lx, wy, lz, BL.PLANKS)
					elif dy == 0: chunk.set_block(lx, wy, lz, BL.PLANKS)
				for ry in range(ROOF_H):
					var roof_y: int = by + H + ry
					if roof_y >= 0 and roof_y < Chunk.SY and rz >= ry and rz <= D - 1 - ry:
						chunk.set_block(lx, roof_y, lz, BL.PLANKS)
				if rz == D / 2:
					var snow_y: int = by + H + ROOF_H
					if snow_y >= 0 and snow_y < Chunk.SY: chunk.set_block(lx, snow_y, lz, BL.SNOW)
	var chx: int = bx + W - 2 - cwx
	var chz: int = bz + 1 - cwz
	if chx >= 0 and chx < Chunk.SX and chz >= 0 and chz < Chunk.SZ:
		for dy in range(H + ROOF_H - 1, H + ROOF_H + 3):
			var wy: int = by + dy
			if wy >= 0 and wy < Chunk.SY: chunk.set_block(chx, wy, chz, BL.COBBLE)
	var llx: int = anchor.x - cwx
	var llz: int = anchor.z - cwz
	if llx >= 0 and llx < Chunk.SX and llz >= 0 and llz < Chunk.SZ and by + 1 >= 0 and by + 1 < Chunk.SY:
		chunk.set_block(llx, by + 1, llz, BL.LANTERN)
	var trees := [[anchor.x - 8, anchor.z - 4, 5], [anchor.x + 7, anchor.z + 3, 6], [anchor.x - 6, anchor.z + 7, 4]]
	for t in trees:
		var twx: int = int(t[0])
		var twz: int = int(t[1])
		var th: int = int(t[2])
		var tlx: int = twx - cwx
		var tlz: int = twz - cwz
		if tlx < 0 or tlx >= Chunk.SX or tlz < 0 or tlz >= Chunk.SZ: continue
		for dy in range(1, th + 1):
			var wy: int = anchor.y + dy
			if wy >= 0 and wy < Chunk.SY: chunk.set_block(tlx, wy, tlz, BL.LOG)
		for dy in range(2, th + 2):
			var r := th + 1 - dy
			if r < 1: continue
			var wy: int = anchor.y + dy
			if wy < 0 or wy >= Chunk.SY: continue
			for ddx in range(-r, r + 1):
				for ddz in range(-r, r + 1):
					if absi(ddx) + absi(ddz) > r: continue
					var lx: int = twx + ddx - cwx
					var lz: int = twz + ddz - cwz
					if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
						chunk.set_block(lx, wy, lz, BL.PINE_LEAVES)
