extends RefCounted
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")
const TOWERS := [
	[0, 0, 3, 28, BL.NEON_CYAN],
	[-8, -6, 2, 20, BL.NEON_MAGENTA],
	[7, 5, 2, 22, BL.NEON_LIME],
]

static func stamp(chunk, anchor: Vector3i) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	for t in TOWERS:
		var tx: int = anchor.x + int(t[0])
		var tz: int = anchor.z + int(t[1])
		var hw: int = int(t[2])
		var th: int = int(t[3])
		var neon: int = int(t[4])
		var sx: int = maxi(tx - hw, cwx)
		var ex: int = mini(tx + hw, cwx + Chunk.SX - 1)
		var sz: int = maxi(tz - hw, cwz)
		var ez: int = mini(tz + hw, cwz + Chunk.SZ - 1)
		if sx > ex or sz > ez: continue
		for wx in range(sx, ex + 1):
			for wz in range(sz, ez + 1):
				var lx: int = wx - cwx
				var lz: int = wz - cwz
				var dx: int = absi(wx - tx)
				var dz: int = absi(wz - tz)
				var on_corner := (dx == hw and dz == hw)
				var on_edge := (dx == hw or dz == hw)
				for dy in range(1, th + 1):
					var wy: int = anchor.y + dy
					if wy < 0 or wy >= Chunk.SY: continue
					if on_corner: chunk.set_block(lx, wy, lz, neon)
					elif on_edge and dy % 6 == 0: chunk.set_block(lx, wy, lz, neon)
					elif on_edge: chunk.set_block(lx, wy, lz, BL.GLASS)
					elif dy % 6 == 0: chunk.set_block(lx, wy, lz, BL.STEEL_BLOCK)
					elif dy == th: chunk.set_block(lx, wy, lz, BL.STEEL_BLOCK)
				if dx == 0 and dz == 0:
					for spy in range(1, 5):
						var sy: int = anchor.y + th + spy
						if sy >= 0 and sy < Chunk.SY:
							chunk.set_block(lx, sy, lz, neon if spy == 4 else BL.POLISHED_IRON)
