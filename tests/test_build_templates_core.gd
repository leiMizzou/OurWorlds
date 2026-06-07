extends SceneTree
const BuildTemplates = preload("res://scripts/BuildTemplates.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
var failed := 0
func check(c: bool, m: String) -> void:
	if c: print("  ok   ", m)
	else: failed += 1; printerr("  FAIL ", m)

func _initialize() -> void:
	# Simple template uses the default block id for every cell.
	var plat: Array = BuildTemplates.edits_for("platform", Vector3i(0, 40, 0), 0, BlockLibrary.STONE)
	check(plat.size() > 0, "platform returns cells")
	check((plat[0] as Dictionary).has("pos") and (plat[0] as Dictionary).has("id"), "edit has pos+id")
	var all_stone := true
	for raw in plat:
		if int((raw as Dictionary)["id"]) != BlockLibrary.STONE: all_stone = false
	check(all_stone, "simple template uses default_block_id")

	# Decorated template carries its own ids; campfire centre is the moonstone lamp.
	var fire: Array = BuildTemplates.edits_for("campfire", Vector3i(0, 40, 0), 0, BlockLibrary.STONE)
	var centre_is_lamp := false
	for raw in fire:
		var e: Dictionary = raw
		if e["pos"] == Vector3i(0, 40, 0) and int(e["id"]) == BlockLibrary.MOONSTONE_LAMP:
			centre_is_lamp = true
	check(centre_is_lamp, "campfire centre == moonstone lamp")

	# Unknown template -> empty.
	check(BuildTemplates.edits_for("nope", Vector3i.ZERO, 0, BlockLibrary.STONE).is_empty(), "unknown template -> []")

	# orientation=1 (south-north) axis swap on a simple template
	var arch1: Array = BuildTemplates.edits_for("arch", Vector3i(0, 0, 0), 1, BlockLibrary.STONE)
	check(arch1.size() == 13, "arch orientation=1 cell count == 13")
	# pillar is a simple 5-cell column
	check(BuildTemplates.edits_for("pillar", Vector3i.ZERO, 0, BlockLibrary.STONE).size() == 5, "pillar == 5 cells")

	if failed == 0: print("✅ ALL BUILD TEMPLATES CORE TESTS PASSED")
	else: printerr("❌ ", failed, " build-template-core failures")
	quit(0 if failed == 0 else 1)
