extends CanvasLayer
# 暂停菜单：继续、保存、视距、音量和鼠标灵敏度，外加显示/全屏/分辨率与操作说明。只在暂停时接管鼠标。

const GameSettings = preload("res://scripts/GameSettings.gd")
# i18n：Locale 是自动加载单例（见 project.godot [autoload]）。
# 本脚本经 _loc()（/root/Locale 节点路径）访问它，而不是裸标识符 `Locale` ——
# 因为 GDScript 在 `godot --script` 编译被 preload 的脚本时不会注入 autoload 全局名。

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
var _language_option: OptionButton
var _controls_overlay: Control      # “操作说明”浮层（覆盖在面板之上）
# i18n：需在切换语言时重译的标签/控件引用（_retranslate 逐项重设文案）。
var _brand_title_label: Label
var _summary_section_title: Label
var _settings_title_label: Label
var _display_title_label: Label
var _quality_label: Label
var _language_label: Label
var _resolution_label: Label
var _controls_title_label: Label
var _controls_close_button: Button
var _controls_hint_label: Label
var _controls_action_labels := []   # [{ "label": Label, "key": "CONTROLS_..." }]
var _loc_cached: Node               # 缓存的 Locale 自动加载单例（经 /root/Locale 取，见 _loc()）
const VIEW_RADIUS_MIN := 2
const VIEW_RADIUS_MAX := 6
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

# 经节点路径取 Locale 自动加载单例（不要用裸标识符 `Locale`）：
# GDScript 在 `godot --script` 编译被 preload 的脚本时不会注入 autoload 全局名，
# 裸引用会报 “Identifier not found: Locale” 并使依赖该脚本的纯逻辑测试编译失败。
# 运行期 /root/Locale 一定存在；用一个安全垫片，万一缺失也只是退化为返回 key。
func _loc() -> Node:
	if _loc_cached != null and is_instance_valid(_loc_cached):
		return _loc_cached
	var tree := get_tree()
	if tree != null and tree.root != null:
		_loc_cached = tree.root.get_node_or_null("Locale")
	if _loc_cached == null:
		# 极端兜底（理论上不会发生）：用脚本实例临时顶上，保证不崩。
		_loc_cached = (load("res://scripts/Locale.gd") as GDScript).new()
		_loc_cached.call("load_strings")
	return _loc_cached

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

	_brand_title_label = Label.new()
	_brand_title_label.text = _loc().t("PAUSE_TITLE")
	_brand_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_brand_title_label.add_theme_font_size_override("font_size", 28)
	_brand_title_label.modulate = Color(1, 1, 1, 0.96)
	box.add_child(_brand_title_label)

	_subtitle_label = Label.new()
	_subtitle_label.text = _loc().t("PAUSE_SUBTITLE_PAUSED")
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

	_resume_button = _nav_button(_loc().t("PAUSE_RESUME"))
	_resume_button.tooltip_text = _loc().t("PAUSE_RESUME_TOOLTIP")
	_resume_button.pressed.connect(func(): resume_requested.emit())
	_left_buttons.add_child(_resume_button)

	_save_button = _nav_button(_loc().t("PAUSE_SAVE_WORLD"))
	_save_button.tooltip_text = _loc().t("PAUSE_SAVE_TOOLTIP")
	_save_button.pressed.connect(func(): save_requested.emit())
	_left_buttons.add_child(_save_button)

	_palette_button = _nav_button(_loc().t("PAUSE_PALETTE"))
	_palette_button.tooltip_text = _loc().t("PAUSE_PALETTE_TOOLTIP")
	_palette_button.pressed.connect(func(): palette_requested.emit())
	_left_buttons.add_child(_palette_button)

	_journal_button = _nav_button(_loc().t("PAUSE_JOURNAL"))
	_journal_button.tooltip_text = _loc().t("PAUSE_JOURNAL_TOOLTIP")
	_journal_button.pressed.connect(func(): journal_requested.emit())
	_left_buttons.add_child(_journal_button)

	_map_button = _nav_button(_loc().t("PAUSE_MAP"))
	_map_button.tooltip_text = _loc().t("PAUSE_MAP_TOOLTIP")
	_map_button.pressed.connect(func(): map_requested.emit())
	_left_buttons.add_child(_map_button)

	_controls_button = _nav_button(_loc().t("PAUSE_CONTROLS"))
	_controls_button.tooltip_text = _loc().t("PAUSE_CONTROLS_TOOLTIP")
	_controls_button.pressed.connect(_toggle_controls_overlay)
	_left_buttons.add_child(_controls_button)

	_title_button = _nav_button(_loc().t("PAUSE_BACK_TO_TITLE"))
	_title_button.tooltip_text = _loc().t("PAUSE_BACK_TO_TITLE_TOOLTIP")
	_title_button.pressed.connect(func(): title_requested.emit())
	_left_buttons.add_child(_title_button)

	_settings_title_label = Label.new()
	_settings_title_label.text = _loc().t("SETTINGS_TITLE")
	_settings_title_label.add_theme_font_size_override("font_size", 13)
	_settings_title_label.modulate = Color(1.0, 0.92, 0.70, 0.86)
	right.add_child(_settings_title_label)
	right.add_child(_view_radius_row())
	right.add_child(_quality_row())
	right.add_child(_slider_row("SETTINGS_VOLUME", _volume, _on_volume_changed))
	right.add_child(_slider_row("SETTINGS_SENSITIVITY", _sensitivity, _on_sensitivity_changed))
	right.add_child(_weather_toggle())
	right.add_child(_language_row())

	_display_title_label = Label.new()
	_display_title_label.text = _loc().t("DISPLAY_TITLE")
	_display_title_label.add_theme_font_size_override("font_size", 13)
	_display_title_label.modulate = Color(1.0, 0.92, 0.70, 0.86)
	right.add_child(_display_title_label)
	right.add_child(_fullscreen_row())
	right.add_child(_resolution_row())

	_build_controls_overlay(root)

	_refresh_labels()
	_retranslate()
	_refresh_mode()
	_refresh_summary()
	_sync_display_controls()
	# 语言切换时即时重译（暂停菜单打开期间切换也能立刻生效）。
	if not _loc().language_changed.is_connected(_retranslate):
		_loc().language_changed.connect(_retranslate)

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

	_summary_section_title = Label.new()
	_summary_section_title.text = _loc().t("SUMMARY_CURRENT_WORLD")
	_summary_section_title.add_theme_font_size_override("font_size", 13)
	_summary_section_title.modulate = Color(1.0, 0.92, 0.70, 0.86)
	_summary_box.add_child(_summary_section_title)

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

# label_key 既是 i18n key 也是音量/灵敏度的判别依据（文案最终由 _refresh_labels 带数值重写）。
func _slider_row(label_key: String, value: float, callback: Callable) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	var is_volume := label_key == "SETTINGS_VOLUME"
	var text := Label.new()
	text.add_theme_font_size_override("font_size", 14)
	text.modulate = Color(0.9, 0.95, 1.0, 0.86)
	box.add_child(text)
	if is_volume:
		_volume_label = text
	else:
		_sensitivity_label = text

	var slider := HSlider.new()
	slider.min_value = 0.0 if is_volume else 0.2
	slider.max_value = 1.0 if is_volume else 1.6
	slider.step = 0.05
	slider.value = value
	slider.custom_minimum_size = Vector2(0, 30)
	slider.value_changed.connect(callback)
	box.add_child(slider)
	return box

func _quality_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	_quality_label = Label.new()
	_quality_label.text = _loc().t("SETTINGS_QUALITY")
	_quality_label.custom_minimum_size = Vector2(180, 32)
	_quality_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_quality_label.add_theme_font_size_override("font_size", 14)
	_quality_label.modulate = Color(0.9, 0.95, 1.0, 0.86)
	row.add_child(_quality_label)

	_quality_option = OptionButton.new()
	_quality_option.focus_mode = Control.FOCUS_NONE
	_quality_option.custom_minimum_size = Vector2(116, 34)
	_quality_option.add_item(_loc().t("SETTINGS_QUALITY_PERFORMANCE"))
	_quality_option.set_item_metadata(0, "performance")
	_quality_option.add_item(_loc().t("SETTINGS_QUALITY_BALANCED"))
	_quality_option.set_item_metadata(1, "balanced")
	_quality_option.add_item(_loc().t("SETTINGS_QUALITY_CINEMATIC"))
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
	_weather_check.text = _loc().t("SETTINGS_WEATHER")
	_weather_check.button_pressed = _weather_enabled
	_weather_check.focus_mode = Control.FOCUS_NONE
	_weather_check.tooltip_text = _loc().t("SETTINGS_WEATHER_TOOLTIP")
	_weather_check.add_theme_font_size_override("font_size", 14)
	_weather_check.toggled.connect(_on_weather_toggled)
	return _weather_check

# 语言切换：中文 / English 下拉，元数据存语言码（zh/en），选中即切换并落盘。
func _language_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	_language_label = Label.new()
	_language_label.text = _loc().t("SETTINGS_LANGUAGE")
	_language_label.custom_minimum_size = Vector2(180, 32)
	_language_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_language_label.add_theme_font_size_override("font_size", 14)
	_language_label.modulate = Color(0.9, 0.95, 1.0, 0.86)
	row.add_child(_language_label)

	_language_option = OptionButton.new()
	_language_option.focus_mode = Control.FOCUS_NONE
	_language_option.custom_minimum_size = Vector2(116, 34)
	_language_option.tooltip_text = _loc().t("SETTINGS_LANGUAGE_TOOLTIP")
	_language_option.add_item(_loc().t("LANG_ZH"))
	_language_option.set_item_metadata(0, "zh")
	_language_option.add_item(_loc().t("LANG_EN"))
	_language_option.set_item_metadata(1, "en")
	_language_option.select(_language_index(_loc().current()))
	_language_option.item_selected.connect(_on_language_selected)
	row.add_child(_language_option)
	return row

func _language_index(lang: String) -> int:
	return 1 if lang == "en" else 0

func _on_language_selected(index: int) -> void:
	if _language_option == null:
		return
	_loc().set_language(str(_language_option.get_item_metadata(index)))

# ---- 显示：全屏开关 + 分辨率下拉（商用必备）----

func _fullscreen_row() -> Control:
	_fullscreen_check = CheckBox.new()
	_fullscreen_check.text = _loc().t("DISPLAY_FULLSCREEN")
	_fullscreen_check.button_pressed = _fullscreen
	_fullscreen_check.focus_mode = Control.FOCUS_NONE
	_fullscreen_check.tooltip_text = _loc().t("DISPLAY_FULLSCREEN_TOOLTIP")
	_fullscreen_check.add_theme_font_size_override("font_size", 14)
	_fullscreen_check.toggled.connect(_on_fullscreen_toggled)
	return _fullscreen_check

func _resolution_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	_resolution_label = Label.new()
	_resolution_label.text = _loc().t("DISPLAY_RESOLUTION")
	_resolution_label.custom_minimum_size = Vector2(180, 32)
	_resolution_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_resolution_label.add_theme_font_size_override("font_size", 14)
	_resolution_label.modulate = Color(0.9, 0.95, 1.0, 0.86)
	row.add_child(_resolution_label)

	_resolution_option = OptionButton.new()
	_resolution_option.focus_mode = Control.FOCUS_NONE
	_resolution_option.custom_minimum_size = Vector2(140, 34)
	_resolution_option.tooltip_text = _loc().t("DISPLAY_RESOLUTION_TOOLTIP")
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
	_view_radius = clampi(_view_radius - 1, VIEW_RADIUS_MIN, VIEW_RADIUS_MAX)
	_refresh_labels()
	view_radius_changed.emit(_view_radius)

func _increase_view_radius() -> void:
	_view_radius = clampi(_view_radius + 1, VIEW_RADIUS_MIN, VIEW_RADIUS_MAX)
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

# 左右两列键位：[操作 key, 键位 key]（i18n key，运行时经 _loc().t 取双语文案）。
# 覆盖移动/视角/挖放/材料库/模板/撤销/手记/地图/拍照等。
const _CONTROLS_LEFT := [
	["CONTROLS_MOVE", "CONTROLS_KEY_MOVE"],
	["CONTROLS_LOOK", "CONTROLS_KEY_LOOK"],
	["CONTROLS_JUMP_RUN", "CONTROLS_KEY_JUMP_RUN"],
	["CONTROLS_FLY_TOGGLE", "CONTROLS_KEY_FLY_TOGGLE"],
	["CONTROLS_FLY_UP_DOWN", "CONTROLS_KEY_JUMP_RUN"],
	["CONTROLS_DIG", "CONTROLS_KEY_DIG"],
	["CONTROLS_PLACE", "CONTROLS_KEY_PLACE"],
	["CONTROLS_SELECT_BLOCK", "CONTROLS_KEY_SELECT_BLOCK"],
	["CONTROLS_RECENT_MATERIAL", "CONTROLS_KEY_RECENT_MATERIAL"],
]
const _CONTROLS_RIGHT := [
	["CONTROLS_MATERIALS", "CONTROLS_KEY_MATERIALS"],
	["CONTROLS_BUILD_BRUSH", "CONTROLS_KEY_BUILD_BRUSH"],
	["CONTROLS_TEMPLATE_PREV_NEXT", "CONTROLS_KEY_TEMPLATE_PREV_NEXT"],
	["CONTROLS_ROTATE_TEMPLATE", "CONTROLS_KEY_ROTATE_TEMPLATE"],
	["CONTROLS_UNDO_REDO", "CONTROLS_KEY_UNDO_REDO"],
	["CONTROLS_JOURNAL", "CONTROLS_KEY_JOURNAL"],
	["CONTROLS_MAP", "CONTROLS_KEY_MAP"],
	["CONTROLS_PHOTO", "CONTROLS_KEY_PHOTO"],
	["CONTROLS_VIEW_SWITCH", "CONTROLS_KEY_VIEW_SWITCH"],
	["CONTROLS_PAUSE_MOUSE", "CONTROLS_KEY_PAUSE_MOUSE"],
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

	_controls_title_label = Label.new()
	_controls_title_label.text = _loc().t("CONTROLS_TITLE")
	_controls_title_label.add_theme_font_size_override("font_size", 26)
	_controls_title_label.modulate = Color(1.0, 0.97, 0.86, 0.97)
	_controls_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_controls_title_label)

	_controls_close_button = _button(_loc().t("CONTROLS_BACK"))
	_controls_close_button.custom_minimum_size = Vector2(96, 36)
	_controls_close_button.focus_mode = Control.FOCUS_ALL
	_controls_close_button.name = "ControlsCloseButton"
	_controls_close_button.pressed.connect(_hide_controls_overlay)
	header.add_child(_controls_close_button)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 26)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(columns)
	columns.add_child(_controls_column(_CONTROLS_LEFT))
	columns.add_child(_controls_column(_CONTROLS_RIGHT))

	_controls_hint_label = Label.new()
	_controls_hint_label.text = _loc().t("CONTROLS_HINT")
	_controls_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_controls_hint_label.add_theme_font_size_override("font_size", 12)
	_controls_hint_label.modulate = Color(0.80, 0.88, 0.96, 0.66)
	box.add_child(_controls_hint_label)

func _controls_column(rows: Array) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 7)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for raw in rows:
		var entry: Array = raw
		# entry = [操作 i18n key, 键位 i18n key]
		col.add_child(_controls_row(String(entry[0]), String(entry[1])))
	return col

func _controls_row(action_key: String, key_key: String) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)

	var action_label := Label.new()
	action_label.text = _loc().t(action_key)
	action_label.add_theme_font_size_override("font_size", 14)
	action_label.modulate = Color(0.88, 0.94, 1.0, 0.88)
	action_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(action_label)
	# 登记到重译清单：语言切换时 _retranslate 会按 key 重设文案。
	_controls_action_labels.append({"label": action_label, "key": action_key})

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
	key_label.text = _loc().t(key_key)
	key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_label.add_theme_font_size_override("font_size", 13)
	key_label.modulate = Color(1.0, 0.95, 0.80, 0.96)
	key_margin.add_child(key_label)
	row.add_child(key_panel)
	_controls_action_labels.append({"label": key_label, "key": key_key})
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

# i18n：把全部静态文案按当前语言重设一遍。构建后调用一次，并接到
# _loc().language_changed —— 暂停菜单打开期间切换语言也会立刻生效。
func _retranslate() -> void:
	if _brand_title_label != null:
		_brand_title_label.text = _loc().t("PAUSE_TITLE")
	# 左栏主功能按钮 + 提示（继续/返回标题随模式变化，交给 _refresh_mode）。
	if _save_button != null:
		_save_button.text = _loc().t("PAUSE_SAVE_WORLD")
		_save_button.tooltip_text = _loc().t("PAUSE_SAVE_TOOLTIP")
	if _palette_button != null:
		_palette_button.text = _loc().t("PAUSE_PALETTE")
		_palette_button.tooltip_text = _loc().t("PAUSE_PALETTE_TOOLTIP")
	if _journal_button != null:
		_journal_button.text = _loc().t("PAUSE_JOURNAL")
		_journal_button.tooltip_text = _loc().t("PAUSE_JOURNAL_TOOLTIP")
	if _map_button != null:
		_map_button.text = _loc().t("PAUSE_MAP")
		_map_button.tooltip_text = _loc().t("PAUSE_MAP_TOOLTIP")
	if _controls_button != null:
		_controls_button.text = _loc().t("PAUSE_CONTROLS")
		_controls_button.tooltip_text = _loc().t("PAUSE_CONTROLS_TOOLTIP")
	if _title_button != null:
		_title_button.text = _loc().t("PAUSE_BACK_TO_TITLE")
		_title_button.tooltip_text = _loc().t("PAUSE_BACK_TO_TITLE_TOOLTIP")
	if _resume_button != null:
		_resume_button.tooltip_text = _loc().t("PAUSE_RESUME_TOOLTIP")
	# 分组标题
	if _summary_section_title != null:
		_summary_section_title.text = _loc().t("SUMMARY_CURRENT_WORLD")
	if _settings_title_label != null:
		_settings_title_label.text = _loc().t("SETTINGS_TITLE")
	if _display_title_label != null:
		_display_title_label.text = _loc().t("DISPLAY_TITLE")
	# 设置项标签 + 控件
	if _quality_label != null:
		_quality_label.text = _loc().t("SETTINGS_QUALITY")
	if _quality_option != null and _quality_option.item_count >= 3:
		_quality_option.set_item_text(0, _loc().t("SETTINGS_QUALITY_PERFORMANCE"))
		_quality_option.set_item_text(1, _loc().t("SETTINGS_QUALITY_BALANCED"))
		_quality_option.set_item_text(2, _loc().t("SETTINGS_QUALITY_CINEMATIC"))
	if _weather_check != null:
		_weather_check.text = _loc().t("SETTINGS_WEATHER")
		_weather_check.tooltip_text = _loc().t("SETTINGS_WEATHER_TOOLTIP")
	if _language_label != null:
		_language_label.text = _loc().t("SETTINGS_LANGUAGE")
	if _language_option != null and _language_option.item_count >= 2:
		_language_option.tooltip_text = _loc().t("SETTINGS_LANGUAGE_TOOLTIP")
		_language_option.set_item_text(0, _loc().t("LANG_ZH"))
		_language_option.set_item_text(1, _loc().t("LANG_EN"))
		_language_option.select(_language_index(_loc().current()))
	# 显示分组
	if _fullscreen_check != null:
		_fullscreen_check.text = _loc().t("DISPLAY_FULLSCREEN")
		_fullscreen_check.tooltip_text = _loc().t("DISPLAY_FULLSCREEN_TOOLTIP")
	if _resolution_label != null:
		_resolution_label.text = _loc().t("DISPLAY_RESOLUTION")
	if _resolution_option != null:
		_resolution_option.tooltip_text = _loc().t("DISPLAY_RESOLUTION_TOOLTIP")
	# 操作说明浮层
	if _controls_title_label != null:
		_controls_title_label.text = _loc().t("CONTROLS_TITLE")
	if _controls_close_button != null:
		_controls_close_button.text = _loc().t("CONTROLS_BACK")
	if _controls_hint_label != null:
		_controls_hint_label.text = _loc().t("CONTROLS_HINT")
	for entry in _controls_action_labels:
		var label: Label = entry.get("label")
		if label != null and is_instance_valid(label):
			label.text = _loc().t(str(entry.get("key", "")))
	# 含数值/随模式变化的文案（视距/音量/灵敏度、副标题、继续按钮）。
	_refresh_labels()
	_refresh_mode()

# 自动加载单例 Locale 比本菜单存活更久：销毁时断开信号，避免悬空回调。
func _exit_tree() -> void:
	if _loc().language_changed.is_connected(_retranslate):
		_loc().language_changed.disconnect(_retranslate)

func _refresh_labels() -> void:
	if _view_label != null:
		_view_label.text = "%s  %d" % [_loc().t("SETTINGS_VIEW_DISTANCE"), _view_radius]
	if _volume_label != null:
		_volume_label.text = "%s  %d%%" % [_loc().t("SETTINGS_VOLUME"), int(round(_volume * 100.0))]
	if _sensitivity_label != null:
		_sensitivity_label.text = "%s  %d%%" % [_loc().t("SETTINGS_SENSITIVITY"), int(round(_sensitivity * 100.0))]

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
		_subtitle_label.text = _loc().t("PAUSE_SUBTITLE_TITLE_SETTINGS") if _title_settings_mode else _loc().t("PAUSE_SUBTITLE_PAUSED")
	if _resume_button != null:
		_resume_button.text = _loc().t("PAUSE_BACK_TO_TITLE") if _title_settings_mode else _loc().t("PAUSE_RESUME")
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
