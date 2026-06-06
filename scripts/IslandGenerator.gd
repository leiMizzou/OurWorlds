extends RefCounted
# IslandGenerator —— 有限浮空主题岛的确定性生成器。
# 与 WorldGenerator 同接口（generate/surface_height/region_label/region_description），供 WorldData 按 kind 选用。
# 纯函数：仅依赖 (seed, wx, wz)；generate 不触碰任何全局可变状态，可在后台线程安全调用。
const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

const ISLAND_SIZE := 512           # 岛边长（格）
const HALF := 256                  # = ISLAND_SIZE / 2
const SECTORS := 3                 # 3×3 扇区
const BASE_Y := 40                 # 岛面基准高度
const FLOOR_Y := 24                # 岛体底壳；其下为空气（浮空）
const WATER_Y := 38                # 水面高度（含水扇区；Task 3 地形用）
const EDGE := 10                   # 边缘崖壁渐变带宽度（Task 3 地形用）

enum IslandTheme { SNOW, DESERT, TROPICAL, VILLAGE, PLAZA, CYBER, OBSERVATORY, FARM, BAY }
const CELL_THEME := [
	IslandTheme.SNOW, IslandTheme.DESERT, IslandTheme.TROPICAL,        # 北排：西→东
	IslandTheme.VILLAGE, IslandTheme.PLAZA, IslandTheme.CYBER,         # 中排
	IslandTheme.OBSERVATORY, IslandTheme.FARM, IslandTheme.BAY,        # 南排
]

var _seed := 1337
func _init(world_seed: int = 1337) -> void:
	_seed = world_seed

func inside(wx: int, wz: int) -> bool:
	return wx >= -HALF and wx < HALF and wz >= -HALF and wz < HALF

# (wx,wz) -> 扇区索引 0..8（row*3+col；col 按 x 西→东，row 按 z 北→南）
func sector_cell(wx: int, wz: int) -> int:
	var span := float(ISLAND_SIZE) / float(SECTORS)
	var col := clampi(int(floor((float(wx) + HALF) / span)), 0, SECTORS - 1)
	var row := clampi(int(floor((float(wz) + HALF) / span)), 0, SECTORS - 1)
	return row * SECTORS + col

func theme_at(wx: int, wz: int) -> int:
	return CELL_THEME[sector_cell(wx, wz)]

# 每个主题的地表：{top=地表块, sub=次表层填充块, water=是否注水}
const THEME_SURFACE := {
	IslandTheme.SNOW:        {"top": BlockLibrary.SNOW,        "sub": BlockLibrary.STONE, "water": false},
	IslandTheme.DESERT:      {"top": BlockLibrary.SAND,        "sub": BlockLibrary.RED_SAND, "water": false},
	IslandTheme.TROPICAL:    {"top": BlockLibrary.GRASS,       "sub": BlockLibrary.DIRT,  "water": true},
	IslandTheme.VILLAGE:     {"top": BlockLibrary.GRASS,       "sub": BlockLibrary.DIRT,  "water": false},
	IslandTheme.PLAZA:       {"top": BlockLibrary.GRASS,       "sub": BlockLibrary.DIRT,  "water": false},
	IslandTheme.CYBER:       {"top": BlockLibrary.STEEL_BLOCK, "sub": BlockLibrary.STONE, "water": false},
	IslandTheme.OBSERVATORY: {"top": BlockLibrary.MARBLE,      "sub": BlockLibrary.STONE, "water": false},
	IslandTheme.FARM:        {"top": BlockLibrary.DIRT,        "sub": BlockLibrary.DIRT,  "water": false},
	IslandTheme.BAY:         {"top": BlockLibrary.SAND,        "sub": BlockLibrary.SAND,  "water": true},
}

const THEME_LABEL := {
	IslandTheme.SNOW: "雪山", IslandTheme.DESERT: "沙漠", IslandTheme.TROPICAL: "热带海岸",
	IslandTheme.VILLAGE: "村庄", IslandTheme.PLAZA: "中央广场", IslandTheme.CYBER: "霓虹城",
	IslandTheme.OBSERVATORY: "天文台", IslandTheme.FARM: "农田", IslandTheme.BAY: "海湾",
}

# 确定性伪噪声 [-1,1]（无需 FastNoiseLite；同 seed 同坐标恒定）
func _noise(a: int, b: int) -> float:
	var n: int = (a * 73856093) ^ (b * 19349663) ^ (_seed * 83492791)
	n = (n << 13) ^ n
	var m: int = (n * (n * n * 15731 + 789221) + 1376312589) & 0x7fffffff
	return 1.0 - float(m) / 1073741824.0

func _theme_height(theme: int, wx: int, wz: int) -> int:
	match theme:
		IslandTheme.SNOW:
			return BASE_Y + 6 + int(round(10.0 * absf(_noise(wx >> 3, wz >> 3))))   # 雪峰
		IslandTheme.DESERT:
			return BASE_Y + int(round(3.0 * _noise(wx >> 4, wz >> 4)))              # 沙丘
		IslandTheme.BAY:
			return BASE_Y - 4                                                       # 海湾低地（水下）
		IslandTheme.TROPICAL:
			return BASE_Y - (1 if _noise(wx >> 4, wz >> 4) < -0.3 else 0)           # 偶有浅滩
		_:
			return BASE_Y

func surface_height(wx: int, wz: int) -> int:
	if not inside(wx, wz):
		return 0
	var h := _theme_height(theme_at(wx, wz), wx, wz)
	var edge_d := HALF - maxi(absi(wx), absi(wz))   # 到最近边界的距离
	if edge_d < EDGE:
		h -= (EDGE - edge_d) * 2                     # 边缘跌落成崖
	return maxi(h, FLOOR_Y + 1)

func generate(chunk: Chunk) -> void:
	for lx in range(Chunk.SX):
		for lz in range(Chunk.SZ):
			var wx := chunk.cx * Chunk.SX + lx
			var wz := chunk.cz * Chunk.SZ + lz
			if not inside(wx, wz):
				continue
			var theme := theme_at(wx, wz)
			var surf: Dictionary = THEME_SURFACE[theme]
			var top := surface_height(wx, wz)
			for y in range(FLOOR_Y, top):
				chunk.set_block(lx, y, lz, surf["sub"])
			chunk.set_block(lx, top, lz, surf["top"])
			# 含水扇区：地表以上注水到 WATER_Y
			if surf["water"]:
				for y in range(top + 1, WATER_Y + 1):
					chunk.set_block(lx, y, lz, BlockLibrary.WATER)

func region_label(wx: int, wz: int) -> String:
	if not inside(wx, wz):
		return "虚空"
	return THEME_LABEL[theme_at(wx, wz)]

func region_description(_wx: int, _wz: int) -> String:
	return "一座浮空的主题岛。"
