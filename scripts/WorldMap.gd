extends CanvasLayer
# 世界地图：暂停式导航面板，展示玩家、归途、遗迹和附近线索。
# i18n：经 _loc()（/root/Locale 节点路径）访问 Locale 自动加载单例，而不是裸标识符
# `Locale` —— GDScript 在 `godot --script` 编译被 preload 的脚本时不会注入 autoload 全局名。

signal close_requested

const WorldMapCanvas = preload("res://scripts/WorldMapCanvas.gd")

# 图例项：[i18n key, 色块颜色]（文案随语言重译，颜色固定）。
const _LEGEND := [
	["MAP_LEGEND_TERRAIN", Color(0.34, 0.64, 0.38, 0.82)],
	["MAP_LEGEND_PLAYER", Color(0.96, 0.98, 1.0, 0.96)],
	["MAP_LEGEND_HOME", Color(0.44, 0.92, 1.0, 0.92)],
	["MAP_LEGEND_RELIC", Color(1.0, 0.82, 0.30, 0.94)],
	["MAP_LEGEND_REPAIR", Color(0.62, 1.0, 0.76, 0.94)],
	["MAP_LEGEND_CLUE", Color(0.72, 1.0, 0.66, 0.92)],
]

var _loc_cached: Node           # 缓存的 Locale 自动加载单例（经 /root/Locale 取，见 _loc()）
var _title_label: Label         # 面板标题（重译用）
var _legend_labels := []        # [{ "label": Label, "key": "MAP_LEGEND_..." }]，重译用
var _last_data := {}            # 上次 _refresh 的数据，供 _retranslate 用当前语言重算动态文案
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

# 经节点路径取 Locale 自动加载单例（不要用裸标识符 `Locale`）：见文件头注释与 PauseMenu。
func _loc() -> Node:
	if _loc_cached != null and is_instance_valid(_loc_cached):
		return _loc_cached
	var tree := get_tree()
	if tree != null and tree.root != null:
		_loc_cached = tree.root.get_node_or_null("Locale")
	if _loc_cached == null:
		_loc_cached = (load("res://scripts/Locale.gd") as GDScript).new()
		_loc_cached.call("load_strings")
	return _loc_cached

func _t(key: String) -> String:
	var l := _loc()
	return l.t(key) if l != null else key

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

	_title_label = Label.new()
	_title_label.text = _t("MAP_TITLE")
	_title_label.add_theme_font_size_override("font_size", 28)
	_title_label.modulate = Color(1, 1, 1, 0.97)
	title_box.add_child(_title_label)

	_world_label = Label.new()
	_world_label.add_theme_font_size_override("font_size", 15)
	_world_label.modulate = Color(0.82, 0.92, 1.0, 0.80)
	title_box.add_child(_world_label)

	_close_button = _button(_t("MAP_CLOSE"), Vector2(86, 36))
	_close_button.focus_mode = Control.FOCUS_ALL
	_close_button.tooltip_text = _t("MAP_CLOSE_TOOLTIP")
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
	for raw in _LEGEND:
		var entry: Array = raw
		legend.add_child(_legend_chip(String(entry[0]), entry[1]))

	# 语言切换时即时重译（地图打开期间切换也立刻生效）。
	if not _loc().language_changed.is_connected(_retranslate):
		_loc().language_changed.connect(_retranslate)

# i18n：静态文案随当前语言重设；动态内容用上次数据重算（_refresh 全程走 _t）。
func _retranslate() -> void:
	if _title_label != null:
		_title_label.text = _t("MAP_TITLE")
	if _close_button != null:
		_close_button.text = _t("MAP_CLOSE")
		_close_button.tooltip_text = _t("MAP_CLOSE_TOOLTIP")
	for entry in _legend_labels:
		var label: Label = entry.get("label")
		if label != null and is_instance_valid(label):
			label.text = _t(str(entry.get("key", "")))
	if not _last_data.is_empty():
		_refresh(_last_data)

# 自动加载单例 Locale 比本面板存活更久：销毁时断开信号，避免悬空回调。
func _exit_tree() -> void:
	if _loc_cached != null and is_instance_valid(_loc_cached) and _loc().language_changed.is_connected(_retranslate):
		_loc().language_changed.disconnect(_retranslate)

func _refresh(data: Dictionary) -> void:
	_last_data = data.duplicate(true)
	var world_name := String(data.get("world_name", _t("MAP_WORLD_FALLBACK")))
	var seed := int(data.get("seed", 0))
	var region := String(data.get("region", _t("REGION_UNKNOWN")))
	var region_detail := String(data.get("region_detail", ""))
	var region_text := _t("MAP_REGION_DETAIL") % [region, region_detail] if region_detail != "" else region
	var weather := String(data.get("weather", _t("MAP_WEATHER_FALLBACK")))
	var home_distance := int(data.get("home_distance", 0))
	var home_direction := String(data.get("home_direction", _t("MAP_HOME_NEARBY")))
	var home_text := _t("MAP_HOME_NEARBY") if home_distance < 18 else _t("MAP_HOME_DIR") % [home_direction, home_distance]
	var landmarks: Array = data.get("landmarks", []) if typeof(data.get("landmarks", [])) == TYPE_ARRAY else []
	var best_restore := _best_restore_percent(landmarks)
	var restored := _restored_count(landmarks)
	var region_count := int(data.get("region_count", 0))
	var region_total := int(data.get("region_total", 0))
	var region_progress := _t("MAP_REGION_PROGRESS") % [region_count, region_total] if region_total > 0 else ""
	_world_label.text = _t("MAP_WORLD_LABEL") % [world_name, seed]
	_summary_label.text = _t("MAP_SUMMARY") % [region_text, weather, home_text, landmarks.size(), restored, best_restore, region_progress]
	if _map_canvas != null:
		_map_canvas.set_map_data(data)
		_stats_label.text = _t("MAP_STATS") % [
			_format_pos(_vec3(data.get("player_pos", Vector3.ZERO))),
			int(round(_map_canvas.map_radius())),
			_target_text(data),
			_t("MAP_NAV_CLUE_VALUE") % [int(data.get("nearby_distance", 0)), String(data.get("nearby_direction", ""))] if bool(data.get("nearby_valid", false)) else _t("MAP_NONE"),
		]
		_refresh_nav_cards(data)

func _refresh_nav_cards(data: Dictionary) -> void:
	if _nav_row == null:
		return
	_clear_children(_nav_row)
	var radius := int(round(_map_canvas.map_radius())) if _map_canvas != null else 0
	var target_text := _target_text(data)
	var nearby_text := _t("MAP_NAV_CLUE_VALUE") % [int(data.get("nearby_distance", 0)), String(data.get("nearby_direction", ""))] if bool(data.get("nearby_valid", false)) else _t("MAP_NONE")
	_nav_row.add_child(_nav_chip(_t("MAP_NAV_COORDS"), _format_pos(_vec3(data.get("player_pos", Vector3.ZERO))), Color(0.86, 0.94, 1.0, 0.90), _t("MAP_NAV_COORDS_NOTE")))
	_nav_row.add_child(_nav_chip(_t("MAP_NAV_RANGE"), _t("MAP_NAV_RANGE_VALUE") % radius, Color(0.74, 0.90, 1.0, 0.90), _t("MAP_NAV_RANGE_NOTE")))
	_nav_row.add_child(_nav_chip(_t("MAP_NAV_TARGET"), target_text, Color(1.0, 0.84, 0.34, 0.94), _t("MAP_NAV_TARGET_NOTE")))
	_nav_row.add_child(_nav_chip(_t("MAP_NAV_CLUE"), nearby_text, Color(0.72, 1.0, 0.66, 0.92), _t("MAP_NAV_CLUE_NOTE")))

func _target_text(data: Dictionary) -> String:
	var raw: Variant = data.get("restoration_target", {})
	if typeof(raw) != TYPE_DICTIONARY:
		return _t("MAP_NONE")
	var target: Dictionary = raw
	if target.is_empty():
		return _t("MAP_NONE")
	var label := String(target.get("label", _t("LANDMARK_FALLBACK")))
	var distance := int(target.get("distance", 0))
	var direction := String(target.get("direction", _t("MAP_HOME_NEARBY")))
	var percent := clampi(int(target.get("restore_percent", 0)), 0, 100)
	var nav := _t("MAP_HOME_NEARBY") if distance < 18 else _t("MAP_HOME_DIR") % [direction, distance]
	var status := _t("MAP_TARGET_DONE") if bool(target.get("restore_complete", false)) or percent >= 100 else String(target.get("restore_label", _t("MAP_TARGET_TODO")))
	return _t("MAP_TARGET") % [nav, label, status, percent]

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

# label_key 是 i18n key；显示文案经 _t 取，并登记到重译清单。
func _legend_chip(label_key: String, color: Color) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var swatch := ColorRect.new()
	swatch.color = color
	swatch.custom_minimum_size = Vector2(14, 14)
	row.add_child(swatch)
	var text := _body_label(13, Color(0.86, 0.92, 0.96, 0.74))
	text.text = _t(label_key)
	row.add_child(text)
	_legend_labels.append({"label": text, "key": label_key})
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
