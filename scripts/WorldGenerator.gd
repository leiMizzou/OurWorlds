extends RefCounted
# 程序化地形：噪声决定地表高度，分层填方块；高处石山+雪顶、地下矿物、3D 噪声挖洞穴。
# 可插拔 —— 要加新群系/结构只动这个文件。
#
# 性能 & 线程：
#   * 每次 generate()/surface_height() 都通过"每线程上下文"(_Ctx) 取噪声，并对
#     surface_height / biome 做 (wx,wz) 级缓存，消除对同一坐标反复 get_noise 的开销。
#   * FastNoiseLite 实例对并发 get_noise 不保证线程安全，所以每个线程独占一套噪声
#     （按 OS.get_thread_caller_id() 懒创建，仅创建时短暂加锁）；热路径无锁。
#     相同 seed -> 各线程噪声完全一致 -> generate() 仍是确定的纯数据函数，可被
#     WorkerThreadPool 并行调用而不破坏存档/出生点。
#   * preset（默认 "normal"）只切换 surface_height 的地形分支，默认路径逐字节不变。

const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

const SEA_LEVEL := 26
const ROCK_LINE := 58    # 高于此：裸石山体
const SNOW_LINE := 72    # 高于此：雪顶
const LANDMARK_RADIUS := 3
# 区域标签。新增的二维群系（温度×湿度）：沙漠/花海草甸/红土台地，与其表层材质一一对应。
const REGION_LABELS := [
	"草原",
	"风草原",
	"花海草甸",
	"针叶林",
	"苔林",
	"沙漠",
	"红土台地",
	"岩岭",
	"玄武岩岭",
	"雪峰",
	"湿地",
	"沙岸",
	"黏土滩",
	"浅水湾",
]

# ---- 二维群系（温度×湿度）：枚举/阈值定义在 _Ctx 内（见下），generate/region_label
# 统一以 _Ctx.Biome2D.* / _Ctx.classify_biome2d() 引用，避免内外类作用域漂移。 ----

# ---- 地形预设：只影响 surface_height 分支，默认 "normal" 与改动前逐字节一致 ----
# flat: 固定地表、跳过山脉项（建造平台）
# islands: 抬高高度对比 + 下调海平面（群岛）
# amplified: 放大山脉系数与 octaves（夸张地形）
const PRESETS := ["normal", "flat", "islands", "amplified"]
const FLAT_HEIGHT := 30   # flat 预设的固定地表高度

var _world_seed := 1337
var _preset := "normal"

# 每线程上下文：噪声实例 + (wx,wz) 级缓存。键 = OS.get_thread_caller_id()。
var _ctx_by_thread := {}
var _ctx_mutex := Mutex.new()

# 一套噪声 + 本区块的高度/群系网格缓存。一个实例只被建它的那个线程使用。
# 缓存用"本块 16×16 扁平网格"而非字典：generate 的主循环本来就要逐列算一遍高度/群系，
# 顺手写进 _h_grid/_b_grid（零额外噪声调用、零预扫描）；之后各结构的 _is_flat_site /
# 摆放探测，只要坐标落在本块就是 O(1) 数组读、零字典/哈希开销；落在块外的少量光环坐标
# 才退回直接计算（与原实现一致）。这样最坏也只等于原来、命中即省噪声，绝不更慢。
class _Ctx:
	extends RefCounted
	# 二维群系（温度×湿度）。干热成片->沙漠/红土台地；冷湿成片->针叶/苔；温润高湿->花海草甸。
	enum Biome2D { GRASS, MEADOW, PINE, MOSS, DESERT, MESA }
	const DRY_MOISTURE := 0.42      # 低于此湿度算"干"
	const WET_MOISTURE := 0.60      # 高于此湿度算"湿"
	const HOT_TEMP := 0.60          # 高于此温度算"热"
	const COLD_TEMP := 0.42         # 低于此温度算"冷"
	const MESA_MOISTURE := 0.34     # 极干 -> 红土台地（mesa）
	var height := FastNoiseLite.new()
	var mountain := FastNoiseLite.new()
	var tree := FastNoiseLite.new()
	var cave := FastNoiseLite.new()
	var biome := FastNoiseLite.new()
	var flora := FastNoiseLite.new()
	var moisture := FastNoiseLite.new()   # 独立湿度场（seed+211），与 biome 正交 -> 二维群系
	var temperature := FastNoiseLite.new() # 温度扰动（seed+277），叠到纬度/高度上
	var cavern := FastNoiseLite.new()      # 低频大空腔场（seed+419），过阈值挖溶洞
	var preset := "normal"
	var sea_level := SEA_LEVEL
	# 本块 16×16 预计算网格（索引 = lx * Chunk.SZ + lz）。
	var _grid_wx0 := 0
	var _grid_wz0 := 0
	var _grid_active := false
	var _h_grid := PackedInt32Array()
	var _b_grid := PackedFloat32Array()
	var _m_grid := PackedFloat32Array()   # 湿度
	var _t_grid := PackedFloat32Array()   # 温度

	func setup(world_seed: int, p: String) -> void:
		preset = p
		sea_level = SEA_LEVEL - 6 if p == "islands" else SEA_LEVEL
		_h_grid.resize(Chunk.SX * Chunk.SZ)
		_b_grid.resize(Chunk.SX * Chunk.SZ)
		_m_grid.resize(Chunk.SX * Chunk.SZ)
		_t_grid.resize(Chunk.SX * Chunk.SZ)

		height.noise_type = FastNoiseLite.TYPE_PERLIN
		height.seed = world_seed
		height.frequency = 0.0065
		height.fractal_octaves = 4

		mountain.noise_type = FastNoiseLite.TYPE_PERLIN
		mountain.fractal_type = FastNoiseLite.FRACTAL_RIDGED
		mountain.seed = world_seed + 7
		mountain.frequency = 0.008
		mountain.fractal_octaves = 6 if p == "amplified" else 4

		tree.noise_type = FastNoiseLite.TYPE_VALUE
		tree.seed = world_seed + 99
		tree.frequency = 1.0

		cave.noise_type = FastNoiseLite.TYPE_PERLIN
		cave.seed = world_seed + 31
		cave.frequency = 0.045
		cave.fractal_octaves = 2

		biome.noise_type = FastNoiseLite.TYPE_PERLIN
		biome.seed = world_seed + 53
		biome.frequency = 0.0028
		biome.fractal_octaves = 3

		flora.noise_type = FastNoiseLite.TYPE_VALUE
		flora.seed = world_seed + 151
		flora.frequency = 0.55

		# 湿度：独立大尺度场，决定干/湿带。频率比 biome 略低 -> 成片的湿区/旱区。
		moisture.noise_type = FastNoiseLite.TYPE_PERLIN
		moisture.seed = world_seed + 211
		moisture.frequency = 0.0024
		moisture.fractal_octaves = 2

		# 温度：缓慢扰动场，叠到纬度(z)/高度上合成总温度。低频 -> 大块冷热区。
		temperature.noise_type = FastNoiseLite.TYPE_PERLIN
		temperature.seed = world_seed + 277
		temperature.frequency = 0.0018
		temperature.fractal_octaves = 2

		# 大空腔：低频 3D 噪声，绝对值低处挖成溶洞大厅（与高频 cave 的窄通道互补）。
		cavern.noise_type = FastNoiseLite.TYPE_PERLIN
		cavern.seed = world_seed + 419
		cavern.frequency = 0.02
		cavern.fractal_octaves = 2

	# 进入一个区块：登记网格原点并启用。具体高度/群系由主循环边算边写入 _h_grid/_b_grid
	# （零额外噪声调用、零额外预扫描），之后结构摆放可 O(1) 复用。
	func arm_grid(base_wx: int, base_wz: int) -> void:
		_grid_wx0 = base_wx
		_grid_wz0 = base_wz
		_grid_active = true

	# 地表高度：命中本块网格则数组读，否则直接计算。
	func surface_height(wx: int, wz: int) -> int:
		if _grid_active:
			var lx := wx - _grid_wx0
			var lz := wz - _grid_wz0
			if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
				return _h_grid[lx * Chunk.SZ + lz]
		return _compute_height(wx, wz)

	# 群系标量（0..1）：命中本块网格则数组读，否则直接计算。
	func biome_at(wx: int, wz: int) -> float:
		if _grid_active:
			var lx := wx - _grid_wx0
			var lz := wz - _grid_wz0
			if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
				return _b_grid[lx * Chunk.SZ + lz]
		return _compute_biome(wx, wz)

	# 真正的高度计算（唯一来源）。默认 preset 与原 surface_height 逐字节一致。
	func _compute_height(wx: int, wz: int) -> int:
		match preset:
			"flat":
				return FLAT_HEIGHT
			"islands":
				# 抬高高度对比：地表噪声放大、海平面下调（群岛）。山脉项保留。
				var h_i := 30.0 + height.get_noise_2d(wx, wz) * 22.0
				var mm_i := (mountain.get_noise_2d(wx, wz) + 1.0) * 0.5
				h_i += pow(mm_i, 3.0) * 80.0
				return int(clamp(h_i, 2, Chunk.SY - 8))
			"amplified":
				# 夸张地形：放大山脉系数（octaves 已在 setup 调高）。
				var h_a := 30.0 + height.get_noise_2d(wx, wz) * 14.0
				var mm_a := (mountain.get_noise_2d(wx, wz) + 1.0) * 0.5
				h_a += pow(mm_a, 3.0) * 150.0
				return int(clamp(h_a, 2, Chunk.SY - 8))
			_:
				# normal —— 与历史实现完全一致。
				var h := 30.0 + height.get_noise_2d(wx, wz) * 14.0
				var mm := (mountain.get_noise_2d(wx, wz) + 1.0) * 0.5
				h += pow(mm, 3.0) * 80.0
				return int(clamp(h, 2, Chunk.SY - 8))

	func _compute_biome(wx: int, wz: int) -> float:
		return (biome.get_noise_2d(wx, wz) + 1.0) * 0.5

	# 湿度标量（0..1）：命中本块网格则数组读，否则直接计算。
	func moisture_at(wx: int, wz: int) -> float:
		if _grid_active:
			var lx := wx - _grid_wx0
			var lz := wz - _grid_wz0
			if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
				return _m_grid[lx * Chunk.SZ + lz]
		return _compute_moisture(wx, wz)

	func _compute_moisture(wx: int, wz: int) -> float:
		return (moisture.get_noise_2d(wx, wz) + 1.0) * 0.5

	# 温度标量（0..1）：命中本块网格则数组读，否则直接计算。
	func temperature_at(wx: int, wz: int) -> float:
		if _grid_active:
			var lx := wx - _grid_wx0
			var lz := wz - _grid_wz0
			if lx >= 0 and lx < Chunk.SX and lz >= 0 and lz < Chunk.SZ:
				return _t_grid[lx * Chunk.SZ + lz]
		return _compute_temperature(wx, wz, surface_height(wx, wz))

	# 总温度（0..1）：缓慢纬度带 + 噪声扰动 - 高度致冷。让冷热各自成片、且高山转冷。
	func _compute_temperature(wx: int, wz: int, h: int) -> float:
		var lat := 0.52 + sin(float(wz) * 0.0016) * 0.40        # 纬度带（缓慢南北冷热）
		var noise_t := temperature.get_noise_2d(wx, wz) * 0.40
		var altitude := clampf(float(h - SEA_LEVEL) / 64.0, 0.0, 1.0) * 0.26  # 越高越冷
		return clampf(lat + noise_t - altitude, 0.0, 1.0)

	# 二维群系分类：温度×湿度矩阵决定表层群系（枚举）。generate/region_label 共用。
	func biome2d_at(wx: int, wz: int) -> int:
		var t := temperature_at(wx, wz)
		var m := moisture_at(wx, wz)
		var b := biome_at(wx, wz)
		return classify_biome2d(t, m, b)

	static func classify_biome2d(t: float, m: float, b: float) -> int:
		# 干热成片：高温且低湿 -> 沙漠；其中更红更裸的（极干）-> 红土台地。
		if t >= HOT_TEMP and m < DRY_MOISTURE:
			if m < MESA_MOISTURE and b > 0.5:
				return Biome2D.MESA
			return Biome2D.DESERT
		# 冷湿成片：低温高湿 -> 苔林；低温中湿仍偏针叶。
		if t < COLD_TEMP and m >= WET_MOISTURE:
			return Biome2D.MOSS
		# 温润高湿（不冷不旱）-> 花海草甸。
		if m >= WET_MOISTURE and t >= COLD_TEMP and t < HOT_TEMP:
			return Biome2D.MEADOW
		# 湿润偏冷 -> 针叶林（沿用旧 biome 标量的针叶倾向）。
		if b > 0.64 and m >= DRY_MOISTURE:
			return Biome2D.PINE
		return Biome2D.GRASS

func _init(world_seed: int = 1337) -> void:
	_world_seed = world_seed

# 选择地形预设（可选；默认 "normal" 行为与历史逐字节一致）。
# 在任何 generate() 之前调用即可；会作废已建的线程上下文。
func set_preset(preset: String) -> void:
	var p := preset if preset in PRESETS else "normal"
	if p == _preset:
		return
	_preset = p
	_ctx_mutex.lock()
	_ctx_by_thread.clear()
	_ctx_mutex.unlock()

func get_preset() -> String:
	return _preset

# 取当前线程的上下文（懒创建）。整段加锁：每次 generate 只调一次（约 25ms 一次），
# 锁开销可忽略；却能彻底避免"一个线程读共享字典、另一个线程同时写/清空"的并发竞态
# （Godot Dictionary 跨线程读写不保证安全）。命中后各线程仍独占自己的 _Ctx，热路径无锁。
func _ctx() -> _Ctx:
	var tid := OS.get_thread_caller_id()
	_ctx_mutex.lock()
	var c: _Ctx = _ctx_by_thread.get(tid)
	if c == null:
		c = _Ctx.new()
		c.setup(_world_seed, _preset)
		_ctx_by_thread[tid] = c
	_ctx_mutex.unlock()
	return c

func surface_height(wx: int, wz: int) -> int:
	return _ctx().surface_height(wx, wz)

func region_label(wx: int, wz: int) -> String:
	return _region_label_ctx(_ctx(), wx, wz)

func _region_label_ctx(c: _Ctx, wx: int, wz: int) -> String:
	var h := c.surface_height(wx, wz)
	var biome := c.biome_at(wx, wz)
	if h < SEA_LEVEL:
		return "浅水湾"
	if h <= SEA_LEVEL + 1:
		return "沙岸" if _shore_block(c, wx, wz, biome) == BlockLibrary.SAND else "黏土滩"
	if _is_wetland(c, wx, wz, h, biome):
		return "湿地"
	if h >= SNOW_LINE:
		return "雪峰"
	if h >= ROCK_LINE:
		return "玄武岩岭" if biome > 0.62 else "岩岭"
	# 二维群系（温度×湿度）决定的成片地貌，标签与表层材质一致。
	var kind := c.biome2d_at(wx, wz)
	match kind:
		_Ctx.Biome2D.MESA:
			return "红土台地"
		_Ctx.Biome2D.DESERT:
			return "沙漠"
		_Ctx.Biome2D.MEADOW:
			return "花海草甸"
		_Ctx.Biome2D.MOSS:
			if h > SEA_LEVEL + 8:
				return "苔林"
		_Ctx.Biome2D.PINE:
			return "针叶林"
	if biome > 0.72 and h > SEA_LEVEL + 8:
		return "苔林"
	if biome > 0.64:
		return "针叶林"
	if biome < 0.34 and h > SEA_LEVEL + 6:
		return "风草原"
	return "草原"

func region_description(wx: int, wz: int) -> String:
	return region_description_for_label(region_label(wx, wz))

static func region_description_for_label(label: String) -> String:
	match label:
		"浅水湾":
			return "低岸水面，适合架桥"
		"沙岸":
			return "平坦沙脊，靠近水线"
		"黏土滩":
			return "湿润低滩，可采黏土"
		"湿地":
			return "浅水黏土，芦苇成片"
		"雪峰":
			return "冷白高脊，山雪常至"
		"玄武岩岭":
			return "黑石峭坡，夜间醒目"
		"岩岭":
			return "裸石坡面，适合采石"
		"苔林":
			return "苔石林地，蘑菇散落"
		"针叶林":
			return "高树密集，适合木构"
		"风草原":
			return "开阔高草，视野通透"
		"花海草甸":
			return "野花连片，高草摇曳"
		"沙漠":
			return "连绵黄沙，干枯灌木"
		"红土台地":
			return "赤陶分层，红沙裸露"
		"草原":
			return "平缓草地，适合起造"
		_:
			return "地貌变化，留意资源"

func generate(chunk: Chunk) -> void:
	var c := _ctx()
	# 本块开工：登记本块 16×16 网格；主循环边算高度/群系边写进网格（零额外噪声调用），
	# 结束后各结构摆放（_is_flat_site / _place_*）即可 O(1) 复用，省掉对同坐标重算噪声。
	var base_wx := chunk.cx * Chunk.SX
	var base_wz := chunk.cz * Chunk.SZ
	c.arm_grid(base_wx, base_wz)
	# 把噪声实例取成局部变量，避免内层（尤其洞穴 ~2万次/块）反复属性解引用。
	var cave_noise: FastNoiseLite = c.cave
	var cavern_noise: FastNoiseLite = c.cavern
	var tree_noise: FastNoiseLite = c.tree
	var height_noise: FastNoiseLite = c.height
	var mountain_noise: FastNoiseLite = c.mountain
	var biome_noise: FastNoiseLite = c.biome
	var moisture_noise: FastNoiseLite = c.moisture
	var temperature_noise: FastNoiseLite = c.temperature
	var is_normal := c.preset == "normal"
	for lx in range(Chunk.SX):
		for lz in range(Chunk.SZ):
			var wx := base_wx + lx
			var wz := base_wz + lz
			# 默认 preset 内联展开（与历史逐字节一致），非默认走 _compute_height 分支。
			var h: int
			if is_normal:
				var hf := 30.0 + height_noise.get_noise_2d(wx, wz) * 14.0
				hf += pow((mountain_noise.get_noise_2d(wx, wz) + 1.0) * 0.5, 3.0) * 80.0
				h = int(clamp(hf, 2, Chunk.SY - 8))
			else:
				h = c._compute_height(wx, wz)
			var biome := (biome_noise.get_noise_2d(wx, wz) + 1.0) * 0.5
			var moist := (moisture_noise.get_noise_2d(wx, wz) + 1.0) * 0.5
			# 总温度：纬度带 + 噪声 - 高度致冷（与 _Ctx._compute_temperature 一致）。
			var temp := clampf(
				0.52 + sin(float(wz) * 0.0016) * 0.40
				+ temperature_noise.get_noise_2d(wx, wz) * 0.40
				- clampf(float(h - SEA_LEVEL) / 64.0, 0.0, 1.0) * 0.26,
				0.0, 1.0)
			# 填入本块网格，供后续结构摆放 / region_label O(1) 复用。
			c._h_grid[lx * Chunk.SZ + lz] = h
			c._b_grid[lx * Chunk.SZ + lz] = biome
			c._m_grid[lx * Chunk.SZ + lz] = moist
			c._t_grid[lx * Chunk.SZ + lz] = temp
			var kind := _Ctx.classify_biome2d(temp, moist, biome)

			# 按高度决定表层/亚表层
			var top_block := BlockLibrary.GRASS
			var sub_block := BlockLibrary.DIRT
			if h >= SNOW_LINE:
				top_block = BlockLibrary.SNOW
				sub_block = BlockLibrary.STONE
			elif h >= ROCK_LINE:
				top_block = BlockLibrary.BASALT if biome > 0.62 else BlockLibrary.STONE
				sub_block = BlockLibrary.STONE
			elif kind == _Ctx.Biome2D.DESERT:
				# 沙漠：表层连续沙，亚表层也偏沙，干热成片。
				top_block = BlockLibrary.SAND
				sub_block = BlockLibrary.SAND
			elif kind == _Ctx.Biome2D.MESA:
				# 红土台地：表层红沙，亚表层赤陶分层（见下方逐格分层）。
				top_block = BlockLibrary.RED_SAND
				sub_block = BlockLibrary.TERRACOTTA
			elif biome > 0.72 and h > SEA_LEVEL + 8:
				top_block = BlockLibrary.MOSSY_STONE
				sub_block = BlockLibrary.DIRT

			var is_mesa := kind == _Ctx.Biome2D.MESA
			for y in range(h + 1):
				var block := BlockLibrary.STONE
				if y > h - 4:
					block = sub_block
				if y == h:
					block = top_block
				# 红土台地分层：亚表层按高度交替红沙/赤陶，做出 mesa 条纹。
				if is_mesa and y < h and y > h - 9:
					block = BlockLibrary.RED_SAND if (y % 3 == 0) else BlockLibrary.TERRACOTTA
				# 深层石头里埋矿
				if block == BlockLibrary.STONE and y > 2 and y < h - 4:
					var o := _ore(wx, y, wz)
					if o != 0:
						block = o
				chunk.set_block(lx, y, lz, block)

			# 洞穴：挖空地下（保留地表硬壳，不破坏行走层）
			for y in range(3, h - 3):
				if abs(cave_noise.get_noise_3d(wx, y * 2.0, wz)) < 0.05:
					chunk.set_block(lx, y, lz, BlockLibrary.AIR)
			# 大空腔：低频场过阈值挖成溶洞大厅（地表硬壳以下，留底壳）。
			_carve_cavern(chunk, cavern_noise, lx, lz, wx, wz, h)
			_plant_cave_crystals(chunk, lx, lz, wx, wz, h)

			var wetland := _is_wetland(c, wx, wz, h, biome)
			# 水边变沙；低地湿地偶尔露出黏土，让岸线/谷地有可辨认材料。
			if h <= SEA_LEVEL + 1:
				var shore := _shore_block(c, wx, wz, biome)
				chunk.set_block(lx, h, lz, shore)
			elif wetland:
				chunk.set_block(lx, h, lz, BlockLibrary.CLAY)
			# 灌水到海平面
			if h < SEA_LEVEL:
				for y in range(h + 1, SEA_LEVEL + 1):
					chunk.set_block(lx, y, lz, BlockLibrary.WATER)
			elif h <= SEA_LEVEL + 2 or wetland:
				_plant_reeds(c, chunk, lx, h + 1, lz, wx, wz)
			# 草地上偶尔种树 / 花草。地形内容尽量靠噪声决定，避免手工摆放感。
			elif h < ROCK_LINE:
				var tree_roll := tree_noise.get_noise_2d(wx, wz)
				if kind == _Ctx.Biome2D.DESERT or kind == _Ctx.Biome2D.MESA:
					# 干热区不长树：偶发干枯灌木（用枯红蘑菇造型替代，稀疏点缀）。
					_plant_dry_shrub(c, chunk, lx, h + 1, lz, wx, wz)
				elif kind == _Ctx.Biome2D.PINE and tree_roll > 0.86:
					_plant_pine(c, chunk, lx, h + 1, lz)
				elif biome > 0.64 and tree_roll > 0.86:
					_plant_pine(c, chunk, lx, h + 1, lz)
				elif tree_roll > 0.91:
					_plant_tree(c, chunk, lx, h + 1, lz)
				else:
					_plant_flora(c, chunk, lx, h + 1, lz, wx, wz, biome, kind)
	_place_springs(c, chunk)
	_place_crystal_geodes(c, chunk)
	_place_boulder_clusters(c, chunk)
	_place_fallen_logs(c, chunk)
	_place_cavern_landmarks(c, chunk)
	_place_landmarks(c, chunk)

func _ore(wx: int, y: int, wz: int) -> int:
	var r := _hash3(wx, y, wz)
	if y < 22 and r > 0.992:
		return BlockLibrary.IRON_ORE
	if y < 36 and r > 0.986:
		return BlockLibrary.COPPER_ORE
	if r > 0.976:
		return BlockLibrary.COAL_ORE
	return 0

func _shore_block(c: _Ctx, wx: int, wz: int, biome: float) -> int:
	var wet := _hash3(wx, 17, wz)
	if biome > 0.58 and wet > 0.58:
		return BlockLibrary.CLAY
	return BlockLibrary.SAND

func _is_wetland(c: _Ctx, wx: int, wz: int, h: int, biome: float) -> bool:
	return h <= SEA_LEVEL + 12 and biome > 0.46 and _hash3(wx, 29, wz) > 0.66

func _plant_tree(c: _Ctx, chunk: Chunk, lx: int, base_y: int, lz: int) -> void:
	var wx := chunk.cx * Chunk.SX + lx
	var wz := chunk.cz * Chunk.SZ + lz
	var trunk := 4 + int((c.tree.get_noise_2d(wx * 13, wz * 7) + 1.0) * 1.5)
	for i in range(trunk):
		chunk.set_block(lx, base_y + i, lz, BlockLibrary.LOG)
	var top := base_y + trunk
	for dx in range(-2, 3):
		for dy in range(-2, 2):
			for dz in range(-2, 3):
				if abs(dx) + abs(dy) + abs(dz) <= 3:
					var x := lx + dx
					var y := top + dy
					var z := lz + dz
					if chunk.in_bounds(x, y, z) and chunk.get_block(x, y, z) == 0:
						chunk.set_block(x, y, z, BlockLibrary.LEAVES)

func _plant_pine(c: _Ctx, chunk: Chunk, lx: int, base_y: int, lz: int) -> void:
	var wx := chunk.cx * Chunk.SX + lx
	var wz := chunk.cz * Chunk.SZ + lz
	var trunk := 6 + int((c.tree.get_noise_2d(wx * 5, wz * 11) + 1.0) * 2.0)
	for i in range(trunk):
		if chunk.in_bounds(lx, base_y + i, lz):
			chunk.set_block(lx, base_y + i, lz, BlockLibrary.LOG)
	for layer in range(4):
		var y := base_y + trunk - 1 - layer
		var radius := 2 - int(layer / 2)
		for dx in range(-radius, radius + 1):
			for dz in range(-radius, radius + 1):
				if abs(dx) + abs(dz) > radius + 1:
					continue
				var x := lx + dx
				var z := lz + dz
				if chunk.in_bounds(x, y, z) and chunk.get_block(x, y, z) == 0:
					chunk.set_block(x, y, z, BlockLibrary.PINE_LEAVES)
	if chunk.in_bounds(lx, base_y + trunk, lz):
		chunk.set_block(lx, base_y + trunk, lz, BlockLibrary.PINE_LEAVES)

func _plant_flora(c: _Ctx, chunk: Chunk, lx: int, y: int, lz: int, wx: int, wz: int, biome: float, kind: int = -1) -> void:
	if y >= Chunk.SY or chunk.get_block(lx, y, lz) != BlockLibrary.AIR:
		return
	var f := c.flora.get_noise_2d(wx, wz)
	# 花海草甸：放宽阈值 -> 高密度野花/高草连成片。
	if kind == _Ctx.Biome2D.MEADOW:
		if f > 0.05:
			chunk.set_block(lx, y, lz, BlockLibrary.WILDFLOWER)
		elif f > -0.55:
			chunk.set_block(lx, y, lz, BlockLibrary.TALL_GRASS)
		elif f < -0.82:
			chunk.set_block(lx, y, lz, BlockLibrary.RED_MUSHROOM)
		return
	if biome > 0.62 and f < -0.58:
		chunk.set_block(lx, y, lz, BlockLibrary.RED_MUSHROOM)
	elif f > 0.72 and biome < 0.68:
		chunk.set_block(lx, y, lz, BlockLibrary.WILDFLOWER)
	elif f > 0.58 and biome < 0.78:
		chunk.set_block(lx, y, lz, BlockLibrary.TALL_GRASS)

# 干热区干枯灌木：稀疏点缀（用红蘑菇造型当枯灌木），不长树、不长草甸花。
func _plant_dry_shrub(c: _Ctx, chunk: Chunk, lx: int, y: int, lz: int, wx: int, wz: int) -> void:
	if y >= Chunk.SY or chunk.get_block(lx, y, lz) != BlockLibrary.AIR:
		return
	if _hash3(wx, 487, wz) > 0.965:
		chunk.set_block(lx, y, lz, BlockLibrary.RED_MUSHROOM)
	elif _hash3(wx, 491, wz) > 0.94:
		chunk.set_block(lx, y, lz, BlockLibrary.TALL_GRASS)

func _place_boulder_clusters(c: _Ctx, chunk: Chunk) -> void:
	if _hash3(chunk.cx, 389, chunk.cz) < 0.68:
		return
	var lx := 3 + int(_hash3(chunk.cx, 397, chunk.cz) * 10.0)
	var lz := 3 + int(_hash3(chunk.cx, 409, chunk.cz) * 10.0)
	var wx := chunk.cx * Chunk.SX + lx
	var wz := chunk.cz * Chunk.SZ + lz
	var h := c.surface_height(wx, wz)
	var biome := c.biome_at(wx, wz)
	if h <= SEA_LEVEL + 3 or h >= SNOW_LINE + 4:
		return
	if not _is_flat_site(c, wx, wz, 2, 2):
		return
	var placed := []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var dist: int = abs(dx) + abs(dz)
			if dist > 2:
				continue
			var x := lx + dx
			var z := lz + dz
			var cell_wx := chunk.cx * Chunk.SX + x
			var cell_wz := chunk.cz * Chunk.SZ + z
			var surface := c.surface_height(cell_wx, cell_wz)
			if abs(surface - h) > 1:
				continue
			var roll := _hash3(cell_wx, surface + 421, cell_wz)
			if dist > 0 and roll < 0.32:
				continue
			var y := surface + 1
			if not _can_place_boulder_cell(chunk, x, y, z):
				continue
			var before := chunk.get_block(x, y, z)
			chunk.set_block(x, y, z, _boulder_block_id(c, cell_wx, y, cell_wz, biome, dist))
			placed.append({"pos": Vector3i(x, y, z), "before": before})
			if dist == 0 and _can_place_boulder_cell(chunk, x, y + 1, z) and _hash3(cell_wx, y + 433, cell_wz) > 0.30:
				var cap_before := chunk.get_block(x, y + 1, z)
				chunk.set_block(x, y + 1, z, _boulder_block_id(c, cell_wx, y + 1, cell_wz, biome, dist))
				placed.append({"pos": Vector3i(x, y + 1, z), "before": cap_before})
	if placed.size() < 2:
		for raw in placed:
			var entry: Dictionary = raw
			var pos: Vector3i = entry["pos"]
			chunk.set_block(pos.x, pos.y, pos.z, int(entry["before"]))

func _can_place_boulder_cell(chunk: Chunk, lx: int, y: int, lz: int) -> bool:
	if not chunk.in_bounds(lx, y, lz):
		return false
	var ground := chunk.get_block(lx, y - 1, lz)
	if ground == BlockLibrary.AIR or ground == BlockLibrary.WATER:
		return false
	var current := chunk.get_block(lx, y, lz)
	return current == BlockLibrary.AIR or _is_replaceable_flora(current)

func _boulder_block_id(c: _Ctx, wx: int, y: int, wz: int, biome: float, dist: int) -> int:
	var h := c.surface_height(wx, wz)
	var roll := _hash3(wx, y + 443 + dist * 17, wz)
	if h >= ROCK_LINE - 3:
		return BlockLibrary.BASALT if roll > 0.36 else BlockLibrary.STONE
	if biome > 0.68 or roll > 0.74:
		return BlockLibrary.MOSSY_STONE
	if roll > 0.43:
		return BlockLibrary.COBBLE
	return BlockLibrary.STONE

func _place_fallen_logs(c: _Ctx, chunk: Chunk) -> void:
	if _hash3(chunk.cx, 307, chunk.cz) < 0.76:
		return
	var lx := 3 + int(_hash3(chunk.cx, 313, chunk.cz) * 10.0)
	var lz := 3 + int(_hash3(chunk.cx, 331, chunk.cz) * 10.0)
	var wx := chunk.cx * Chunk.SX + lx
	var wz := chunk.cz * Chunk.SZ + lz
	var h := c.surface_height(wx, wz)
	var biome := c.biome_at(wx, wz)
	if h <= SEA_LEVEL + 3 or h >= ROCK_LINE - 2:
		return
	if biome < 0.48 and _hash3(wx, 337, wz) < 0.58:
		return
	if not _is_flat_site(c, wx, wz, 2, 2):
		return
	var axis_x := _hash3(chunk.cx, 347, chunk.cz) > 0.5
	var length := 3 + int(_hash3(chunk.cx, 353, chunk.cz) * 2.0)
	var cells := []
	for i in range(length):
		var offset := i - int(length / 2)
		var x := lx + offset if axis_x else lx
		var z := lz if axis_x else lz + offset
		var cell_wx := chunk.cx * Chunk.SX + x
		var cell_wz := chunk.cz * Chunk.SZ + z
		var y := c.surface_height(cell_wx, cell_wz) + 1
		if not _can_place_fallen_log_cell(chunk, x, y, z):
			return
		cells.append(Vector3i(x, y, z))
	for raw in cells:
		var cell: Vector3i = raw
		chunk.set_block(cell.x, cell.y, cell.z, BlockLibrary.LOG)
	_fallen_log_decoration(chunk, cells, axis_x)

func _can_place_fallen_log_cell(chunk: Chunk, lx: int, y: int, lz: int) -> bool:
	if not chunk.in_bounds(lx, y + 1, lz):
		return false
	var ground := chunk.get_block(lx, y - 1, lz)
	if ground == BlockLibrary.AIR or ground == BlockLibrary.WATER:
		return false
	var current := chunk.get_block(lx, y, lz)
	if current != BlockLibrary.AIR and not _is_replaceable_flora(current):
		return false
	return chunk.get_block(lx, y + 1, lz) == BlockLibrary.AIR

func _is_replaceable_flora(id: int) -> bool:
	return id == BlockLibrary.TALL_GRASS \
		or id == BlockLibrary.WILDFLOWER \
		or id == BlockLibrary.RED_MUSHROOM \
		or id == BlockLibrary.REEDS

func _fallen_log_decoration(chunk: Chunk, cells: Array, axis_x: bool) -> void:
	for i in range(cells.size()):
		var cell: Vector3i = cells[i]
		var side := -1 if i % 2 == 0 else 1
		var dx := 0 if axis_x else side
		var dz := side if axis_x else 0
		_place_log_edge_detail(chunk, cell.x + dx, cell.y, cell.z + dz, i)
		if i == 0 or i == cells.size() - 1:
			_place_log_edge_detail(chunk, cell.x - dx, cell.y, cell.z - dz, i + 9)

func _place_log_edge_detail(chunk: Chunk, lx: int, y: int, lz: int, salt: int) -> void:
	if not chunk.in_bounds(lx, y, lz) or chunk.get_block(lx, y, lz) != BlockLibrary.AIR:
		return
	var ground := chunk.get_block(lx, y - 1, lz)
	if ground == BlockLibrary.AIR or ground == BlockLibrary.WATER:
		return
	var r := _hash3(chunk.cx * 101 + lx, y + 359 + salt, chunk.cz * 103 + lz)
	if r > 0.78:
		chunk.set_block(lx, y, lz, BlockLibrary.RED_MUSHROOM)
	elif r > 0.56:
		chunk.set_block(lx, y, lz, BlockLibrary.TALL_GRASS)
	elif r > 0.40:
		chunk.set_block(lx, y, lz, BlockLibrary.WILDFLOWER)

func _plant_reeds(c: _Ctx, chunk: Chunk, lx: int, y: int, lz: int, wx: int, wz: int) -> void:
	if y >= Chunk.SY - 1 or chunk.get_block(lx, y, lz) != BlockLibrary.AIR:
		return
	if c.flora.get_noise_2d(wx * 3, wz * 3) < 0.42:
		return
	var height := 1 + int(_hash3(wx, 23, wz) * 3.0)
	for i in range(height):
		if chunk.in_bounds(lx, y + i, lz) and chunk.get_block(lx, y + i, lz) == BlockLibrary.AIR:
			chunk.set_block(lx, y + i, lz, BlockLibrary.REEDS)

# 大溶洞空腔：低频 3D 噪声仅在一条较窄深度带、且过较严阈值时挖出"偶发大厅"（不是遍地空腔）。
# 阈值随距带心衰减 -> 中心成腔、上下迅速收口（留地表硬壳与底壳，不破坏行走层/基岩）。
const CAVERN_TOP := 40         # 空腔带顶（更深，远离地表）
const CAVERN_BOTTOM := 10      # 空腔带底（留底壳）
const CAVERN_THRESHOLD := 0.052 # |noise| 低于此才挖空 —— 取小值让溶洞稀有、成厅而非遍地
func _carve_cavern(chunk: Chunk, cavern_noise: FastNoiseLite, lx: int, lz: int, wx: int, wz: int, surface: int) -> void:
	var top := mini(CAVERN_TOP, surface - 8)
	if top <= CAVERN_BOTTOM + 3:
		return
	var mid := float(CAVERN_BOTTOM + top) * 0.5
	var span := maxf(float(top - CAVERN_BOTTOM) * 0.5, 1.0)
	# 性能门：开腔阈值仅在带心(falloff=1)取满值、向上下迅速归零，故只有带心附近近零交叉的列才会开腔。
	# 低频场沿 y 变化平缓，单个带心采样即可判：幅值远高于阈值(0.20 ≫ 0.052)则本列无腔，
	# 直接跳过整列逐格噪声（绝大多数列在此返回，省下 ~30 次/列的 3D 噪声）。
	if absf(cavern_noise.get_noise_3d(wx, mid, wz)) > 0.20:
		return
	var carved := false
	for y in range(CAVERN_BOTTOM, top):
		var cur := chunk.get_block(lx, y, lz)
		if cur == BlockLibrary.AIR or cur == BlockLibrary.WATER:
			continue
		# 竖向收口：离带心越远阈值越小（平方衰减更陡）-> 顶/底快速封口、中心成腔
		var d := clampf(absf(float(y) - mid) / span, 0.0, 1.0)
		var falloff := (1.0 - d) * (1.0 - d)
		var thr := CAVERN_THRESHOLD * falloff
		if absf(cavern_noise.get_noise_3d(wx, float(y), wz)) < thr:
			chunk.set_block(lx, y, lz, BlockLibrary.AIR)
			carved = true
	if carved:
		_line_crystal_cave(chunk, lx, lz, wx, wz, CAVERN_BOTTOM, top)

# 把空腔地面（空气下方为石/亚表层固体）铺成蓝晶/苔石的"水晶洞"地衣层（稀疏，只点缀不刷屏）。
func _line_crystal_cave(chunk: Chunk, lx: int, lz: int, wx: int, wz: int, lo: int, hi: int) -> void:
	for y in range(lo + 1, hi):
		if chunk.get_block(lx, y, lz) != BlockLibrary.AIR:
			continue
		var below := chunk.get_block(lx, y - 1, lz)
		if not _is_cave_floor(below):
			continue
		var r := _hash3(wx, y * 7 + 601, wz)
		# 地面：稀疏苔石铺底，极零星蓝晶簇（向上长一格），其余保留原石地。
		if r > 0.955:
			chunk.set_block(lx, y - 1, lz, BlockLibrary.MOSSY_STONE)
			if r > 0.99 and chunk.get_block(lx, y, lz) == BlockLibrary.AIR:
				chunk.set_block(lx, y, lz, BlockLibrary.BLUE_CRYSTAL)
		elif r > 0.90:
			chunk.set_block(lx, y - 1, lz, BlockLibrary.MOSSY_STONE)

func _is_cave_floor(id: int) -> bool:
	return id == BlockLibrary.STONE or id == BlockLibrary.COBBLE \
		or id == BlockLibrary.BASALT or id == BlockLibrary.DIRT \
		or id == BlockLibrary.MOSSY_STONE

func _plant_cave_crystals(chunk: Chunk, lx: int, lz: int, wx: int, wz: int, surface: int) -> void:
	var max_y := mini(surface - 5, 52)
	if max_y <= 8:
		return
	for y in range(6, max_y):
		if chunk.get_block(lx, y, lz) != BlockLibrary.AIR:
			continue
		var below := chunk.get_block(lx, y - 1, lz)
		if below == BlockLibrary.AIR or below == BlockLibrary.WATER:
			continue
		if chunk.get_block(lx, y + 1, lz) != BlockLibrary.AIR:
			continue
		if _hash3(wx, y * 5 + 41, wz) > 0.996:
			chunk.set_block(lx, y, lz, BlockLibrary.BLUE_CRYSTAL)
			return

func _place_crystal_geodes(c: _Ctx, chunk: Chunk) -> void:
	if _hash3(chunk.cx, 503, chunk.cz) < 0.88:
		return
	var lx := 4 + int(_hash3(chunk.cx, 509, chunk.cz) * 8.0)
	var lz := 4 + int(_hash3(chunk.cx, 521, chunk.cz) * 8.0)
	var wx := chunk.cx * Chunk.SX + lx
	var wz := chunk.cz * Chunk.SZ + lz
	var surface := c.surface_height(wx, wz)
	var min_y := 10
	var max_y := mini(surface - 10, 54)
	if max_y <= min_y:
		return
	var cy := min_y + int(_hash3(chunk.cx, 541, chunk.cz) * float(max_y - min_y))
	var radius := 3
	if _hash3(wx, cy + 547, wz) > 0.72:
		radius = 2
	_build_crystal_geode(chunk, lx, cy, lz, radius)

func _build_crystal_geode(chunk: Chunk, cx: int, cy: int, cz: int, radius: int) -> void:
	var outer2 := float(radius * radius) + 1.65
	var inner_radius := maxi(radius - 1, 1)
	var inner2 := float(inner_radius * inner_radius)
	for dy in range(-radius, radius + 1):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				var lx := cx + dx
				var y := cy + dy
				var lz := cz + dz
				if not chunk.in_bounds(lx, y, lz):
					continue
				var dist2 := float(dx * dx + dy * dy + dz * dz)
				if dist2 > outer2:
					continue
				if dist2 <= inner2:
					chunk.set_block(lx, y, lz, BlockLibrary.AIR)
				else:
					chunk.set_block(lx, y, lz, _geode_shell_block(chunk, lx, y, lz, dist2))
	_seed_geode_crystals(chunk, cx, cy, cz, radius)

func _geode_shell_block(chunk: Chunk, lx: int, y: int, lz: int, dist2: float) -> int:
	var wx := chunk.cx * Chunk.SX + lx
	var wz := chunk.cz * Chunk.SZ + lz
	var r := _hash3(wx, y + 557 + int(dist2 * 7.0), wz)
	if r > 0.80:
		return BlockLibrary.MARBLE
	if r > 0.50:
		return BlockLibrary.BASALT
	return BlockLibrary.STONE

func _seed_geode_crystals(chunk: Chunk, cx: int, cy: int, cz: int, radius: int) -> void:
	var floor_y := cy - radius + 1
	var candidates := [
		Vector3i(cx, floor_y, cz),
		Vector3i(cx + 1, floor_y, cz),
		Vector3i(cx - 1, floor_y, cz),
		Vector3i(cx, floor_y, cz + 1),
		Vector3i(cx, floor_y, cz - 1),
		Vector3i(cx + 2, cy, cz),
		Vector3i(cx - 2, cy, cz),
		Vector3i(cx, cy, cz + 2),
		Vector3i(cx, cy, cz - 2),
		Vector3i(cx, cy + 1, cz),
	]
	for i in range(candidates.size()):
		var pos: Vector3i = candidates[i]
		if i > 0 and _hash3(chunk.cx * 17 + pos.x, pos.y + 563 + i, chunk.cz * 19 + pos.z) < 0.38:
			continue
		if _can_place_geode_crystal(chunk, pos):
			chunk.set_block(pos.x, pos.y, pos.z, BlockLibrary.BLUE_CRYSTAL)

func _can_place_geode_crystal(chunk: Chunk, pos: Vector3i) -> bool:
	if not chunk.in_bounds(pos.x, pos.y, pos.z):
		return false
	if chunk.get_block(pos.x, pos.y, pos.z) != BlockLibrary.AIR:
		return false
	var support := [
		Vector3i(0, -1, 0), Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
		Vector3i(0, 0, 1), Vector3i(0, 0, -1), Vector3i(0, 1, 0),
	]
	for raw in support:
		var d: Vector3i = raw
		var id := chunk.get_block(pos.x + d.x, pos.y + d.y, pos.z + d.z)
		if id == BlockLibrary.STONE or id == BlockLibrary.BASALT or id == BlockLibrary.MARBLE:
			return true
	return false

func _place_springs(c: _Ctx, chunk: Chunk) -> void:
	if _hash3(chunk.cx, 203, chunk.cz) < 0.82:
		return
	var lx := 4 + int(_hash3(chunk.cx, 211, chunk.cz) * 8.0)
	var lz := 4 + int(_hash3(chunk.cx, 223, chunk.cz) * 8.0)
	var wx := chunk.cx * Chunk.SX + lx
	var wz := chunk.cz * Chunk.SZ + lz
	var h := c.surface_height(wx, wz)
	var biome := c.biome_at(wx, wz)
	if h <= SEA_LEVEL + 3 or h >= ROCK_LINE - 4:
		return
	if not _is_flat_site(c, wx, wz, 2, 1):
		return
	var wetland_bonus := biome > 0.45 or _hash3(wx, 239, wz) > 0.50
	if not wetland_bonus:
		return
	_build_spring(chunk, lx, h, lz)

func _build_spring(chunk: Chunk, cx: int, surface_y: int, cz: int) -> void:
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var lx := cx + dx
			var lz := cz + dz
			if not chunk.in_bounds(lx, surface_y, lz):
				continue
			for y in range(surface_y + 1, mini(surface_y + 4, Chunk.SY)):
				chunk.set_block(lx, y, lz, BlockLibrary.AIR)
			var manhattan: int = abs(dx) + abs(dz)
			var cheb: int = maxi(abs(dx), abs(dz))
			if manhattan <= 1:
				_safe_set(chunk, lx, surface_y - 1, lz, BlockLibrary.CLAY)
				_safe_set(chunk, lx, surface_y, lz, BlockLibrary.WATER)
			elif cheb <= 2:
				var edge_id := BlockLibrary.CLAY
				if manhattan >= 3:
					edge_id = BlockLibrary.MOSSY_STONE if _hash3(lx, surface_y + 251, lz) > 0.54 else BlockLibrary.COBBLE
				_safe_set(chunk, lx, surface_y, lz, edge_id)
				_spring_decoration(chunk, lx, surface_y + 1, lz, manhattan)

func _spring_decoration(chunk: Chunk, lx: int, y: int, lz: int, manhattan: int) -> void:
	if y >= Chunk.SY or chunk.get_block(lx, y, lz) != BlockLibrary.AIR:
		return
	var r := _hash3(chunk.cx * 97 + lx, y + 263, chunk.cz * 101 + lz)
	if manhattan == 2 and r > 0.58:
		chunk.set_block(lx, y, lz, BlockLibrary.REEDS)
	elif r > 0.82:
		chunk.set_block(lx, y, lz, BlockLibrary.WILDFLOWER)
	elif r > 0.68:
		chunk.set_block(lx, y, lz, BlockLibrary.TALL_GRASS)

# 地下祭坛：在地下深带挖一个石厅，立 MARBLE 基座 + SUNSTONE 暖光锚（被 DiscoveryTracker 识别为
# 可发现/可修复地标），四壁嵌高浓度矿脉 —— 把"发现+修复"循环延伸到地下。
# 复用 _build_ruin/_build_stone_circle 的"苔石+大理石"语汇；以 SUNSTONE 锚标记为地下祭坛。
# 稀有度：~3% 区块（与地表遗迹同量级，作为"难得一遇的地下奇观"而非遍地结构）。
func _place_cavern_landmarks(c: _Ctx, chunk: Chunk) -> void:
	if _hash3(chunk.cx, 701, chunk.cz) < 0.965:
		return
	var lx := 5 + int(_hash3(chunk.cx, 709, chunk.cz) * 6.0)
	var lz := 5 + int(_hash3(chunk.cx, 719, chunk.cz) * 6.0)
	var wx := chunk.cx * Chunk.SX + lx
	var wz := chunk.cz * Chunk.SZ + lz
	var surface := c.surface_height(wx, wz)
	# 选一个深度带高度：在 16..min(40, surface-12)，确定性放置。
	var top := mini(40, surface - 12)
	if top <= 16:
		return
	var cy := 16 + int(_hash3(chunk.cx, 727, chunk.cz) * float(top - 16))
	_build_underground_altar(chunk, lx, cy, lz)

func _build_underground_altar(chunk: Chunk, cx: int, base_y: int, cz: int) -> void:
	var radius := 3
	var height := 6
	# 1) 挖一个圆角石厅（自带空腔，确保可进入/可发现，不依赖洞穴噪声落点）。
	for dy in range(0, height):
		for dz in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if abs(dx) + abs(dz) > radius + 1:
					continue
				var lx := cx + dx
				var y := base_y + dy
				var lz := cz + dz
				if chunk.in_bounds(lx, y, lz):
					chunk.set_block(lx, y, lz, BlockLibrary.AIR)
	# 2) 厅壁/底铺苔石与高浓度矿脉（地下宝库），顶部封一圈。
	for dz in range(-radius - 1, radius + 2):
		for dx in range(-radius - 1, radius + 2):
			var lx := cx + dx
			var lz := cz + dz
			var manh: int = abs(dx) + abs(dz)
			if manh > radius + 2:
				continue
			# 地面
			_safe_set(chunk, lx, base_y - 1, lz, BlockLibrary.MOSSY_STONE)
			# 四壁（环上一圈）嵌矿脉
			if manh >= radius:
				for y in range(base_y, base_y + height):
					var ore := _altar_vein_block(lx, y, lz)
					_safe_set(chunk, lx, y, lz, ore)
			# 顶盖
			_safe_set(chunk, lx, base_y + height, lz, BlockLibrary.STONE)
	# 3) 中央锚点：MARBLE 基座 + SUNSTONE 暖光锚（DiscoveryTracker 据"SUNSTONE 立于 MARBLE 上"识别为地下祭坛）。
	# 用 SUNSTONE 而非 LANTERN 当锚：自发光、地下醒目，且与地表遗迹的 LANTERN 锚区分，互不误判。
	_safe_set(chunk, cx, base_y - 1, cz, BlockLibrary.MARBLE)
	_safe_set(chunk, cx, base_y, cz, BlockLibrary.MARBLE)
	_safe_set(chunk, cx, base_y + 1, cz, BlockLibrary.SUNSTONE)   # 锚：地下祭坛
	# 基座四角苔石矮柱 + 大理石台沿（拉满 ruin_score，并呼应地面遗迹语汇）。
	for raw in [Vector2i(-2, -2), Vector2i(2, -2), Vector2i(-2, 2), Vector2i(2, 2)]:
		var p: Vector2i = raw
		_safe_set(chunk, cx + p.x, base_y - 1, cz + p.y, BlockLibrary.MARBLE)
		_safe_set(chunk, cx + p.x, base_y, cz + p.y, BlockLibrary.MOSSY_STONE)
		_safe_set(chunk, cx + p.x, base_y + 1, cz + p.y, BlockLibrary.MOSSY_STONE)
	# 四向点缀：暖光石 + 蓝晶，让地下地标在黑暗中醒目（呼应水晶洞氛围）。
	_safe_set(chunk, cx - 1, base_y + 1, cz, BlockLibrary.SUNSTONE)
	_safe_set(chunk, cx + 1, base_y + 1, cz, BlockLibrary.SUNSTONE)
	_safe_set(chunk, cx, base_y + 1, cz - 1, BlockLibrary.BLUE_CRYSTAL)
	_safe_set(chunk, cx, base_y + 1, cz + 1, BlockLibrary.BLUE_CRYSTAL)

func _altar_vein_block(lx: int, y: int, lz: int) -> int:
	var r := _hash3(lx, y + 733, lz)
	if r > 0.80:
		return BlockLibrary.IRON_ORE
	if r > 0.58:
		return BlockLibrary.COPPER_ORE
	if r > 0.34:
		return BlockLibrary.COAL_ORE
	return BlockLibrary.MOSSY_STONE

func _place_landmarks(c: _Ctx, chunk: Chunk) -> void:
	var roll := _hash3(chunk.cx, 77, chunk.cz)
	if roll < 0.72:
		return
	var lx := 5 + int(_hash3(chunk.cx, 91, chunk.cz) * 6.0)
	var lz := 5 + int(_hash3(chunk.cx, 113, chunk.cz) * 6.0)
	var wx := chunk.cx * Chunk.SX + lx
	var wz := chunk.cz * Chunk.SZ + lz
	var h := c.surface_height(wx, wz)
	if h <= SEA_LEVEL + 2 or h >= ROCK_LINE - 3 or h >= Chunk.SY - 8:
		return
	if not _is_flat_landmark_site(c, wx, wz):
		return
	var variant := int(_hash3(chunk.cx, 149, chunk.cz) * 3.0)
	match variant:
		0:
			_build_ruin(chunk, lx, h + 1, lz)
		1:
			_build_stone_circle(chunk, lx, h + 1, lz)
		_:
			_build_watch_spire(chunk, lx, h + 1, lz)

func _is_flat_landmark_site(c: _Ctx, wx: int, wz: int) -> bool:
	return _is_flat_site(c, wx, wz, LANDMARK_RADIUS, 3)

func _is_flat_site(c: _Ctx, wx: int, wz: int, radius: int, max_delta: int) -> bool:
	var min_h := Chunk.SY
	var max_h := 0
	for dz in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var hh := c.surface_height(wx + dx, wz + dz)
			min_h = mini(min_h, hh)
			max_h = maxi(max_h, hh)
	return max_h - min_h <= max_delta

func _build_ruin(chunk: Chunk, cx: int, base_y: int, cz: int) -> void:
	for dz in range(-LANDMARK_RADIUS, LANDMARK_RADIUS + 1):
		for dx in range(-LANDMARK_RADIUS, LANDMARK_RADIUS + 1):
			var lx := cx + dx
			var lz := cz + dz
			if not chunk.in_bounds(lx, base_y, lz):
				continue
			for y in range(base_y, mini(base_y + 7, Chunk.SY)):
				if chunk.get_block(lx, y, lz) != BlockLibrary.AIR:
					chunk.set_block(lx, y, lz, BlockLibrary.AIR)
			if abs(dx) <= 2 and abs(dz) <= 2:
				var floor_id := BlockLibrary.MOSSY_STONE if _hash3(chunk.cx * 31 + lx, base_y, chunk.cz * 37 + lz) > 0.55 else BlockLibrary.COBBLE
				chunk.set_block(lx, base_y - 1, lz, floor_id)

	var corners := [Vector2i(-3, -3), Vector2i(3, -3), Vector2i(-3, 3), Vector2i(3, 3)]
	for i in range(corners.size()):
		var p: Vector2i = corners[i]
		var height := 2 + int(_hash3(chunk.cx * 11 + i, base_y, chunk.cz * 13) * 3.0)
		_column(chunk, cx + p.x, base_y, cz + p.y, height)

	for x in range(-2, 3):
		if abs(x) == 1:
			continue
		_wall_block(chunk, cx + x, base_y, cz - 3, 1)
		if x != 0:
			_wall_block(chunk, cx + x, base_y + 1, cz - 3, 2)
	for z in range(-2, 3):
		if abs(z) != 1:
			_wall_block(chunk, cx - 3, base_y, cz + z, 1)
		if z == 0 or z == 2:
			_wall_block(chunk, cx + 3, base_y, cz + z, 1)

	_safe_set(chunk, cx, base_y, cz, BlockLibrary.MARBLE)
	_safe_set(chunk, cx, base_y + 1, cz, BlockLibrary.LANTERN)
	_safe_set(chunk, cx, base_y - 1, cz, BlockLibrary.MOSSY_STONE)
	_safe_set(chunk, cx - 2, base_y, cz + 2, BlockLibrary.MOONSTONE_LAMP)
	if _hash3(chunk.cx, base_y, chunk.cz) > 0.45:
		_safe_set(chunk, cx - 1, base_y, cz + 1, BlockLibrary.WILDFLOWER)
	if _hash3(chunk.cx, base_y + 9, chunk.cz) > 0.35:
		_safe_set(chunk, cx + 2, base_y, cz - 1, BlockLibrary.TALL_GRASS)

func _build_stone_circle(chunk: Chunk, cx: int, base_y: int, cz: int) -> void:
	_clear_landmark_air(chunk, cx, base_y, cz, 7)
	for dz in range(-LANDMARK_RADIUS, LANDMARK_RADIUS + 1):
		for dx in range(-LANDMARK_RADIUS, LANDMARK_RADIUS + 1):
			var dist: int = abs(dx) + abs(dz)
			var cheb: int = maxi(abs(dx), abs(dz))
			if cheb <= 1:
				_safe_set(chunk, cx + dx, base_y - 1, cz + dz, BlockLibrary.MARBLE if dist == 0 else BlockLibrary.MOSSY_STONE)
			elif cheb == LANDMARK_RADIUS and dist <= 5:
				_safe_set(chunk, cx + dx, base_y - 1, cz + dz, BlockLibrary.COBBLE)

	var standing := [
		Vector2i(-3, 0), Vector2i(3, 0), Vector2i(0, -3), Vector2i(0, 3),
		Vector2i(-2, -2), Vector2i(2, -2), Vector2i(-2, 2), Vector2i(2, 2),
	]
	for i in range(standing.size()):
		var p: Vector2i = standing[i]
		var height := 2 + int(_hash3(chunk.cx * 17 + i, base_y, chunk.cz * 23) * 2.0)
		for y in range(base_y, mini(base_y + height, Chunk.SY)):
			var id := BlockLibrary.MOSSY_STONE if (i + y) % 2 == 0 else BlockLibrary.COBBLE
			_safe_set(chunk, cx + p.x, y, cz + p.y, id)

	_safe_set(chunk, cx, base_y - 1, cz, BlockLibrary.COBBLE)
	_safe_set(chunk, cx, base_y, cz, BlockLibrary.MARBLE)
	_safe_set(chunk, cx, base_y + 1, cz, BlockLibrary.LANTERN)
	_safe_set(chunk, cx - 2, base_y, cz, BlockLibrary.MOONSTONE_LAMP)
	_safe_set(chunk, cx + 2, base_y, cz, BlockLibrary.MOONSTONE_LAMP)
	_safe_set(chunk, cx - 1, base_y, cz, BlockLibrary.WILDFLOWER)
	_safe_set(chunk, cx + 1, base_y, cz, BlockLibrary.TALL_GRASS)

func _build_watch_spire(chunk: Chunk, cx: int, base_y: int, cz: int) -> void:
	_clear_landmark_air(chunk, cx, base_y, cz, 9)
	for dz in range(-2, 3):
		for dx in range(-2, 3):
			var edge: bool = abs(dx) == 2 or abs(dz) == 2
			var id := BlockLibrary.BRICK if edge else BlockLibrary.MOSSY_STONE
			_safe_set(chunk, cx + dx, base_y - 1, cz + dz, id)

	var posts := [Vector2i(-2, -2), Vector2i(2, -2), Vector2i(-2, 2), Vector2i(2, 2)]
	for i in range(posts.size()):
		var p: Vector2i = posts[i]
		for y in range(base_y, mini(base_y + 5, Chunk.SY)):
			var id := BlockLibrary.BRICK if y % 2 == 0 else BlockLibrary.MOSSY_STONE
			_safe_set(chunk, cx + p.x, y, cz + p.y, id)
		_safe_set(chunk, cx + p.x, base_y + 5, cz + p.y, BlockLibrary.MARBLE)

	for z in range(-1, 2):
		for x in range(-1, 2):
			var id := BlockLibrary.BRICK if abs(x) == 1 or abs(z) == 1 else BlockLibrary.MARBLE
			_safe_set(chunk, cx + x, base_y + 4, cz + z, id)
	_safe_set(chunk, cx, base_y + 5, cz, BlockLibrary.MARBLE)
	_safe_set(chunk, cx, base_y + 6, cz, BlockLibrary.LANTERN)
	_safe_set(chunk, cx, base_y + 4, cz, BlockLibrary.BRICK)
	_safe_set(chunk, cx - 1, base_y + 5, cz, BlockLibrary.MOONSTONE_LAMP)
	_safe_set(chunk, cx + 1, base_y + 5, cz, BlockLibrary.MOONSTONE_LAMP)

func _clear_landmark_air(chunk: Chunk, cx: int, base_y: int, cz: int, height: int) -> void:
	for dz in range(-LANDMARK_RADIUS, LANDMARK_RADIUS + 1):
		for dx in range(-LANDMARK_RADIUS, LANDMARK_RADIUS + 1):
			var lx := cx + dx
			var lz := cz + dz
			if not chunk.in_bounds(lx, base_y, lz):
				continue
			for y in range(base_y, mini(base_y + height, Chunk.SY)):
				if chunk.get_block(lx, y, lz) != BlockLibrary.AIR:
					chunk.set_block(lx, y, lz, BlockLibrary.AIR)

func _column(chunk: Chunk, lx: int, base_y: int, lz: int, height: int) -> void:
	for y in range(base_y, mini(base_y + height, Chunk.SY)):
		var id := BlockLibrary.MOSSY_STONE if _hash3(lx, y, lz) > 0.62 else BlockLibrary.COBBLE
		_safe_set(chunk, lx, y, lz, id)

func _wall_block(chunk: Chunk, lx: int, y: int, lz: int, salt: int) -> void:
	if _hash3(lx + salt * 19, y, lz - salt * 7) < 0.18:
		return
	var id := BlockLibrary.BRICK if _hash3(lx, y + salt, lz) > 0.72 else BlockLibrary.MOSSY_STONE
	_safe_set(chunk, lx, y, lz, id)

func _safe_set(chunk: Chunk, lx: int, y: int, lz: int, id: int) -> void:
	if chunk.in_bounds(lx, y, lz):
		chunk.set_block(lx, y, lz, id)

static func _hash3(x: int, y: int, z: int) -> float:
	var h := x * 374761393 + y * 668265263 + z * 2246822519
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xffffff) / float(0x1000000)
