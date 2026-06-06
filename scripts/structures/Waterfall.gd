extends RefCounted
# 热带→海湾扇区交界处的瀑布——水流从高处岩壁倾泻而下。
const Chunk = preload("res://scripts/Chunk.gd")
const BL = preload("res://scripts/BlockLibrary.gd")

const WIDTH := 5        # 水帘宽度
const HEIGHT := 12      # 瀑布落差
const CLIFF_DEPTH := 3  # 岩壁厚度

static func stamp(chunk, _lib, anchor: Vector3i) -> void:
	var cwx: int = chunk.cx * Chunk.SX
	var cwz: int = chunk.cz * Chunk.SZ
	var half_w: int = WIDTH / 2
	# 岩壁（MOSSY_STONE）
	for dx in range(-half_w - 1, half_w + 2):
		for dy in range(HEIGHT + 2):
			for dz in range(-CLIFF_DEPTH, 1):
				var wx: int = anchor.x + dx
				var wz: int = anchor.z + dz
				var wy: int = anchor.y + dy
				var lx: int = wx - cwx
				var lz: int = wz - cwz
				if lx < 0 or lx >= Chunk.SX or lz < 0 or lz >= Chunk.SZ: continue
				if wy < 0 or wy >= Chunk.SY: continue
				# 水帘区域用 WATER
				if dx >= -half_w and dx <= half_w and dz == 0:
					chunk.set_block(lx, wy, lz, BL.WATER)
				else:
					chunk.set_block(lx, wy, lz, BL.MOSSY_STONE)
	# 瀑布顶部唇缘（STONE）
	for dx in range(-half_w - 1, half_w + 2):
		var wx: int = anchor.x + dx
		var wy: int = anchor.y + HEIGHT + 1
		var wz: int = anchor.z
		var lx: int = wx - cwx
		var lz: int = wz - cwz
		if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ and wy >= 0 and wy < Chunk.SY:
			chunk.set_block(lx, wy, lz, BL.STONE)
	# 瀑布底部水池
	for dx in range(-half_w - 2, half_w + 3):
		for dz in range(1, 5):
			var wx: int = anchor.x + dx
			var wz: int = anchor.z + dz
			var wy: int = anchor.y - 1
			var lx: int = wx - cwx
			var lz: int = wz - cwz
			if lx < 0 or lx >= Chunk.SX or lz < 0 or lz >= Chunk.SZ: continue
			if wy < 0 or wy >= Chunk.SY: continue
			# 池底是 MOSSY_STONE，池水是 WATER
			chunk.set_block(lx, wy, lz, BL.MOSSY_STONE)
			if wy + 1 < Chunk.SY:
				chunk.set_block(lx, wy + 1, lz, BL.WATER)
	# 池边苔石+藤蔓装饰
	for dx in [-half_w - 2, half_w + 2]:
		for dz in range(1, 5):
			var wx: int = anchor.x + dx
			var wz: int = anchor.z + dz
			var lx: int = wx - cwx
			var lz: int = wz - cwz
			for dy in range(3):
				var wy: int = anchor.y + dy
				if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ and wy >= 0 and wy < Chunk.SY:
					chunk.set_block(lx, wy, lz, BL.MOSSY_STONE)
