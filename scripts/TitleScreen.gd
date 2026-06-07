extends CanvasLayer
# 首屏入口：让玩家先看到真实世界，再进入建造。
#
# i18n：经 _loc()（/root/Locale 节点路径）访问 Locale 单例，而不是裸标识符 `Locale` ——
# 因为 GDScript 在 `godot --script` 编译被 preload 的脚本时不会注入 autoload 全局名。

signal continue_requested(seed: int)
signal new_world_requested(seed: int, kind: String)
signal delete_world_requested(seed: int)
signal settings_requested

const WorldCatalog = preload("res://scripts/WorldCatalog.gd")
const WorldCover = preload("res://scripts/WorldCover.gd")

var _anim_root: Control
var _panel: PanelContainer
var _tween: Tween
var _save_label: Label
var _seed_label: Label
var _world_label: Label
var _meta_label: Label
var _world_stats_row: GridContainer
var _world_cover: WorldCover
var _new_seed_edit: LineEdit
var _new_seed_name_label: Label
var _delete_hint: Label
var _prev_button: Button
var _next_button: Button
var _delete_button: Button
var _continue_button: Button
var _settings_button: Button
var _random_seed_button: Button
var _fresh_button: Button
var _worlds := []
var _selected_index := 0
var _fallback_seed := 1337
var _new_seed := 1337
var _new_kind := "infinite"
var _kind_button: CheckButton
var _delete_pending := false
# i18n：需在切换语言时重译的静态标签/按钮引用（动态文案由 _refresh_* 重算）。
var _tagline_label: Label
var _new_seed_section_label: Label
var _autosave_note_label: Label
var _loc_cached: Node               # 缓存的 Locale 自动加载单例（经 /root/Locale 取，见 _loc()）

# 经节点路径取 Locale 自动加载单例（不要用裸标识符 `Locale`）：
# GDScript 在 `godot --script` 编译被 preload 的脚本时不会注入 autoload 全局名，
# 裸引用会报 “Identifier not found: Locale” 并使依赖该脚本的纯逻辑测试编译失败。
# 运行期 /root/Locale 一定存在；用一个安全垫片，万一缺失也只是退化为返回 key。
func _loc() -> Node:
	if _loc_cached != null and is_instance_valid(_loc_cached):
		return _loc_cached
	# is_inside_tree() 守卫：在 SceneTree._initialize 阶段直接构造（无头单测）时
	# get_tree() 尚未就绪会打印 “data.tree is null” 噪声——此时退到下面的兜底实例。
	var tree := get_tree() if is_inside_tree() else null
	if tree != null and tree.root != null:
		_loc_cached = tree.root.get_node_or_null("Locale")
	if _loc_cached == null:
		# 极端兜底（理论上不会发生）：用脚本实例临时顶上，保证不崩。
		_loc_cached = (load("res://scripts/Locale.gd") as GDScript).new()
		_loc_cached.call("load_strings")
	return _loc_cached

func _t(key: String) -> String:
	var l := _loc()
	return l.t(key) if l != null else key

func setup(worlds: Array, selected_seed: int, fallback_seed: int) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_fallback_seed = fallback_seed
	_build()
	set_worlds(worlds, selected_seed)

func open() -> void:
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_play_open_anim()
	_focus_first_button.call_deferred()

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

# 进场聚焦首个主按钮，并把动作按钮串成上下导航链（左右方向键留给 Main 切世界）。
func _focus_first_button() -> void:
	if not visible:
		return
	var buttons := _nav_buttons()
	if buttons.is_empty():
		return
	_link_focus_chain(buttons)
	if _continue_button != null and _continue_button.visible:
		_continue_button.grab_focus()
	else:
		(buttons[0] as Button).grab_focus()

func _nav_buttons() -> Array:
	var out := []
	for b in [_continue_button, _settings_button, _random_seed_button, _fresh_button, _delete_button]:
		if b != null and (b as Button).visible and not (b as Button).disabled:
			out.append(b)
	return out

func _link_focus_chain(buttons: Array) -> void:
	var n := buttons.size()
	for i in range(n):
		var b: Button = buttons[i]
		var up: Button = buttons[(i - 1 + n) % n]
		var down: Button = buttons[(i + 1) % n]
		b.focus_neighbor_top = up.get_path()
		b.focus_neighbor_bottom = down.get_path()
		b.focus_previous = up.get_path()
		b.focus_next = down.get_path()

func request_continue_selected() -> void:
	continue_requested.emit(_selected_seed())

func request_move_selection(delta: int) -> bool:
	if delta == 0 or _worlds.size() < 2:
		return false
	if _new_seed_edit != null and _new_seed_edit.has_focus():
		return false
	_move_selection(delta)
	return true

func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# 动画容器：背景 + 面板一起淡入，面板再轻微缩放。
	_anim_root = Control.new()
	_anim_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_anim_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_anim_root)

	var dim := ColorRect.new()
	dim.color = Color(0.015, 0.025, 0.035, 0.42)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.gui_input.connect(_on_background_gui_input)
	_anim_root.add_child(dim)

	var wrap := HBoxContainer.new()
	wrap.anchor_left = 0.0
	wrap.anchor_right = 1.0
	wrap.anchor_top = 0.0
	wrap.anchor_bottom = 1.0
	wrap.offset_left = 72
	wrap.offset_right = -72
	wrap.offset_top = 28
	wrap.offset_bottom = -28
	wrap.alignment = BoxContainer.ALIGNMENT_BEGIN
	_anim_root.add_child(wrap)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(430, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.gui_input.connect(_on_background_gui_input)
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.060, 0.065, 0.88), Color(1, 1, 1, 0.14), 1))
	wrap.add_child(panel)
	_panel = panel

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_bottom", 18)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 9)
	margin.add_child(box)

	var title := Label.new()
	title.text = "OurWorlds"
	title.add_theme_font_size_override("font_size", 40)
	title.modulate = Color(1, 1, 1, 0.98)
	box.add_child(title)

	_tagline_label = Label.new()
	_tagline_label.text = _t("TITLE_TAGLINE")
	_tagline_label.add_theme_font_size_override("font_size", 16)
	_tagline_label.modulate = Color(0.82, 0.92, 1.0, 0.82)
	box.add_child(_tagline_label)

	box.add_child(_spacer(8))

	_world_cover = WorldCover.new()
	_world_cover.name = "WorldCover"
	_world_cover.custom_minimum_size = Vector2(0, 106)
	box.add_child(_world_cover)

	box.add_child(_world_row())

	_world_stats_row = GridContainer.new()
	_world_stats_row.columns = 4
	_world_stats_row.add_theme_constant_override("h_separation", 7)
	_world_stats_row.add_theme_constant_override("v_separation", 6)
	box.add_child(_world_stats_row)

	_continue_button = _button(_t("TITLE_CONTINUE_WORLD"))
	_continue_button.tooltip_text = _t("TITLE_CONTINUE_TOOLTIP")
	_continue_button.pressed.connect(request_continue_selected)
	box.add_child(_continue_button)

	_settings_button = _button(_t("TITLE_SETTINGS"))
	_settings_button.tooltip_text = _t("TITLE_SETTINGS_TOOLTIP")
	_settings_button.pressed.connect(func(): settings_requested.emit())
	box.add_child(_settings_button)

	box.add_child(_new_seed_panel())

	_fresh_button = _button(_t("TITLE_CREATE_WORLD"))
	_fresh_button.tooltip_text = _t("TITLE_CREATE_TOOLTIP")
	_fresh_button.pressed.connect(_on_new_world_pressed)
	box.add_child(_fresh_button)

	_delete_button = _button(_t("TITLE_DELETE_WORLD"))
	_delete_button.tooltip_text = _t("TITLE_DELETE_TOOLTIP")
	_delete_button.pressed.connect(_on_delete_pressed)
	box.add_child(_delete_button)

	_delete_hint = Label.new()
	_delete_hint.text = _t("TITLE_DELETE_HINT")
	_delete_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_delete_hint.add_theme_font_size_override("font_size", 12)
	_delete_hint.modulate = Color(1.0, 0.62, 0.54, 0.90)
	box.add_child(_delete_hint)

	_save_label = Label.new()
	_save_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_save_label.add_theme_font_size_override("font_size", 13)
	_save_label.modulate = Color(0.86, 0.93, 1.0, 0.80)
	_save_label.visible = false
	box.add_child(_save_label)

	_seed_label = Label.new()
	_seed_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_seed_label.add_theme_font_size_override("font_size", 13)
	_seed_label.modulate = Color(0.86, 0.93, 1.0, 0.66)
	_seed_label.visible = false
	box.add_child(_seed_label)

	_meta_label = Label.new()
	_meta_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_meta_label.add_theme_font_size_override("font_size", 13)
	_meta_label.modulate = Color(0.86, 0.93, 1.0, 0.62)
	_meta_label.visible = false
	box.add_child(_meta_label)

	_autosave_note_label = Label.new()
	_autosave_note_label.text = _t("TITLE_AUTOSAVE_NOTE")
	_autosave_note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_autosave_note_label.add_theme_font_size_override("font_size", 13)
	_autosave_note_label.modulate = Color(1.0, 0.92, 0.70, 0.88)
	_autosave_note_label.visible = false
	box.add_child(_autosave_note_label)

	# 语言切换时即时重译（标题页打开期间切换也能立刻生效）。
	var l := _loc()
	if l != null and not l.language_changed.is_connected(_retranslate):
		l.language_changed.connect(_retranslate)

func set_worlds(worlds: Array, selected_seed: int) -> void:
	_worlds = worlds.duplicate()
	_selected_index = 0
	_delete_pending = false
	for i in range(_worlds.size()):
		var meta: Dictionary = _worlds[i]
		if int(meta.get("seed", 0)) == selected_seed:
			_selected_index = i
			break
	if _worlds.is_empty():
		_fallback_seed = selected_seed
	_set_new_seed(_suggest_new_seed(selected_seed))
	_refresh_world_labels()

func _world_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_prev_button = _button("<")
	_prev_button.custom_minimum_size = Vector2(48, 38)
	_prev_button.focus_mode = Control.FOCUS_NONE
	_prev_button.tooltip_text = _t("TITLE_PREV_WORLD_TOOLTIP")
	_prev_button.pressed.connect(func(): _move_selection(-1))
	row.add_child(_prev_button)

	_world_label = Label.new()
	_world_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_world_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_world_label.custom_minimum_size = Vector2(260, 38)
	_world_label.add_theme_font_size_override("font_size", 16)
	_world_label.modulate = Color(1, 1, 1, 0.92)
	row.add_child(_world_label)

	_next_button = _button(">")
	_next_button.custom_minimum_size = Vector2(48, 38)
	_next_button.focus_mode = Control.FOCUS_NONE
	_next_button.tooltip_text = _t("TITLE_NEXT_WORLD_TOOLTIP")
	_next_button.pressed.connect(func(): _move_selection(1))
	row.add_child(_next_button)
	return row

func _new_seed_panel() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)

	_new_seed_section_label = Label.new()
	_new_seed_section_label.text = _t("TITLE_NEW_SEED_LABEL")
	_new_seed_section_label.add_theme_font_size_override("font_size", 13)
	_new_seed_section_label.modulate = Color(0.86, 0.93, 1.0, 0.74)
	box.add_child(_new_seed_section_label)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)

	_new_seed_edit = LineEdit.new()
	_new_seed_edit.placeholder_text = _t("TITLE_SEED_PLACEHOLDER")
	_new_seed_edit.clear_button_enabled = true
	_new_seed_edit.custom_minimum_size = Vector2(0, 36)
	_new_seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_new_seed_edit.add_theme_font_size_override("font_size", 14)
	_new_seed_edit.text_changed.connect(_on_new_seed_changed)
	_new_seed_edit.text_submitted.connect(_on_new_seed_submitted)
	row.add_child(_new_seed_edit)

	_random_seed_button = _button(_t("TITLE_RANDOM"))
	_random_seed_button.custom_minimum_size = Vector2(76, 36)
	_random_seed_button.tooltip_text = _t("TITLE_RANDOM_TOOLTIP")
	_random_seed_button.add_theme_font_size_override("font_size", 14)
	_random_seed_button.pressed.connect(_randomize_new_seed)
	row.add_child(_random_seed_button)

	_new_seed_name_label = Label.new()
	_new_seed_name_label.add_theme_font_size_override("font_size", 12)
	_new_seed_name_label.modulate = Color(1.0, 0.92, 0.70, 0.82)
	box.add_child(_new_seed_name_label)
	_kind_button = CheckButton.new()
	_kind_button.text = _t("TITLE_KIND_ISLAND")
	_kind_button.tooltip_text = _t("TITLE_KIND_ISLAND_TOOLTIP")
	_kind_button.add_theme_font_size_override("font_size", 13)
	_kind_button.toggled.connect(func(on):
		_new_kind = "themed_island" if on else "infinite"
		_refresh_new_seed_preview()
	)
	box.add_child(_kind_button)
	return box

func _move_selection(delta: int) -> void:
	if _worlds.is_empty():
		return
	_selected_index = posmod(_selected_index + delta, _worlds.size())
	_delete_pending = false
	_refresh_world_labels()

func _on_delete_pressed() -> void:
	if _worlds.is_empty():
		return
	if not _delete_pending:
		_delete_pending = true
		_refresh_world_labels()
		return
	var seed := _selected_seed()
	_delete_pending = false
	_refresh_world_labels()
	delete_world_requested.emit(seed)

func _on_new_seed_changed(text: String) -> void:
	_new_seed = _seed_from_text(text, _new_seed)
	_refresh_new_seed_preview()

func _on_new_seed_submitted(text: String) -> void:
	if _new_seed_edit != null and _new_seed_edit.text != text:
		_new_seed_edit.text = text
	_on_new_seed_changed(text)
	_on_new_world_pressed()

func _on_new_world_pressed() -> void:
	new_world_requested.emit(_new_world_seed(), _new_kind)

func _randomize_new_seed() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_set_new_seed(rng.randi_range(1000, 999999999))

func _set_new_seed(seed: int) -> void:
	_new_seed = clampi(seed, 1, 999999999)
	if _new_seed_edit != null:
		_new_seed_edit.text = str(_new_seed)
	_refresh_new_seed_preview()

func _new_world_seed() -> int:
	return _seed_from_text(_new_seed_edit.text if _new_seed_edit != null else str(_new_seed), _new_seed)

func _seed_from_text(text: String, fallback: int) -> int:
	var clean := text.strip_edges()
	if clean.is_empty():
		return clampi(fallback, 1, 999999999)
	if clean.is_valid_int():
		return clampi(absi(int(clean)), 1, 999999999)
	var h := 0
	for i in range(clean.length()):
		h = int((h * 131 + clean.unicode_at(i)) % 999999999)
	return maxi(1, h)

func _suggest_new_seed(selected_seed: int) -> int:
	var seed: int = absi(selected_seed * 1103515245 + 12345) % 999999999
	if seed < 1000:
		seed += 1000
	return seed

func _refresh_new_seed_preview() -> void:
	var seed := _new_world_seed()
	var is_island := _new_kind == "themed_island"
	var biome := _t("TITLE_KIND_ISLAND") if is_island else WorldCatalog.world_biome_label(seed)
	if _new_seed_name_label != null:
		_new_seed_name_label.text = _t("TITLE_SEED_PREVIEW") % [WorldCatalog.world_name(seed), biome, seed]
	if _world_cover != null and _worlds.is_empty():
		_world_cover.set_world_meta({
			"seed": seed,
			"name": WorldCatalog.world_name(seed),
			"biome_label": biome,
			"journey_total": WorldCatalog.JOURNEY_TOTAL,
		}, true)

func _selected_seed() -> int:
	if _worlds.is_empty():
		return _fallback_seed
	var meta: Dictionary = _worlds[_selected_index]
	return int(meta.get("seed", _fallback_seed))

func _refresh_world_labels() -> void:
	var has_worlds := not _worlds.is_empty()
	var stats_meta: Dictionary = {}
	if has_worlds:
		stats_meta = _worlds[_selected_index]
	if _world_label != null:
		if has_worlds:
			var world_name := String(stats_meta.get("name", _t("TITLE_WORLD_FALLBACK")))
			var biome := String(stats_meta.get("biome_label", WorldCatalog.world_biome_label(int(stats_meta.get("seed", _fallback_seed)))))
			_world_label.text = _t("TITLE_WORLD_LABEL") % [world_name, biome, _selected_index + 1, _worlds.size()]
		else:
			_world_label.text = _t("TITLE_NEW_WORLD_LABEL")
	if _world_cover != null:
		if has_worlds:
			_world_cover.set_world_meta(_worlds[_selected_index], false)
		else:
			var preview_seed := _new_world_seed()
			_world_cover.set_world_meta({
				"seed": preview_seed,
				"name": WorldCatalog.world_name(preview_seed),
				"biome_label": WorldCatalog.world_biome_label(preview_seed),
				"journey_total": WorldCatalog.JOURNEY_TOTAL,
			}, true)
	_refresh_world_stats(has_worlds, stats_meta)
	if _save_label != null:
		var backup_label := has_worlds and bool(stats_meta.get("from_backup", false))
		var save_state := _t("TITLE_SAVE_FROM_BACKUP") if backup_label else (_t("TITLE_SAVE_FOUND") if has_worlds else _t("TITLE_SAVE_NEW"))
		_save_label.text = _t("TITLE_SAVE_PREFIX") % save_state
		_save_label.visible = backup_label
	if _seed_label != null:
		_seed_label.text = _t("TITLE_SEED_DETAIL") % [_selected_seed(), WorldCatalog.world_biome_label(_selected_seed())]
		_seed_label.visible = false
	if _meta_label != null:
		if has_worlds:
			var recovery_note := _t("TITLE_NEEDS_SAVE") if bool(stats_meta.get("from_backup", false)) else ""
			_meta_label.text = _t("TITLE_LAST_SAVED") % [
				_format_time(int(stats_meta.get("updated_at", 0))),
				recovery_note,
			]
		else:
			_meta_label.text = _t("TITLE_READY_NEW")
		_meta_label.visible = has_worlds and bool(stats_meta.get("from_backup", false))
	if _delete_button != null:
		_delete_button.disabled = not has_worlds
		_delete_button.text = _t("TITLE_DELETE_CONFIRM") if _delete_pending and has_worlds else _t("TITLE_DELETE_WORLD")
		_delete_button.modulate = Color(1.0, 0.62, 0.58, 1.0) if _delete_pending and has_worlds else Color(1, 1, 1, 1)
	if _delete_hint != null:
		_delete_hint.visible = _delete_pending and has_worlds
	if _prev_button != null:
		_prev_button.disabled = _worlds.size() < 2
	if _next_button != null:
		_next_button.disabled = _worlds.size() < 2
	if _continue_button != null:
		_continue_button.text = _t("TITLE_CONTINUE_WORLD") if has_worlds else _t("TITLE_START_WORLD")

func _refresh_world_stats(has_worlds: bool, meta: Dictionary) -> void:
	if _world_stats_row == null:
		return
	_clear_children(_world_stats_row)
	var edit_count := int(meta.get("edit_count", 0)) if has_worlds else 0
	var discovery_count := int(meta.get("discovery_count", 0)) if has_worlds else 0
	var restored_count := int(meta.get("restored_count", 0)) if has_worlds else 0
	var best_restore := int(meta.get("best_restore_percent", 0)) if has_worlds else 0
	var journey_count := int(meta.get("journey_count", 0)) if has_worlds else 0
	var journey_total := int(meta.get("journey_total", WorldCatalog.JOURNEY_TOTAL))
	var region_count := int(meta.get("region_count", 0)) if has_worlds else 0
	var region_total := int(meta.get("region_total", 0))
	var region_text := "%d/%d" % [region_count, region_total] if region_total > 0 else str(region_count)
	_world_stats_row.add_child(_world_stat_chip(_t("TITLE_STAT_BUILD"), _t("TITLE_STAT_BUILD_VALUE") % edit_count, Color(1.0, 0.74, 0.38, 0.92)))
	_world_stats_row.add_child(_world_stat_chip(_t("TITLE_STAT_RELIC"), _t("TITLE_STAT_RELIC_VALUE") % [discovery_count, restored_count], Color(0.66, 0.90, 1.0, 0.94)))
	_world_stats_row.add_child(_world_stat_chip(_t("TITLE_STAT_JOURNEY"), "%d/%d" % [journey_count, journey_total], Color(1.0, 0.92, 0.48, 0.94)))
	_world_stats_row.add_child(_world_stat_chip(_t("TITLE_STAT_REGION"), region_text, Color(0.62, 1.0, 0.74, 0.92)))
	if best_restore > 0 and _world_stats_row.get_child_count() >= 2:
		var relic_chip := _world_stats_row.get_child(1)
		var relic_label := relic_chip.get_node_or_null("Margin/Box/Value") as Label
		if relic_label != null:
			relic_label.text = _t("TITLE_STAT_RELIC_BEST") % [restored_count, best_restore]

func _format_time(ts: int) -> String:
	if ts <= 0:
		return _t("TITLE_TIME_UNKNOWN")
	var d := Time.get_datetime_dict_from_unix_time(ts)
	return "%04d-%02d-%02d %02d:%02d" % [d["year"], d["month"], d["day"], d["hour"], d["minute"]]

func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 40)
	# 主按钮可键盘聚焦（保留主题金色聚焦环）；左右切世界的箭头单独设回 FOCUS_NONE。
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_font_size_override("font_size", 16)
	return b

func _on_background_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _new_seed_edit != null and _new_seed_edit.has_focus():
			_new_seed_edit.release_focus()
			return
		if _delete_pending:
			_delete_pending = false
			_refresh_world_labels()
			return
		request_continue_selected()

func _spacer(height: int) -> Control:
	var c := Control.new()
	if height > 100:
		c.custom_minimum_size = Vector2(1, 0)
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		c.custom_minimum_size = Vector2(1, height)
	return c

func _separator() -> Control:
	var line := ColorRect.new()
	line.color = Color(1, 1, 1, 0.12)
	line.custom_minimum_size = Vector2(0, 1)
	return line

func _world_stat_chip(title: String, value: String, tint: Color) -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(86, 42)
	panel.add_theme_stylebox_override("panel", _panel_style(Color(tint.r * 0.12, tint.g * 0.12, tint.b * 0.12, 0.76), Color(tint.r, tint.g, tint.b, 0.36), 1))

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 4)
	margin.add_theme_constant_override("margin_bottom", 4)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 0)
	margin.add_child(box)

	var title_label := Label.new()
	title_label.text = title
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 11)
	title_label.modulate = Color(tint.r, tint.g, tint.b, 0.82)
	box.add_child(title_label)

	var value_label := Label.new()
	value_label.name = "Value"
	value_label.text = value
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value_label.add_theme_font_size_override("font_size", 13)
	value_label.modulate = Color(0.94, 0.99, 1.0, 0.94)
	value_label.clip_text = true
	box.add_child(value_label)
	return panel

# i18n：把全部静态文案按当前语言重设一遍，并触发动态文案（世界标签/种子预览/统计）
# 重算。构建后调用一次，并接到 _loc().language_changed —— 标题页打开期间切换语言也会
# 立刻生效。
func _retranslate() -> void:
	if _tagline_label != null:
		_tagline_label.text = _t("TITLE_TAGLINE")
	if _settings_button != null:
		_settings_button.text = _t("TITLE_SETTINGS")
		_settings_button.tooltip_text = _t("TITLE_SETTINGS_TOOLTIP")
	if _continue_button != null:
		_continue_button.tooltip_text = _t("TITLE_CONTINUE_TOOLTIP")
	if _fresh_button != null:
		_fresh_button.text = _t("TITLE_CREATE_WORLD")
		_fresh_button.tooltip_text = _t("TITLE_CREATE_TOOLTIP")
	if _delete_button != null:
		_delete_button.tooltip_text = _t("TITLE_DELETE_TOOLTIP")
	if _delete_hint != null:
		_delete_hint.text = _t("TITLE_DELETE_HINT")
	if _autosave_note_label != null:
		_autosave_note_label.text = _t("TITLE_AUTOSAVE_NOTE")
	if _prev_button != null:
		_prev_button.tooltip_text = _t("TITLE_PREV_WORLD_TOOLTIP")
	if _next_button != null:
		_next_button.tooltip_text = _t("TITLE_NEXT_WORLD_TOOLTIP")
	if _new_seed_section_label != null:
		_new_seed_section_label.text = _t("TITLE_NEW_SEED_LABEL")
	if _new_seed_edit != null:
		_new_seed_edit.placeholder_text = _t("TITLE_SEED_PLACEHOLDER")
	if _random_seed_button != null:
		_random_seed_button.text = _t("TITLE_RANDOM")
		_random_seed_button.tooltip_text = _t("TITLE_RANDOM_TOOLTIP")
	if _kind_button != null:
		_kind_button.text = _t("TITLE_KIND_ISLAND")
		_kind_button.tooltip_text = _t("TITLE_KIND_ISLAND_TOOLTIP")
	# 含数值/随选择变化的文案（世界标签、统计卡片、保存状态、删除/继续按钮文案、种子预览）。
	_refresh_world_labels()
	_refresh_new_seed_preview()

# 自动加载单例 Locale 比本标题页存活更久：销毁时断开信号，避免悬空回调。
func _exit_tree() -> void:
	var l := _loc()
	if l != null and l.language_changed.is_connected(_retranslate):
		l.language_changed.disconnect(_retranslate)

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

# 仅测试用：直接设定世界类型（绕过 UI 勾选）。
func set_new_kind_for_test(kind: String) -> void:
	_new_kind = kind
	if _kind_button != null:
		_kind_button.set_pressed_no_signal(kind == "themed_island")
