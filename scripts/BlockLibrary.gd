extends RefCounted
# 方块定义 + 程序生成的像素图集 + 共用材质 + 给后台线程用的"数值查找表(LUT)"。
# 数据驱动：加方块只在 _build_defs() 加一行；换真实贴图只改 _tile_color()。

# ---- 方块 ID ----
const AIR := 0
const GRASS := 1
const DIRT := 2
const STONE := 3
const COBBLE := 4
const LOG := 5
const PLANKS := 6
const SAND := 7
const GLASS := 8
const WATER := 9
const LEAVES := 10
const SNOW := 11
const COAL_ORE := 12
const IRON_ORE := 13
const BRICK := 14
const MOSSY_STONE := 15
const BASALT := 16
const MARBLE := 17
const LANTERN := 18
const WILDFLOWER := 19
const TALL_GRASS := 20
const PINE_LEAVES := 21
const COPPER_ORE := 22
const RED_MUSHROOM := 23
const REEDS := 24
const BLUE_CRYSTAL := 25
const CLAY := 26
const MOONSTONE_LAMP := 27
# ---- 建材/探索回报方块（精炼金属 + 暖色地貌 + 可建造光源）----
const POLISHED_IRON := 28   # 铁矿精炼：冷亮金属面 + 铆钉/拉丝
const COPPER_PANEL := 29    # 铜面板：暖橙金属 + 氧化绿斑纹
const STEEL_BLOCK := 30     # 钢块：中性银灰，斜向高光 + 接缝
const GOLD_TRIM := 31       # 鎏金饰板：奢华金面 + 横向装饰刻线
const RED_SAND := 32        # 红沙：mesa/沙漠暖红地貌
const TERRACOTTA := 33      # 赤陶/陶土：暖砖红，细腻团块
const SUNSTONE := 34        # 暖光石：暖白自发光建材（可建造光源）
# ---- 赛博/科技方块（SP2：霓虹发光 + 铁轨）----
const NEON_CYAN := 35       # 霓虹青：暗底+亮青网格线，自发光
const NEON_MAGENTA := 36    # 霓虹品红：暗底+品红网格线，自发光
const NEON_LIME := 37       # 霓虹绿：暗底+黄绿网格线，自发光
const RAIL := 38            # 铁轨：深色金属底+平行亮轨+枕木

const _NAME_EN := {
	AIR: "Air",
	GRASS: "Grass Block",
	DIRT: "Dirt",
	STONE: "Stone",
	COBBLE: "Cobblestone",
	LOG: "Log",
	PLANKS: "Wood Planks",
	SAND: "Sand",
	GLASS: "Glass",
	WATER: "Water",
	LEAVES: "Leaves",
	SNOW: "Snow",
	COAL_ORE: "Coal Ore",
	IRON_ORE: "Iron Ore",
	BRICK: "Bricks",
	MOSSY_STONE: "Mossy Stone",
	BASALT: "Basalt",
	MARBLE: "Marble",
	LANTERN: "Lantern",
	WILDFLOWER: "Wildflower",
	TALL_GRASS: "Tall Grass",
	PINE_LEAVES: "Pine Leaves",
	COPPER_ORE: "Copper Ore",
	RED_MUSHROOM: "Red Mushroom",
	REEDS: "Reeds",
	BLUE_CRYSTAL: "Blue Crystal",
	CLAY: "Clay",
	MOONSTONE_LAMP: "Moonstone Lamp",
	POLISHED_IRON: "Polished Iron",
	COPPER_PANEL: "Copper Panel",
	STEEL_BLOCK: "Steel Block",
	GOLD_TRIM: "Gold Trim",
	RED_SAND: "Red Sand",
	TERRACOTTA: "Terracotta",
	SUNSTONE: "Sunstone",
	NEON_CYAN: "Neon Cyan",
	NEON_MAGENTA: "Neon Magenta",
	NEON_LIME: "Neon Lime",
	RAIL: "Rail",
}

# ---- 图集贴图格子编号 ----
const T_GRASS_TOP := 0
const T_GRASS_SIDE := 1
const T_DIRT := 2
const T_STONE := 3
const T_COBBLE := 4
const T_LOG_TOP := 5
const T_LOG_SIDE := 6
const T_PLANKS := 7
const T_SAND := 8
const T_GLASS := 9
const T_WATER := 10
const T_LEAVES := 11
const T_SNOW := 12
const T_COAL := 13
const T_IRON := 14
const T_BRICK := 15
const T_MOSSY := 16
const T_BASALT := 17
const T_MARBLE := 18
const T_LANTERN := 19
const T_WILDFLOWER := 20
const T_TALL_GRASS := 21
const T_PINE_LEAVES := 22
const T_COPPER := 23
const T_RED_MUSHROOM := 24
const T_REEDS := 25
const T_BLUE_CRYSTAL := 26
const T_CLAY := 27
const T_MOONSTONE_LAMP := 28
const T_POLISHED_IRON := 29
const T_COPPER_PANEL := 30
const T_STEEL_BLOCK := 31
const T_GOLD_TRIM := 32
const T_RED_SAND := 33
const T_TERRACOTTA := 34
const T_SUNSTONE := 35
const T_NEON_CYAN := 36
const T_NEON_MAGENTA := 37
const T_NEON_LIME := 38
const T_RAIL := 39
const TILE_COUNT := 40

const ATLAS_COLS := 8
const ATLAS_ROWS := 5
const TILE := 16

var _defs := {}
var atlas: ImageTexture
var material: StandardMaterial3D
var material_emissive: StandardMaterial3D
var water_material: ShaderMaterial

# 后台线程安全的查找表（只读纯数值，不碰 Dictionary）
var solid_lut: PackedByteArray
var opaque_lut: PackedByteArray
var transp_lut: PackedByteArray
var water_lut: PackedByteArray
var tile_top_lut: PackedInt32Array
var tile_side_lut: PackedInt32Array
var tile_bot_lut: PackedInt32Array
# 材质分桶：0=哑光(绝大多数)，1=自发光(灯笼/月石灯/蓝晶/暖光石)。ChunkMesher 据此把面分到不同 surface。
var mat_bucket_lut: PackedByteArray

func _init() -> void:
	_build_defs()
	_build_luts()
	_build_atlas()
	_build_materials()

func _build_defs() -> void:
	_defs[GRASS]    = {"name": "草方块", "top": T_GRASS_TOP, "side": T_GRASS_SIDE, "bottom": T_DIRT, "solid": true, "transparent": false}
	_defs[DIRT]     = {"name": "泥土",   "top": T_DIRT,  "side": T_DIRT,  "bottom": T_DIRT,  "solid": true, "transparent": false}
	_defs[STONE]    = {"name": "石头",   "top": T_STONE, "side": T_STONE, "bottom": T_STONE, "solid": true, "transparent": false}
	_defs[COBBLE]   = {"name": "圆石",   "top": T_COBBLE, "side": T_COBBLE, "bottom": T_COBBLE, "solid": true, "transparent": false}
	_defs[LOG]      = {"name": "木头",   "top": T_LOG_TOP, "side": T_LOG_SIDE, "bottom": T_LOG_TOP, "solid": true, "transparent": false}
	_defs[PLANKS]   = {"name": "木板",   "top": T_PLANKS, "side": T_PLANKS, "bottom": T_PLANKS, "solid": true, "transparent": false}
	_defs[SAND]     = {"name": "沙子",   "top": T_SAND,  "side": T_SAND,  "bottom": T_SAND,  "solid": true, "transparent": false}
	_defs[GLASS]    = {"name": "玻璃",   "top": T_GLASS, "side": T_GLASS, "bottom": T_GLASS, "solid": true, "transparent": true}
	_defs[WATER]    = {"name": "水",     "top": T_WATER, "side": T_WATER, "bottom": T_WATER, "solid": false, "transparent": true}
	_defs[LEAVES]   = {"name": "树叶",   "top": T_LEAVES, "side": T_LEAVES, "bottom": T_LEAVES, "solid": true, "transparent": true}
	_defs[SNOW]     = {"name": "雪",     "top": T_SNOW,  "side": T_SNOW,  "bottom": T_SNOW,  "solid": true, "transparent": false}
	_defs[COAL_ORE] = {"name": "煤矿",   "top": T_COAL,  "side": T_COAL,  "bottom": T_COAL,  "solid": true, "transparent": false}
	_defs[IRON_ORE] = {"name": "铁矿",   "top": T_IRON,  "side": T_IRON,  "bottom": T_IRON,  "solid": true, "transparent": false}
	_defs[BRICK]    = {"name": "砖块",   "top": T_BRICK, "side": T_BRICK, "bottom": T_BRICK, "solid": true, "transparent": false}
	_defs[MOSSY_STONE] = {"name": "苔石", "top": T_MOSSY, "side": T_MOSSY, "bottom": T_MOSSY, "solid": true, "transparent": false}
	_defs[BASALT]   = {"name": "玄武岩", "top": T_BASALT, "side": T_BASALT, "bottom": T_BASALT, "solid": true, "transparent": false}
	_defs[MARBLE]   = {"name": "大理石", "top": T_MARBLE, "side": T_MARBLE, "bottom": T_MARBLE, "solid": true, "transparent": false}
	_defs[LANTERN]  = {"name": "灯笼",   "top": T_LANTERN, "side": T_LANTERN, "bottom": T_LANTERN, "solid": true, "transparent": true}
	_defs[WILDFLOWER] = {"name": "野花", "top": T_WILDFLOWER, "side": T_WILDFLOWER, "bottom": T_WILDFLOWER, "solid": false, "transparent": true}
	_defs[TALL_GRASS] = {"name": "草丛", "top": T_TALL_GRASS, "side": T_TALL_GRASS, "bottom": T_TALL_GRASS, "solid": false, "transparent": true}
	_defs[PINE_LEAVES] = {"name": "针叶", "top": T_PINE_LEAVES, "side": T_PINE_LEAVES, "bottom": T_PINE_LEAVES, "solid": true, "transparent": true}
	_defs[COPPER_ORE] = {"name": "铜矿", "top": T_COPPER, "side": T_COPPER, "bottom": T_COPPER, "solid": true, "transparent": false}
	_defs[RED_MUSHROOM] = {"name": "红蘑菇", "top": T_RED_MUSHROOM, "side": T_RED_MUSHROOM, "bottom": T_RED_MUSHROOM, "solid": false, "transparent": true}
	_defs[REEDS] = {"name": "芦苇", "top": T_REEDS, "side": T_REEDS, "bottom": T_REEDS, "solid": false, "transparent": true}
	_defs[BLUE_CRYSTAL] = {"name": "蓝晶", "top": T_BLUE_CRYSTAL, "side": T_BLUE_CRYSTAL, "bottom": T_BLUE_CRYSTAL, "solid": true, "transparent": true}
	_defs[CLAY] = {"name": "黏土", "top": T_CLAY, "side": T_CLAY, "bottom": T_CLAY, "solid": true, "transparent": false}
	_defs[MOONSTONE_LAMP] = {"name": "月石灯", "top": T_MOONSTONE_LAMP, "side": T_MOONSTONE_LAMP, "bottom": T_MOONSTONE_LAMP, "solid": true, "transparent": true}
	# 精炼金属建材：哑光桶(0)，靠贴图（高对比+斜向高光）体现金属质感，不依赖额外材质桶
	_defs[POLISHED_IRON] = {"name": "精炼铁", "top": T_POLISHED_IRON, "side": T_POLISHED_IRON, "bottom": T_POLISHED_IRON, "solid": true, "transparent": false}
	_defs[COPPER_PANEL]  = {"name": "铜面板", "top": T_COPPER_PANEL, "side": T_COPPER_PANEL, "bottom": T_COPPER_PANEL, "solid": true, "transparent": false}
	_defs[STEEL_BLOCK]   = {"name": "钢块",   "top": T_STEEL_BLOCK, "side": T_STEEL_BLOCK, "bottom": T_STEEL_BLOCK, "solid": true, "transparent": false}
	_defs[GOLD_TRIM]     = {"name": "鎏金饰板", "top": T_GOLD_TRIM, "side": T_GOLD_TRIM, "bottom": T_GOLD_TRIM, "solid": true, "transparent": false}
	# 暖色地貌/建材：实心不透明，供世界生成 mesa/沙漠用
	_defs[RED_SAND]      = {"name": "红沙",   "top": T_RED_SAND, "side": T_RED_SAND, "bottom": T_RED_SAND, "solid": true, "transparent": false}
	_defs[TERRACOTTA]    = {"name": "赤陶",   "top": T_TERRACOTTA, "side": T_TERRACOTTA, "bottom": T_TERRACOTTA, "solid": true, "transparent": false}
	# 可建造光源：自发光(进桶1)，与 MOONSTONE_LAMP/LANTERN 同样 transparent，发光像素 alpha 略低于 1
	_defs[SUNSTONE]      = {"name": "暖光石", "top": T_SUNSTONE, "side": T_SUNSTONE, "bottom": T_SUNSTONE, "solid": true, "transparent": true}
	# 赛博/科技方块（SP2）——霓虹自发光 + 铁轨
	_defs[NEON_CYAN]     = {"name": "霓虹青",   "top": T_NEON_CYAN, "side": T_NEON_CYAN, "bottom": T_NEON_CYAN, "solid": true, "transparent": false}
	_defs[NEON_MAGENTA]  = {"name": "霓虹品红", "top": T_NEON_MAGENTA, "side": T_NEON_MAGENTA, "bottom": T_NEON_MAGENTA, "solid": true, "transparent": false}
	_defs[NEON_LIME]     = {"name": "霓虹绿",   "top": T_NEON_LIME, "side": T_NEON_LIME, "bottom": T_NEON_LIME, "solid": true, "transparent": false}
	_defs[RAIL]          = {"name": "铁轨",     "top": T_RAIL, "side": T_RAIL, "bottom": T_RAIL, "solid": true, "transparent": false}

# 把定义压成扁平数值表，供后台线程造网格时无锁读取
func _build_luts() -> void:
	var n := RAIL + 1
	solid_lut = PackedByteArray(); solid_lut.resize(n)
	opaque_lut = PackedByteArray(); opaque_lut.resize(n)
	transp_lut = PackedByteArray(); transp_lut.resize(n)
	water_lut = PackedByteArray(); water_lut.resize(n)
	tile_top_lut = PackedInt32Array(); tile_top_lut.resize(n)
	tile_side_lut = PackedInt32Array(); tile_side_lut.resize(n)
	tile_bot_lut = PackedInt32Array(); tile_bot_lut.resize(n)
	for id in range(n):
		if _defs.has(id):
			var dd = _defs[id]
			solid_lut[id] = 1 if dd["solid"] else 0
			transp_lut[id] = 1 if dd["transparent"] else 0
			opaque_lut[id] = 1 if (dd["solid"] and not dd["transparent"]) else 0
			water_lut[id] = 1 if id == WATER else 0
			tile_top_lut[id] = dd["top"]
			tile_side_lut[id] = dd["side"]
			tile_bot_lut[id] = dd["bottom"]
	mat_bucket_lut = PackedByteArray(); mat_bucket_lut.resize(n)
	for eid in range(n):
		mat_bucket_lut[eid] = 1 if (eid == LANTERN or eid == MOONSTONE_LAMP or eid == BLUE_CRYSTAL or eid == SUNSTONE or eid == NEON_CYAN or eid == NEON_MAGENTA or eid == NEON_LIME) else 0

func hotbar_blocks() -> Array:
	return [GRASS, DIRT, STONE, BRICK, MOSSY_STONE, BASALT, MARBLE, LOG, PLANKS, GLASS, LANTERN, MOONSTONE_LAMP, SUNSTONE, POLISHED_IRON, NEON_CYAN, WILDFLOWER]

func creative_blocks() -> Array:
	# 注意：矿石(COPPER_ORE)排在精炼金属(COPPER_PANEL)之前——材料库按本列表顺序取"搜索首个匹配"，
	# 保证搜"铜"先命中铜矿(资源)而非铜面板(建材)。
	return [
		GRASS, DIRT, STONE, COBBLE, BRICK, MOSSY_STONE,
		BASALT, MARBLE, SAND, SNOW, CLAY, RED_SAND, TERRACOTTA, LOG, PLANKS,
		COAL_ORE, IRON_ORE, COPPER_ORE,
		POLISHED_IRON, COPPER_PANEL, STEEL_BLOCK, GOLD_TRIM,
		GLASS, LEAVES, PINE_LEAVES, LANTERN, MOONSTONE_LAMP, SUNSTONE,
		NEON_CYAN, NEON_MAGENTA, NEON_LIME, RAIL,
		WILDFLOWER, TALL_GRASS, RED_MUSHROOM, REEDS, BLUE_CRYSTAL,
		WATER,
	]

func creative_categories() -> Array:
	return [
		{"id": "all", "name": "全部", "blocks": creative_blocks()},
		{"id": "terrain", "name": "地形", "blocks": [GRASS, DIRT, STONE, COBBLE, SAND, RED_SAND, SNOW, CLAY, TERRACOTTA, WATER]},
		{"id": "building", "name": "建筑", "blocks": [BRICK, MOSSY_STONE, BASALT, MARBLE, CLAY, TERRACOTTA, POLISHED_IRON, COPPER_PANEL, STEEL_BLOCK, GOLD_TRIM, LOG, PLANKS, GLASS, SUNSTONE, MOONSTONE_LAMP]},
		{"id": "nature", "name": "自然", "blocks": [LEAVES, PINE_LEAVES, WILDFLOWER, TALL_GRASS, RED_MUSHROOM, REEDS]},
		{"id": "decor", "name": "装饰", "blocks": [LANTERN, MOONSTONE_LAMP, SUNSTONE, GOLD_TRIM, GLASS, WILDFLOWER, TALL_GRASS, RED_MUSHROOM, REEDS, BLUE_CRYSTAL]},
		{"id": "tech", "name": "科技", "blocks": [NEON_CYAN, NEON_MAGENTA, NEON_LIME, RAIL, STEEL_BLOCK, GLASS, POLISHED_IRON]},
		{"id": "ores", "name": "矿物", "blocks": [COAL_ORE, IRON_ORE, COPPER_ORE, BLUE_CRYSTAL, STONE]},
	]

func creative_category_blocks(category_id: String) -> Array:
	for cat in creative_categories():
		var meta: Dictionary = cat
		if String(meta.get("id", "")) == category_id:
			return meta.get("blocks", creative_blocks()).duplicate()
	return creative_blocks()

func has_def(id: int) -> bool: return _defs.has(id)
func block_name(id: int) -> String: return String(_defs[id]["name"]) if _defs.has(id) else "空气"
func block_name_for_language(id: int, lang: String) -> String:
	if lang == "en":
		return String(_NAME_EN.get(id, "Air"))
	return block_name(id)
func is_air(id: int) -> bool: return id == AIR
func is_renderable(id: int) -> bool: return id != AIR and _defs.has(id)
func is_solid(id: int) -> bool: return _defs.has(id) and _defs[id]["solid"]
func is_transparent(id: int) -> bool: return _defs.has(id) and _defs[id]["transparent"]
func is_opaque(id: int) -> bool: return is_renderable(id) and _defs[id]["solid"] and not _defs[id]["transparent"]
func is_collidable(id: int) -> bool: return is_solid(id)
func is_water(id: int) -> bool: return id == WATER

func tile_for(id: int, face_y: int) -> int:
	var d = _defs[id]
	if face_y > 0: return d["top"]
	elif face_y < 0: return d["bottom"]
	return d["side"]

func preview_color(id: int) -> Color:
	if not _defs.has(id):
		return Color(0.05, 1.0, 0.92, 1.0)
	var d: Dictionary = _defs[id]
	var colors := [
		_average_tile_color(int(d["top"])),
		_average_tile_color(int(d["side"])),
		_average_tile_color(int(d["bottom"])),
	]
	var sum := Color(0, 0, 0, 0)
	for c in colors:
		sum.r += c.r
		sum.g += c.g
		sum.b += c.b
		sum.a += c.a
	var avg := Color(sum.r / 3.0, sum.g / 3.0, sum.b / 3.0, sum.a / 3.0)
	var lift := 0.18
	return Color(
		clampf(avg.r + lift, 0.0, 1.0),
		clampf(avg.g + lift, 0.0, 1.0),
		clampf(avg.b + lift, 0.0, 1.0),
		1.0
	)

func uv_rect(tile: int) -> Rect2:
	var col := tile % ATLAS_COLS
	var row := tile / ATLAS_COLS
	var inset := 0.5 / float(ATLAS_COLS * TILE)
	var u0 := float(col) / float(ATLAS_COLS) + inset
	var v0 := float(row) / float(ATLAS_ROWS) + inset
	var u1 := float(col + 1) / float(ATLAS_COLS) - inset
	var v1 := float(row + 1) / float(ATLAS_ROWS) - inset
	return Rect2(u0, v0, u1 - u0, v1 - v0)

# ============ 程序生成像素贴图 ============

func _average_tile_color(tile: int) -> Color:
	var sum := Color(0, 0, 0, 0)
	var count := 0
	for py in [2, 6, 10, 14]:
		for px in [2, 6, 10, 14]:
			var c := _tile_color(tile, px, py)
			if c.a <= 0.05:
				continue
			sum.r += c.r
			sum.g += c.g
			sum.b += c.b
			sum.a += c.a
			count += 1
	if count == 0:
		return Color(0.7, 0.9, 1.0, 1.0)
	return Color(sum.r / float(count), sum.g / float(count), sum.b / float(count), sum.a / float(count))

func _build_atlas() -> void:
	var img := Image.create(ATLAS_COLS * TILE, ATLAS_ROWS * TILE, true, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for tile in range(TILE_COUNT):
		var ox := (tile % ATLAS_COLS) * TILE
		var oy := (tile / ATLAS_COLS) * TILE
		for py in range(TILE):
			for px in range(TILE):
				img.set_pixel(ox + px, oy + py, _tile_color(tile, px, py))
	# 生成 mipmap 链：消除远处方块贴图的闪烁/摩尔纹（配合材质 NEAREST_WITH_MIPMAPS 保持像素硬边）
	img.generate_mipmaps()
	atlas = ImageTexture.create_from_image(img)

func _build_materials() -> void:
	material = StandardMaterial3D.new()
	material.albedo_texture = atlas
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	material.cull_mode = BaseMaterial3D.CULL_BACK
	material.roughness = 0.92
	material.metallic = 0.0
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material.alpha_scissor_threshold = 0.5
	# 逐顶点 AO（ChunkMesher 写入顶点色，灰度）直接乘到 albedo，让方块有体积感
	material.vertex_color_use_as_albedo = true
	# 让 AO 暗部更干净，避免 specular 把暗角“洗白”
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	# 自发光材质：灯笼/月石灯/蓝晶用，图集亮色像素进入 HDR 触发泛光（发光块真正“会亮”）
	material_emissive = StandardMaterial3D.new()
	material_emissive.albedo_texture = atlas
	material_emissive.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	material_emissive.cull_mode = BaseMaterial3D.CULL_BACK
	material_emissive.roughness = 0.6
	material_emissive.metallic = 0.0
	material_emissive.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	material_emissive.alpha_scissor_threshold = 0.5
	material_emissive.vertex_color_use_as_albedo = true
	material_emissive.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material_emissive.emission_enabled = true
	material_emissive.emission_texture = atlas
	material_emissive.emission = Color(1.0, 1.0, 1.0)
	material_emissive.emission_operator = BaseMaterial3D.EMISSION_OP_MULTIPLY
	material_emissive.emission_energy_multiplier = 3.2

	var water_shader := Shader.new()
	water_shader.code = """
shader_type spatial;
render_mode blend_mix, depth_prepass_alpha, cull_disabled;

uniform sampler2D albedo_tex : source_color, filter_nearest;
uniform vec4 tint : source_color = vec4(0.36, 0.66, 0.92, 0.78);
uniform vec4 deep_tint : source_color = vec4(0.05, 0.20, 0.42, 1.0);
uniform vec4 sky_tint : source_color = vec4(0.62, 0.80, 0.98, 1.0);
uniform float wave_strength = 0.030;
uniform float ripple_strength = 0.0028;
uniform float fresnel_power = 4.0;

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// 两组交叉行波叠加，水面起伏更自然不机械
	float wave = sin(v_world.x * 2.7 + TIME * 0.95) + cos(v_world.z * 2.1 + TIME * 0.72);
	wave += 0.5 * sin((v_world.x + v_world.z) * 1.3 - TIME * 1.4);
	VERTEX.y += wave * wave_strength;
}

void fragment() {
	// 采样图集水纹并做细微 UV 抖动 = 流动波光
	vec2 wobble = vec2(
		sin(UV.y * 76.0 + TIME * 1.35),
		cos(UV.x * 68.0 + TIME * 1.10)
	) * ripple_strength;
	vec4 tex_a = texture(albedo_tex, UV);
	vec4 tex_b = texture(albedo_tex, UV + wobble);
	vec3 water_col = mix(tex_a.rgb, tex_b.rgb, 0.4) * tint.rgb;

	// 视角菲涅尔：掠射角(边缘)更亮、更反天空；俯视(正上)更通透见底色
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float fres = pow(1.0 - ndv, fresnel_power);

	// 深浅过渡：正视偏深蓝，掠视混入天空反射
	vec3 body = mix(deep_tint.rgb, water_col, clamp(ndv * 1.15, 0.0, 1.0));
	vec3 col = mix(body, sky_tint.rgb, fres * 0.65);

	// 细碎高光闪点（程序化，不依赖屏幕纹理）
	float spark = sin(v_world.x * 12.0 + TIME * 2.3) * cos(v_world.z * 11.0 - TIME * 1.9);
	col += vec3(0.05) * smoothstep(0.85, 1.0, spark);

	ALBEDO = col;
	// 掠射角更不透明(反光像镜面)，俯视更透(见水下)
	ALPHA = clamp(tint.a + fres * 0.18, 0.0, 0.94);
	ROUGHNESS = mix(0.06, 0.22, ndv);
	SPECULAR = 0.6;
	METALLIC = 0.0;
	EMISSION = water_col * 0.03;
}
"""
	water_material = ShaderMaterial.new()
	water_material.shader = water_shader
	water_material.set_shader_parameter("albedo_tex", atlas)
	water_material.set_shader_parameter("tint", Color(0.36, 0.66, 0.92, 0.78))
	water_material.set_shader_parameter("deep_tint", Color(0.05, 0.20, 0.42, 1.0))
	water_material.set_shader_parameter("sky_tint", Color(0.62, 0.80, 0.98, 1.0))
	water_material.set_shader_parameter("wave_strength", 0.030)
	water_material.set_shader_parameter("ripple_strength", 0.0028)
	water_material.set_shader_parameter("fresnel_power", 4.0)

# 按桶取材质：0=哑光，1=自发光。ChunkMesher.assemble 据此给每个 surface 选材质。
func bucket_material(b: int) -> Material:
	return material_emissive if b == 1 else material

func _tile_color(tile: int, px: int, py: int) -> Color:
	match tile:
		T_GRASS_TOP: return _t_grass_top(px, py)
		T_GRASS_SIDE: return _t_grass_side(px, py)
		T_DIRT: return _t_dirt(px, py)
		T_STONE: return _t_stone(px, py)
		T_COBBLE: return _t_cobble(px, py)
		T_LOG_TOP: return _t_log_top(px, py)
		T_LOG_SIDE: return _t_log_side(px, py)
		T_PLANKS: return _t_planks(px, py)
		T_SAND: return _t_sand(px, py)
		T_GLASS: return _t_glass(px, py)
		T_WATER: return _t_water(px, py)
		T_LEAVES: return _t_leaves(px, py)
		T_SNOW: return _t_snow(px, py)
		T_COAL: return _t_coal(px, py)
		T_IRON: return _t_iron(px, py)
		T_BRICK: return _t_brick(px, py)
		T_MOSSY: return _t_mossy(px, py)
		T_BASALT: return _t_basalt(px, py)
		T_MARBLE: return _t_marble(px, py)
		T_LANTERN: return _t_lantern(px, py)
		T_WILDFLOWER: return _t_wildflower(px, py)
		T_TALL_GRASS: return _t_tall_grass(px, py)
		T_PINE_LEAVES: return _t_pine_leaves(px, py)
		T_COPPER: return _t_copper(px, py)
		T_RED_MUSHROOM: return _t_red_mushroom(px, py)
		T_REEDS: return _t_reeds(px, py)
		T_BLUE_CRYSTAL: return _t_blue_crystal(px, py)
		T_CLAY: return _t_clay(px, py)
		T_MOONSTONE_LAMP: return _t_moonstone_lamp(px, py)
		T_POLISHED_IRON: return _t_polished_iron(px, py)
		T_COPPER_PANEL: return _t_copper_panel(px, py)
		T_STEEL_BLOCK: return _t_steel_block(px, py)
		T_GOLD_TRIM: return _t_gold_trim(px, py)
		T_RED_SAND: return _t_red_sand(px, py)
		T_TERRACOTTA: return _t_terracotta(px, py)
		T_SUNSTONE: return _t_sunstone(px, py)
		T_NEON_CYAN: return _t_neon(px, py, Color(0.0, 0.95, 0.95))
		T_NEON_MAGENTA: return _t_neon(px, py, Color(0.95, 0.15, 0.85))
		T_NEON_LIME: return _t_neon(px, py, Color(0.55, 1.0, 0.10))
		T_RAIL: return _t_rail(px, py)
	return Color(1, 0, 1, 1)

static func _hash01(x: int, y: int, salt: int) -> float:
	var h := x * 374761393 + y * 668265263 + salt * 982451653
	h = (h ^ (h >> 13)) * 1274126177
	h = h ^ (h >> 16)
	return float(h & 0xffffff) / float(0x1000000)

func _spk(base: Color, x: int, y: int, salt: int, amt: float) -> Color:
	var f := 1.0 + (_hash01(x, y, salt) - 0.5) * amt
	return Color(clampf(base.r * f, 0, 1), clampf(base.g * f, 0, 1), clampf(base.b * f, 0, 1), base.a)

# ---- 像素细节工具（确定性，无随机种子，供商用级贴图用）----

# 在 base 上加一个固定的亮度偏移（保 alpha），用于做明暗层次。
func _shade(base: Color, d: float) -> Color:
	return Color(clampf(base.r + d, 0, 1), clampf(base.g + d, 0, 1), clampf(base.b + d, 0, 1), base.a)

# 两色按 t∈[0,1] 线性插值（保留 a 的插值）。
func _mixc(a: Color, b: Color, t: float) -> Color:
	t = clampf(t, 0, 1)
	return Color(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t)

# 双线性平滑的值噪声 ∈[0,1]：比逐像素 _hash01 更柔和、能做云絮/斑驳，不发噪。
func _vnoise(x: float, y: float, salt: int) -> float:
	var xi := int(floor(x))
	var yi := int(floor(y))
	var fx := x - float(xi)
	var fy := y - float(yi)
	# smoothstep 权重，避免线性插值的菱形伪影
	fx = fx * fx * (3.0 - 2.0 * fx)
	fy = fy * fy * (3.0 - 2.0 * fy)
	var a := _hash01(xi, yi, salt)
	var b := _hash01(xi + 1, yi, salt)
	var c := _hash01(xi, yi + 1, salt)
	var d := _hash01(xi + 1, yi + 1, salt)
	var top := a + (b - a) * fx
	var bot := c + (d - c) * fx
	return top + (bot - top) * fy

# 2 个倍频的分形噪声 ∈[0,1]：地表/石材斑驳的主力。
func _fbm(x: float, y: float, salt: int) -> float:
	var v := _vnoise(x, y, salt) * 0.65
	v += _vnoise(x * 2.13 + 5.0, y * 2.13 + 5.0, salt + 17) * 0.35
	return clampf(v, 0, 1)

# 用平滑噪声扰动一个基色（围绕 base 上下浮动 amt 的亮度），比 _spk 干净。
func _grain(base: Color, x: int, y: int, salt: int, freq: float, amt: float) -> Color:
	var n := _fbm(float(x) * freq, float(y) * freq, salt) - 0.5
	return _shade(base, n * amt)

func _t_grass_top(px: int, py: int) -> Color:
	# 暖绿草坪：低频块状色斑铺底（深浅草丛），叠上竖向短草叶颗粒，再点高光草尖。
	var dark := Color(0.30, 0.50, 0.20)
	var lite := Color(0.46, 0.68, 0.30)
	var patch := _fbm(float(px) * 0.42, float(py) * 0.42, 1)
	var base := _mixc(dark, lite, patch)
	# 各向同性的细颗粒（逐像素，不沿行/列对齐 → 不产生条带）
	var grain := (_hash01(px, py, 41) - 0.5) * 0.09
	base = _shade(base, grain)
	# 稀疏亮草尖 / 暗缝隙，增加可读性
	var spr := _hash01(px, py, 42)
	if spr > 0.93: base = _shade(base, 0.12)
	elif spr < 0.06: base = _shade(base, -0.10)
	return base

func _t_dirt(px: int, py: int) -> Color:
	# 暖土黄褐：fbm 块斑 + 稀疏深色小石砾/碎屑颗粒。
	var base := _grain(Color(0.45, 0.32, 0.21), px, py, 2, 0.33, 0.16)
	var g := _hash01(px, py, 43)
	if g > 0.90: base = _shade(base, 0.07)        # 浅色砂粒
	elif g < 0.10: base = _shade(base, -0.09)     # 深色小石/腐殖
	return base

func _t_grass_side(px: int, py: int) -> Color:
	# 顶部草皮带 + 参差下垂草根过渡到泥土，边界自然不死板。
	var soil := _t_dirt(px, py)
	# 草皮覆盖深度随 x 抖动：3~6 像素，下沿做成锯齿草根
	var lip := 3 + int(_hash01(px, 0, 44) * 2.5)
	if py < lip:
		var dark := Color(0.30, 0.50, 0.20)
		var lite := Color(0.46, 0.68, 0.30)
		var top := _mixc(dark, lite, _fbm(float(px) * 0.5, float(py) * 0.5, 1))
		# 顶沿一行更亮，像被光照到的草尖
		if py == 0: top = _shade(top, 0.08)
		return top
	# 草根：草色随机往泥土里多探一两格，做出垂落感
	if py < lip + 3 and _hash01(px, py, 45) > 0.55:
		return _shade(Color(0.32, 0.52, 0.21), -0.04)
	return soil

func _t_stone(px: int, py: int) -> Color:
	# 冷灰岩石：fbm 斑驳铺底（不发噪），叠少量细裂纹与亮斑，整体偏冷略带蓝。
	var base := _grain(Color(0.50, 0.51, 0.56), px, py, 3, 0.28, 0.18)
	# 稀疏发丝裂纹：用高频噪声细线压暗
	var crack := _vnoise(float(px) * 0.9 + 3.0, float(py) * 0.9, 51)
	if crack > 0.78 and _hash01(px, py, 52) > 0.45:
		base = _shade(base, -0.15)
	# 偶发浅色矿物斑点
	if _hash01(px, py, 53) > 0.94:
		base = _shade(base, 0.10)
	return base

func _t_cobble(px: int, py: int) -> Color:
	# 圆石：用抖动后的格子边界做"石块缝"，每块石头自带一点圆润明暗。
	# 4x4 网格，块中心抖动 -> 缝隙不规则；缝隙压暗，块心提亮成卵石。
	var cx := px / 4
	var cy := py / 4
	# 块内坐标 0..3
	var ix := px - cx * 4
	var iy := py - cy * 4
	var tone := 0.46 + _hash01(cx, cy, 4) * 0.20      # 每块基础灰
	var base := Color(tone, tone, tone * 1.05, 1)     # 略带冷蓝
	# 缝隙：块边一圈压暗（抖动让某些边更窄/更宽）
	var edge := _hash01(cx, cy, 61)
	var is_seam := (ix == 0 or iy == 0) or (ix == 3 and edge > 0.5) or (iy == 3 and edge < 0.5)
	if is_seam:
		return _shade(base, -0.20)
	# 卵石高光：块内左上提亮、右下压暗，做出鼓起的立体感
	var lift := (1.5 - float(ix)) * 0.018 + (1.5 - float(iy)) * 0.018
	base = _shade(base, lift)
	return _grain(base, px, py, 62, 0.5, 0.06)

func _t_log_top(px: int, py: int) -> Color:
	# 树桩端面：同心年轮（明暗交替环）+ 深色髓心 + 暖棕外皮圈。
	var r := sqrt(pow(px - 7.5, 2.0) + pow(py - 7.5, 2.0))
	var wood_l := Color(0.52, 0.37, 0.20)
	var wood_d := Color(0.41, 0.28, 0.15)
	# 年轮：用 sin(r) 做平滑环，再叠一点噪声让环不完美
	var ring := 0.5 + 0.5 * sin(r * 2.2 + _vnoise(float(px) * 0.4, float(py) * 0.4, 5) * 1.2)
	var base := _mixc(wood_d, wood_l, ring)
	if r < 1.6:
		base = Color(0.34, 0.23, 0.12)                # 髓心
	if r > 6.6:
		base = _mixc(base, Color(0.30, 0.21, 0.12), 0.6)  # 外侧树皮暗圈
	return _grain(base, px, py, 56, 0.6, 0.05)

func _t_log_side(px: int, py: int) -> Color:
	# 树皮：竖向沟壑纹理（按列噪声分明暗带），暖棕，偶有深裂。
	var bark_l := Color(0.46, 0.32, 0.18)
	var bark_d := Color(0.33, 0.22, 0.12)
	# 列噪声决定这一竖条是凸（亮）还是凹（暗）的树皮脊
	var col := _fbm(float(px) * 0.7, float(py) * 0.18, 6)
	var base := _mixc(bark_d, bark_l, col)
	# 深竖裂缝
	if _hash01(px, py / 6, 57) > 0.88:
		base = _shade(base, -0.12)
	return _grain(base, px, py, 58, 0.5, 0.06)

func _t_planks(px: int, py: int) -> Color:
	# 木板：4 像素一块板，板间深缝；每块板有独立的暖棕基调 + 横向木纹。
	var plank := py / 4
	var tone := 0.58 + _hash01(0, plank, 71) * 0.10   # 每块板基础亮度略不同
	var base := Color(tone, tone * 0.73, tone * 0.43)
	# 横向木纹：沿 x 的低频明暗
	var grain := (_fbm(float(px) * 0.5, float(plank) * 3.7, 72) - 0.5) * 0.10
	base = _shade(base, grain)
	# 板缝（每 4 行底部一条暗缝）+ 缝两侧高光
	var iy := py - plank * 4
	if iy == 3:
		return _shade(base, -0.22)
	if iy == 0:
		base = _shade(base, 0.05)
	# 偶发钉点/木节
	if _hash01(px, py, 73) > 0.97:
		base = _shade(base, -0.14)
	return base

func _t_sand(px: int, py: int) -> Color:
	# 细沙：暖米黄，低频缓波（沙纹）+ 极细颗粒，干净不脏。
	var base := Color(0.86, 0.79, 0.56)
	var ripple := (_fbm(float(px) * 0.35, float(py) * 0.6, 8) - 0.5) * 0.10
	base = _shade(base, ripple)
	var g := _hash01(px, py, 81)
	if g > 0.92: base = _shade(base, 0.05)
	elif g < 0.08: base = _shade(base, -0.05)
	return base

func _t_glass(px: int, py: int) -> Color:
	# 通透玻璃：仅画清晰的框边 + 一道对角高光反光，其余完全透明。
	var border := px == 0 or py == 0 or px == 15 or py == 15
	var inner_border := px == 1 or py == 1 or px == 14 or py == 14
	if border:
		return Color(0.78, 0.90, 0.96, 0.85)          # 浅青框
	if inner_border:
		return Color(0.62, 0.78, 0.88, 0.30)          # 内侧淡描边
	# 对角高光条（左上到中部），模拟玻璃反光
	if (px + py == 6 or px + py == 7) and px < 9:
		return Color(1.0, 1.0, 1.0, 0.55)
	# 反向一道更淡的次高光
	if px - py == 4 and py > 7:
		return Color(0.95, 1.0, 1.0, 0.18)
	return Color(0.7, 0.85, 0.95, 0.0)

func _t_water(px: int, py: int) -> Color:
	# 水：清透海蓝，柔和波光（fbm 让明暗成片而非颗粒），半透明。
	var deep := Color(0.10, 0.34, 0.66)
	var shallow := Color(0.22, 0.52, 0.82)
	var w := _fbm(float(px) * 0.45, float(py) * 0.45, 9)
	var c := _mixc(deep, shallow, w)
	# 稀疏亮波峰
	if w > 0.78: c = _shade(c, 0.06)
	c.a = 0.82
	return c

func _t_leaves(px: int, py: int) -> Color:
	# 树叶：成簇深浅绿（fbm 团块），透光缺口偏向边角，叶面有亮点高光。
	var clump := _fbm(float(px) * 0.55, float(py) * 0.55, 11)
	# 缺口：低密度处 + 随机点 → 镂空，靠近边缘更易透
	var edge_bias := (absf(float(px) - 7.5) + absf(float(py) - 7.5)) / 15.0
	if _hash01(px, py, 12) + edge_bias * 0.35 > 1.05:
		return Color(0, 0, 0, 0)
	var dark := Color(0.16, 0.34, 0.14)
	var lite := Color(0.30, 0.52, 0.22)
	var base := _mixc(dark, lite, clump)
	# 叶面高光小点
	if _hash01(px, py, 13) > 0.90: base = _shade(base, 0.10)
	return base

func _t_snow(px: int, py: int) -> Color:
	# 雪：干净微蓝白，极淡起伏 + 少量闪亮雪晶点，避免死白平板。
	var base := Color(0.93, 0.96, 1.0)
	var d := (_fbm(float(px) * 0.4, float(py) * 0.4, 12) - 0.5) * 0.05
	base = _shade(base, d)
	if _hash01(px, py, 91) > 0.94:
		base = Color(1.0, 1.0, 1.0)                   # 闪亮雪晶
	return base

# 通用矿斑：在石底上长出 2 簇圆形矿团，团心实色、团缘带高光/暗边，清晰可辨。
func _ore_on_stone(px: int, py: int, salt: int, core: Color) -> Color:
	var stone := _t_stone(px, py)
	# 两个矿团中心（按 salt 确定性放置）
	var ax := 3.0 + _hash01(0, 0, salt) * 8.0
	var ay := 4.0 + _hash01(1, 0, salt) * 7.0
	var bx := 8.0 + _hash01(2, 0, salt) * 6.0
	var by := 9.0 + _hash01(3, 0, salt) * 5.0
	var da := sqrt(pow(px - ax, 2.0) + pow(py - ay, 2.0)) - _vnoise(float(px) * 0.8, float(py) * 0.8, salt) * 1.6
	var db := sqrt(pow(px - bx, 2.0) + pow(py - by, 2.0)) - _vnoise(float(px) * 0.8 + 3.0, float(py) * 0.8, salt) * 1.6
	var d := minf(da, db)
	if d < 1.9:
		var c := _grain(core, px, py, salt + 5, 0.7, 0.12)
		# 矿团高光（左上提亮）做出金属/晶面的反光
		c = _shade(c, (2.2 - d) * 0.04)
		return c
	if d < 2.6:
		return _shade(stone, -0.10)                   # 矿团暗边，与石底分离
	return stone

func _t_coal(px: int, py: int) -> Color:
	return _ore_on_stone(px, py, 13, Color(0.13, 0.13, 0.15))   # 乌黑煤

func _t_iron(px: int, py: int) -> Color:
	return _ore_on_stone(px, py, 14, Color(0.82, 0.66, 0.46))   # 赭黄铁

func _t_brick(px: int, py: int) -> Color:
	# 红砖墙：每行错缝半块，灰白砂浆缝清晰，砖面饱满暖红 + 每块独立色调。
	var row := py / 5
	var offset := 4 if row % 2 == 1 else 0           # 错缝
	var mortar_h := (py % 5 == 4)                    # 水平砂浆缝
	var mortar_v := ((px + offset) % 8 == 7)         # 垂直砂浆缝
	if mortar_h or mortar_v:
		return _grain(Color(0.55, 0.50, 0.46), px, py, 101, 0.5, 0.06)  # 浅灰砂浆
	# 砖块本体：每块基础色略不同（有的偏朱、有的偏褐）
	var bx := (px + offset) / 8
	var btone := _hash01(bx, row, 102)
	var brick_col := _mixc(Color(0.58, 0.22, 0.15), Color(0.66, 0.30, 0.20), btone)
	var base := _grain(brick_col, px, py, 103, 0.6, 0.10)
	# 砖面上缘高光 / 下缘阴影，做出微浮雕
	var iy := py % 5
	if iy == 0: base = _shade(base, 0.05)
	elif iy == 3: base = _shade(base, -0.05)
	return base

func _t_mossy(px: int, py: int) -> Color:
	# 苔石：在冷灰石缝面上长出成片青苔（fbm 团块，从底部/缝隙蔓延），苔藓带明暗。
	# 底面复用 cobble 的石块缝感，更有"古墙"味道
	var stone := _t_cobble(px, py)
	var moss_n := _fbm(float(px) * 0.4, float(py) * 0.4, 16)
	# 苔藓偏好聚集在下半部和石缝
	var bias := float(py) / 16.0 * 0.25
	if moss_n + bias > 0.62:
		var md := Color(0.20, 0.36, 0.16)
		var ml := Color(0.34, 0.52, 0.22)
		var moss := _mixc(md, ml, _fbm(float(px) * 0.7, float(py) * 0.7, 18))
		# 苔藓与石面交界处压暗一点，叠出层次
		if moss_n + bias < 0.70:
			moss = _shade(moss, -0.05)
		return moss
	return stone

func _t_basalt(px: int, py: int) -> Color:
	# 玄武岩：深冷灰带柱状竖纹（每隔几列一道亮/暗脊），偏蓝紫，凝重。
	var base_col := Color(0.20, 0.21, 0.25)
	# 柱状竖纹：x 方向周期性明暗带 + 噪声扰动列边界
	var colpos := float(px) + _vnoise(0.0, float(py) * 0.5, 17) * 1.5
	var stripe := 0.5 + 0.5 * sin(colpos * 0.95)
	var base := _shade(base_col, (stripe - 0.5) * 0.10)
	# 横向裂理（稀疏暗线）
	if _hash01(px / 2, py, 111) > 0.90:
		base = _shade(base, -0.05)
	# 细斑驳
	return _grain(base, px, py, 112, 0.6, 0.05)

func _t_marble(px: int, py: int) -> Color:
	# 大理石：明亮米白，柔和灰色脉络（弯曲的 turbulence 纹），优雅干净。
	var base := _grain(Color(0.88, 0.87, 0.83), px, py, 18, 0.35, 0.05)
	# 脉络：用受噪声扭曲的 sin 带，弯曲自然；细脉 + 偶发粗脉
	var warp := _fbm(float(px) * 0.3, float(py) * 0.3, 121) * 4.0
	var v := absf(sin((float(px) + float(py) * 1.3) * 0.4 + warp))
	if v > 0.92:
		return _mixc(base, Color(0.60, 0.62, 0.66), 0.7)   # 主脉
	if v > 0.85:
		return _mixc(base, Color(0.74, 0.75, 0.77), 0.5)   # 次脉羽化
	return base

func _t_lantern(px: int, py: int) -> Color:
	# 暖光灯笼：深木/铁框 + 顶底盖 + 中央炽亮发光纸面（中心最亮，向边缘转橙）。
	var frame := Color(0.20, 0.14, 0.08, 1)
	# 顶/底盖与吊环
	if py <= 1 or py >= 14:
		return frame
	if (px == 7 or px == 8) and py <= 2:
		return Color(0.28, 0.20, 0.12, 1)             # 吊环
	# 竖向骨架（两侧 + 中线）
	if px <= 2 or px >= 13 or px == 7 or px == 8:
		return frame
	# 发光纸面：径向亮度，核心近白热，外缘暖橙
	var d := absf(float(px) - 7.5) + absf(float(py) - 7.5)
	var heat := clampf(1.0 - d / 11.0, 0.0, 1.0)
	heat = heat * heat                                # 集中核心
	var col := _mixc(Color(1.0, 0.55, 0.16), Color(1.0, 0.92, 0.62), heat)
	# 轻微纸纹颗粒
	col = _grain(col, px, py, 19, 0.7, 0.06)
	col.a = 0.97
	return col

func _t_wildflower(px: int, py: int) -> Color:
	# 野花：纤细绿茎 + 两片叶 + 顶部五瓣花冠（带花心），其余透明。
	# 茎（py 大=底部）
	if py >= 6 and px == 8:
		return Color(0.22, 0.50, 0.20, 1)
	if py >= 6 and px == 7 and _hash01(px, py, 201) > 0.5:
		return Color(0.18, 0.44, 0.17, 1)              # 茎暗侧
	# 叶片
	if py == 9 and px >= 5 and px <= 7: return Color(0.24, 0.52, 0.22, 1)
	if py == 11 and px >= 9 and px <= 11: return Color(0.24, 0.52, 0.22, 1)
	# 花冠：以(8,4)为心的小圆
	var d := absi(px - 8) + absi(py - 4)
	if d <= 1:
		return Color(0.99, 0.86, 0.30, 1)              # 花心
	if d <= 3 and py <= 6:
		# 花瓣：同株统一一种颜色（按整体随机，避免每像素杂色）
		var warm := _hash01(0, 0, 202) > 0.5
		var col := Color(0.96, 0.58, 0.22) if warm else Color(0.86, 0.40, 0.86)
		return _shade(col, (_hash01(px, py, 203) - 0.5) * 0.08)
	return Color(0, 0, 0, 0)

func _t_tall_grass(px: int, py: int) -> Color:
	# 草丛：3 簇弯曲草叶，根部深、叶尖亮，自然透明背景。
	var col := Color(0, 0, 0, 0)
	# 每簇：(基x, 顶y, 弯曲方向)
	var blades := [[4, 2, 1], [8, 0, -1], [11, 4, 1]]
	for b in blades:
		var bx: int = b[0]
		var topy: int = b[1]
		var dir: int = b[2]
		if py < topy:
			continue
		# 草叶随高度向 dir 弯：越往上偏移越大
		var sway := int(float(py - topy) * 0.18) * dir
		if abs(px - (bx + sway)) <= 0:
			# 根深尖亮的渐变绿
			var t := clampf(float(py - topy) / 13.0, 0, 1)
			col = _mixc(Color(0.32, 0.58, 0.22), Color(0.20, 0.42, 0.15), t)
			col.a = 1.0
	return col

func _t_pine_leaves(px: int, py: int) -> Color:
	# 针叶：浓郁墨绿，成簇深浅 + 较多镂空（针叶稀疏），偶有亮针尖。
	var clump := _fbm(float(px) * 0.6, float(py) * 0.6, 22)
	var edge_bias := (absf(float(px) - 7.5) + absf(float(py) - 7.5)) / 15.0
	if _hash01(px, py, 23) + edge_bias * 0.40 > 1.00:
		return Color(0, 0, 0, 0)
	var dark := Color(0.09, 0.24, 0.14)
	var lite := Color(0.18, 0.38, 0.20)
	var base := _mixc(dark, lite, clump)
	if _hash01(px, py, 24) > 0.92: base = _shade(base, 0.08)
	return base

func _t_copper(px: int, py: int) -> Color:
	return _ore_on_stone(px, py, 23, Color(0.80, 0.45, 0.24))   # 橙铜

func _t_red_mushroom(px: int, py: int) -> Color:
	# 红蘑菇：米白菌柄（带菌环）+ 圆润红伞盖 + 白色斑点，背景透明。
	# 菌柄
	if py >= 9 and px >= 7 and px <= 8:
		var stem := _grain(Color(0.92, 0.86, 0.74), px, py, 24, 0.6, 0.06)
		if py == 9: stem = _shade(stem, -0.06)         # 菌环阴影
		return stem
	# 伞盖：以(7.5, 6)为心的半圆，底缘平
	var dx := float(px) - 7.5
	var dy := float(py) - 6.0
	var r := sqrt(dx * dx + dy * dy * 1.2)
	if py <= 8 and r <= 5.2:
		# 白色菌斑（确定性圆点）
		if _hash01(px / 2, py / 2, 25) > 0.74:
			return Color(0.98, 0.93, 0.80, 1)
		# 伞盖红，受光左上亮、右下暗，做出鼓起
		var red := Color(0.78, 0.13, 0.12)
		if (dy < 0.0 or dx < 0.0) and r < 4.0:
			red = _shade(red, 0.06)
		if py >= 7:
			red = _shade(red, -0.06)                    # 伞底压暗
		return _grain(red, px, py, 26, 0.6, 0.08)
	return Color(0, 0, 0, 0)

func _t_reeds(px: int, py: int) -> Color:
	# 芦苇：3 根直立芦秆 + 顶端褐色穗子，秆有受光明暗，背景透明。
	var stems: Array[int] = [4, 8, 11]
	for sx in stems:
		if px == sx and py >= 1:
			# 顶端 0~2 行画穗
			if py <= 2:
				return Color(0.55, 0.40, 0.22, 1)       # 芦花穗（褐）
			# 秆：受光侧偏亮黄绿
			var col := Color(0.40, 0.62, 0.28)          # 受光亮黄绿（px==sx 居中）
			return _shade(col, (_hash01(px, py, 27) - 0.5) * 0.06)
		# 穗向两侧散开一点
		if py == 1 and absi(px - sx) == 1:
			return Color(0.58, 0.43, 0.24, 1)
	return Color(0, 0, 0, 0)

func _t_blue_crystal(px: int, py: int) -> Color:
	# 蓝晶：菱形晶体，分面（左亮右暗）模拟切割面，亮高光棱 + 半透明。
	var dx := absi(px - 8)
	var dy := absi(py - 8)
	var center := dx + dy
	if center > 9:
		return Color(0, 0, 0, 0)
	# 晶面分区：左上受光最亮，右下最暗，制造立体切割感
	var facet := 0.0
	if px < 8 and py < 8: facet = 0.30          # 左上面
	elif px >= 8 and py < 8: facet = 0.10       # 右上面
	elif px < 8 and py >= 8: facet = -0.05      # 左下面
	else: facet = -0.18                          # 右下面（最暗）
	var base := Color(0.30, 0.62, 0.98, 0.80)
	base = _shade(base, facet)
	# 棱边高光（菱形边界内一圈）
	if center >= 7:
		base = _mixc(base, Color(0.70, 0.90, 1.0, 0.85), 0.5)
	# 核心闪光点
	if center <= 2:
		base = _mixc(base, Color(0.92, 0.98, 1.0, 0.9), 0.6)
	return base

func _t_clay(px: int, py: int) -> Color:
	# 黏土：柔和的灰青/藕灰，平滑团块色差 + 极细颗粒，质地细腻无棱角。
	var a := Color(0.56, 0.60, 0.62)
	var b := Color(0.62, 0.64, 0.63)
	var base := _mixc(a, b, _fbm(float(px) * 0.38, float(py) * 0.38, 30))
	return _grain(base, px, py, 32, 0.6, 0.05)

func _t_moonstone_lamp(px: int, py: int) -> Color:
	# 月石灯：深蓝石框镶嵌发光月华核心，中心冷白炽亮，向外转柔蓝，对角棱高光。
	var border := px == 0 or px == 15 or py == 0 or py == 15
	if border:
		return Color(0.16, 0.22, 0.34, 0.96)           # 深蓝框
	if px == 1 or px == 14 or py == 1 or py == 14:
		return Color(0.22, 0.30, 0.46, 0.92)           # 框内描边
	# 中央发光核：径向亮度
	var d := absf(float(px) - 7.5) + absf(float(py) - 7.5)
	var heat := clampf(1.0 - d / 12.0, 0.0, 1.0)
	heat = heat * heat
	var col := _mixc(Color(0.38, 0.62, 0.95), Color(0.86, 0.95, 1.0), heat)
	# 对角棱镜高光（月石的光带）
	if px == py or px + py == 15:
		col = _mixc(col, Color(0.92, 0.98, 1.0), 0.45)
	col = _grain(col, px, py, 33, 0.7, 0.05)
	col.a = 0.90
	return col

# ---- 建材：精炼金属（哑光桶，纯靠贴图体现金属高对比 + 斜向高光）----

func _t_polished_iron(px: int, py: int) -> Color:
	# 精炼铁：冷亮银白金属面，对角拉丝高光带（左上炽亮→右下转暗），四角铆钉，边缘倒角。
	var base := Color(0.62, 0.65, 0.70)
	# 对角各向异性高光：沿主对角线最亮，远离对角线快速变暗 → 强金属反光感
	var diag := absf(float(px - py)) / 15.0
	base = _shade(base, (0.34 - diag) * 0.55)
	# 极细横向拉丝纹（金属抛光痕），不发噪
	base = _shade(base, sin(float(py) * 1.9) * 0.018)
	# 倒角边框：上/左提亮，下/右压暗，做出冷压钢板的厚度
	if px == 0 or py == 0:
		base = _shade(base, 0.16)
	elif px == 15 or py == 15:
		base = _shade(base, -0.20)
	# 四角铆钉（小亮点 + 暗边），工业金属面板的标志
	for rp in [[3, 3], [12, 3], [3, 12], [12, 12]]:
		var rd := absi(px - rp[0]) + absi(py - rp[1])
		if rd == 0:
			return Color(0.86, 0.89, 0.94)        # 铆钉高光顶
		if rd == 1:
			base = _shade(base, -0.14)            # 铆钉凹影
	return _grain(base, px, py, 211, 0.6, 0.03)

func _t_copper_panel(px: int, py: int) -> Color:
	# 铜面板：暖橙金属底 + 对角高光，叠成片青绿氧化锈斑（verdigris），底部接缝与铆钉。
	var base := Color(0.74, 0.44, 0.26)
	var diag := absf(float(px - py)) / 15.0
	base = _shade(base, (0.30 - diag) * 0.46)
	# 氧化绿斑：低频 fbm 团块在暖铜上长出青绿铜锈
	var ox := _fbm(float(px) * 0.34, float(py) * 0.34, 212)
	if ox > 0.60:
		var patina := _mixc(Color(0.30, 0.62, 0.52), Color(0.46, 0.74, 0.60), _fbm(float(px) * 0.7, float(py) * 0.7, 213))
		base = _mixc(base, patina, clampf((ox - 0.60) * 2.4, 0.0, 0.85))
	# 面板边框：上/左暖亮、下/右压暗
	if px == 0 or py == 0:
		base = _shade(base, 0.14)
	elif px == 15 or py == 15:
		base = _shade(base, -0.18)
	# 中部一道水平接缝（两片铜皮的折边）
	if py == 8:
		base = _shade(base, -0.16)
	elif py == 7:
		base = _shade(base, 0.08)
	# 两枚铆钉
	for rp in [[4, 4], [11, 12]]:
		if absi(px - rp[0]) + absi(py - rp[1]) == 0:
			return Color(0.92, 0.74, 0.50)
	return _grain(base, px, py, 214, 0.6, 0.04)

func _t_steel_block(px: int, py: int) -> Color:
	# 钢块：中性银灰，强对角镜面高光 + 规整面板接缝（十字分块）+ 角铆钉，干净工业感。
	var base := Color(0.56, 0.58, 0.62)
	var diag := absf(float(px - py)) / 15.0
	base = _shade(base, (0.32 - diag) * 0.52)
	# 反向次高光（右上→左下一道更淡的反射），让金属更有体积
	base = _shade(base, (0.5 - absf(float((px + py) - 15)) / 15.0) * 0.06)
	# 十字接缝把面分成 4 块（中线压暗、缝旁提亮，像铆接钢板）
	if px == 7 or py == 7:
		base = _shade(base, -0.18)
	elif px == 8 or py == 8:
		base = _shade(base, 0.07)
	# 外框倒角
	if px == 0 or py == 0:
		base = _shade(base, 0.14)
	elif px == 15 or py == 15:
		base = _shade(base, -0.18)
	# 四角铆钉
	for rp in [[3, 3], [12, 3], [3, 12], [12, 12]]:
		if absi(px - rp[0]) + absi(py - rp[1]) == 0:
			base = _shade(base, 0.22)
	return _grain(base, px, py, 215, 0.6, 0.03)

func _t_gold_trim(px: int, py: int) -> Color:
	# 鎏金饰板：奢华暖金，强对角炽亮高光 + 上下两道横向装饰刻线（亮脊+暗槽），雕花点缀。
	var base := Color(0.85, 0.68, 0.24)
	var diag := absf(float(px - py)) / 15.0
	base = _shade(base, (0.36 - diag) * 0.62)     # 黄金高反光，对比拉满
	# 横向装饰刻线带（第 3/4 与 11/12 行）：亮脊压暗槽，做出浮雕金线
	if py == 3 or py == 12:
		base = _shade(base, 0.20)                 # 凸起金脊（受光）
	elif py == 4 or py == 11:
		base = _shade(base, -0.22)                # 刻槽阴影
	# 边框
	if px == 0 or py == 0:
		base = _shade(base, 0.16)
	elif px == 15 or py == 15:
		base = _shade(base, -0.20)
	# 中央菱形雕花亮点
	var dc := absi(px - 8) + absi(py - 8)
	if dc <= 1:
		base = _shade(base, 0.18)
	elif dc == 2:
		base = _shade(base, -0.10)
	return _grain(base, px, py, 216, 0.6, 0.03)

# ---- 暖色地貌/建材（实心不透明，供 mesa/沙漠世界生成）----

func _t_red_sand(px: int, py: int) -> Color:
	# 红沙：暖赭红沙地，低频缓波（风蚀沙纹）+ 细颗粒，比普通沙更红更暖（mesa 风味）。
	var base := Color(0.74, 0.40, 0.24)
	var ripple := (_fbm(float(px) * 0.33, float(py) * 0.6, 217) - 0.5) * 0.12
	base = _shade(base, ripple)
	var g := _hash01(px, py, 218)
	if g > 0.91: base = _shade(base, 0.06)        # 浅色石英砂粒
	elif g < 0.09: base = _shade(base, -0.07)     # 深色铁染颗粒
	return base

func _t_terracotta(px: int, py: int) -> Color:
	# 赤陶/陶土：温暖砖红陶面，平滑团块色差（窑变）+ 极细颗粒，质地细腻无棱角。
	var a := Color(0.70, 0.38, 0.27)
	var b := Color(0.78, 0.46, 0.32)
	var base := _mixc(a, b, _fbm(float(px) * 0.36, float(py) * 0.36, 219))
	# 偶发更深的陶土斑（铁矿染色），增加层次
	if _fbm(float(px) * 0.55 + 3.0, float(py) * 0.55, 220) > 0.74:
		base = _mixc(base, Color(0.58, 0.30, 0.22), 0.4)
	return _grain(base, px, py, 221, 0.6, 0.04)

# ---- 可建造光源（自发光，进桶1；transparent=true 与 MOONSTONE_LAMP 一致）----

func _t_sunstone(px: int, py: int) -> Color:
	# 暖光石：暖金石框镶嵌炽亮日华核心，中心近白热、向外转暖橙金，对角光带高光。
	# 与 MOONSTONE_LAMP 同构：实心满铺（无透明背景），靠亮色像素进 emissive 触发泛光。
	var border := px == 0 or px == 15 or py == 0 or py == 15
	if border:
		return Color(0.42, 0.28, 0.12, 0.97)           # 暖金石框
	if px == 1 or px == 14 or py == 1 or py == 14:
		return Color(0.56, 0.38, 0.16, 0.94)           # 框内描边
	# 中央发光核：径向亮度，核心白热 → 外缘暖橙
	var d := absf(float(px) - 7.5) + absf(float(py) - 7.5)
	var heat := clampf(1.0 - d / 12.0, 0.0, 1.0)
	heat = heat * heat                                  # 集中核心
	var col := _mixc(Color(1.0, 0.62, 0.20), Color(1.0, 0.95, 0.74), heat)
	# 对角棱镜光带（日石的光芒）
	if px == py or px + py == 15:
		col = _mixc(col, Color(1.0, 0.96, 0.80), 0.45)
	col = _grain(col, px, py, 222, 0.7, 0.05)
	col.a = 0.97
	return col

# ---- 赛博/科技方块（SP2）——霓虹自发光 + 铁轨 ----

func _t_neon(px: int, py: int, glow: Color) -> Color:
	# 通用霓虹画师：深灰/近黑底板 + 亮色网格线（十字 + 外框）。
	# 底板进 emissive 时发光很弱（暗底几乎不亮），网格线亮色进 emissive 后真正泛光 → 赛博味。
	var dark := Color(0.06, 0.06, 0.08)
	# 外框（最外一圈）：纯亮色，最强发光
	if px == 0 or px == 15 or py == 0 or py == 15:
		return glow
	# 内框描边（次亮）
	if px == 1 or px == 14 or py == 1 or py == 14:
		return _mixc(glow, dark, 0.35)
	# 中央十字网格线（px==7/8 或 py==7/8）：亮色
	if px == 7 or px == 8 or py == 7 or py == 8:
		# 交叉点最亮
		if (px == 7 or px == 8) and (py == 7 or py == 8):
			return _shade(glow, 0.08)
		return _mixc(glow, dark, 0.25)
	# 暗底板：极淡网格暗线（每4格一道微弱线），增加科技感
	var sub_grid := (px % 4 == 0) or (py % 4 == 0)
	if sub_grid:
		return _shade(dark, 0.04)
	# 纯暗底 + 极微噪点
	return _grain(dark, px, py, 230, 0.5, 0.02)

func _t_rail(px: int, py: int) -> Color:
	# 铁轨：深灰金属底板 + 两条平行亮轨（px=4,5 和 px=10,11）+ 横向枕木（每4行）。
	var base := Color(0.22, 0.22, 0.24)              # 深灰底（砾石路基）
	base = _grain(base, px, py, 240, 0.4, 0.08)      # 砾石颗粒感
	# 枕木：每4行一根，宽2..13（留边缘为路基）
	var is_tie := (py % 4 <= 1) and px >= 2 and px <= 13
	if is_tie:
		var tie_col := Color(0.36, 0.26, 0.16)       # 暗棕木枕
		tie_col = _grain(tie_col, px, py, 241, 0.5, 0.06)
		# 枕木上沿亮、下沿暗（浮雕）
		if py % 4 == 0: tie_col = _shade(tie_col, 0.04)
		else: tie_col = _shade(tie_col, -0.04)
		base = tie_col
	# 钢轨：两条亮银轨道（高光金属）
	var is_rail := (px == 4 or px == 5 or px == 10 or px == 11)
	if is_rail:
		var rail_col := Color(0.62, 0.65, 0.70)      # 冷亮钢轨
		# 轨道内侧（px=5,10）略暗 → 立体感
		if px == 5 or px == 10:
			rail_col = _shade(rail_col, -0.08)
		# 对角各向异性高光（模拟抛光钢轨反光）
		var diag := absf(float(px - py)) / 15.0
		rail_col = _shade(rail_col, (0.3 - diag) * 0.3)
		return _grain(rail_col, px, py, 242, 0.6, 0.03)
	return base
