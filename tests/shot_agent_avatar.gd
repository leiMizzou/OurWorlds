extends SceneTree
# 给 opc-ourworlds 的专属小人拍个特写。
#   godot --path <项目> --script res://tests/shot_agent_avatar.gd
var _main = null
var _gen := false
var _f := 0

func _initialize() -> void:
	OS.set_environment("OW_AGENT_PORT", "8972")   # 触发 avatar 创建(空闲端口)
	OS.set_environment("VC_SKIP_TITLE", "1")
	OS.set_environment("VC_NO_SAVE", "1")
	_main = load("res://scenes/Main.tscn").instantiate()
	root.add_child(_main)

func _process(_d: float) -> bool:
	if not _gen:
		if _main != null and _main.world != null:
			_main.world.generate_initial(_main.world.chunk_of(50, 50))
			_gen = true
		return false
	_f += 1
	if _f == 3:
		var bridge = _main.get_node_or_null("AgentBridge")
		var av = bridge.avatar if bridge != null else null
		var p = _main.player
		var h: int = _main.world.surface_y(50, 50)
		print("avatar found=", av != null, " bridge=", bridge != null)
		if av != null:
			av.global_position = Vector3(50, h, 50)
			print("avatar pos set to ", av.global_position)
		p.fly = true
		p.spring.rotation.x = 0.0
		p.global_position = Vector3(50, h + 1.6, 55.5)
		p.look_at(Vector3(50, h + 1.1, 50), Vector3.UP)
	if _f == 12:
		var bridge2 = _main.get_node_or_null("AgentBridge")
		if bridge2 != null and bridge2.avatar != null:
			bridge2.avatar.note_build()   # 截图前闪一下
	if _f >= 14:
		root.get_texture().get_image().save_png("res://_shot_agent_avatar.png")
		print("SHOT saved _shot_agent_avatar.png")
		return true
	return false
