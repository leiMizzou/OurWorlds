extends SceneTree
# 截一张暂停/设置菜单，验证发布向 UI：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_pause_menu.gd

var _main = null
var _f := 0

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_pause/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 6:
		_main.set_game_paused(true)
	elif _f >= 18:
		if DisplayServer.get_name() == "headless":
			printerr("SHOT skipped: headless 渲染驱动无法读取 viewport 纹理")
			return true
		var texture := root.get_texture()
		if texture == null:
			printerr("SHOT skipped: 当前渲染驱动无法读取 viewport 纹理")
			return true
		var img := texture.get_image()
		if img == null:
			printerr("SHOT skipped: 当前渲染驱动没有生成图像")
			return true
		img.save_png("res://_shot_pause_menu.png")
		_main.set_game_paused(false)
		print("SHOT saved: _shot_pause_menu.png")
		return true
	return false
