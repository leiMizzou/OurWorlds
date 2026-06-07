extends RefCounted
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")
const HALF_BASE := 12
const LAYERS := 12

static func stamp(chunk, anchor: Vector3i) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	for layer in range(LAYERS):
		var r := HALF_BASE - layer
		if r <= 0: break
		var wy: int = anchor.y + layer + 1
		if wy < 0 or wy >= Chunk.SY: continue
		var sx: int = maxi(anchor.x - r, cwx)
		var ex: int = mini(anchor.x + r, cwx + Chunk.SX - 1)
		var sz: int = maxi(anchor.z - r, cwz)
		var ez: int = mini(anchor.z + r, cwz + Chunk.SZ - 1)
		if sx > ex or sz > ez: continue
		for wx in range(sx, ex + 1):
			for wz in range(sz, ez + 1):
				var lx: int = wx - cwx
				var lz: int = wz - cwz
				var dx: int = absi(wx - anchor.x)
				var dz: int = absi(wz - anchor.z)
				var bid: int
				if dx == r or dz == r: bid = BL.TERRACOTTA
				elif layer % 2 == 0: bid = BL.SAND
				else: bid = BL.RED_SAND
				chunk.set_block(lx, wy, lz, bid)
	for dy in [1, 2]:
		for ddx in [-1, 0, 1]:
			var wx: int = anchor.x + ddx
			var wz: int = anchor.z + HALF_BASE
			var wy: int = anchor.y + dy
			var lx: int = wx - cwx
			var lz: int = wz - cwz
			if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ and wy >= 0 and wy < Chunk.SY:
				chunk.set_block(lx, wy, lz, BL.AIR)
	var tx: int = anchor.x - cwx
	var tz: int = anchor.z - cwz
	var ty: int = anchor.y + LAYERS + 1
	if tx >= 0 and tx < Chunk.SX and tz >= 0 and tz < Chunk.SZ and ty >= 0 and ty < Chunk.SY:
		chunk.set_block(tx, ty, tz, BL.GOLD_TRIM)
