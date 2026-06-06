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

func surface_height(wx: int, wz: int) -> int:
	if not inside(wx, wz):
		return 0
	return BASE_Y

func generate(chunk: Chunk) -> void:
	for lx in range(Chunk.SX):
		for lz in range(Chunk.SZ):
			var wx := chunk.cx * Chunk.SX + lx
			var wz := chunk.cz * Chunk.SZ + lz
			if not inside(wx, wz):
				continue   # 界外：保持空气（浮空）
			var top := surface_height(wx, wz)
			for y in range(FLOOR_Y, top):
				chunk.set_block(lx, y, lz, BlockLibrary.STONE)
			chunk.set_block(lx, top, lz, BlockLibrary.GRASS)

func region_label(_wx: int, _wz: int) -> String:
	return "主题岛"

func region_description(_wx: int, _wz: int) -> String:
	return "一座浮空的主题岛。"
