extends Control
# 世界地图绘制层：把玩家、出生点、遗迹和线索投影到一个俯视地图里。

var _data := {}

func _ready() -> void:
	custom_minimum_size = Vector2(0, 330)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	clip_contents = true
	queue_redraw()

func set_map_data(data: Dictionary) -> void:
	_data = data.duplicate(true)
	queue_redraw()

func landmark_count() -> int:
	var raw: Variant = _data.get("landmarks", [])
	return (raw as Array).size() if typeof(raw) == TYPE_ARRAY else 0

func restored_count() -> int:
	var count := 0
	var raw: Variant = _data.get("landmarks", [])
	if typeof(raw) == TYPE_ARRAY:
		for item in raw:
			var entry: Dictionary = item
			if bool(entry.get("restore_complete", false)) or int(entry.get("restore_percent", 0)) >= 100:
				count += 1
	return count

func best_restoration_percent() -> int:
	var best := 0
	var raw: Variant = _data.get("landmarks", [])
	if typeof(raw) == TYPE_ARRAY:
		for item in raw:
			var entry: Dictionary = item
			best = max(best, int(entry.get("restore_percent", 0)))
	return clampi(best, 0, 100)

func has_nearby_hint() -> bool:
	return bool(_data.get("nearby_valid", false))

func has_restoration_target() -> bool:
	return not _target_data().is_empty()

func restoration_target_label() -> String:
	return String(_target_data().get("label", ""))

func restoration_target_distance() -> int:
	return int(_target_data().get("distance", 0))

func map_radius() -> float:
	return _map_radius()

func region_sample_count() -> int:
	var raw: Variant = _data.get("region_samples", [])
	return (raw as Array).size() if typeof(raw) == TYPE_ARRAY else 0

func sampled_region_count() -> int:
	var labels := {}
	var raw: Variant = _data.get("region_samples", [])
	if typeof(raw) == TYPE_ARRAY:
		for item in raw:
			var entry: Dictionary = item
			var label := String(entry.get("region", ""))
			if label != "":
				labels[label] = true
	return labels.size()

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if r.size.x < 32.0 or r.size.y < 32.0:
		return
	_draw_background(r)
	_draw_region_layer(r)
	_draw_range_rings(r)
	_draw_grid(r)
	_draw_home_route(r)
	_draw_restoration_route(r)
	_draw_landmarks(r)
	_draw_nearby_hint(r)
	_draw_player(r)
	_draw_compass_marks(r)
	_draw_frame(r)

func _draw_background(r: Rect2) -> void:
	draw_rect(r, Color(0.030, 0.045, 0.050, 0.98))
	for i in range(8):
		var t0 := float(i) / 8.0
		var band := Rect2(Vector2(0, r.size.y * t0), Vector2(r.size.x, r.size.y / 8.0 + 1.0))
		var c := Color(0.055, 0.075, 0.072, 0.76).lerp(Color(0.032, 0.050, 0.064, 0.88), t0)
		draw_rect(band, c)
	var seed := int(_data.get("seed", 1337))
	for i in range(7):
		var y := lerpf(r.size.y * 0.16, r.size.y * 0.88, _unit(seed, i * 7 + 3))
		var amp := 8.0 + _unit(seed, i * 11 + 5) * 24.0
		var points := PackedVector2Array()
		var steps := 10
		for s in range(steps + 1):
			var x := r.size.x * float(s) / float(steps)
			points.append(Vector2(x, y + sin(float(s) * 0.85 + float(i)) * amp))
		draw_polyline(points, Color(0.76, 0.92, 0.82, 0.06), 2.0)

func _draw_region_layer(r: Rect2) -> void:
	var raw: Variant = _data.get("region_samples", [])
	if typeof(raw) != TYPE_ARRAY:
		return
	var entries: Array = raw
	if entries.is_empty():
		return
	var radius := _map_radius()
	var scale := minf(r.size.x, r.size.y) * 0.46 / radius
	for item in entries:
		var entry: Dictionary = item
		var pos := _vec3(entry.get("world_pos", Vector3.ZERO))
		var label := String(entry.get("region", ""))
		var step := maxf(8.0, float(entry.get("step", 32)) * scale * 0.94)
		var p := _world_to_map(pos, r)
		var tile := Rect2(p - Vector2(step, step) * 0.5, Vector2(step, step))
		draw_rect(tile, _region_color(label))

func _draw_grid(r: Rect2) -> void:
	var center := r.size * 0.5
	for i in range(-4, 5):
		var t := float(i) / 4.0
		var x := center.x + t * r.size.x * 0.46
		var y := center.y + t * r.size.y * 0.46
		var major := i == 0
		var c := Color(1, 1, 1, 0.16) if major else Color(1, 1, 1, 0.055)
		draw_line(Vector2(x, 0), Vector2(x, r.size.y), c, 1.0)
		draw_line(Vector2(0, y), Vector2(r.size.x, y), c, 1.0)

func _draw_range_rings(r: Rect2) -> void:
	var center := r.size * 0.5
	var max_radius := minf(r.size.x, r.size.y) * 0.46
	for i in range(1, 4):
		var radius := max_radius * float(i) / 3.0
		var alpha := 0.055 + 0.025 * float(i)
		draw_arc(center, radius, 0.0, TAU, 80, Color(0.78, 0.92, 1.0, alpha), 1.1)
		draw_line(center + Vector2(radius, -5), center + Vector2(radius, 5), Color(0.78, 0.92, 1.0, alpha + 0.03), 1.0)
		draw_line(center + Vector2(-radius, -5), center + Vector2(-radius, 5), Color(0.78, 0.92, 1.0, alpha + 0.03), 1.0)
		draw_line(center + Vector2(-5, radius), center + Vector2(5, radius), Color(0.78, 0.92, 1.0, alpha + 0.03), 1.0)
		draw_line(center + Vector2(-5, -radius), center + Vector2(5, -radius), Color(0.78, 0.92, 1.0, alpha + 0.03), 1.0)

func _draw_home_route(r: Rect2) -> void:
	var player_pos := _vec3(_data.get("player_pos", Vector3.ZERO))
	var home_pos := _vec3(_data.get("home_pos", Vector3.ZERO))
	var p := _world_to_map(player_pos, r)
	var h := _world_to_map(home_pos, r)
	draw_line(p, h, Color(0.50, 0.92, 1.0, 0.36), 2.0)
	_draw_diamond(h, 8.0, Color(0.44, 0.92, 1.0, 0.92), Color(0.05, 0.16, 0.20, 0.95))

func _draw_restoration_route(r: Rect2) -> void:
	var target := _target_data()
	if target.is_empty():
		return
	var player_pos := _vec3(_data.get("player_pos", Vector3.ZERO))
	var target_pos := _vec3(target.get("world_pos", Vector3.ZERO))
	var p := _world_to_map(player_pos, r)
	var t := _world_to_map(target_pos, r)
	draw_line(p, t, Color(1.0, 0.78, 0.24, 0.42), 2.6)
	draw_arc(t, 20.0, 0.0, TAU, 36, Color(1.0, 0.82, 0.28, 0.74), 2.0)
	draw_arc(t, 24.0, 0.0, TAU, 36, Color(1.0, 0.82, 0.28, 0.20), 2.0)

func _draw_landmarks(r: Rect2) -> void:
	var raw: Variant = _data.get("landmarks", [])
	if typeof(raw) != TYPE_ARRAY:
		return
	var entries: Array = raw
	var target_key := String(_target_data().get("key", ""))
	for i in range(entries.size()):
		var entry: Dictionary = entries[i]
		var pos := _landmark_pos(entry)
		var p := _world_to_map(pos, r)
		var restore := clampf(float(int(entry.get("restore_percent", 0))) / 100.0, 0.0, 1.0)
		var fill := Color(1.0, 0.82, 0.30, 0.94).lerp(Color(0.62, 1.0, 0.76, 0.96), restore)
		var glow := Color(fill.r, fill.g, fill.b, lerpf(0.16, 0.28, restore))
		var focused := target_key != "" and String(entry.get("key", "")) == target_key
		draw_circle(p, lerpf(8.0, 14.0, restore), glow)
		if focused:
			draw_circle(p, 18.0, Color(1.0, 0.78, 0.24, 0.16))
		if restore >= 1.0:
			draw_arc(p, 15.0, 0.0, TAU, 32, Color(0.68, 1.0, 0.78, 0.82), 2.0)
		draw_rect(Rect2(p - Vector2(4, 4), Vector2(8, 8)), fill)
		draw_rect(Rect2(p - Vector2(4, 4), Vector2(8, 8)), Color(0.14, 0.10, 0.04, 0.90), false, 1.0)

func _draw_nearby_hint(r: Rect2) -> void:
	if not has_nearby_hint():
		return
	var pos := _vec3(_data.get("nearby_position", Vector3.ZERO))
	var p := _world_to_map(pos, r)
	draw_circle(p, 15.0, Color(0.64, 1.0, 0.56, 0.13))
	draw_arc(p, 14.0, 0.0, TAU, 32, Color(0.72, 1.0, 0.66, 0.78), 2.0)
	draw_circle(p, 3.5, Color(0.78, 1.0, 0.66, 0.92))

func _draw_player(r: Rect2) -> void:
	var pos := _world_to_map(_vec3(_data.get("player_pos", Vector3.ZERO)), r)
	var forward3 := _vec3(_data.get("player_forward", Vector3(0, 0, -1)))
	var dir := Vector2(forward3.x, -forward3.z)
	if dir.length_squared() < 0.001:
		dir = Vector2(0, -1)
	else:
		dir = dir.normalized()
	var right := Vector2(-dir.y, dir.x)
	var points := PackedVector2Array([
		pos + dir * 14.0,
		pos - dir * 8.0 + right * 7.0,
		pos - dir * 4.0,
		pos - dir * 8.0 - right * 7.0,
	])
	draw_colored_polygon(points, Color(0.96, 0.98, 1.0, 0.98))
	draw_polyline(points + PackedVector2Array([points[0]]), Color(0.04, 0.06, 0.08, 0.92), 1.4)

func _draw_compass_marks(r: Rect2) -> void:
	var center := r.size * 0.5
	var edge := minf(r.size.x, r.size.y) * 0.46
	var color := Color(0.82, 0.94, 1.0, 0.34)
	var strong := Color(0.92, 0.98, 1.0, 0.58)
	_draw_compass_tick(center + Vector2(0, -edge), Vector2(0, -1), 13.0, strong)
	_draw_compass_tick(center + Vector2(edge, 0), Vector2(1, 0), 9.0, color)
	_draw_compass_tick(center + Vector2(0, edge), Vector2(0, 1), 9.0, color)
	_draw_compass_tick(center + Vector2(-edge, 0), Vector2(-1, 0), 9.0, color)
	var north := PackedVector2Array([
		center + Vector2(0, -edge - 24),
		center + Vector2(7, -edge - 8),
		center + Vector2(0, -edge - 12),
		center + Vector2(-7, -edge - 8),
	])
	draw_colored_polygon(north, Color(0.84, 0.96, 1.0, 0.54))
	draw_polyline(north + PackedVector2Array([north[0]]), Color(0.03, 0.05, 0.06, 0.70), 1.0)

func _draw_compass_tick(pos: Vector2, dir: Vector2, length: float, color: Color) -> void:
	var normal := dir.normalized()
	var tangent := Vector2(-normal.y, normal.x)
	draw_line(pos - tangent * 4.0, pos + tangent * 4.0, color, 1.4)
	draw_line(pos, pos - normal * length, color, 1.4)

func _draw_frame(r: Rect2) -> void:
	draw_rect(r, Color(0, 0, 0, 0.18))
	draw_rect(r, Color(1, 1, 1, 0.15), false, 1.0)
	draw_line(Vector2(0, 0), Vector2(r.size.x, 0), Color(1, 1, 1, 0.20), 1.0)

func _world_to_map(world_pos: Vector3, r: Rect2) -> Vector2:
	var player_pos := _vec3(_data.get("player_pos", Vector3.ZERO))
	var radius := _map_radius()
	var scale := minf(r.size.x, r.size.y) * 0.46 / radius
	var dx := (world_pos.x - player_pos.x) * scale
	var dz := (world_pos.z - player_pos.z) * scale
	return r.size * 0.5 + Vector2(dx, -dz)

func _map_radius() -> float:
	var player_pos := _vec3(_data.get("player_pos", Vector3.ZERO))
	var home_pos := _vec3(_data.get("home_pos", Vector3.ZERO))
	var farthest := _flat_distance(player_pos, home_pos)
	if has_nearby_hint():
		farthest = maxf(farthest, _flat_distance(player_pos, _vec3(_data.get("nearby_position", Vector3.ZERO))))
	var target := _target_data()
	if not target.is_empty():
		farthest = maxf(farthest, _flat_distance(player_pos, _vec3(target.get("world_pos", Vector3.ZERO))))
	var raw: Variant = _data.get("landmarks", [])
	if typeof(raw) == TYPE_ARRAY:
		for item in raw:
			var entry: Dictionary = item
			farthest = maxf(farthest, _flat_distance(player_pos, _landmark_pos(entry)))
	return clampf(farthest * 1.25 + 16.0, 48.0, 256.0)

func _landmark_pos(entry: Dictionary) -> Vector3:
	if entry.has("world_pos"):
		return _vec3(entry.get("world_pos"))
	var pos_text := String(entry.get("pos", ""))
	var parts := pos_text.split(",")
	if parts.size() != 3:
		return Vector3.ZERO
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))

func _vec3(value: Variant) -> Vector3:
	if typeof(value) == TYPE_VECTOR3:
		return value
	if typeof(value) == TYPE_VECTOR3I:
		var p: Vector3i = value
		return Vector3(p.x, p.y, p.z)
	return Vector3.ZERO

func _target_data() -> Dictionary:
	var raw: Variant = _data.get("restoration_target", {})
	if typeof(raw) == TYPE_DICTIONARY:
		return raw
	return {}

func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()

func _draw_diamond(pos: Vector2, radius: float, fill: Color, stroke: Color) -> void:
	var points := PackedVector2Array([
		pos + Vector2(0, -radius),
		pos + Vector2(radius, 0),
		pos + Vector2(0, radius),
		pos + Vector2(-radius, 0),
	])
	draw_colored_polygon(points, fill)
	draw_polyline(points + PackedVector2Array([points[0]]), stroke, 1.3)

func _region_color(label: String) -> Color:
	match label:
		"浅水湾":
			return Color(0.22, 0.48, 0.70, 0.30)
		"沙岸":
			return Color(0.76, 0.68, 0.42, 0.26)
		"黏土滩":
			return Color(0.64, 0.46, 0.36, 0.28)
		"湿地":
			return Color(0.22, 0.56, 0.48, 0.30)
		"雪峰":
			return Color(0.74, 0.88, 1.0, 0.30)
		"玄武岩岭":
			return Color(0.22, 0.24, 0.30, 0.32)
		"岩岭":
			return Color(0.42, 0.46, 0.48, 0.28)
		"苔林":
			return Color(0.28, 0.54, 0.34, 0.30)
		"针叶林":
			return Color(0.18, 0.42, 0.30, 0.30)
		"风草原":
			return Color(0.56, 0.70, 0.34, 0.28)
		"草原":
			return Color(0.34, 0.64, 0.38, 0.28)
		_:
			return Color(0.36, 0.48, 0.46, 0.22)

func _unit(seed: int, salt: int) -> float:
	var h := absi(seed * 1103515245 + salt * 1013904223 + 12345)
	h = absi(h ^ (h >> 16))
	return float(h % 10000) / 9999.0
