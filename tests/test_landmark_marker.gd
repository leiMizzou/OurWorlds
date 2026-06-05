extends SceneTree
# 验证附近遗迹世界信标的显示、定位和隐藏：
#   godot --headless --path <项目> --script res://tests/test_landmark_marker.gd

const LandmarkMarker = preload("res://scripts/LandmarkMarker.gd")

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
	var marker := LandmarkMarker.new()
	root.add_child(marker)
	marker.setup()
	check(not marker.visible, "初始化后信标隐藏")
	check(marker.get_child_count() >= 5, "信标包含光柱和地面指示")
	check(marker.progress_tick_count() == 10, "信标包含十段修复进度刻度")

	var target := Vector3(12, 34, -5)
	marker.set_marker(target, true)
	check(marker.visible, "启用后信标显示")
	check(marker.position.distance_to(target + Vector3(0, 0.2, 0)) < 0.001, "信标定位到目标上方")
	marker._process(0.2)
	check(marker._beam.scale.y > 0.0, "信标脉动不会压扁光柱")

	marker.set_marker(target, true, "repair", 45)
	check(marker.marker_mode() == "repair", "修复目标使用修复信标模式")
	check(marker.marker_progress() == 45, "修复信标记录修复进度")
	check(marker.active_progress_ticks() == 5, "修复刻度按进度点亮")
	marker._process(0.2)
	check(marker._mat.albedo_color.g > marker._mat.albedo_color.r, "修复信标偏向绿色")
	check(marker._progress_ticks[0].visible, "修复模式显示进度刻度")
	check(marker._progress_tick_mats[0].albedo_color.a > marker._progress_tick_mats[6].albedo_color.a, "已点亮刻度比未点亮刻度更醒目")

	marker.set_marker(target, true, "repair", 100)
	check(marker.active_progress_ticks() == marker.progress_tick_count(), "满修复点亮全部刻度")
	marker.set_marker(target, true, "complete", 35)
	check(marker.marker_mode() == "complete", "完成遗迹使用完成信标模式")
	check(marker.marker_progress() == 100, "完成信标强制记录满进度")
	check(marker.active_progress_ticks() == marker.progress_tick_count(), "完成信标保持全部刻度点亮")
	marker._process(0.2)
	check(marker._mat.albedo_color.b > 0.6 and marker._mat.albedo_color.r > 0.5, "完成信标使用金蓝色调")
	marker.set_marker(target, true, "hint")
	check(marker.marker_mode() == "hint", "普通线索信标保持线索模式")
	check(not marker._progress_ticks[0].visible, "线索模式隐藏修复刻度")

	marker.set_marker(Vector3.ZERO, false)
	check(not marker.visible, "关闭后信标隐藏")
	marker.free()

	if failed == 0:
		print("✅ ALL LANDMARK MARKER TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个遗迹信标测试失败")
	quit(failed)
