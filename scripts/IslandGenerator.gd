extends RefCounted
# IslandGenerator —— 有限浮空主题岛的确定性生成器。
# 与 WorldGenerator 同接口（generate/surface_height/region_label/region_description），供 WorldData 按 kind 选用。
# 纯函数：仅依赖 (seed, wx, wz)；generate 不触碰任何全局可变状态，可在后台线程安全调用。
const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Pyramid = preload("res://scripts/structures/Pyramid.gd")
const ObservatoryDome = preload("res://scripts/structures/ObservatoryDome.gd")
const CyberTowers = preload("res://scripts/structures/CyberTowers.gd")
const WindmillFarm = preload("res://scripts/structures/WindmillFarm.gd")
const LighthouseDock = preload("res://scripts/structures/LighthouseDock.gd")
const SnowCabin = preload("res://scripts/structures/SnowCabin.gd")
const Village = preload("res://scripts/structures/Village.gd")
const PlazaMonument = preload("res://scripts/structures/PlazaMonument.gd")
const RailBridgeNet = preload("res://scripts/structures/RailBridgeNet.gd")
const IslandDecorator = preload("res://scripts/structures/IslandDecorator.gd")
const Waterfall = preload("res://scripts/structures/Waterfall.gd")

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

# Sector -> structure builder (static stamp function)
const THEME_BUILDER := {
	IslandTheme.SNOW: SnowCabin,
	IslandTheme.DESERT: Pyramid,
	IslandTheme.TROPICAL: LighthouseDock,
	IslandTheme.VILLAGE: Village,
	IslandTheme.PLAZA: PlazaMonument,
	IslandTheme.CYBER: CyberTowers,
	IslandTheme.OBSERVATORY: ObservatoryDome,
	IslandTheme.FARM: WindmillFarm,
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
			return BASE_Y - (4 if _noise(wx >> 4, wz >> 4) < -0.2 else 0)           # 低洼成浅海（< WATER_Y 才注水）
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

# 扇区中心世界坐标（确定性，按 cell 0..8 算出）
func sector_anchor(cell: int) -> Vector3i:
	var col := cell % SECTORS
	var row := cell / SECTORS
	var span := ISLAND_SIZE / SECTORS
	var cx := -HALF + span / 2 + col * span
	var cz := -HALF + span / 2 + row * span
	var sy := surface_height(cx, cz)
	return Vector3i(cx, sy, cz)

func generate(chunk: Chunk) -> void:
	# 1) 地形
	for lx in range(Chunk.SX):
		for lz in range(Chunk.SZ):
			var wx := chunk.cx * Chunk.SX + lx
			var wz := chunk.cz * Chunk.SZ + lz
			if not inside(wx, wz):
				continue
			var theme: int = theme_at(wx, wz)
			var surf: Dictionary = THEME_SURFACE[theme]
			var top := surface_height(wx, wz)
			for y in range(FLOOR_Y, top):
				chunk.set_block(lx, y, lz, surf["sub"])
			chunk.set_block(lx, top, lz, surf["top"])
			if surf["water"]:
				for y in range(top + 1, WATER_Y + 1):
					chunk.set_block(lx, y, lz, BlockLibrary.WATER)
	# 2) 标志建筑
	for cell in range(SECTORS * SECTORS):
		var cell_theme: int = CELL_THEME[cell]
		if THEME_BUILDER.has(cell_theme):
			var anchor := sector_anchor(cell)
			THEME_BUILDER[cell_theme].stamp(chunk, null, anchor)
	# 3) 铁轨连接网
	RailBridgeNet.stamp(chunk, null, Vector3i(0, BASE_Y, 0))
	# 4) 散布装饰（植被、灯柱、细节）
	for cell in range(SECTORS * SECTORS):
		var dec_theme: int = CELL_THEME[cell]
		var dec_anchor := sector_anchor(cell)
		IslandDecorator.stamp(chunk, null, dec_anchor, dec_theme, _seed)
	# 5) 瀑布（热带→海湾交界处）
	var tropical_anchor := sector_anchor(2)   # TROPICAL = cell 2（北排东）
	var bay_anchor := sector_anchor(8)        # BAY = cell 8（南排东）
	var wf_x: int = (tropical_anchor.x + bay_anchor.x) / 2
	var wf_z: int = (tropical_anchor.z + bay_anchor.z) / 2
	Waterfall.stamp(chunk, null, Vector3i(wf_x, BASE_Y, wf_z))

func region_label(wx: int, wz: int) -> String:
	if not inside(wx, wz):
		return "虚空"
	return THEME_LABEL[theme_at(wx, wz)]

const THEME_DESC := {
	IslandTheme.SNOW: "白雪皑皑的高山，松林间有木屋和冰晶闪烁。",
	IslandTheme.DESERT: "金沙起伏的沙丘，砂岩金字塔在烈日下矗立。",
	IslandTheme.TROPICAL: "碧水白沙的热带海岸，棕榈摇曳，灯塔守望远方。",
	IslandTheme.VILLAGE: "炊烟袅袅的宁静村庄，木屋沿鹅卵石小路排列。",
	IslandTheme.PLAZA: "岛屿中心的喷泉广场，金柱耸立，四通八达。",
	IslandTheme.CYBER: "霓虹闪烁的未来城区，钢铁与光构成冰冷的高塔。",
	IslandTheme.OBSERVATORY: "半球穹顶的天文台，大理石台阶通向星空。",
	IslandTheme.FARM: "阡陌纵横的田园，风车悠悠转动，作物随风摇曳。",
	IslandTheme.BAY: "静谧的海湾，浅水拍岸，远处是无尽的虚空。",
}

func region_description(wx: int, wz: int) -> String:
	if not inside(wx, wz):
		return "岛屿边缘之外，虚空深渊。"
	return THEME_DESC.get(theme_at(wx, wz), "一座浮空的主题岛。")
