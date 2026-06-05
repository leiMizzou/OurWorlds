extends CanvasLayer
# 抬头显示：准星、状态条、快捷栏和轻量反馈。界面只负责信息层，不抢游戏输入。

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

const JOURNEY_GUIDE := [
	{"key": "explore", "label": "探索附近地形", "hint": "WASD"},
	{"key": "select_material", "label": "选择一种材料", "hint": "数字键 / 滚轮"},
	{"key": "open_palette", "label": "打开材料库", "hint": "E"},
	{"key": "place_block", "label": "放置一个方块", "hint": "右键"},
	{"key": "use_template", "label": "使用建造模板", "hint": "T 后右键"},
	{"key": "open_map", "label": "查看世界地图", "hint": "M"},
	{"key": "discover_landmark", "label": "记录一处遗迹", "hint": "跟随线索"},
	{"key": "save_world", "label": "保存世界", "hint": "Esc 后保存"},
]

var lib: BlockLibrary
var player

var _name_label: Label
var _current_icon: TextureRect
var _guide_label: Label
var _status_label: Label
var _coords_label: Label
var _compass_label: Label
var _feedback_label: Label
var _control_hint_label: Label
var _control_hint_panel: PanelContainer
var _crosshair: Control
var _crosshair_center: Control
var _build_intent_panel: PanelContainer
var _build_mode_label: Label
var _build_detail_label: Label
var _build_state_label: Label
var _recent_row: HBoxContainer
var _template_panel: PanelContainer
var _template_row: HBoxContainer
var _template_orientation_label: Label
var _recent_slots := []
var _recent_blocks := []
var _template_slots := []
var _slots := []
var _slot_ids := []
var _style_normal: StyleBoxFlat
var _style_selected: StyleBoxFlat
var _style_recent: StyleBoxFlat
var _style_template: StyleBoxFlat
var _style_template_selected: StyleBoxFlat
var _feedback_t := 0.0
var _feedback_base_top := -14.0
var _feedback_base_bottom := 14.0
var _crosshair_pulse_t := 0.0
var _crosshair_pulse_dur := 0.12
var _control_hint_state := 0   # 0=未决定, 1=淡入显示中, 2=已淡出
var _control_hint_alpha := 0.0
var _broke_once := false
var _journey_total := JOURNEY_GUIDE.size()
var _journey_steps := {}
var _shown_block_id := -1
var _start_pos := Vector3.ZERO
var _selected_once := false
var _placed_once := false
var _saved_once := false
var _weather_label := "晴朗"
var _region_label := "草原"
var _save_status := "已保存"
var _discovery_count := 0
var _last_discovery_label := ""
var _nearby_landmark_distance := -1
var _nearby_landmark_direction := ""
var _restored_landmark_count := 0
var _best_restore_percent := 0
var _focused_landmark_label := ""
var _focused_restore_percent := -1
var _focused_restore_complete := false
var _focused_landmark_distance := -1
var _focused_landmark_direction := ""

func setup(block_lib: BlockLibrary, p) -> void:
	lib = block_lib
	player = p
	if player != null:
		_start_pos = player.global_position
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	if player != null and player.has_signal("action_feedback"):
		player.action_feedback.connect(_on_player_action_feedback)

func _build() -> void:
	_style_normal = _panel_style(Color(0.05, 0.07, 0.09, 0.48), Color(1, 1, 1, 0.15), 1)
	_style_selected = _panel_style(Color(0.18, 0.20, 0.15, 0.78), Color(1.0, 0.86, 0.25, 0.95), 2)
	_style_recent = _panel_style(Color(0.05, 0.07, 0.09, 0.46), Color(1, 1, 1, 0.12), 1)
	_style_template = _panel_style(Color(0.035, 0.05, 0.055, 0.56), Color(1, 1, 1, 0.11), 1)
	_style_template_selected = _panel_style(Color(0.18, 0.22, 0.16, 0.82), Color(0.78, 1.0, 0.38, 0.95), 2)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	_build_crosshair(root)
	_build_status(root)
	_build_guide(root)
	_build_intent(root)
	_build_feedback(root)
	_build_control_hint(root)
	_build_hotbar(root)

func _build_crosshair(root: Control) -> void:
	# 准星收进 _crosshair 这个成员（保留名字给测试）；中心点 _crosshair_center 负责"活化"配色与脉冲。
	_crosshair = Control.new()
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair.anchor_left = 0.5
	_crosshair.anchor_right = 0.5
	_crosshair.anchor_top = 0.5
	_crosshair.anchor_bottom = 0.5
	_crosshair.offset_left = -15
	_crosshair.offset_right = 15
	_crosshair.offset_top = -15
	_crosshair.offset_bottom = 15
	_crosshair.pivot_offset = Vector2(15, 15)
	root.add_child(_crosshair)
	_add_bar(_crosshair, Vector2(13, 3), Vector2(4, 9), Color(0, 0, 0, 0.55))
	_add_bar(_crosshair, Vector2(13, 18), Vector2(4, 9), Color(0, 0, 0, 0.55))
	_add_bar(_crosshair, Vector2(3, 13), Vector2(9, 4), Color(0, 0, 0, 0.55))
	_add_bar(_crosshair, Vector2(18, 13), Vector2(9, 4), Color(0, 0, 0, 0.55))
	_add_bar(_crosshair, Vector2(14, 4), Vector2(2, 7), Color(1, 1, 1, 0.82))
	_add_bar(_crosshair, Vector2(14, 19), Vector2(2, 7), Color(1, 1, 1, 0.82))
	_add_bar(_crosshair, Vector2(4, 14), Vector2(7, 2), Color(1, 1, 1, 0.82))
	_add_bar(_crosshair, Vector2(19, 14), Vector2(7, 2), Color(1, 1, 1, 0.82))

	# 中心活化点：随瞄准状态变青/红/白，并在挖/放时做脉冲。
	_crosshair_center = Control.new()
	_crosshair_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair_center.position = Vector2(11, 11)
	_crosshair_center.size = Vector2(8, 8)
	_crosshair_center.pivot_offset = Vector2(4, 4)
	_crosshair.add_child(_crosshair_center)
	_add_bar(_crosshair_center, Vector2(2.5, 2.5), Vector2(3, 3), Color(0, 0, 0, 0.6))
	var dot := ColorRect.new()
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot.color = Color(1, 1, 1, 1)
	dot.position = Vector2(3, 3)
	dot.size = Vector2(2, 2)
	_crosshair_center.add_child(dot)
	_crosshair_center.modulate = Color(1, 1, 1, 0.9)

func _build_status(root: Control) -> void:
	# 顶栏只放"模式 · 区域 · 天气 · 存档"这条分层信息，干净清爽。
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.anchor_left = 0.0
	panel.anchor_top = 0.0
	panel.offset_left = 18
	panel.offset_top = 16
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.03, 0.05, 0.07, 0.42), Color(1, 1, 1, 0.10), 1))
	root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	panel.add_child(margin)

	_status_label = Label.new()
	_status_label.theme_type_variation = "Body"
	_status_label.modulate = Color(1, 1, 1, 0.96)
	margin.add_child(_status_label)

	# 坐标与紧凑罗盘移到右下角小字（Caption），给顶栏减负。
	var nav_panel := PanelContainer.new()
	nav_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	nav_panel.anchor_left = 1.0
	nav_panel.anchor_right = 1.0
	nav_panel.anchor_top = 1.0
	nav_panel.anchor_bottom = 1.0
	nav_panel.offset_left = -212
	nav_panel.offset_right = -16
	nav_panel.offset_top = -64
	nav_panel.offset_bottom = -16
	nav_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.03, 0.05, 0.07, 0.40), Color(1, 1, 1, 0.09), 1))
	root.add_child(nav_panel)

	var nav_margin := MarginContainer.new()
	nav_margin.add_theme_constant_override("margin_left", 11)
	nav_margin.add_theme_constant_override("margin_right", 11)
	nav_margin.add_theme_constant_override("margin_top", 6)
	nav_margin.add_theme_constant_override("margin_bottom", 6)
	nav_panel.add_child(nav_margin)

	var nav_box := VBoxContainer.new()
	nav_box.alignment = BoxContainer.ALIGNMENT_END
	nav_box.add_theme_constant_override("separation", 1)
	nav_margin.add_child(nav_box)

	_compass_label = Label.new()
	_compass_label.theme_type_variation = "Caption"
	_compass_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_compass_label.modulate = Color(0.82, 0.94, 0.94, 0.92)
	nav_box.add_child(_compass_label)

	_coords_label = Label.new()
	_coords_label.theme_type_variation = "Caption"
	_coords_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_coords_label.modulate = Color(0.74, 0.84, 0.95, 0.78)
	nav_box.add_child(_coords_label)

func _build_guide(root: Control) -> void:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 0.0
	panel.offset_left = -262
	panel.offset_right = -18
	panel.offset_top = 16
	panel.offset_bottom = 82
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.03, 0.05, 0.07, 0.38), Color(1, 1, 1, 0.10), 1))
	root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	panel.add_child(margin)

	_guide_label = Label.new()
	_guide_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_guide_label.theme_type_variation = "Body"
	_guide_label.modulate = Color(1.0, 0.92, 0.70, 0.92)
	margin.add_child(_guide_label)

func _build_intent(root: Control) -> void:
	_build_intent_panel = PanelContainer.new()
	_build_intent_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_intent_panel.anchor_left = 1.0
	_build_intent_panel.anchor_right = 1.0
	_build_intent_panel.anchor_top = 1.0
	_build_intent_panel.anchor_bottom = 1.0
	_build_intent_panel.offset_left = -300
	_build_intent_panel.offset_right = -18
	_build_intent_panel.offset_top = -302
	_build_intent_panel.offset_bottom = -226
	_build_intent_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.038, 0.042, 0.50), Color(1, 1, 1, 0.10), 1))
	root.add_child(_build_intent_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	_build_intent_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)

	_build_mode_label = Label.new()
	_build_mode_label.theme_type_variation = "Caption"
	_build_mode_label.modulate = Color(0.84, 1.0, 0.74, 0.94)
	box.add_child(_build_mode_label)

	_build_detail_label = Label.new()
	_build_detail_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_detail_label.theme_type_variation = "Body"
	_build_detail_label.modulate = Color(0.92, 0.98, 1.0, 0.92)
	box.add_child(_build_detail_label)

	_build_state_label = Label.new()
	_build_state_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_build_state_label.theme_type_variation = "Caption"
	_build_state_label.modulate = Color(0.76, 0.94, 0.82, 0.92)
	box.add_child(_build_state_label)

func _build_feedback(root: Control) -> void:
	_feedback_label = Label.new()
	_feedback_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feedback_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_feedback_label.theme_type_variation = "H2"
	_feedback_label.add_theme_color_override("font_outline_color", Color(0.02, 0.025, 0.03, 0.78))
	_feedback_label.add_theme_constant_override("outline_size", 4)
	_feedback_label.modulate = Color(1.0, 0.88, 0.36, 0.0)
	_feedback_label.anchor_left = 0.5
	_feedback_label.anchor_right = 0.5
	_feedback_label.anchor_top = 0.64
	_feedback_label.anchor_bottom = 0.64
	_feedback_label.offset_left = -180
	_feedback_label.offset_right = 180
	_feedback_label.offset_top = _feedback_base_top
	_feedback_label.offset_bottom = _feedback_base_bottom
	root.add_child(_feedback_label)

func _build_control_hint(root: Control) -> void:
	# 新手控制提示：首次进世界在屏幕中央淡入一行，完成第一次挖掘后淡出。纯 HUD 状态驱动。
	_control_hint_panel = PanelContainer.new()
	_control_hint_panel.name = "ControlHint"
	_control_hint_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_control_hint_panel.anchor_left = 0.5
	_control_hint_panel.anchor_right = 0.5
	_control_hint_panel.anchor_top = 0.5
	_control_hint_panel.anchor_bottom = 0.5
	_control_hint_panel.offset_left = -208
	_control_hint_panel.offset_right = 208
	_control_hint_panel.offset_top = 52
	_control_hint_panel.offset_bottom = 92
	_control_hint_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.03, 0.05, 0.07, 0.62), Color(1.0, 0.92, 0.62, 0.30), 1))
	_control_hint_panel.modulate = Color(1, 1, 1, 0.0)
	_control_hint_panel.visible = false
	root.add_child(_control_hint_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_top", 7)
	margin.add_theme_constant_override("margin_bottom", 7)
	_control_hint_panel.add_child(margin)

	_control_hint_label = Label.new()
	_control_hint_label.theme_type_variation = "Body"
	_control_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_control_hint_label.text = "左键挖  ·  右键放  ·  E 材料库"
	_control_hint_label.modulate = Color(1.0, 0.96, 0.82, 1.0)
	margin.add_child(_control_hint_label)

func _build_hotbar(root: Control) -> void:
	var bottom := VBoxContainer.new()
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	bottom.anchor_left = 0.5
	bottom.anchor_right = 0.5
	bottom.anchor_top = 1.0
	bottom.anchor_bottom = 1.0
	bottom.offset_left = -420
	bottom.offset_right = 420
	bottom.offset_top = -208
	bottom.offset_bottom = -16
	bottom.add_theme_constant_override("separation", 7)
	root.add_child(bottom)

	_build_template_strip(bottom)

	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", _panel_style(Color(0.03, 0.045, 0.05, 0.58), Color(1, 1, 1, 0.11), 1))
	badge.custom_minimum_size = Vector2(164, 38)
	badge.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	bottom.add_child(badge)

	var badge_margin := MarginContainer.new()
	badge_margin.add_theme_constant_override("margin_left", 10)
	badge_margin.add_theme_constant_override("margin_right", 12)
	badge_margin.add_theme_constant_override("margin_top", 5)
	badge_margin.add_theme_constant_override("margin_bottom", 5)
	badge.add_child(badge_margin)

	var badge_row := HBoxContainer.new()
	badge_row.add_theme_constant_override("separation", 8)
	badge_margin.add_child(badge_row)

	_current_icon = TextureRect.new()
	_current_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_current_icon.stretch_mode = TextureRect.STRETCH_SCALE
	_current_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_current_icon.custom_minimum_size = Vector2(28, 28)
	_current_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge_row.add_child(_current_icon)

	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.theme_type_variation = "Body"
	_name_label.modulate = Color(1, 1, 1, 0.96)
	badge_row.add_child(_name_label)

	_recent_row = HBoxContainer.new()
	_recent_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_recent_row.add_theme_constant_override("separation", 5)
	_recent_row.visible = false
	bottom.add_child(_recent_row)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 6)
	bottom.add_child(row)

	for id in lib.hotbar_blocks():
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(50, 50)
		slot.add_theme_stylebox_override("panel", _style_normal)
		row.add_child(slot)
		_slot_ids.append(id)

		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 6)
		margin.add_theme_constant_override("margin_right", 6)
		margin.add_theme_constant_override("margin_top", 6)
		margin.add_theme_constant_override("margin_bottom", 6)
		slot.add_child(margin)

		var icon := TextureRect.new()
		icon.texture = _icon(id)
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.custom_minimum_size = Vector2(38, 38)
		margin.add_child(icon)
		_slots.append(slot)

func _build_template_strip(parent: VBoxContainer) -> void:
	_template_panel = PanelContainer.new()
	_template_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_template_panel.custom_minimum_size = Vector2(940, 42)
	_template_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_template_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.025, 0.038, 0.042, 0.58), Color(1, 1, 1, 0.10), 1))
	parent.add_child(_template_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	_template_panel.add_child(margin)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	margin.add_child(row)

	var title := Label.new()
	title.text = "模板"
	title.custom_minimum_size = Vector2(42, 26)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.theme_type_variation = "Caption"
	title.modulate = Color(0.82, 0.92, 0.88, 0.92)
	row.add_child(title)

	_template_row = HBoxContainer.new()
	_template_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_template_row.add_theme_constant_override("separation", 4)
	row.add_child(_template_row)

	_template_orientation_label = Label.new()
	_template_orientation_label.custom_minimum_size = Vector2(44, 26)
	_template_orientation_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_template_orientation_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_template_orientation_label.theme_type_variation = "Caption"
	_template_orientation_label.modulate = Color(0.84, 1.0, 0.74, 0.94)
	row.add_child(_template_orientation_label)

	_rebuild_template_strip()

func _rebuild_template_strip() -> void:
	if _template_row == null:
		return
	for child in _template_row.get_children():
		_template_row.remove_child(child)
		child.free()
	_template_slots.clear()
	if player == null or not player.has_method("build_template_count"):
		_template_panel.visible = false
		return
	_template_panel.visible = true
	for i in range(player.build_template_count()):
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(60, 28)
		slot.add_theme_stylebox_override("panel", _style_template)
		_template_row.add_child(slot)

		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 4)
		margin.add_theme_constant_override("margin_right", 4)
		margin.add_theme_constant_override("margin_top", 4)
		margin.add_theme_constant_override("margin_bottom", 4)
		slot.add_child(margin)

		var item := HBoxContainer.new()
		item.alignment = BoxContainer.ALIGNMENT_CENTER
		item.add_theme_constant_override("separation", 4)
		margin.add_child(item)

		var template_id: String = player.build_template_id_at(i)
		var icon := _template_icon(template_id)
		item.add_child(icon)

		var label := Label.new()
		label.text = player.build_template_label_at(i)
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.theme_type_variation = "Caption"
		label.modulate = Color(0.92, 0.98, 0.94, 0.78)
		item.add_child(label)
		_template_slots.append({"index": i, "panel": slot, "label": label, "icon": icon})

func _template_icon(template_id: String) -> Control:
	var icon := Control.new()
	icon.custom_minimum_size = Vector2(18, 18)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cells := _template_icon_cells(template_id)
	for raw in cells:
		var cell: Vector2i = raw
		var dot := ColorRect.new()
		dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		dot.color = Color(0.78, 1.0, 0.38, 0.82)
		dot.position = Vector2(2 + cell.x * 4, 2 + cell.y * 4)
		dot.size = Vector2(3, 3)
		icon.add_child(dot)
	return icon

func _template_icon_cells(template_id: String) -> Array:
	match template_id:
		"platform":
			return [Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2)]
		"pillar":
			return [Vector2i(1, 0), Vector2i(1, 1), Vector2i(1, 2), Vector2i(1, 3)]
		"arch":
			return [Vector2i(0, 3), Vector2i(0, 2), Vector2i(0, 1), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 1), Vector2i(3, 2), Vector2i(3, 3)]
		"wall":
			return [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2)]
		"stairs":
			return [Vector2i(0, 3), Vector2i(1, 3), Vector2i(1, 2), Vector2i(2, 3), Vector2i(2, 2), Vector2i(2, 1), Vector2i(3, 3), Vector2i(3, 2), Vector2i(3, 1), Vector2i(3, 0)]
		"room_frame":
			return [Vector2i(0, 0), Vector2i(3, 0), Vector2i(0, 3), Vector2i(3, 3), Vector2i(1, 0), Vector2i(2, 0), Vector2i(1, 3), Vector2i(2, 3), Vector2i(0, 1), Vector2i(0, 2), Vector2i(3, 1), Vector2i(3, 2)]
		"cabin":
			return [Vector2i(0, 3), Vector2i(1, 3), Vector2i(2, 3), Vector2i(3, 3), Vector2i(0, 2), Vector2i(3, 2), Vector2i(1, 1), Vector2i(2, 1), Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
		"campfire":
			return [Vector2i(1, 1), Vector2i(2, 1), Vector2i(1, 2), Vector2i(2, 2), Vector2i(0, 0), Vector2i(3, 0), Vector2i(0, 3), Vector2i(3, 3)]
		"bridge":
			return [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2), Vector2i(0, 0), Vector2i(3, 0), Vector2i(0, 3), Vector2i(3, 3)]
		"garden":
			return [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(0, 3), Vector2i(1, 3), Vector2i(2, 3), Vector2i(3, 3), Vector2i(0, 1), Vector2i(3, 1), Vector2i(1, 1), Vector2i(2, 2)]
		"beacon_tower":
			return [Vector2i(0, 3), Vector2i(1, 3), Vector2i(2, 3), Vector2i(3, 3), Vector2i(1, 2), Vector2i(2, 2), Vector2i(1, 1), Vector2i(2, 1), Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
		"signpost":
			return [Vector2i(1, 3), Vector2i(2, 3), Vector2i(1, 2), Vector2i(1, 1), Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0)]
		_:
			return [Vector2i(1, 1), Vector2i(2, 2)]

func _process(delta: float) -> void:
	if player == null:
		return

	if not _slots.is_empty():
		for i in range(_slots.size()):
			var is_selected := int(_slot_ids[i]) == int(player.current_block())
			_slots[i].add_theme_stylebox_override("panel", _style_selected if is_selected else _style_normal)
			_slots[i].modulate = Color(1, 1, 1, 1) if is_selected else Color(1, 1, 1, 0.64)

			var block_id: int = player.current_block()
			_refresh_current_material(block_id)
			_refresh_recent_selection(block_id)
			_refresh_template_selection()
			_refresh_build_intent()
	var p: Vector3 = player.global_position
	_refresh_status_bar(p)
	_refresh_coords(p)
	_update_guide(p)
	_refresh_compass(p)
	_update_control_hint(delta)
	_update_crosshair(delta)

	if _feedback_t > 0.0:
		_feedback_t -= delta
		var a := clampf(_feedback_t / 0.55, 0.0, 1.0)
		_feedback_label.modulate.a = minf(1.0, a * 1.6)
		var lift := -8.0 * (1.0 - a)
		_feedback_label.offset_top = _feedback_base_top + lift
		_feedback_label.offset_bottom = _feedback_base_bottom + lift
	else:
		_feedback_label.modulate.a = 0.0

# 顶栏：模式 · ◇区域 · ◐天气 · ◆存档（+ 画笔/模板/遗迹）——分隔点 + 主次 modulate 分层。
func _refresh_status_bar(p: Vector3) -> void:
	var segments := PackedStringArray()
	segments.append("创造 · %s" % ("飞行" if player.fly else "步行"))
	segments.append("◇ %s" % _region_label)
	segments.append("◐ %s" % _weather_label)
	segments.append("◆ %s" % _save_status)
	var home := _home_status(p).strip_edges()
	if home != "":
		segments.append("⮌ %s" % home)
	if player.has_method("brush_label") and player.brush_label() != "1x1":
		segments.append("▤ 画笔 %s" % player.brush_label())
	if player.has_method("build_template_id") and player.build_template_id() != "off":
		var orientation := ""
		if player.has_method("build_template_orientation_label"):
			orientation = " " + player.build_template_orientation_label()
		segments.append("▣ 模板 %s%s" % [player.build_template_label(), orientation])
	if _discovery_count > 0:
		segments.append("⌖ 遗迹 %d" % _discovery_count)
	elif _nearby_landmark_distance >= 0:
		segments.append("⌖ 附近遗迹 %dm %s" % [_nearby_landmark_distance, _nearby_landmark_direction])
	_status_label.text = "   ·   ".join(segments)
	# 主次分层：有未保存改动时整条略提亮强调，已保存时回到沉静主色。
	var has_unsaved := _save_status == "有改动"
	_status_label.modulate = Color(1.0, 0.97, 0.86, 0.98) if has_unsaved else Color(0.92, 0.96, 1.0, 0.92)

# 坐标移到右下角小字（Caption），含归途提示，给顶栏减负。
func _refresh_coords(p: Vector3) -> void:
	if _coords_label == null:
		return
	_coords_label.text = "X %d   Y %d   Z %d" % [int(p.x), int(p.y), int(p.z)]

# 新手控制提示：首次进世界（edit_count==0）淡入；玩家第一次挖掘后淡出。纯 HUD 状态机。
func _update_control_hint(delta: float) -> void:
	if _control_hint_panel == null:
		return
	if _control_hint_state == 0:
		_control_hint_state = 1 if _is_fresh_world() else 2
	if _broke_once and _control_hint_state == 1:
		_control_hint_state = 2
	var target := 1.0 if _control_hint_state == 1 else 0.0
	_control_hint_alpha = move_toward(_control_hint_alpha, target, delta * 3.2)
	_control_hint_panel.visible = _control_hint_alpha > 0.01
	_control_hint_panel.modulate.a = _control_hint_alpha

func _is_fresh_world() -> bool:
	if player == null:
		return false
	var w = player.world if "world" in player else null
	if w == null or not w.has_method("edit_count"):
		return false
	return int(w.edit_count()) == 0

# 准星活化：中心点随瞄准状态变青/红/白；挖/放反馈触发 0.12s 的 1.0→1.25→1.0 脉冲。
func _update_crosshair(delta: float) -> void:
	if _crosshair_center != null:
		var state := "idle"
		if player.has_method("aim_state"):
			state = String(player.aim_state())
		elif player.has_method("has_target"):
			state = "ok" if player.has_target() else "idle"
		match state:
			"ok":
				_crosshair_center.modulate = Color(0.30, 1.0, 0.92, 1.0)   # 青：可放置
			"blocked":
				_crosshair_center.modulate = Color(1.0, 0.34, 0.30, 1.0)   # 红：被阻挡
			_:
				_crosshair_center.modulate = Color(1.0, 1.0, 1.0, 0.9)     # 白：无目标
	if _crosshair != null:
		if _crosshair_pulse_t > 0.0:
			_crosshair_pulse_t = maxf(0.0, _crosshair_pulse_t - delta)
			var phase := 1.0 - (_crosshair_pulse_t / _crosshair_pulse_dur)   # 0→1
			var bump := sin(clampf(phase, 0.0, 1.0) * PI)                    # 0→1→0
			var s := 1.0 + 0.25 * bump
			_crosshair.scale = Vector2(s, s)
		else:
			_crosshair.scale = Vector2.ONE

func _pulse_crosshair() -> void:
	_crosshair_pulse_t = _crosshair_pulse_dur

func _on_player_action_feedback(kind: String, label: String) -> void:
	if kind == "select" or kind == "pick":
		_selected_once = true
	elif kind == "place":
		_placed_once = true
	elif kind == "save":
		_saved_once = true
	elif kind == "break":
		_broke_once = true
	if kind == "break" or kind == "place":
		_pulse_crosshair()
	show_feedback(kind, label)

func show_feedback(kind: String, label: String) -> void:
	if kind == "save":
		_saved_once = true
	_feedback_label.text = label
	match kind:
		"break":
			_feedback_label.modulate = Color(0.86, 0.95, 1.0, 1.0)
		"place":
			_feedback_label.modulate = Color(1.0, 0.88, 0.36, 1.0)
		"pick":
			_feedback_label.modulate = Color(0.52, 0.96, 0.92, 1.0)
		"mode":
			_feedback_label.modulate = Color(0.55, 0.95, 0.70, 1.0)
		"save":
			_feedback_label.modulate = Color(0.58, 0.90, 1.0, 1.0)
		"weather":
			_feedback_label.modulate = Color(0.66, 0.84, 1.0, 1.0)
		"region":
			_feedback_label.modulate = Color(0.68, 0.96, 0.72, 1.0)
		"journey":
			_feedback_label.modulate = Color(1.0, 0.92, 0.46, 1.0)
		"discover":
			_feedback_label.modulate = Color(1.0, 0.82, 0.28, 1.0)
		"undo":
			_feedback_label.modulate = Color(0.62, 0.86, 1.0, 1.0)
		"redo":
			_feedback_label.modulate = Color(0.58, 0.94, 0.68, 1.0)
		"blocked":
			_feedback_label.modulate = Color(1.0, 0.38, 0.32, 1.0)
		_:
			_feedback_label.modulate = Color(1, 1, 1, 1)
	_feedback_t = 0.85

func set_weather_label(label: String) -> void:
	_weather_label = label

func set_region_label(label: String) -> void:
	_region_label = label

func set_save_state(has_unsaved: bool, enabled: bool = true) -> void:
	if not enabled:
		_save_status = "本地会话"
	else:
		_save_status = "有改动" if has_unsaved else "已保存"

func set_discovery_count(value: int) -> void:
	_discovery_count = maxi(0, value)

func set_last_discovery_label(label: String) -> void:
	_last_discovery_label = label.replace("发现", "").strip_edges()
	if _last_discovery_label != "":
		_focused_landmark_label = _last_discovery_label
		if _focused_restore_percent < 0:
			_focused_restore_percent = 0
		_focused_restore_complete = false

func set_nearby_landmark_distance(value: int) -> void:
	_nearby_landmark_distance = value
	if value < 0:
		_nearby_landmark_direction = ""

func set_nearby_landmark_hint(distance: int, direction: String) -> void:
	_nearby_landmark_distance = distance
	_nearby_landmark_direction = direction if distance >= 0 else ""

func set_journey_steps(steps: Array, total: int = 4) -> void:
	_journey_steps.clear()
	for raw in steps:
		_journey_steps[str(raw)] = true
	_journey_total = maxi(1, total)

func set_restoration_goal(label: String, percent: int, complete: bool, restored_count: int, best_percent: int, distance: int = -1, direction: String = "") -> void:
	_focused_landmark_label = label.replace("发现", "").strip_edges()
	_focused_restore_percent = -1 if percent < 0 else clampi(percent, 0, 100)
	_focused_restore_complete = complete
	_restored_landmark_count = maxi(0, restored_count)
	_best_restore_percent = clampi(best_percent, 0, 100)
	_focused_landmark_distance = distance
	_focused_landmark_direction = direction if distance >= 0 else ""

func set_recent_blocks(blocks: Array) -> void:
	_recent_blocks.clear()
	for raw in blocks:
		var id := int(raw)
		if lib != null and lib.has_def(id) and lib.is_renderable(id) and not _recent_blocks.has(id):
			_recent_blocks.append(id)
		if _recent_blocks.size() >= 5:
			break
	_rebuild_recent_row()

func _refresh_current_material(block_id: int) -> void:
	if _shown_block_id == block_id:
		return
	_shown_block_id = block_id
	_name_label.text = lib.block_name(block_id)
	if _current_icon != null:
		_current_icon.texture = _icon(block_id)

func _rebuild_recent_row() -> void:
	if _recent_row == null:
		return
	for child in _recent_row.get_children():
		_recent_row.remove_child(child)
		child.free()
	_recent_slots.clear()
	_recent_row.visible = not _recent_blocks.is_empty()
	for id in _recent_blocks:
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(32, 32)
		slot.add_theme_stylebox_override("panel", _style_recent)
		_recent_row.add_child(slot)

		var margin := MarginContainer.new()
		margin.add_theme_constant_override("margin_left", 4)
		margin.add_theme_constant_override("margin_right", 4)
		margin.add_theme_constant_override("margin_top", 4)
		margin.add_theme_constant_override("margin_bottom", 4)
		slot.add_child(margin)

		var icon := TextureRect.new()
		icon.texture = _icon(id)
		icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		icon.stretch_mode = TextureRect.STRETCH_SCALE
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.custom_minimum_size = Vector2(24, 24)
		margin.add_child(icon)
		_recent_slots.append({"id": id, "panel": slot})

func _refresh_recent_selection(block_id: int) -> void:
	for entry in _recent_slots:
		var slot: Dictionary = entry
		var panel: PanelContainer = slot["panel"]
		panel.add_theme_stylebox_override("panel", _style_selected if int(slot["id"]) == block_id else _style_recent)

func _refresh_template_selection() -> void:
	if _template_panel == null:
		return
	if player == null or not player.has_method("build_template_index"):
		_template_panel.visible = false
		return
	_template_panel.visible = true
	var current := int(player.build_template_index())
	for entry in _template_slots:
		var slot: Dictionary = entry
		var panel: PanelContainer = slot["panel"]
		var label: Label = slot["label"]
		var icon: Control = slot["icon"]
		var selected := int(slot["index"]) == current
		panel.add_theme_stylebox_override("panel", _style_template_selected if selected else _style_template)
		label.modulate = Color(1.0, 1.0, 1.0, 0.96) if selected else Color(0.92, 0.98, 0.94, 0.64)
		icon.modulate = Color(1.0, 1.0, 1.0, 1.0) if selected else Color(0.82, 0.92, 0.86, 0.58)
	if _template_orientation_label != null:
		_template_orientation_label.text = player.build_template_orientation_label()
		_template_orientation_label.visible = _template_orientation_label.text != ""

func _refresh_build_intent() -> void:
	if _build_intent_panel == null:
		return
	if player == null or not player.has_method("placement_intent_summary"):
		_build_intent_panel.visible = false
		return
	_build_intent_panel.visible = true
	var data: Dictionary = player.placement_intent_summary()
	var mode := String(data.get("mode", "单格"))
	var detail := String(data.get("detail", ""))
	var state := String(data.get("state", ""))
	var reason := String(data.get("reason", ""))
	var kind := String(data.get("state_kind", "idle"))
	_build_mode_label.text = mode
	_build_detail_label.text = detail
	_build_state_label.text = state if reason == "" else "%s · %s" % [state, reason]
	match kind:
		"ok":
			_build_state_label.modulate = Color(0.72, 1.0, 0.62, 0.90)
			_build_intent_panel.modulate = Color(1, 1, 1, 1)
		"blocked":
			_build_state_label.modulate = Color(1.0, 0.42, 0.34, 0.94)
			_build_intent_panel.modulate = Color(1.0, 0.90, 0.88, 1.0)
		_:
			_build_state_label.modulate = Color(0.76, 0.88, 0.92, 0.78)
			_build_intent_panel.modulate = Color(1, 1, 1, 0.78)

func _update_guide(pos: Vector3) -> void:
	if _guide_label == null:
		return
	for i in range(JOURNEY_GUIDE.size()):
		var meta: Dictionary = JOURNEY_GUIDE[i]
		var key := String(meta.get("key", ""))
		if _journey_goal_done(key, pos):
			continue
		var label := String(meta.get("label", "目标"))
		if key == "discover_landmark" and _nearby_landmark_distance >= 0:
			label = "%s（%s约 %dm）" % [label, _nearby_landmark_direction, _nearby_landmark_distance]
		var hint := String(meta.get("hint", ""))
		if hint != "":
			label = "%s  ·  %s" % [label, hint]
		_guide_label.text = "目标 %d/%d：%s" % [i + 1, _journey_total, label]
		return
	if _focused_landmark_label != "" and not _focused_restore_complete:
		var details := PackedStringArray()
		if _focused_restore_percent >= 0:
			details.append("%d%%" % _focused_restore_percent)
		var nav := _focused_navigation_label()
		if nav != "":
			details.append(nav)
		var suffix := "（%s）" % "，".join(details) if not details.is_empty() else ""
		_guide_label.text = "目标：修复%s%s  ·  右键建造修复" % [_focused_landmark_label, suffix]
	elif _restored_landmark_count > 0:
		var best_text := ""
		if _best_restore_percent > 0:
			best_text = "  最佳 %d%%" % _best_restore_percent
		_guide_label.text = "目标：寻找下一处遗迹  已修复 %d%s  ·  跟随线索" % [_restored_landmark_count, best_text]
	elif _best_restore_percent > 0:
		_guide_label.text = "目标：继续修复已发现的遗迹（最佳 %d%%）  ·  右键建造修复" % _best_restore_percent
	elif _last_discovery_label != "":
		_guide_label.text = "目标：修复%s  ·  右键建造修复" % _last_discovery_label
	elif _discovery_count > 0:
		_guide_label.text = "目标：修复已发现的遗迹  ·  右键建造修复"
	elif _nearby_landmark_distance >= 0:
		_guide_label.text = "附近遗迹  %s  约 %dm  ·  前往记录" % [_nearby_landmark_direction, _nearby_landmark_distance]
	else:
		_guide_label.text = "世界已就绪，开始建造  ·  E 材料 / M 地图"

func _refresh_compass(pos: Vector3) -> void:
	if _compass_label == null:
		return
	var segments := []
	segments.append("方位 " + _heading_label())
	var home_distance := Vector2(pos.x - _start_pos.x, pos.z - _start_pos.z).length()
	if home_distance >= 18.0:
		segments.append("归途 %dm %s" % [int(round(home_distance)), _relative_direction_label(_start_pos - pos)])
	if _focused_landmark_label != "" and not _focused_restore_complete and _focused_landmark_distance >= 0:
		var restore_direction := _focused_landmark_direction if _focused_landmark_direction != "" else "附近"
		segments.append("修复 %dm %s" % [_focused_landmark_distance, restore_direction])
	elif _nearby_landmark_distance >= 0:
		var hint_direction := _nearby_landmark_direction if _nearby_landmark_direction != "" else "附近"
		segments.append("线索 %dm %s" % [_nearby_landmark_distance, hint_direction])
	_compass_label.text = _join_compass_segments(segments)

func _focused_navigation_label() -> String:
	if _focused_landmark_distance < 0:
		return ""
	if _focused_landmark_distance < 18:
		return "附近"
	if _focused_landmark_direction == "":
		return "约 %dm" % _focused_landmark_distance
	return "%s约 %dm" % [_focused_landmark_direction, _focused_landmark_distance]

func _join_compass_segments(segments: Array) -> String:
	var text := ""
	for raw in segments:
		if text != "":
			text += "  "
		text += String(raw)
	return text

func _heading_label() -> String:
	if player == null:
		return "北"
	var basis: Basis = player.global_transform.basis if player.is_inside_tree() else player.transform.basis
	var forward := Vector3(-basis.z.x, 0.0, -basis.z.z)
	if forward.length_squared() < 0.001:
		return "北"
	var angle := atan2(forward.normalized().x, -forward.normalized().z)
	var sector := posmod(int(round(angle / (PI / 4.0))), 8)
	match sector:
		0: return "北"
		1: return "东北"
		2: return "东"
		3: return "东南"
		4: return "南"
		5: return "西南"
		6: return "西"
		_: return "西北"

func _journey_goal_done(key: String, pos: Vector3) -> bool:
	if _journey_done(key):
		return true
	match key:
		"explore":
			return Vector2(pos.x - _start_pos.x, pos.z - _start_pos.z).length() > 6.0
		"select_material":
			return _selected_once
		"place_block":
			return _placed_once
		"discover_landmark":
			return _discovery_count > 0
		"save_world":
			return _saved_once
		_:
			return false

func _journey_done(key: String) -> bool:
	return _journey_steps.has(key)

func _home_status(pos: Vector3) -> String:
	var distance := Vector2(pos.x - _start_pos.x, pos.z - _start_pos.z).length()
	if distance < 18.0:
		return ""
	return "  归途 %dm %s" % [int(round(distance)), _relative_direction_label(_start_pos - pos)]

func _relative_direction_label(to_target: Vector3) -> String:
	var flat := Vector3(to_target.x, 0.0, to_target.z)
	if flat.length_squared() < 0.001 or player == null:
		return "附近"
	var basis: Basis = player.global_transform.basis if player.is_inside_tree() else player.transform.basis
	var forward: Vector3 = -basis.z
	var right: Vector3 = basis.x
	var angle := atan2(flat.normalized().dot(right), flat.normalized().dot(forward))
	var sector := posmod(int(round(angle / (PI / 4.0))), 8)
	match sector:
		0: return "前方"
		1: return "右前"
		2: return "右侧"
		3: return "右后"
		4: return "后方"
		5: return "左后"
		6: return "左侧"
		_: return "左前"

func _add_bar(parent: Control, pos: Vector2, size: Vector2, color: Color) -> void:
	var bar := ColorRect.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.color = color
	bar.position = pos
	bar.size = size
	parent.add_child(bar)

func _panel_style(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.border_width_left = width
	s.border_width_top = width
	s.border_width_right = width
	s.border_width_bottom = width
	s.corner_radius_top_left = 6
	s.corner_radius_top_right = 6
	s.corner_radius_bottom_left = 6
	s.corner_radius_bottom_right = 6
	return s

func _icon(id: int) -> AtlasTexture:
	var at := AtlasTexture.new()
	at.atlas = lib.atlas
	var tile: int = lib.tile_for(id, 0)
	var col := tile % BlockLibrary.ATLAS_COLS
	var row := tile / BlockLibrary.ATLAS_COLS
	at.region = Rect2(col * BlockLibrary.TILE, row * BlockLibrary.TILE, BlockLibrary.TILE, BlockLibrary.TILE)
	return at
