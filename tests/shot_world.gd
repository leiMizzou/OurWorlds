extends SceneTree
# 渲染世界并截一张"宏大全景"PNG（需要渲染，别加 --headless）：
#   VC_RADIUS=5 godot --path <项目> --script res://tests/shot_world.gd
# 流程：加载主场景 -> 等 _ready 跑完 -> 同步铺满整片 -> 抬到山峰斜上方 -> 截图退出。

var _main = null
var _gen_done := false
var _sf := 0   # 铺满之后才开始数帧

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_world/settings.json")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	# 等 _ready 把 world 建好，再同步铺满整片（截图要完整全景）
	if not _gen_done:
		if _main != null and _main.world != null:
			_main.world.generate_initial(Vector2i(0, 0))
			_gen_done = true
		return false

	_sf += 1
	if _sf == 2:
		# 找最高的山峰，从斜上方望向它，让山体撑满画面 = 宏大
		var p = _main.player
		var best_h := -999
		var bx := 0
		var bz := 0
		for z in range(-75, 76, 5):
			for x in range(-75, 76, 5):
				var hh: int = _main.world.surface_y(x, z)
				if hh > best_h:
					best_h = hh
					bx = x
					bz = z
		var peak := Vector3(bx, best_h, bz)
		p.fly = true
		p.global_position = peak + Vector3(-30, 14, -30)
		p.spring.rotation.x = 0.0
		p.look_at(peak + Vector3(0, 2, 0), Vector3.UP)
		if OS.has_environment("VC_TIME"):
			_main._time = float(OS.get_environment("VC_TIME"))   # 指定时刻（看昼夜）
	if _sf >= 24:
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_world.png")
		print("SHOT saved: _shot_world.png  (", img.get_width(), "x", img.get_height(), ")")
		return true
	return false
