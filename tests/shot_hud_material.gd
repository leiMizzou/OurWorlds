extends SceneTree
# 截一张 HUD 当前材料徽章和最近材料条：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_hud_material.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _main = null
var _f := 0
var _gen := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_hud_material/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen = true
		return false

	_f += 1
	if _f == 2:
		_main.set_palette_active(true)
		_main.block_palette._select_block(BlockLibrary.COPPER_ORE)
		var p = _main.player
		p.rotation.y = deg_to_rad(-20)
		p.spring.rotation.x = deg_to_rad(-12)
	elif _f >= 24:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_hud_material.png")
		print("SHOT saved: _shot_hud_material.png")
		return true
	return false
