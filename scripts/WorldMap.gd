extends CanvasLayer
# 世界地图：暂停式导航面板，展示玩家、归途、遗迹和附近线索。

signal close_requested

const WorldMapCanvas = preload("res://scripts/WorldMapCanvas.gd")

var _anim_root: Control
var _panel: PanelContainer
var _tween: Tween
var _close_button: Button
var _world_label: Label
var _summary_label: Label
var _stats_label: Label
var _nav_row: GridContainer
var _map_canvas: WorldMapCanvas

func setup() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	close()

func open(data: Dictionary) -> void:
	_refresh(data)
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_play_open_anim()
	if _close_button != null:
		_close_button.grab_focus.call_deferred()

func close() -> void:
	# 同步隐藏（Main 同帧读取 visible）；复位动画容器供下次进场。
	if _tween != null and _tween.is_running():
		_tween.kill()
	visible = false
	if _anim_root != null:
		_anim_root.modulate.a = 1.0
	if _panel != null:
		_panel.scale = Vector2.ONE

func _make_tween() -> Tween:
	if _tween != null and _tween.is_running():
		_tween.kill()
	_tween = create_tween()
	_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	return _tween

func _play_open_anim() -> void:
	if _anim_root == null:
		return
	_anim_root.modulate.a = 0.0
	if _panel != null:
		_panel.pivot_offset = _panel.size * 0.5
		_panel.scale = Vector2(0.97, 0.97)
	var t := _make_tween()
	t.set_parallel(true)
	t.tween_property(_anim_root, "modulate:a", 1.0, 0.14).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	if _panel != null:
		t.tween_property(_panel, "scale", Vector2.ONE, 0.14).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	# 动画容器：背景 + 面板一起淡入，面板再轻微缩放。
	_anim_root = Control.new()
	_anim_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_anim_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_anim_root)

	var dim := ColorRect.new()
	dim.color = Color(0.010, 0.018, 0.022, 0.60)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_anim_root.add_child(dim)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -390
	panel.offset_right = 390
	panel.offset_top = -270
	panel.offset_bottom = 270
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.042, 0.052, 0.055, 0.96), Color(1, 1, 1, 0.15), 1, 8))
	_anim_root.add_child(panel)
	_panel = panel

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	box.add_child(header)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override("separation", 2)
	header.add_child(title_box)

	var title := Label.new()
	title.text = "世界地图"
	title.add_theme_font_size_override("font_size", 28)
	title.modulate = Color(1, 1, 1, 0.97)
	title_box.add_child(title)

	_world_label = Label.new()
	_world_label.add_theme_font_size_override("font_size", 15)
	_world_label.modulate = Color(0.82, 0.92, 1.0, 0.80)
	title_box.add_child(_world_label)

	_close_button = _button("关闭", Vector2(86, 36))
	_close_button.focus_mode = Control.FOCUS_ALL
	_close_button.tooltip_text = "关闭地图（Esc / M）"
	_close_button.pressed.connect(func(): close_requested.emit())
	header.add_child(_close_button)

	_summary_label = _body_label(14, Color(0.88, 0.95, 1.0, 0.86))
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_summary_label)

	_map_canvas = WorldMapCanvas.new()
	_map_canvas.name = "WorldMapCanvas"
	box.add_child(_map_canvas)

	_stats_label = _body_label(14, Color(0.82, 0.90, 0.96, 0.76))
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_stats_label.visible = false
	box.add_child(_stats_label)

	_nav_row = GridContainer.new()
	_nav_row.columns = 4
	_nav_row.add_theme_constant_override("h_separation", 8)
	_nav_row.add_theme_constant_override("v_separation", 6)
	box.add_child(_nav_row)

	var legend := HBoxContainer.new()
	legend.alignment = BoxContainer.ALIGNMENT_CENTER
	legend.add_theme_constant_override("separation", 8)
	box.add_child(legend)
	legend.add_child(_legend_chip("地貌", Color(0.34, 0.64, 0.38, 0.82)))
	legend.add_child(_legend_chip("玩家", Color(0.96, 0.98, 1.0, 0.96)))
	legend.add_child(_legend_chip("归途", Color(0.44, 0.92, 1.0, 0.92)))
	legend.add_child(_legend_chip("遗迹", Color(1.0, 0.82, 0.30, 0.94)))
	legend.add_child(_legend_chip("修复", Color(0.62, 1.0, 0.76, 0.94)))
	legend.add_child(_legend_chip("线索", Color(0.72, 1.0, 0.66, 0.92)))

func _refresh(data: Dictionary) -> void:
	var world_name := String(data.get("world_name", "未命名世界"))
	var seed := int(data.get("seed", 0))
	var region := String(data.get("region", "未知区域"))
	var region_detail := String(data.get("region_detail", ""))
	var region_text := "%s · %s" % [region, region_detail] if region_detail != "" else region
	var weather := String(data.get("weather", "晴朗"))
	var home_distance := int(data.get("home_distance", 0))
	var home_direction := String(data.get("home_direction", "附近"))
	var home_text := "附近" if home_distance < 18 else "%s %dm" % [home_direction, home_distance]
	var landmarks: Array = data.get("landmarks", []) if typeof(data.get("landmarks", [])) == TYPE_ARRAY else []
	var best_restore := _best_restore_percent(landmarks)
	var restored := _restored_count(landmarks)
	var region_count := int(data.get("region_count", 0))
	var region_total := int(data.get("region_total", 0))
	var region_progress := "    区域  %d/%d" % [region_count, region_total] if region_total > 0 else ""
	_world_label.text = "%s  #%d" % [world_name, seed]
	_summary_label.text = "当前区域  %s    天气  %s    归途  %s    遗迹  %d    已修复  %d    最佳  %d%%%s" % [region_text, weather, home_text, landmarks.size(), restored, best_restore, region_progress]
	if _map_canvas != null:
		_map_canvas.set_map_data(data)
		_stats_label.text = "坐标  %s    地图半径  %dm    修复目标  %s    附近线索  %s" % [
			_format_pos(_vec3(data.get("player_pos", Vector3.ZERO))),
			int(round(_map_canvas.map_radius())),
			_target_text(data),
			("%dm %s" % [int(data.get("nearby_distance", 0)), String(data.get("nearby_direction", ""))]) if bool(data.get("nearby_valid", false)) else "无",
		]
		_refresh_nav_cards(data)

func _refresh_nav_cards(data: Dictionary) -> void:
	if _nav_row == null:
		return
	_clear_children(_nav_row)
	var radius := int(round(_map_canvas.map_radius())) if _map_canvas != null else 0
	var target_text := _target_text(data)
	var nearby_text := ("%dm %s" % [int(data.get("nearby_distance", 0)), String(data.get("nearby_direction", ""))]) if bool(data.get("nearby_valid", false)) else "无"
	_nav_row.add_child(_nav_chip("坐标", _format_pos(_vec3(data.get("player_pos", Vector3.ZERO))), Color(0.86, 0.94, 1.0, 0.90), "当前玩家所在世界坐标 X / Y / Z"))
	_nav_row.add_child(_nav_chip("范围", "%dm 半径" % radius, Color(0.74, 0.90, 1.0, 0.90), "地图覆盖的世界半径（米）"))
	_nav_row.add_child(_nav_chip("修复目标", target_text, Color(1.0, 0.84, 0.34, 0.94), "当前推荐修复的遗迹方向、距离与进度"))
	_nav_row.add_child(_nav_chip("附近线索", nearby_text, Color(0.72, 1.0, 0.66, 0.92), "最近一处线索的距离与方向"))

func _target_text(data: Dictionary) -> String:
	var raw: Variant = data.get("restoration_target", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return "无"
	var target: Dictionary = raw
	if target.is_empty():
		return "无"
	var label := String(target.get("label", "古遗迹"))
	var distance := int(target.get("distance", 0))
	var direction := String(target.get("direction", "附近"))
	var percent := clampi(int(target.get("restore_percent", 0)), 0, 100)
	var nav := "附近" if distance < 18 else "%s %dm" % [direction, distance]
	var status := "已修复" if bool(target.get("restore_complete", false)) or percent >= 100 else String(target.get("restore_label", "待修复"))
	return "%s %s %s %d%%" % [nav, label, status, percent]

func _format_pos(pos: Vector3) -> String:
	return "%d, %d, %d" % [int(round(pos.x)), int(round(pos.y)), int(round(pos.z))]

func _best_restore_percent(landmarks: Array) -> int:
	var best := 0
	for raw in landmarks:
		var entry: Dictionary = raw
		best = max(best, int(entry.get("restore_percent", 0)))
	return clampi(best, 0, 100)

func _restored_count(landmarks: Array) -> int:
	var count := 0
	for raw in landmarks:
		var entry: Dictionary = raw
		if bool(entry.get("restore_complete", false)) or int(entry.get("restore_percent", 0)) >= 100:
			count += 1
	return count

func _vec3(value: Variant) -> Vector3:
	if typeof(value) == TYPE_VECTOR3:
		return value
	if typeof(value) == TYPE_VECTOR3I:
		var p: Vector3i = value
		return Vector3(p.x, p.y, p.z)
	return Vector3.ZERO

func _legend_chip(label: String, color: Color) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var swatch := ColorRect.new()
	swatch.color = color
	swatch.custom_minimum_size = Vector2(14, 14)
	row.add_child(swatch)
	var text := _body_label(13, Color(0.86, 0.92, 0.96, 0.74))
	text.text = label
	row.add_child(text)
	return row

func _nav_chip(title: String, value: String, tint: Color, note: String = "") -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(172, 50)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.tooltip_text = note
	panel.add_theme_stylebox_override("panel", _panel_style(Color(tint.r * 0.10, tint.g * 0.10, tint.b * 0.10, 0.76), Color(tint.r, tint.g, tint.b, 0.34), 1, 6))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 9)
	margin.add_theme_constant_override("margin_right", 9)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_bottom", 5)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	margin.add_child(box)

	var title_label := _body_label(12, Color(tint.r, tint.g, tint.b, 0.84))
	title_label.text = title
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title_label)

	var value_label := _body_label(13, Color(0.94, 0.99, 1.0, 0.92))
	value_label.text = value
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(value_label)
	return panel

func _button(text: String, size: Vector2) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = size
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 15)
	return b

func _body_label(font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.add_theme_font_size_override("font_size", font_size)
	label.modulate = color
	return label

func _clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.free()

func _panel_style(bg: Color, border: Color, width: int, radius: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.border_width_left = width
	s.border_width_top = width
	s.border_width_right = width
	s.border_width_bottom = width
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	return s
