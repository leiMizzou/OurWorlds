extends SceneTree
# 截一张创造模式材料库：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_block_palette.gd

var _main = null
var _f := 0

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_block_palette/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 16:
		_main.set_palette_active(true)
	elif _f >= 30:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_block_palette.png")
		_main.set_palette_active(false)
		print("SHOT saved: _shot_block_palette.png")
		return true
	return false
