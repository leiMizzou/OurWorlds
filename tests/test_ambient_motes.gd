extends SceneTree
# 验证环境微光：夜晚更明显，雨天削弱，并跟随目标位置。
#   godot --headless --path <项目> --script res://tests/test_ambient_motes.gd

const AmbientMotes = preload("res://scripts/AmbientMotes.gd")

var failed := 0

func _process(_delta: float) -> bool:
	return true

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	var target := Node3D.new()
	target.position = Vector3(12, 34, -7)
	root.add_child(target)

	var motes := AmbientMotes.new()
	root.add_child(motes)
	motes.setup(target, 2468)

	motes.set_atmosphere(1.0, 0.0)
	motes._process(0.25)
	var day_count := motes.visible_mote_count()
	var day_alpha: float = motes._mat.albedo_color.a
	check(day_count > 0, "晴朗白天有少量微光")
	check(motes._motes.visible, "有微光时节点可见")

	motes.set_atmosphere(0.0, 0.0)
	motes._process(0.25)
	var night_count := motes.visible_mote_count()
	var night_alpha: float = motes._mat.albedo_color.a
	var grass_night_color: Color = motes._mat.albedo_color
	check(night_count > day_count, "晴朗夜晚微光更多")
	check(night_alpha > day_alpha, "晴朗夜晚微光更亮")

	motes.set_region_label("湿地")
	motes._process(0.25)
	var wet_count := motes.visible_mote_count()
	var wet_color: Color = motes._mat.albedo_color
	check(motes.current_region_label() == "湿地", "环境微光记录当前区域标签")
	check(wet_count > night_count, "湿地区域微光更密")
	check(wet_color.g > grass_night_color.g and wet_color.b > grass_night_color.b, "湿地区域微光偏青绿")

	motes.set_region_label("针叶林")
	motes._process(0.25)
	var pine_count := motes.visible_mote_count()
	var pine_color: Color = motes._mat.albedo_color
	check(pine_count > night_count, "针叶林区域微光更密")
	check(pine_color.g > grass_night_color.g and pine_color.r < grass_night_color.r, "针叶林区域微光偏森林绿")

	motes.set_region_label("苔林")
	motes._process(0.25)
	check(motes.visible_mote_count() >= pine_count - 1, "苔林区域沿用森林微光密度")
	check(motes.current_theme_color().g > motes.current_theme_color().r, "苔林主题色偏绿")

	motes.set_region_label("雪峰")
	motes._process(0.25)
	check(motes.visible_mote_count() < wet_count, "雪峰区域微光更稀疏")
	check(motes.current_theme_color().b > motes.current_theme_color().r, "雪峰主题色偏冷")

	var target_delta := Vector3(20, 5, 11)
	var before_origin := motes.first_mote_origin()
	target.position += target_delta
	motes._process(0.25)
	var after_origin := motes.first_mote_origin()
	check(after_origin.distance_to(before_origin + target_delta) < 8.0, "微光会跟随目标附近刷新")

	motes.set_atmosphere(0.0, 1.0)
	motes._process(0.25)
	check(motes.visible_mote_count() < night_count, "雨天压低微光数量")
	check(motes._mat.albedo_color.a < night_alpha, "雨天压低微光亮度")

	motes.free()
	target.free()

	if failed == 0:
		print("✅ ALL AMBIENT MOTE TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个环境微光测试失败")
	quit(failed)
