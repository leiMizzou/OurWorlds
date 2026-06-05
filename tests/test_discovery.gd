extends SceneTree
# 验证探索发现：靠近生成遗迹时只触发一次，普通放置灯笼不误判。
#   godot --headless --path <项目> --script res://tests/test_discovery.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const DiscoveryTracker = preload("res://scripts/DiscoveryTracker.gd")
const World = preload("res://scripts/World.gd")

var failed := 0
var _feedback := []
var _landmarks := []
var _hints := []
var _directions := []

func _process(_delta: float) -> bool:
	return true

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _on_feedback(kind: String, label: String) -> void:
	_feedback.append({"kind": kind, "label": label})

func _on_landmark(pos: Vector3i, label: String) -> void:
	_landmarks.append({"pos": pos, "label": label})

func _on_hint(distance: int, direction: String) -> void:
	_hints.append(distance)
	_directions.append(direction)

func _initialize() -> void:
	var lib := BlockLibrary.new()
	var world := World.new()
	root.add_child(world)
	world.setup(lib, 1337, "")
	world.set_view_radius(6)
	world.generate_initial(Vector2i(0, 0))

	var target := Node3D.new()
	root.add_child(target)
	target.position = Vector3.ZERO

	var tracker := DiscoveryTracker.new()
	root.add_child(tracker)
	tracker.setup(world, target)
	tracker.discovery_feedback.connect(_on_feedback)
	tracker.landmark_discovered.connect(_on_landmark)
	tracker.nearby_hint_changed.connect(_on_hint)

	var landmarks := _recognized_landmarks(world, tracker)
	check(not landmarks.is_empty(), "测试世界内存在可发现遗迹")
	var landmark: Vector3i = landmarks[0] if not landmarks.is_empty() else Vector3i.ZERO

	var hint_pos := _find_safe_hint_position(landmarks)
	check(hint_pos.y > -900.0, "找到不会误触发发现的提示测试点")
	target.position = hint_pos
	check(tracker.scan_now() == 0, "提示范围内但发现范围外不会直接发现")
	check(tracker.nearby_hint_distance() > DiscoveryTracker.DISCOVERY_RADIUS, "记录最近未发现遗迹距离")
	check(tracker.nearby_hint_direction() != "", "记录最近未发现遗迹方向")
	check(tracker.nearby_hint_position() != Vector3.ZERO, "记录最近未发现遗迹世界位置")
	check(not _hints.is_empty() and int(_hints[_hints.size() - 1]) > DiscoveryTracker.DISCOVERY_RADIUS, "附近遗迹提示发出距离")
	check(not _directions.is_empty() and str(_directions[_directions.size() - 1]) != "", "附近遗迹提示发出方向")

	target.position = Vector3(landmark) + Vector3(0.5, 0.5, 0.5)
	check(tracker.scan_now() == 1, "靠近遗迹触发一次发现")
	check(tracker.discovered_count() == 1, "发现计数为 1")
	check(not _feedback.is_empty() and str(_feedback[0].get("kind", "")) == "discover", "发现发出 HUD/音效反馈")
	check(_valid_discovery_label(str(_feedback[0].get("label", ""))), "发现反馈包含具名地标")
	check(tracker._landmark_label(landmark) == str(_feedback[0].get("label", "")), "地标名称由位置稳定生成")
	check(not _landmarks.is_empty() and Vector3i(_landmarks[0].get("pos", Vector3i.ZERO)) == landmark, "发现信号包含遗迹位置")
	check(not _landmarks.is_empty() and str(_landmarks[0].get("label", "")) == str(_feedback[0].get("label", "")), "发现信号和反馈标签一致")
	check(tracker.nearby_hint_distance() == -1 or tracker.nearby_hint_distance() > DiscoveryTracker.DISCOVERY_RADIUS, "发现后不继续提示已发现遗迹")

	var feedback_count := _feedback.size()
	check(tracker.scan_now() == 0, "重复扫描不会重复触发同一遗迹")
	check(_feedback.size() == feedback_count, "重复扫描不重复发反馈")
	var entries := tracker.discovered_entries()
	check(not entries.is_empty() and int((entries[0] as Dictionary).get("restore_percent", -1)) == 0, "新发现遗迹初始修复度为 0")
	check(not entries.is_empty() and str((entries[0] as Dictionary).get("type", "")) != "", "遗迹记录包含类型档案")
	check(not entries.is_empty() and str((entries[0] as Dictionary).get("guardian", "")) != "", "遗迹记录包含守护物档案")
	check(not entries.is_empty() and str((entries[0] as Dictionary).get("archive", "")).contains("守护物"), "遗迹记录包含可读档案短句")
	_raise_repair_to(world, landmark, 5)
	entries = tracker.discovered_entries()
	var repaired: Dictionary = entries[0] if not entries.is_empty() else {}
	check(int(repaired.get("restore_count", 0)) >= 5, "遗迹周围改造计入修复点数")
	check(int(repaired.get("restore_percent", 0)) > 0 and int(repaired.get("restore_percent", 0)) < 100, "少量改造显示部分修复")
	check(str(repaired.get("restore_label", "")) == "修复中", "部分修复显示修复中状态")
	check(not bool(repaired.get("restore_complete", true)), "部分修复未完成")
	_raise_repair_to(world, landmark, World.LANDMARK_RESTORE_TARGET)
	entries = tracker.discovered_entries()
	repaired = entries[0] if not entries.is_empty() else {}
	check(int(repaired.get("restore_percent", 0)) == 100, "达到目标后遗迹修复度满")
	check(str(repaired.get("restore_label", "")) == "修复完成", "满修复显示完成状态")
	check(bool(repaired.get("restore_complete", false)), "满修复标记完成")
	check(str(repaired.get("archive", "")).contains("重新照亮"), "满修复后档案短句反映遗迹已被点亮")

	var tracker2 := DiscoveryTracker.new()
	root.add_child(tracker2)
	tracker2.setup(world, target)
	tracker2.discovery_feedback.connect(_on_feedback)
	check(tracker2.discovered_count() == 1, "新的发现追踪器从世界恢复发现记录")
	feedback_count = _feedback.size()
	check(tracker2.scan_now() == 0, "恢复后的发现追踪器不重复发现")
	check(_feedback.size() == feedback_count, "恢复后的发现追踪器不重复发反馈")
	tracker2.free()

	var placed := landmark + Vector3i(20, 0, 0)
	world.set_block(placed.x, placed.y - 1, placed.z, BlockLibrary.MARBLE)
	world.set_block(placed.x, placed.y, placed.z, BlockLibrary.LANTERN)
	tracker._chunk_cache.clear()
	target.position = Vector3(placed) + Vector3(0.5, 0.5, 0.5)
	check(tracker.scan_now() == 0, "普通灯笼加基座不会误判为遗迹")

	tracker.free()
	target.free()
	world.free()

	if failed == 0:
		print("✅ ALL DISCOVERY TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个发现系统测试失败")
	quit(failed)

func _recognized_landmarks(world, tracker: DiscoveryTracker) -> Array:
	var out := []
	for cc in world._chunks.keys():
		out.append_array(tracker._landmarks_for_chunk(cc))
	return out

func _find_safe_hint_position(landmarks: Array) -> Vector3:
	var offsets := [
		Vector3(24, 0, 0), Vector3(-24, 0, 0), Vector3(0, 0, 24), Vector3(0, 0, -24),
		Vector3(32, 0, 0), Vector3(-32, 0, 0), Vector3(0, 0, 32), Vector3(0, 0, -32),
		Vector3(28, 0, 18), Vector3(-28, 0, -18), Vector3(18, 0, -28), Vector3(-18, 0, 28),
	]
	for lm in landmarks:
		var landmark: Vector3i = lm
		var center := Vector3(landmark) + Vector3(0.5, 0.5, 0.5)
		for offset in offsets:
			var candidate: Vector3 = center + offset
			if _is_hint_only(candidate, landmarks):
				return candidate
	return Vector3(0, -999, 0)

func _is_hint_only(candidate: Vector3, landmarks: Array) -> bool:
	var nearest := INF
	for lm in landmarks:
		var landmark: Vector3i = lm
		var d := candidate.distance_to(Vector3(landmark) + Vector3(0.5, 0.5, 0.5))
		if d <= DiscoveryTracker.DISCOVERY_RADIUS:
			return false
		nearest = minf(nearest, d)
	return nearest <= DiscoveryTracker.HINT_RADIUS

func _raise_repair_to(world, landmark: Vector3i, target_count: int) -> void:
	for dy in range(1, 5):
		for dz in range(-6, 7):
			for dx in range(-6, 7):
				if dx == 0 and dz == 0:
					continue
				var before := int(world.edited_blocks_near(landmark))
				if before >= target_count:
					return
				world.set_block(landmark.x + dx, landmark.y + dy, landmark.z + dz, BlockLibrary.MOONSTONE_LAMP)
				if int(world.edited_blocks_near(landmark)) >= target_count:
					return

func _valid_discovery_label(label: String) -> bool:
	return label.begins_with("发现") and (
		label.ends_with("古遗迹") or label.ends_with("石环") or label.ends_with("守望高塔")
	) and label.length() > "发现石环".length()
