extends CanvasLayer
# 暂停菜单：继续、保存、视距、音量和鼠标灵敏度，外加显示/全屏/分辨率与操作说明。只在暂停时接管鼠标。

const GameSettings = preload("res://scripts/GameSettings.gd")

signal resume_requested
signal save_requested
signal palette_requested
signal journal_requested
signal map_requested
signal title_requested
signal view_radius_changed(value: int)
signal volume_changed(value: float)
signal sensitivity_changed(value: float)
signal weather_enabled_changed(value: bool)
signal graphics_quality_changed(value: String)

var _panel: PanelContainer
var _anim_root: Control            # 承载缩放/淡入的容器（dim + panel），进出场动画作用对象
var _tween: Tween
var _subtitle_label: Label
var _summary_box: VBoxContainer
var _world_summary_label: Label
var _summary_chips: GridContainer
var _journey_summary_label: Label
var _landmark_summary_label: Label
var _location_summary_label: Label
var _left_buttons: VBoxContainer    # 左栏主功能按钮容器（键盘聚焦链首项落在这里）
var _resume_button: Button
var _save_button: Button
var _palette_button: Button
var _journal_button: Button
var _map_button: Button
var _controls_button: Button
var _title_button: Button
var _view_label: Label
var _volume_label: Label
var _sensitivity_label: Label
var _quality_option: OptionButton
var _fullscreen_check: CheckBox
var _resolution_option: OptionButton
var _weather_check: CheckBox
var _controls_overlay: Control      # “操作说明”浮层（覆盖在面板之上）
var _view_radius := 4
var _volume := 0.65
var _sensitivity := 1.0
var _weather_enabled := true
var _graphics_quality := "balanced"
var _fullscreen := false
var _resolution := "1280x720"
var _title_settings_mode := false
var _summary_data := {}

func setup(initial_radius: int, initial_volume: float, initial_sensitivity: float, initial_weather_enabled: bool = true, initial_graphics_quality: String = "balanced") -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_view_radius = initial_radius
	_volume = initial_volume
	_sensitivity = initial_sensitivity
	_weather_enabled = initial_weather_enabled
	_graphics_quality = _sanitize_quality(initial_graphics_quality)
	# 从落盘设置同步当前全屏/分辨率（GameSettings 是数据真相源，这里只读）。
	var saved := GameSettings.load_settings()
	_fullscreen = bool(saved.get("fullscreen", false))
	_resolution = String(saved.get("resolution", "1280x720"))
	_build()
	visible = false
	_title_settings_mode = false
	_refresh_mode()

func open(title_settings_mode: bool = false) -> void:
	_title_settings_mode = title_settings_mode
	_hide_controls_overlay()
	_refresh_mode()
	_refresh_summary()
	_sync_display_controls()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_play_open_anim()
	_focus_first_button.call_deferred()

func close() -> void:
	# 同步隐藏：Main 在同一帧内会读取 visible（且测试断言之），不能延迟。
	# 取舍：进场用动画（最显眼、最值得），退场即时——既保留观感又对 Main/测试稳定。
	if _tween != null and _tween.is_running():
		_tween.kill()
	visible = false
	_title_settings_mode = false
	_hide_controls_overlay()
	# 复位动画容器，让下次 open() 从干净状态再次淡入缩放。
	if _anim_root != null:
		_anim_root.modulate.a = 1.0
		_anim_root.scale = Vector2.ONE
	_refresh_mode()

# 操作说明浮层打开时，Esc 只关闭浮层（不让 Main 把整个暂停菜单也收掉）。
# 用 _input（早于 _unhandled_input）抢先消费，避免与 Main 的 Esc 处理打架。
func _input(event: InputEvent) -> void:
	if not visible or _controls_overlay == null or not _controls_overlay.visible:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		_hide_controls_overlay()
		get_viewport().set_input_as_handled()

func set_world_summary(data: Dictionary) -> void:
	_summary_data = data.duplicate()
	_refresh_summary()

func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# 动画容器：dim + 面板都放进来，进出场一起淡入并轻微缩放（pivot 居中）。
	_anim_root = Control.new()
	_anim_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_anim_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_anim_root)

	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.035, 0.045, 0.58)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_anim_root.add_child(dim)

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -400
	_panel.offset_right = 400
	_panel.offset_top = -282
	_panel.offset_bottom = 282
	_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.055, 0.068, 0.075, 0.94), Color(1, 1, 1, 0.14), 1))
	_anim_root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 22)
	margin.add_theme_constant_override("margin_right", 22)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	margin.add_child(box)

	var title := Label.new()
	title.text = "VoxelCraft"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.modulate = Color(1, 1, 1, 0.96)
	box.add_child(title)

	_subtitle_label = Label.new()
	_subtitle_label.text = "已暂停"
	_subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_subtitle_label.add_theme_font_size_override("font_size", 15)
	_subtitle_label.modulate = Color(0.82, 0.90, 0.96, 0.78)
	box.add_child(_subtitle_label)

	var content := HBoxContainer.new()
	content.add_theme_constant_override("separation", 18)
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(content)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(380, 0)
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 10)
	content.add_child(left)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	content.add_child(right)

	left.add_child(_summary_section())

	# 主功能按钮统一放进可聚焦的按钮列，open() 时聚焦首项并用方向键上下串联。
	_left_buttons = VBoxContainer.new()
	_left_buttons.add_theme_constant_override("separation", 10)
	left.add_child(_left_buttons)

	_resume_button = _nav_button("继续")
	_resume_button.tooltip_text = "返回游戏（Esc）"
	_resume_button.pressed.connect(func(): resume_requested.emit())
	_left_buttons.add_child(_resume_button)

	_save_button = _nav_button("保存世界")
	_save_button.tooltip_text = "把当前世界写入本地存档"
	_save_button.pressed.connect(func(): save_requested.emit())
	_left_buttons.add_child(_save_button)

	_palette_button = _nav_button("材料库")
	_palette_button.tooltip_text = "浏览全部可放置方块（E）"
	_palette_button.pressed.connect(func(): palette_requested.emit())
	_left_buttons.add_child(_palette_button)

	_journal_button = _nav_button("旅行手记")
	_journal_button.tooltip_text = "查看世界印记与旅程进度（J）"
	_journal_button.pressed.connect(func(): journal_requested.emit())
	_left_buttons.add_child(_journal_button)

	_map_button = _nav_button("世界地图")
	_map_button.tooltip_text = "打开周边地貌与遗迹地图（M）"
	_map_button.pressed.connect(func(): map_requested.emit())
	_left_buttons.add_child(_map_button)

	_controls_button = _nav_button("操作说明")
	_controls_button.tooltip_text = "查看全部键位与操作"
	_controls_button.pressed.connect(_toggle_controls_overlay)
	_left_buttons.add_child(_controls_button)

	_title_button = _nav_button("返回标题")
	_title_button.tooltip_text = "回到首屏世界选择"
	_title_button.pressed.connect(func(): title_requested.emit())
	_left_buttons.add_child(_title_button)

	var settings_title := Label.new()
	settings_title.text = "设置"
	settings_title.add_theme_font_size_override("font_size", 13)
	settings_title.modulate = Color(1.0, 0.92, 0.70, 0.86)
	right.add_child(settings_title)
	right.add_child(_view_radius_row())
	right.add_child(_quality_row())
	right.add_child(_slider_row("音量", _volume, _on_volume_changed))
	right.add_child(_slider_row("灵敏度", _sensitivity, _on_sensitivity_changed))
	right.add_child(_weather_toggle())

	var display_title := Label.new()
	display_title.text = "显示"
	display_title.add_theme_font_size_override("font_size", 13)
	display_title.modulate = Color(1.0, 0.92, 0.70, 0.86)
	right.add_child(display_title)
	right.add_child(_fullscreen_row())
	right.add_child(_resolution_row())

	_build_controls_overlay(root)

	_refresh_labels()
	_refresh_mode()
	_refresh_summary()
	_sync_display_controls()

func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 38)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 16)
	return b

# 左栏主功能按钮：可键盘聚焦（保留主题金色聚焦环），用于方向键导航。
func _nav_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 38)
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_size_override("font_size", 16)
	return b

# ============ 进出场动画（暂停无关，确保暂停界面照常播放）============

func _make_tween() -> Tween:
	if _tween != null and _tween.is_running():
		_tween.kill()
	_tween = create_tween()
	# 暂停时仍推进，否则暂停菜单的淡入/缩放会被冻结。
	_tween.set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	return _tween

func _play_open_anim() -> void:
	if _anim_root == null:
		return
	# 以面板中心为缩放支点，避免从左上角“长出来”。
	_anim_root.pivot_offset = _anim_root.size * 0.5
	_anim_root.modulate.a = 0.0
	_anim_root.scale = Vector2(0.97, 0.97)
	var t := _make_tween()
	t.set_parallel(true)
	t.tween_property(_anim_root, "modulate:a", 1.0, 0.14).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	t.tween_property(_anim_root, "scale", Vector2.ONE, 0.14).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)

# ============ 键盘 / 手柄聚焦链 ============

func _visible_nav_buttons() -> Array:
	var out := []
	if _left_buttons == null:
		return out
	for child in _left_buttons.get_children():
		if child is Button and (child as Button).visible:
			out.append(child)
	return out

func _focus_first_button() -> void:
	# 操作说明浮层打开时把焦点留给浮层关闭按钮；否则聚焦左栏首个可见项。
	if _controls_overlay != null and _controls_overlay.visible:
		return
	var buttons := _visible_nav_buttons()
	if buttons.is_empty():
		return
	_link_focus_chain(buttons)
	(buttons[0] as Button).grab_focus()

func _link_focus_chain(buttons: Array) -> void:
	var n := buttons.size()
	for i in range(n):
		var b: Button = buttons[i]
		var up: Button = buttons[(i - 1 + n) % n]
		var down: Button = buttons[(i + 1) % n]
		var up_path := up.get_path()
		var down_path := down.get_path()
		# 上下方向键在按钮列内循环；左右也接到上一/下一项，方便手柄左右摇杆。
		b.focus_neighbor_top = up_path
		b.focus_neighbor_bottom = down_path
		b.focus_neighbor_left = up_path
		b.focus_neighbor_right = down_path
		b.focus_previous = up_path
		b.focus_next = down_path

func _summary_section() -> Control:
	_summary_box = VBoxContainer.new()
	_summary_box.add_theme_constant_override("separation", 4)

	var title := Label.new()
	title.text = "当前世界"
	title.add_theme_font_size_override("font_size", 13)
	title.modulate = Color(1.0, 0.92, 0.70, 0.86)
	_summary_box.add_child(title)

	_world_summary_label = _summary_label(Color(0.93, 0.98, 1.0, 0.90))
	_summary_box.add_child(_world_summary_label)

	_summary_chips = GridContainer.new()
	_summary_chips.columns = 2
	_summary_chips.add_theme_constant_override("h_separation", 8)
	_summary_chips.add_theme_constant_override("v_separation", 6)
	_summary_box.add_child(_summary_chips)

	_journey_summary_label = _summary_label(Color(0.82, 0.94, 1.0, 0.80))
	_journey_summary_label.visible = false
	_summary_box.add_child(_journey_summary_label)
	_landmark_summary_label = _summary_label(Color(0.86, 1.0, 0.78, 0.78))
	_landmark_summary_label.visible = false
	_summary_box.add_child(_landmark_summary_label)
	_location_summary_label = _summary_label(Color(0.86, 0.92, 1.0, 0.66))
	_summary_box.add_child(_location_summary_label)
	return _summary_box

func _summary_label(color: Color) -> Label:
	var label := Label.new()
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", 13)
	label.modulate = color
	return label

func _summary_chip(title: String, value: String, note: String, tint: Color) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(184, 60)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.tooltip_text = note
	panel.add_theme_stylebox_override("panel", _panel_style(Color(tint.r * 0.10, tint.g * 0.10, tint.b * 0.10, 0.76), Color(tint.r, tint.g, tint.b, 0.32), 1))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 9)
	margin.add_theme_constant_override("margin_right", 9)
	margin.add_theme_constant_override("margin_top", 5)
	margin.add_theme_constant_override("margin_bottom", 5)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	margin.add_child(box)

	var title_label := _summary_label(Color(tint.r, tint.g, tint.b, 0.86))
	title_label.text = title
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 11)
	box.add_child(title_label)

	var value_label := _summary_label(Color(0.94, 0.99, 1.0, 0.94))
	value_label.text = value
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value_label.add_theme_font_size_override("font_size", 13)
	box.add_child(value_label)
	return panel

func _view_radius_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_view_label = Label.new()
	_view_label.custom_minimum_size = Vector2(180, 32)
	_view_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_view_label)

	var minus := _button("-")
	minus.custom_minimum_size = Vector2(48, 34)
	minus.pressed.connect(_decrease_view_radius)
	row.add_child(minus)

	var plus := _button("+")
	plus.custom_minimum_size = Vector2(48, 34)
	plus.pressed.connect(_increase_view_radius)
	row.add_child(plus)
	return row

func _slider_row(label: String, value: float, callback: Callable) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var text := Label.new()
	text.add_theme_font_size_override("font_size", 14)
	text.modulate = Color(0.9, 0.95, 1.0, 0.86)
	box.add_child(text)
	if label == "音量":
		_volume_label = text
	else:
		_sensitivity_label = text

	var slider := HSlider.new()
	slider.min_value = 0.0 if label == "音量" else 0.2
	slider.max_value = 1.0 if label == "音量" else 1.6
	slider.step = 0.05
	slider.value = value
	slider.custom_minimum_size = Vector2(0, 30)
	slider.value_changed.connect(callback)
	box.add_child(slider)
	return box

func _quality_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = "画质"
	label.custom_minimum_size = Vector2(180, 32)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.modulate = Color(0.9, 0.95, 1.0, 0.86)
	row.add_child(label)

	_quality_option = OptionButton.new()
	_quality_option.focus_mode = Control.FOCUS_NONE
	_quality_option.custom_minimum_size = Vector2(116, 34)
	_quality_option.add_item("性能")
	_quality_option.set_item_metadata(0, "performance")
	_quality_option.add_item("均衡")
	_quality_option.set_item_metadata(1, "balanced")
	_quality_option.add_item("精美")
	_quality_option.set_item_metadata(2, "cinematic")
	_quality_option.select(_quality_index(_graphics_quality))
	_quality_option.item_selected.connect(_on_quality_selected)
	row.add_child(_quality_option)
	return row

func _quality_index(value: String) -> int:
	match _sanitize_quality(value):
		"performance":
			return 0
		"cinematic":
			return 2
		_:
			return 1

func _separator() -> Control:
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.12)
	line.custom_minimum_size = Vector2(0, 1)
	return line

func _weather_toggle() -> Control:
	_weather_check = CheckBox.new()
	_weather_check.text = "动态天气"
	_weather_check.button_pressed = _weather_enabled
	_weather_check.focus_mode = Control.FOCUS_NONE
	_weather_check.tooltip_text = "开启后世界会随机出现降雨等天气"
	_weather_check.add_theme_font_size_override("font_size", 14)
	_weather_check.toggled.connect(_on_weather_toggled)
	return _weather_check

# ---- 显示：全屏开关 + 分辨率下拉（商用必备）----

func _fullscreen_row() -> Control:
	_fullscreen_check = CheckBox.new()
	_fullscreen_check.text = "全屏"
	_fullscreen_check.button_pressed = _fullscreen
	_fullscreen_check.focus_mode = Control.FOCUS_NONE
	_fullscreen_check.tooltip_text = "在全屏与窗口模式之间切换"
	_fullscreen_check.add_theme_font_size_override("font_size", 14)
	_fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	return _fullscreen_check

func _resolution_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var label := Label.new()
	label.text = "分辨率"
	label.custom_minimum_size = Vector2(180, 32)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 14)
	label.modulate = Color(0.9, 0.95, 1.0, 0.86)
	row.add_child(label)

	_resolution_option = OptionButton.new()
	_resolution_option.focus_mode = Control.FOCUS_NONE
	_resolution_option.custom_minimum_size = Vector2(140, 34)
	_resolution_option.tooltip_text = "窗口模式下的窗口尺寸（全屏时跟随显示器）"
	for i in range(GameSettings.RESOLUTIONS.size()):
		var value := String(GameSettings.RESOLUTIONS[i])
		_resolution_option.add_item(value)
		_resolution_option.set_item_metadata(i, value)
	_resolution_option.select(_resolution_index(_resolution))
	_resolution_option.item_selected.connect(_on_resolution_selected)
	row.add_child(_resolution_option)
	return row

func _resolution_index(value: String) -> int:
	var idx := GameSettings.RESOLUTIONS.find(value)
	return idx if idx >= 0 else 0

# 全屏时分辨率下拉无意义（跟随显示器），灰掉以减少困惑。
func _sync_display_controls() -> void:
	if _fullscreen_check != null:
		_fullscreen_check.button_pressed = _fullscreen
	if _resolution_option != null:
		_resolution_option.select(_resolution_index(_resolution))
		_resolution_option.disabled = _fullscreen

func _on_fullscreen_toggled(value: bool) -> void:
	_fullscreen = value
	_apply_window_mode()
	_persist_display()
	_sync_display_controls()

func _on_resolution_selected(index: int) -> void:
	if _resolution_option == null:
		return
	_resolution = String(_resolution_option.get_item_metadata(index))
	if not _fullscreen:
		_apply_resolution()
	_persist_display()

func _apply_window_mode() -> void:
	# 无窗口（headless）时 DisplayServer 仍可调用但无副作用；这里做存在性保护。
	if not DisplayServer.has_method("window_set_mode"):
		return
	if _fullscreen:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		_apply_resolution()

func _apply_resolution() -> void:
	if not DisplayServer.has_method("window_set_size"):
		return
	var size := GameSettings.resolution_size(_resolution)
	DisplayServer.window_set_size(size)
	# 重新居中，避免改尺寸后窗口贴边或跑出屏幕。
	if DisplayServer.has_method("window_set_position"):
		var screen := DisplayServer.screen_get_size()
		var pos := (screen - size) / 2
		DisplayServer.window_set_position(Vector2i(maxi(pos.x, 0), maxi(pos.y, 0)))

# 直接落盘全屏/分辨率（这两项无 Main 信号，由 PauseMenu 自管，GameSettings 是真相源）。
func _persist_display() -> void:
	var settings := GameSettings.load_settings()
	settings["fullscreen"] = _fullscreen
	settings["resolution"] = _resolution
	GameSettings.save_settings(settings)

func _decrease_view_radius() -> void:
	_view_radius = clampi(_view_radius - 1, 2, 6)
	_refresh_labels()
	view_radius_changed.emit(_view_radius)

func _increase_view_radius() -> void:
	_view_radius = clampi(_view_radius + 1, 2, 6)
	_refresh_labels()
	view_radius_changed.emit(_view_radius)

func _on_volume_changed(value: float) -> void:
	_volume = value
	_refresh_labels()
	volume_changed.emit(value)

func _on_sensitivity_changed(value: float) -> void:
	_sensitivity = value
	_refresh_labels()
	sensitivity_changed.emit(value)

func _on_weather_toggled(value: bool) -> void:
	_weather_enabled = value
	weather_enabled_changed.emit(value)

func _on_quality_selected(index: int) -> void:
	if _quality_option == null:
		return
	_graphics_quality = _sanitize_quality(str(_quality_option.get_item_metadata(index)))
	graphics_quality_changed.emit(_graphics_quality)

func _sanitize_quality(value: String) -> String:
	if value == "performance" or value == "balanced" or value == "cinematic":
		return value
	return "balanced"

# ============ 操作说明浮层（两列键位表，键位对齐 DESIGN 操作表）============

# 左右两列键位：[操作, 键]。覆盖移动/视角/挖放/材料库/模板/撤销/手记/地图/拍照等。
const _CONTROLS_LEFT := [
	["移动", "W A S D"],
	["视角", "鼠标"],
	["跳 / 跑", "空格 / Shift"],
	["飞行切换", "双击空格"],
	["飞行升 / 降", "空格 / Shift"],
	["挖方块", "鼠标左键"],
	["放方块", "鼠标右键"],
	["选方块", "数字 1–8 / 滚轮"],
	["最近材料", "R"],
]
const _CONTROLS_RIGHT := [
	["材料库", "E"],
	["建造画笔", "B"],
	["模板 上一 / 下一", "Q / T"],
	["旋转模板", "G"],
	["撤销 / 重做", "Z / Y"],
	["旅行手记", "J"],
	["世界地图", "M"],
	["拍照 / 截图", "F1 / F2"],
	["切换视角", "V / F5"],
	["暂停 / 抓放鼠标", "Esc"],
]

func _build_controls_overlay(parent: Control) -> void:
	_controls_overlay = Control.new()
	_controls_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_controls_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_controls_overlay.visible = false
	parent.add_child(_controls_overlay)

	var scrim := ColorRect.new()
	scrim.color = Color(0.01, 0.02, 0.03, 0.62)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 点击浮层背景即关闭。
	scrim.gui_input.connect(_on_controls_scrim_input)
	_controls_overlay.add_child(scrim)

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 0.5
	panel.anchor_bottom = 0.5
	panel.offset_left = -360
	panel.offset_right = 360
	panel.offset_top = -240
	panel.offset_bottom = 240
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.05, 0.064, 0.072, 0.97), Color(1.0, 0.86, 0.42, 0.30), 1))
	_controls_overlay.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 26)
	margin.add_theme_constant_override("margin_right", 26)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	box.add_child(header)

	var title := Label.new()
	title.text = "操作说明"
	title.add_theme_font_size_override("font_size", 26)
	title.modulate = Color(1.0, 0.97, 0.86, 0.97)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var close_button := _button("返回")
	close_button.custom_minimum_size = Vector2(96, 36)
	close_button.focus_mode = Control.FOCUS_ALL
	close_button.name = "ControlsCloseButton"
	close_button.pressed.connect(_hide_controls_overlay)
	header.add_child(close_button)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 26)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(columns)
	columns.add_child(_controls_column(_CONTROLS_LEFT))
	columns.add_child(_controls_column(_CONTROLS_RIGHT))

	var hint := Label.new()
	hint.text = "按 Esc 或点击空白处返回"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_font_size_override("font_size", 12)
	hint.modulate = Color(0.80, 0.88, 0.96, 0.66)
	box.add_child(hint)

func _controls_column(rows: Array) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for raw in rows:
		var entry: Array = raw
		col.add_child(_controls_row(String(entry[0]), String(entry[1])))
	return col

func _controls_row(action: String, key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var action_label := Label.new()
	action_label.text = action
	action_label.add_theme_font_size_override("font_size", 14)
	action_label.modulate = Color(0.88, 0.94, 1.0, 0.88)
	action_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(action_label)

	# 键位做成小胶囊，更像“键帽”，可读性更强。
	var key_panel := PanelContainer.new()
	key_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.10, 0.13, 0.15, 0.94), Color(1.0, 0.86, 0.42, 0.32), 1))
	var key_margin := MarginContainer.new()
	key_margin.add_theme_constant_override("margin_left", 9)
	key_margin.add_theme_constant_override("margin_right", 9)
	key_margin.add_theme_constant_override("margin_top", 2)
	key_margin.add_theme_constant_override("margin_bottom", 2)
	key_panel.add_child(key_margin)
	var key_label := Label.new()
	key_label.text = key
	key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_label.add_theme_font_size_override("font_size", 13)
	key_label.modulate = Color(1.0, 0.95, 0.80, 0.96)
	key_margin.add_child(key_label)
	row.add_child(key_panel)
	return row

func _toggle_controls_overlay() -> void:
	if _controls_overlay == null:
		return
	if _controls_overlay.visible:
		_hide_controls_overlay()
	else:
		_show_controls_overlay()

func _show_controls_overlay() -> void:
	if _controls_overlay == null:
		return
	_controls_overlay.visible = true
	# 淡入浮层（暂停无关）。
	_controls_overlay.modulate.a = 0.0
	var t := _make_tween()
	t.tween_property(_controls_overlay, "modulate:a", 1.0, 0.12).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	var close_button := _controls_overlay.find_child("ControlsCloseButton", true, false)
	if close_button is Button:
		(close_button as Button).grab_focus.call_deferred()

func _hide_controls_overlay() -> void:
	if _controls_overlay == null:
		return
	_controls_overlay.visible = false
	_controls_overlay.modulate.a = 1.0
	if visible:
		_focus_first_button.call_deferred()

func controls_overlay_visible() -> bool:
	return _controls_overlay != null and _controls_overlay.visible

func _on_controls_scrim_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_hide_controls_overlay()

func _refresh_labels() -> void:
	if _view_label != null:
		_view_label.text = "视距  %d" % _view_radius
	if _volume_label != null:
		_volume_label.text = "音量  %d%%" % int(round(_volume * 100.0))
	if _sensitivity_label != null:
		_sensitivity_label.text = "灵敏度  %d%%" % int(round(_sensitivity * 100.0))

func _refresh_summary() -> void:
	if _summary_box == null:
		return
	_summary_box.visible = not _title_settings_mode
	if _title_settings_mode:
		return
	var world_name := String(_summary_data.get("world_name", "本地世界"))
	var seed := int(_summary_data.get("seed", 0))
	var edit_count := maxi(0, int(_summary_data.get("edit_count", 0)))
	_world_summary_label.text = "世界：%s  #%d  编辑 %d 格" % [world_name, seed, edit_count]

	var journey_total := maxi(1, int(_summary_data.get("journey_total", 8)))
	var journey_count := clampi(int(_summary_data.get("journey_count", 0)), 0, journey_total)
	var next_label := String(_summary_data.get("next_journey_label", ""))
	if journey_count >= journey_total:
		_journey_summary_label.text = "旅程：%d/%d  首局目标完成" % [journey_count, journey_total]
	elif next_label != "":
		_journey_summary_label.text = "旅程：%d/%d  下个目标：%s" % [journey_count, journey_total, next_label]
	else:
		_journey_summary_label.text = "旅程：%d/%d" % [journey_count, journey_total]

	var discovered := maxi(0, int(_summary_data.get("discovered_count", 0)))
	var restored := maxi(0, int(_summary_data.get("restored_count", 0)))
	var best_percent := clampi(int(_summary_data.get("best_restore_percent", 0)), 0, 100)
	var target_label := String(_summary_data.get("restoration_target_label", ""))
	var target_percent := int(_summary_data.get("restoration_target_percent", -1))
	if target_label != "" and target_percent >= 0:
		_landmark_summary_label.text = "遗迹：发现 %d  修复 %d  %s %d%%" % [discovered, restored, target_label, target_percent]
	elif best_percent > 0:
		_landmark_summary_label.text = "遗迹：发现 %d  修复 %d  最佳 %d%%" % [discovered, restored, best_percent]
	else:
		_landmark_summary_label.text = "遗迹：发现 %d  修复 %d" % [discovered, restored]

	var region := String(_summary_data.get("region", "未知区域"))
	var region_detail := String(_summary_data.get("region_detail", ""))
	var region_text := "%s · %s" % [region, region_detail] if region_detail != "" else region
	var weather := String(_summary_data.get("weather", "晴朗"))
	var save_status := String(_summary_data.get("save_status", "本地会话"))
	var home_distance := maxi(0, int(_summary_data.get("home_distance", 0)))
	var home_direction := String(_summary_data.get("home_direction", "附近"))
	var home_text := "附近" if home_distance < 18 else "%s %d 格" % [home_direction, home_distance]
	var region_count := int(_summary_data.get("region_count", 0))
	var region_total := int(_summary_data.get("region_total", 0))
	var region_progress := "    区域：%d/%d" % [region_count, region_total] if region_total > 0 else ""
	_location_summary_label.text = "位置：%s  天气 %s\n归途：%s    存档：%s%s" % [region_text, weather, home_text, save_status, region_progress]
	_refresh_summary_chips(journey_count, journey_total, next_label, discovered, restored, best_percent, target_label, target_percent, home_text, save_status)

func _refresh_summary_chips(journey_count: int, journey_total: int, next_label: String, discovered: int, restored: int, best_percent: int, target_label: String, target_percent: int, home_text: String, save_status: String) -> void:
	if _summary_chips == null:
		return
	_clear_children(_summary_chips)
	var journey_value := "%d/%d" % [journey_count, journey_total]
	var journey_note := "首局目标完成" if journey_count >= journey_total else ("下个：%s" % next_label if next_label != "" else "继续探索")
	var relic_value := "发现 %d  修复 %d" % [discovered, restored]
	var relic_note := "最佳 %d%%" % best_percent if best_percent > 0 else "等待第一处记录"
	var restore_value := "%s %d%%" % [target_label, target_percent] if target_label != "" and target_percent >= 0 else "暂无目标"
	var restore_note := "右键建造修复" if target_label != "" and target_percent >= 0 else "跟随线索发现遗迹"
	_summary_chips.add_child(_summary_chip("旅程", journey_value, journey_note, Color(1.0, 0.92, 0.48, 0.92)))
	_summary_chips.add_child(_summary_chip("遗迹", relic_value, relic_note, Color(0.66, 0.90, 1.0, 0.92)))
	_summary_chips.add_child(_summary_chip("修复", restore_value, restore_note, Color(0.66, 1.0, 0.74, 0.92)))
	_summary_chips.add_child(_summary_chip("归途", home_text, save_status, Color(0.86, 0.94, 1.0, 0.86)))

func _refresh_mode() -> void:
	if _panel != null:
		# 首屏设置模式只显示右侧设置栏，但因新增“显示”分组需更高一些容纳全屏/分辨率。
		_panel.offset_top = -238 if _title_settings_mode else -315
		_panel.offset_bottom = 238 if _title_settings_mode else 315
	if _subtitle_label != null:
		_subtitle_label.text = "首屏设置" if _title_settings_mode else "已暂停"
	if _resume_button != null:
		_resume_button.text = "返回标题" if _title_settings_mode else "继续"
	if _summary_box != null:
		_summary_box.visible = not _title_settings_mode
	# 操作说明在首屏设置模式同样隐藏（没有世界上下文）。
	var game_buttons := [_save_button, _palette_button, _journal_button, _map_button, _controls_button, _title_button]
	for raw in game_buttons:
		var button: Button = raw
		if button != null:
			button.visible = not _title_settings_mode

func _clear_children(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.free()

func _panel_style(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.border_width_left = width
	s.border_width_top = width
	s.border_width_right = width
	s.border_width_bottom = width
	s.corner_radius_top_left = 8
	s.corner_radius_top_right = 8
	s.corner_radius_bottom_left = 8
	s.corner_radius_bottom_right = 8
	return s
