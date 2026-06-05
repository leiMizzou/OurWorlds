extends CanvasLayer
# 拍照模式取景层：无文字构图辅助，只在沉浸拍照时显示。

var _root: Control
var _frame: PanelContainer
var _guide_lines := []
var _vignette := []

func setup() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 40
	_build()
	set_active(false)

func set_active(active: bool) -> void:
	visible = active

func is_active() -> bool:
	return visible

func guide_line_count() -> int:
	return _guide_lines.size()

func has_frame() -> bool:
	return _frame != null

func vignette_piece_count() -> int:
	return _vignette.size()

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_add_vignette()
	_add_rule_line(true, 1.0 / 3.0)
	_add_rule_line(true, 2.0 / 3.0)
	_add_rule_line(false, 1.0 / 3.0)
	_add_rule_line(false, 2.0 / 3.0)
	_add_center_mark()
	_add_frame()

func _add_vignette() -> void:
	_add_edge_shadow(0.0, 0.0, 1.0, 0.0, 0, 0, 0, 78)
	_add_edge_shadow(0.0, 1.0, 1.0, 1.0, 0, -78, 0, 0)
	_add_edge_shadow(0.0, 0.0, 0.0, 1.0, 0, 0, 70, 0)
	_add_edge_shadow(1.0, 0.0, 1.0, 1.0, -70, 0, 0, 0)

func _add_edge_shadow(left: float, top: float, right: float, bottom: float, off_l: int, off_t: int, off_r: int, off_b: int) -> void:
	var shadow := ColorRect.new()
	shadow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	shadow.color = Color(0.0, 0.0, 0.0, 0.18)
	shadow.anchor_left = left
	shadow.anchor_top = top
	shadow.anchor_right = right
	shadow.anchor_bottom = bottom
	shadow.offset_left = off_l
	shadow.offset_top = off_t
	shadow.offset_right = off_r
	shadow.offset_bottom = off_b
	_root.add_child(shadow)
	_vignette.append(shadow)

func _add_rule_line(vertical: bool, anchor: float) -> void:
	var line := ColorRect.new()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.color = Color(1.0, 1.0, 1.0, 0.24)
	if vertical:
		line.anchor_left = anchor
		line.anchor_right = anchor
		line.anchor_top = 0.0
		line.anchor_bottom = 1.0
		line.offset_left = -0.5
		line.offset_right = 0.5
	else:
		line.anchor_left = 0.0
		line.anchor_right = 1.0
		line.anchor_top = anchor
		line.anchor_bottom = anchor
		line.offset_top = -0.5
		line.offset_bottom = 0.5
	_root.add_child(line)
	_guide_lines.append(line)

func _add_center_mark() -> void:
	_add_center_bar(Vector2(-18, -0.5), Vector2(-7, 0.5))
	_add_center_bar(Vector2(7, -0.5), Vector2(18, 0.5))
	_add_center_bar(Vector2(-0.5, -18), Vector2(0.5, -7))
	_add_center_bar(Vector2(-0.5, 7), Vector2(0.5, 18))

func _add_center_bar(offset_min: Vector2, offset_max: Vector2) -> void:
	var bar := ColorRect.new()
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.color = Color(1.0, 0.94, 0.62, 0.42)
	bar.anchor_left = 0.5
	bar.anchor_right = 0.5
	bar.anchor_top = 0.5
	bar.anchor_bottom = 0.5
	bar.offset_left = offset_min.x
	bar.offset_top = offset_min.y
	bar.offset_right = offset_max.x
	bar.offset_bottom = offset_max.y
	_root.add_child(bar)
	_guide_lines.append(bar)

func _add_frame() -> void:
	_frame = PanelContainer.new()
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.anchor_left = 0.0
	_frame.anchor_top = 0.0
	_frame.anchor_right = 1.0
	_frame.anchor_bottom = 1.0
	_frame.offset_left = 28
	_frame.offset_top = 24
	_frame.offset_right = -28
	_frame.offset_bottom = -24
	_frame.add_theme_stylebox_override("panel", _frame_style())
	_root.add_child(_frame)

func _frame_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0)
	style.border_color = Color(1.0, 0.94, 0.62, 0.28)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	return style
