extends SceneTree
# 俯瞰主题岛截图（需渲染，勿加 --headless）：
#   VC_SEED=2026 godot --path . --script res://tests/shot_island.gd
const World = preload("res://scripts/World.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

func _initialize() -> void:
	var lib := BlockLibrary.new()
	var w := World.new()
	root.add_child(w)
	w.setup(lib, 2026, "", "themed_island")
	w.set_view_radius(6)
	w.prime(Vector2i(0, 0), 16)          # 覆盖整座 512 格岛（±16 区块）
	# 天空 + 太阳，让裸 World 也能被照亮
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky.sky_material = ProceduralSkyMaterial.new()
	e.sky = sky
	env.environment = e
	root.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -45, 0)
	root.add_child(sun)
	# 等距俯瞰（用 Transform3D.looking_at 纯数学定向，避免 look_at 需在树内的限制）
	var cam := Camera3D.new()
	var cam_pos := Vector3(240, 210, 240)
	cam.transform = Transform3D(Basis(), cam_pos).looking_at(Vector3(0, 42, 0), Vector3.UP)
	cam.current = true
	root.add_child(cam)
	await create_timer(10.0).timeout    # 等后台造网格
	var img := root.get_viewport().get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path("res://_shot_island.png"))
	print("PLAY OK: wrote _shot_island.png")
	quit(0)
