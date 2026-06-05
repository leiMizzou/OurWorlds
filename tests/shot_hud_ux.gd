extends SceneTree
# 截一张 HUD UX 自检图：新手控制提示淡入、准星活化（瞄准地形→青）、顶栏清爽、字阶统一。
#   godot --path <项目> --script res://tests/shot_hud_ux.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _main = null
var _f := 0
var _gen := false

func _initialize() -> void:
	OS.set_environment("VC_NO_SAVE", "1")
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_SETTINGS_PATH", "user://tests/shot_hud_ux/settings.json")
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
		var p = _main.player
		# 低头瞄准脚前的地面，让准星活化为"可放置=青"
		p.rotation.y = deg_to_rad(-18)
		p.spring.rotation.x = deg_to_rad(-42)
		p.pitch = deg_to_rad(-42)
	elif _f >= 40:
		# 跑够帧让控制提示淡入完成、准星更新到瞄准态
		var img := root.get_texture().get_image()
		img.save_png("res://_shot_hud_ux.png")
		print("SHOT saved: _shot_hud_ux.png")
		print("hint_alpha=", snappedf(_main.hud._control_hint_alpha, 0.01),
			"  hint_visible=", _main.hud._control_hint_panel.visible,
			"  has_target=", _main.player.has_target(),
			"  aim=", _main.player.aim_state(),
			"  cross_mod=", _main.hud._crosshair_center.modulate)
		return true
	return false
