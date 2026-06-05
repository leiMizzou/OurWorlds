extends SceneTree
# 验证"真正进游戏"的代码路径不崩（无需画面，headless 跑）：
#   godot --headless --script res://tests/test_play.gd
# 加载主场景 -> 脚下生成 -> 玩家下落踩地 -> 移动触发流式 -> 挖一个方块 -> 检查。

var _f := 0
var _main = null

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.set_environment("VC_NO_SAVE", "1")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/play/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 40:
		_main.player.global_position += Vector3(20, 0, 0)   # 走开一段，触发流式加载
	elif _f == 70:
		# 挖掉玩家脚下那格，验证 set_block + 重建网格不崩
		var p = _main.player.global_position
		_main.world.set_block(int(floor(p.x)), int(floor(p.y)) - 1, int(floor(p.z)), 0)
	elif _f >= 110:
		var chunks: int = _main.world._nodes.size()
		var py: float = _main.player.global_position.y
		print("PLAY OK  frames=", _f, "  已加载区块=", chunks, "  玩家y=", snappedf(py, 0.1))
		if chunks > 0 and py > -20.0:
			print("✅ 进游戏路径正常（有地形、玩家踩在地上没穿模坠落）")
		else:
			printerr("❌ 异常：chunks=", chunks, " player_y=", py)
		return true
	return false
