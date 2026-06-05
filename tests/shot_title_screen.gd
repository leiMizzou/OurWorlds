extends SceneTree
# 截一张首屏标题入口，验证第一印象：
#   VC_RADIUS=3 godot --path <项目> --script res://tests/shot_title_screen.gd

var _main = null
var _f := 0
var _shot_done := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.unset_environment("VC_SKIP_TITLE")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_title/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_f += 1
	if not _shot_done and _f >= 20:
		if DisplayServer.get_name().to_lower().contains("headless"):
			print("SHOT skipped: viewport texture unavailable in headless")
			_main.set_title_active(false)
			_shot_done = true
			return true
		var texture := root.get_texture()
		if texture == null:
			print("SHOT skipped: viewport texture unavailable")
			_main.set_title_active(false)
			_shot_done = true
			return true
		var img := texture.get_image()
		if img == null or img.is_empty():
			print("SHOT skipped: viewport image unavailable")
			_main.set_title_active(false)
			_shot_done = true
			return true
		img.save_png("res://_shot_title_screen.png")
		print("SHOT saved: _shot_title_screen.png")
		_main.set_title_active(false)
		_shot_done = true
	elif _shot_done and _f >= 80:
		return true
	return false
