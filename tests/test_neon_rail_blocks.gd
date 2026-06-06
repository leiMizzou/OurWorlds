extends SceneTree
# SP2 TDD：霓虹发光方块(青/品红/绿) + 铁轨方块——定义/LUT/图集/材料库/agent 契约。
#   godot --headless --path . --script res://tests/test_neon_rail_blocks.gd
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const AgentBridge  = preload("res://scripts/AgentBridge.gd")
var failed := 0

func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	var lib := BlockLibrary.new()

	# ---- 1) 四个新块都有定义 ----
	check(lib.has_def(BlockLibrary.NEON_CYAN),    "NEON_CYAN has def")
	check(lib.has_def(BlockLibrary.NEON_MAGENTA), "NEON_MAGENTA has def")
	check(lib.has_def(BlockLibrary.NEON_LIME),    "NEON_LIME has def")
	check(lib.has_def(BlockLibrary.RAIL),         "RAIL has def")

	# ---- 2) 名称正确 ----
	check(lib.block_name(BlockLibrary.NEON_CYAN) == "霓虹青",       "NEON_CYAN name")
	check(lib.block_name(BlockLibrary.NEON_MAGENTA) == "霓虹品红",  "NEON_MAGENTA name")
	check(lib.block_name(BlockLibrary.NEON_LIME) == "霓虹绿",       "NEON_LIME name")
	check(lib.block_name(BlockLibrary.RAIL) == "铁轨",              "RAIL name")

	# ---- 3) 发光桶：三个霓虹=1(emissive)，铁轨=0(matte) ----
	check(lib.mat_bucket_lut[BlockLibrary.NEON_CYAN] == 1,    "NEON_CYAN emissive bucket")
	check(lib.mat_bucket_lut[BlockLibrary.NEON_MAGENTA] == 1, "NEON_MAGENTA emissive bucket")
	check(lib.mat_bucket_lut[BlockLibrary.NEON_LIME] == 1,    "NEON_LIME emissive bucket")
	check(lib.mat_bucket_lut[BlockLibrary.RAIL] == 0,         "RAIL matte bucket")

	# ---- 4) solid/tile LUT ----
	check(lib.solid_lut[BlockLibrary.NEON_CYAN] == 1,  "NEON_CYAN solid")
	check(lib.solid_lut[BlockLibrary.RAIL] == 1,       "RAIL solid")
	check(lib.tile_top_lut[BlockLibrary.RAIL] == BlockLibrary.T_RAIL, "RAIL tile_top == T_RAIL")
	check(lib.tile_top_lut[BlockLibrary.NEON_CYAN] == BlockLibrary.T_NEON_CYAN, "NEON_CYAN tile_top")

	# ---- 5) 材料库包含新块 ----
	var cblocks := lib.creative_blocks()
	check(cblocks.has(BlockLibrary.NEON_CYAN),    "creative_blocks has NEON_CYAN")
	check(cblocks.has(BlockLibrary.NEON_MAGENTA), "creative_blocks has NEON_MAGENTA")
	check(cblocks.has(BlockLibrary.NEON_LIME),    "creative_blocks has NEON_LIME")
	check(cblocks.has(BlockLibrary.RAIL),         "creative_blocks has RAIL")

	# ---- 6) 分类中有"科技"类别 ----
	var found_tech := false
	for cat in lib.creative_categories():
		if String(cat["id"]) == "tech":
			found_tech = true
			var blist: Array = cat["blocks"]
			check(blist.has(BlockLibrary.NEON_CYAN), "tech category has NEON_CYAN")
			check(blist.has(BlockLibrary.RAIL),      "tech category has RAIL")
	check(found_tech, "creative_categories has 'tech'")

	# ---- 7) Atlas 构建没崩（能 new 出来已证明 _tile_color 覆盖了新 tile，无越界） ----
	check(lib.atlas != null, "atlas built successfully")

	# ---- 8) Agent BLOCK_ALIASES 包含新块 ----
	check(AgentBridge.BLOCK_ALIASES.has(35), "BLOCK_ALIASES has 35")
	check(AgentBridge.BLOCK_ALIASES.has(36), "BLOCK_ALIASES has 36")
	check(AgentBridge.BLOCK_ALIASES.has(37), "BLOCK_ALIASES has 37")
	check(AgentBridge.BLOCK_ALIASES.has(38), "BLOCK_ALIASES has 38")
	check(str(AgentBridge.BLOCK_ALIASES[35]) == "neon_cyan",    "alias 35=neon_cyan")
	check(str(AgentBridge.BLOCK_ALIASES[38]) == "rail",         "alias 38=rail")

	if failed == 0: print("✅ ALL NEON/RAIL BLOCK TESTS PASSED")
	else: printerr("❌ ", failed, " 个霓虹/铁轨方块测试失败")
	quit(0 if failed == 0 else 1)
