extends CanvasLayer
# 旅行手记：把世界身份、旅程进度和探索记录收束成一个可随时查看的游戏内记录页。

signal close_requested

const JOURNEY_META := [
	{"key": "explore", "label": "探索"},
	{"key": "select_material", "label": "选材"},
	{"key": "open_palette", "label": "材料库"},
	{"key": "place_block", "label": "建造"},
	{"key": "use_template", "label": "模板"},
	{"key": "open_map", "label": "地图"},
	{"key": "discover_landmark", "label": "遗迹"},
	{"key": "save_world", "label": "存档"},
]

var _world_label: Label
var _summary_label: Label
var _legacy_row: GridContainer
var _region_label: Label
var _region_row: GridContainer
var _journey_label: Label
var _journey_row: GridContainer
var _clue_label: Label
var _restoration_target_label: Label
var _landmark_count_label: Label
var _landmark_list: VBoxContainer

func setup() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	close()

func open(data: Dictionary) -> void:
	_refresh(data)
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func close() -> void:
	visible = false

func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.012, 0.020, 0.026, 0.58)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -365
	panel.offset_right = 365
	panel.offset_top = -310
	panel.offset_bottom = 310
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.044, 0.056, 0.060, 0.96), Color(1, 1, 1, 0.15), 1, 8))
	root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	box.add_child(header)

	var title_box := VBoxContainer.new()
	title_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_box.add_theme_constant_override("separation", 2)
	header.add_child(title_box)

	var title := Label.new()
	title.text = "旅行手记"
	title.add_theme_font_size_override("font_size", 28)
	title.modulate = Color(1, 1, 1, 0.97)
	title_box.add_child(title)

	_world_label = Label.new()
	_world_label.add_theme_font_size_override("font_size", 15)
	_world_label.modulate = Color(0.82, 0.92, 1.0, 0.80)
	title_box.add_child(_world_label)

	var close_button := _button("关闭", Vector2(86, 36))
	close_button.pressed.connect(func(): close_requested.emit())
	header.add_child(close_button)

	_summary_label = _body_label(14, Color(0.88, 0.95, 1.0, 0.86))
	_summary_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_summary_label)

	_legacy_row = GridContainer.new()
	_legacy_row.columns = 4
	_legacy_row.add_theme_constant_override("h_separation", 8)
	_legacy_row.add_theme_constant_override("v_separation", 6)
	box.add_child(_legacy_row)

	_region_label = _body_label(15, Color(0.80, 0.96, 0.84, 0.92))
	box.add_child(_region_label)

	_region_row = GridContainer.new()
	_region_row.columns = 4
	_region_row.add_theme_constant_override("h_separation", 8)
	_region_row.add_theme_constant_override("v_separation", 7)
	box.add_child(_region_row)

	box.add_child(_separator())

	_journey_label = _body_label(16, Color(1.0, 0.91, 0.58, 0.94))
	box.add_child(_journey_label)

	_journey_row = GridContainer.new()
	_journey_row.columns = 4
	_journey_row.add_theme_constant_override("h_separation", 8)
	_journey_row.add_theme_constant_override("v_separation", 8)
	box.add_child(_journey_row)

	box.add_child(_separator())

	_clue_label = _body_label(15, Color(0.78, 0.96, 0.80, 0.90))
	_clue_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_clue_label)

	_restoration_target_label = _body_label(15, Color(1.0, 0.88, 0.48, 0.92))
	_restoration_target_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_restoration_target_label)

	_landmark_count_label = _body_label(16, Color(0.92, 0.96, 1.0, 0.94))
	box.add_child(_landmark_count_label)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 104)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(scroll)

	_landmark_list = VBoxContainer.new()
	_landmark_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_landmark_list.add_theme_constant_override("separation", 7)
	scroll.add_child(_landmark_list)

func _refresh(data: Dictionary) -> void:
	var world_name := String(data.get("world_name", "未命名世界"))
	var seed := int(data.get("seed", 0))
	var region := String(data.get("region", "未知区域"))
	var region_detail := String(data.get("region_detail", ""))
	var region_text := "%s · %s" % [region, region_detail] if region_detail != "" else region
	var weather := String(data.get("weather", "晴朗"))
	var save_status := String(data.get("save_status", "已保存"))
	var edit_count := int(data.get("edit_count", 0))
	var region_count := int(data.get("region_count", 0))
	var region_total := int(data.get("region_total", 0))
	var region_progress := "    区域  %d/%d" % [region_count, region_total] if region_total > 0 else ""
	var home_distance := int(data.get("home_distance", 0))
	var home_direction := String(data.get("home_direction", "附近"))
	var home_text := "附近" if home_distance < 18 else "%s %dm" % [home_direction, home_distance]
	_world_label.text = "%s  #%d" % [world_name, seed]
	_summary_label.text = "当前区域  %s    天气  %s    归途  %s    存档  %s    改动  %d%s" % [region_text, weather, home_text, save_status, edit_count, region_progress]
	_refresh_legacy(data)
	_refresh_regions(data)
	_refresh_journey(data)
	_refresh_clue(data)
	_refresh_restoration_target(data)
	_refresh_landmarks(data)

func _refresh_legacy(data: Dictionary) -> void:
	if _legacy_row == null:
		return
	_clear_children(_legacy_row)
	var raw_landmarks: Variant = data.get("landmarks", [])
	var landmarks: Array = raw_landmarks if typeof(raw_landmarks) == TYPE_ARRAY else []
	var edit_count: int = maxi(0, int(data.get("edit_count", 0)))
	var region_total: int = maxi(0, int(data.get("region_total", 0)))
	var region_count: int = clampi(int(data.get("region_count", 0)), 0, region_total) if region_total > 0 else 0
	var raw_steps: Variant = data.get("journey_steps", [])
	var journey_count: int = raw_steps.size() if typeof(raw_steps) == TYPE_ARRAY else 0
	var journey_total: int = maxi(1, int(data.get("journey_total", JOURNEY_META.size())))
	var restored: int = _restored_count(landmarks)
	var best: int = _best_restore_percent(landmarks)
	_legacy_row.add_child(_legacy_chip("建造", "%d 格" % edit_count, Color(1.0, 0.74, 0.38, 0.92)))
	_legacy_row.add_child(_legacy_chip("区域", "%d/%d" % [region_count, region_total], Color(0.62, 1.0, 0.74, 0.92)))
	_legacy_row.add_child(_legacy_chip("旅程", "%d/%d" % [journey_count, journey_total], Color(1.0, 0.92, 0.48, 0.94)))
	_legacy_row.add_child(_legacy_chip("修复", "%d/%d  最佳 %d%%" % [restored, landmarks.size(), best], Color(0.66, 0.90, 1.0, 0.94)))

func _refresh_regions(data: Dictionary) -> void:
	var total := int(data.get("region_total", 0))
	var raw_regions: Variant = data.get("visited_regions", [])
	var regions := []
	if typeof(raw_regions) == TYPE_ARRAY:
		for raw in raw_regions:
			var label := String(raw).strip_edges()
			if label != "" and not regions.has(label):
				regions.append(label)
	if total <= 0:
		_region_label.visible = false
		_region_row.visible = false
		return
	_region_label.visible = true
	_region_row.visible = true
	_region_label.text = "区域足迹  %d/%d" % [regions.size(), total]
	_clear_children(_region_row)
	if regions.is_empty():
		_region_row.add_child(_region_chip("尚未记录", false))
		return
	for label in regions:
		_region_row.add_child(_region_chip(label, true))
	var undiscovered := total - regions.size()
	if undiscovered > 0:
		_region_row.add_child(_region_chip("未踏足 %d" % undiscovered, false))

func _refresh_journey(data: Dictionary) -> void:
	var done := {}
	var raw_steps: Variant = data.get("journey_steps", [])
	if typeof(raw_steps) == TYPE_ARRAY:
		for raw in raw_steps:
			done[str(raw)] = true
	var total := maxi(1, int(data.get("journey_total", JOURNEY_META.size())))
	_journey_label.text = "旅程进度  %d/%d" % [done.size(), total]
	_clear_children(_journey_row)
	for raw_meta in JOURNEY_META:
		var meta: Dictionary = raw_meta
		var key := String(meta.get("key", ""))
		var label := String(meta.get("label", "目标"))
		_journey_row.add_child(_journey_chip(label, done.has(key)))

func _refresh_clue(data: Dictionary) -> void:
	var distance := int(data.get("nearby_distance", -1))
	var direction := String(data.get("nearby_direction", ""))
	if distance >= 0 and direction != "":
		_clue_label.text = "线索  %s  约 %dm 有未记录遗迹" % [direction, distance]
	else:
		_clue_label.text = "线索  暂无新的遗迹回响"

func _refresh_restoration_target(data: Dictionary) -> void:
	var target := _target_data(data)
	if target.is_empty():
		_restoration_target_label.text = "修复目标  尚未记录遗迹"
		return
	var label := String(target.get("label", "古遗迹"))
	var distance := int(target.get("distance", 0))
	var direction := String(target.get("direction", "附近"))
	var nav := "附近" if distance < 18 else "%s %dm" % [direction, distance]
	var percent := clampi(int(target.get("restore_percent", 0)), 0, 100)
	var status := "已修复" if bool(target.get("restore_complete", false)) or percent >= 100 else String(target.get("restore_label", "待修复"))
	_restoration_target_label.text = "修复目标  %s  %s · %s %d%%" % [nav, label, status, percent]

func _refresh_landmarks(data: Dictionary) -> void:
	var raw_entries: Variant = data.get("landmarks", [])
	var entries := []
	if typeof(raw_entries) == TYPE_ARRAY:
		entries = raw_entries
	var target := _target_data(data)
	var target_key := String(target.get("key", ""))
	var restored := _restored_count(entries)
	_landmark_count_label.text = "遗迹记录  %d    已修复  %d" % [entries.size(), restored]
	_clear_children(_landmark_list)
	if entries.is_empty():
		_landmark_list.add_child(_empty_label("尚未记录遗迹"))
		return
	for raw in entries:
		var entry: Dictionary = raw
		_landmark_list.add_child(_landmark_row(
			String(entry.get("label", "古遗迹")),
			String(entry.get("nav_label", entry.get("pos", ""))),
			int(entry.get("restore_percent", 0)),
			String(entry.get("restore_label", "待修复")),
			target_key != "" and String(entry.get("key", "")) == target_key,
			String(entry.get("archive", ""))
			))

func _legacy_chip(title: String, value: String, tint: Color) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(150, 46)
	panel.add_theme_stylebox_override("panel", _panel_style(Color(tint.r * 0.12, tint.g * 0.12, tint.b * 0.12, 0.82), Color(tint.r, tint.g, tint.b, 0.42), 1, 6))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_bottom", 5)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	margin.add_child(box)

	var title_label := _body_label(12, Color(tint.r, tint.g, tint.b, 0.82))
	title_label.text = title
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title_label)

	var value_label := _body_label(15, Color(0.94, 0.99, 1.0, 0.94))
	value_label.text = value
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(value_label)
	return panel

func _journey_chip(label: String, done: bool) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(150, 34)
	panel.add_theme_stylebox_override("panel", _panel_style(
		Color(0.13, 0.15, 0.10, 0.90) if done else Color(0.055, 0.066, 0.070, 0.88),
		Color(0.95, 0.80, 0.24, 0.84) if done else Color(1, 1, 1, 0.12),
		1,
		6
	))
	var text := Label.new()
	text.text = ("已 " if done else "待 ") + label
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text.add_theme_font_size_override("font_size", 14)
	text.modulate = Color(1.0, 0.92, 0.55, 0.95) if done else Color(0.82, 0.88, 0.92, 0.76)
	panel.add_child(text)
	return panel

func _region_chip(label: String, visited: bool) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(150, 28)
	panel.add_theme_stylebox_override("panel", _panel_style(
		Color(0.075, 0.135, 0.096, 0.88) if visited else Color(0.035, 0.046, 0.050, 0.70),
		Color(0.56, 1.0, 0.68, 0.78) if visited else Color(1, 1, 1, 0.10),
		1,
		6
	))
	var text := Label.new()
	text.text = label
	text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	text.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	text.add_theme_font_size_override("font_size", 13)
	text.modulate = Color(0.82, 1.0, 0.86, 0.94) if visited else Color(0.72, 0.82, 0.86, 0.62)
	panel.add_child(text)
	return panel

func _landmark_row(label: String, pos: String, restore_percent: int, restore_label: String, focused: bool = false, archive: String = "") -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(0, 58)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _panel_style(
		Color(0.105, 0.092, 0.046, 0.86) if focused else Color(0.035, 0.046, 0.050, 0.74),
		Color(1.0, 0.78, 0.26, 0.72) if focused else Color(1, 1, 1, 0.10),
		1,
		6
	))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 7)
	margin.add_theme_constant_override("margin_bottom", 7)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)

	var name_label := _body_label(15, Color(0.94, 0.98, 1.0, 0.94))
	name_label.text = ("目标  " if focused else "") + label
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var restore_text := _body_label(13, _restore_color(restore_percent))
	restore_text.text = "%s %d%%" % [restore_label, clampi(restore_percent, 0, 100)]
	restore_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	restore_text.custom_minimum_size = Vector2(118, 0)
	row.add_child(restore_text)

	var pos_label := _body_label(13, Color(0.72, 0.82, 0.88, 0.70))
	pos_label.text = pos
	pos_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	pos_label.custom_minimum_size = Vector2(110, 0)
	row.add_child(pos_label)
	if archive != "":
		var archive_label := _body_label(12, Color(0.72, 0.90, 0.82, 0.72))
		archive_label.text = archive
		archive_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(archive_label)
	return panel

func _target_data(data: Dictionary) -> Dictionary:
	var raw: Variant = data.get("restoration_target", {})
	if typeof(raw) == TYPE_DICTIONARY:
		return raw
	return {}

func _restore_color(percent: int) -> Color:
	if percent >= 100:
		return Color(0.66, 1.0, 0.72, 0.94)
	if percent > 0:
		return Color(1.0, 0.88, 0.42, 0.92)
	return Color(0.72, 0.82, 0.88, 0.70)

func _restored_count(entries: Array) -> int:
	var count := 0
	for raw in entries:
		var entry: Dictionary = raw
		if bool(entry.get("restore_complete", false)) or int(entry.get("restore_percent", 0)) >= 100:
				count += 1
	return count

func _best_restore_percent(entries: Array) -> int:
	var best := 0
	for raw in entries:
		var entry: Dictionary = raw
		best = max(best, int(entry.get("restore_percent", 0)))
	return clampi(best, 0, 100)

func _empty_label(text: String) -> Label:
	var label := _body_label(15, Color(0.78, 0.86, 0.90, 0.66))
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(0, 42)
	return label

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

func _separator() -> Control:
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.11)
	line.custom_minimum_size = Vector2(0, 1)
	return line

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
