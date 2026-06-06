extends RefCounted
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")
const POOL_R := 5
const PILLAR_H := 10
const PATH_LEN := 30
const LAMP_SPACING := 6

static func stamp(chunk, _lib, anchor: Vector3i) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	var wy: int = anchor.y
	if wy >= 0 and wy < Chunk.SY:
		for dir in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
			var ddx: int = dir[0]
			var ddz: int = dir[1]
			for dist in range(POOL_R + 2, PATH_LEN):
				for side in [-1, 0]:
					var px: int = anchor.x + ddx * dist + (0 if ddx != 0 else side)
					var pz: int = anchor.z + ddz * dist + (side if ddx != 0 else 0)
					var lx: int = px - cwx
					var lz: int = pz - cwz
					if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
						chunk.set_block(lx, wy, lz, BL.COBBLE)
				if dist % LAMP_SPACING == 0:
					for ls in [-2, 1]:
						var lpx: int = anchor.x + ddx * dist + (0 if ddx != 0 else ls)
						var lpz: int = anchor.z + ddz * dist + (ls if ddx != 0 else 0)
						var llx: int = lpx - cwx
						var llz: int = lpz - cwz
						if llx >= 0 and llx < Chunk.SX and llz >= 0 and llz < Chunk.SZ:
							if wy + 1 < Chunk.SY: chunk.set_block(llx, wy + 1, llz, BL.COBBLE)
							if wy + 2 < Chunk.SY: chunk.set_block(llx, wy + 2, llz, BL.LANTERN)
	var psx: int = maxi(anchor.x - POOL_R, cwx)
	var pex: int = mini(anchor.x + POOL_R, cwx + Chunk.SX - 1)
	var psz: int = maxi(anchor.z - POOL_R, cwz)
	var pez: int = mini(anchor.z + POOL_R, cwz + Chunk.SZ - 1)
	if psx <= pex and psz <= pez:
		for wx in range(psx, pex + 1):
			for wz in range(psz, pez + 1):
				var dx: int = wx - anchor.x
				var dz: int = wz - anchor.z
				var r2: int = dx * dx + dz * dz
				var lx: int = wx - cwx
				var lz: int = wz - cwz
				if r2 <= POOL_R * POOL_R:
					if r2 > (POOL_R - 1) * (POOL_R - 1):
						if wy >= 0 and wy < Chunk.SY: chunk.set_block(lx, wy, lz, BL.MARBLE)
						if wy + 1 < Chunk.SY: chunk.set_block(lx, wy + 1, lz, BL.MARBLE)
					elif dx != 0 or dz != 0:
						if wy >= 0 and wy < Chunk.SY: chunk.set_block(lx, wy, lz, BL.WATER)
	var plx: int = anchor.x - cwx
	var plz: int = anchor.z - cwz
	if plx >= 0 and plx < Chunk.SX and plz >= 0 and plz < Chunk.SZ:
		for dy in range(PILLAR_H):
			var py: int = anchor.y + dy
			if py < 0 or py >= Chunk.SY: continue
			if dy < 2: chunk.set_block(plx, py, plz, BL.MARBLE)
			elif dy < PILLAR_H - 2: chunk.set_block(plx, py, plz, BL.GOLD_TRIM)
			else: chunk.set_block(plx, py, plz, BL.SUNSTONE)
		var arm_y := anchor.y + PILLAR_H / 2
		if arm_y >= 0 and arm_y < Chunk.SY:
			for adir in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var ax: int = anchor.x + int(adir[0]) - cwx
				var az: int = anchor.z + int(adir[1]) - cwz
				if ax >= 0 and ax < Chunk.SX and az >= 0 and az < Chunk.SZ:
					chunk.set_block(ax, arm_y, az, BL.GOLD_TRIM)
