extends CanvasLayer
# 创造模式材料库：展示全部可放置方块，点击后回到建造。
# i18n：面板 chrome（标题/关闭/最近/搜索框/分类提示/空状态）走 _loc()（/root/Locale 节点路径）双语化。
# 方块名、分类名（来自 BlockLibrary，属世界内容）与特性/用途标签（块描述，兼作中文搜索索引）保持中文不译。

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

signal block_selected(id: int)
signal close_requested

var lib: BlockLibrary
var _loc_cached: Node           # 缓存的 Locale 自动加载单例（经 /root/Locale 取，见 _loc()）
var _title_label: Label         # 面板标题（重译用）
var _close_button: Button       # 关闭按钮（重译用）
var _panel: PanelContainer
var _grid: GridContainer
var _search_edit: LineEdit
var _empty_label: Label
var _detail_icon: TextureRect
var _detail_name_label: Label
var _detail_meta_label: Label
var _detail_use_label: Label
var _buttons := {}
var _tab_buttons := {}
var _selected_id := BlockLibrary.GRASS
var _active_category := "all"
var _search_text := ""
var _recent_blocks := []
var _style_cell: StyleBoxFlat
var _style_selected: StyleBoxFlat
var _icon_cache := {}          # id -> Texture2D（2.5D 等距图标或回退的平面图集贴图）
var _atlas_img: Image          # 图集像素源（只读，用于合成等距图标）

# 常用方块的搜索别名：拼音首字母 + 英文名（grass/草/cao 互通）。
# 只“增加”可命中词，绝不移除既有语义词，避免破坏现有搜索断言。
const _BLOCK_ALIASES := {
	BlockLibrary.GRASS: "grass cao caofangkuai 草地 绿",
	BlockLibrary.DIRT: "dirt tu nitu 土",
	BlockLibrary.STONE: "stone shi shitou 岩",
	BlockLibrary.COBBLE: "cobble yuanshi 卵石 圆",
	BlockLibrary.LOG: "log wood mutou mu 原木 树干",
	BlockLibrary.PLANKS: "planks board muban 木板 板",
	BlockLibrary.SAND: "sand shazi sha 沙",
	BlockLibrary.GLASS: "glass boli 玻璃 窗",
	BlockLibrary.WATER: "water shui 水 海",
	BlockLibrary.LEAVES: "leaves shuye ye 叶 树叶",
	BlockLibrary.SNOW: "snow xue 雪 白",
	BlockLibrary.COAL_ORE: "coal meikuang mei 煤 煤炭",
	BlockLibrary.IRON_ORE: "iron tiekuang tie 铁 铁矿",
	BlockLibrary.BRICK: "brick zhuan zhuankuai 砖 红砖",
	BlockLibrary.MOSSY_STONE: "mossy taishi tai 苔 苔藓 古墙",
	BlockLibrary.BASALT: "basalt xuanwuyan xwy 玄武 黑",
	BlockLibrary.MARBLE: "marble dalishi dls 大理 白石",
	BlockLibrary.LANTERN: "lantern denglong deng 灯笼 灯",
	BlockLibrary.WILDFLOWER: "flower yehua hua 野花 花",
	BlockLibrary.TALL_GRASS: "grass caocong cong 草丛 草",
	BlockLibrary.PINE_LEAVES: "pine zhenye songye 针叶 松",
	BlockLibrary.COPPER_ORE: "copper tongkuang tong 铜 铜矿",
	BlockLibrary.RED_MUSHROOM: "mushroom hongmogu mogu gu 蘑菇 菌",
	BlockLibrary.REEDS: "reeds luwei lu 芦苇 苇",
	BlockLibrary.BLUE_CRYSTAL: "crystal lanjing jing 蓝晶 水晶",
	BlockLibrary.CLAY: "clay niantu nian 黏土 陶土",
	BlockLibrary.MOONSTONE_LAMP: "moonstone yueshideng yueshi deng 月石 月光",
	BlockLibrary.POLISHED_IRON: "polishediron jinglian tie 精炼铁 钢铁",
	BlockLibrary.COPPER_PANEL: "copperpanel tongmianban tong 铜面板 面板",
	BlockLibrary.STEEL_BLOCK: "steel gangkuai gang 钢 钢块",
	BlockLibrary.GOLD_TRIM: "gold liujin jin 鎏金 金 黄金",
	BlockLibrary.RED_SAND: "redsand hongsha sha 红沙 红砂",
	BlockLibrary.TERRACOTTA: "terracotta chitao tao 赤陶 陶",
	BlockLibrary.SUNSTONE: "sunstone nuanguangshi nuanguang 暖光石 暖光",
}

func setup(block_lib: BlockLibrary, recent_blocks: Array = []) -> void:
	lib = block_lib
	# 取图集像素源，用于合成 2.5D 等距方块图标（只读 BlockLibrary.atlas）。
	if lib != null and lib.atlas != null:
		_atlas_img = lib.atlas.get_image()
	_recent_blocks = _sanitize_recent(recent_blocks)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build()
	close()

func open(selected_id: int) -> void:
	_selected_id = selected_id
	_set_search_text("")
	_refresh_all()
	visible = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if _search_edit != null:
		_search_edit.grab_focus()
		_search_edit.select_all()

func close() -> void:
	visible = false

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

# i18n：重设面板 chrome 文案（标题/关闭/搜索框/最近页签/空状态/分类提示）。
# 方块名、分类名、特性与用途标签是内容/搜索索引，由 _refresh_all 在当前数据下重建即可。
func _retranslate() -> void:
	if _title_label != null:
		_title_label.text = _t("PALETTE_TITLE")
	if _close_button != null:
		_close_button.text = _t("PALETTE_CLOSE")
	if _empty_label != null:
		_empty_label.text = _t("PALETTE_EMPTY")
	if _search_edit != null:
		_search_edit.placeholder_text = _t("PALETTE_SEARCH_PLACEHOLDER")
		_search_edit.tooltip_text = _t("PALETTE_SEARCH_TOOLTIP")
	if _tab_buttons.has("recent") and is_instance_valid(_tab_buttons["recent"]):
		(_tab_buttons["recent"] as Button).text = _t("PALETTE_TAB_RECENT")
	for id in _tab_buttons.keys():
		var b: Button = _tab_buttons[id]
		if b != null and is_instance_valid(b):
			b.tooltip_text = _category_tooltip(String(id))
	_refresh_all()

# 自动加载单例 Locale 比本面板存活更久：销毁时断开信号，避免悬空回调。
func _exit_tree() -> void:
	if _loc_cached != null and is_instance_valid(_loc_cached) and _loc().language_changed.is_connected(_retranslate):
		_loc().language_changed.disconnect(_retranslate)

func _build() -> void:
	_style_cell = _panel_style(Color(0.06, 0.075, 0.08, 0.84), Color(1, 1, 1, 0.12), 1)
	_style_selected = _panel_style(Color(0.13, 0.12, 0.065, 0.94), Color(1.0, 0.82, 0.24, 0.88), 2)

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var dim := ColorRect.new()
	dim.color = Color(0.01, 0.018, 0.025, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -390
	_panel.offset_right = 390
	_panel.offset_top = -260
	_panel.offset_bottom = 260
	_panel.add_theme_stylebox_override("panel", _panel_style(Color(0.045, 0.058, 0.062, 0.96), Color(1, 1, 1, 0.15), 1))
	root.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 24)
	margin.add_theme_constant_override("margin_right", 24)
	margin.add_theme_constant_override("margin_top", 22)
	margin.add_theme_constant_override("margin_bottom", 22)
	_panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	box.add_child(header)

	_title_label = Label.new()
	_title_label.text = _t("PALETTE_TITLE")
	_title_label.add_theme_font_size_override("font_size", 28)
	_title_label.modulate = Color(1, 1, 1, 0.97)
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title_label)

	header.add_child(_build_detail_panel())

	_close_button = _top_button(_t("PALETTE_CLOSE"))
	_close_button.pressed.connect(func(): close_requested.emit())
	header.add_child(_close_button)

	box.add_child(_build_tabs())
	box.add_child(_build_search())

	_grid = GridContainer.new()
	_grid.columns = 6
	_grid.add_theme_constant_override("h_separation", 8)
	_grid.add_theme_constant_override("v_separation", 8)
	box.add_child(_grid)

	for id in lib.creative_blocks():
		var cell := _block_cell(id)
		_grid.add_child(cell)

	_empty_label = Label.new()
	_empty_label.text = _t("PALETTE_EMPTY")
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", 15)
	_empty_label.modulate = Color(0.82, 0.88, 0.92, 0.68)
	_empty_label.visible = false
	box.add_child(_empty_label)
	_refresh_all()

	# 语言切换时即时重译（材料库打开期间切换也立刻生效）。
	if not _loc().language_changed.is_connected(_retranslate):
		_loc().language_changed.connect(_retranslate)

func _build_detail_panel() -> Control:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(286, 72)
	panel.add_theme_stylebox_override("panel", _panel_style(Color(0.03, 0.045, 0.048, 0.82), Color(1.0, 0.82, 0.24, 0.18), 1))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 7)
	margin.add_theme_constant_override("margin_bottom", 7)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	margin.add_child(row)

	_detail_icon = TextureRect.new()
	_detail_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_detail_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_detail_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_detail_icon.custom_minimum_size = Vector2(46, 46)
	_detail_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_detail_icon)

	var text_box := VBoxContainer.new()
	text_box.add_theme_constant_override("separation", 1)
	text_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text_box)

	_detail_name_label = Label.new()
	_detail_name_label.add_theme_font_size_override("font_size", 16)
	_detail_name_label.modulate = Color(1.0, 0.96, 0.78, 0.96)
	_detail_name_label.clip_text = true
	text_box.add_child(_detail_name_label)

	_detail_meta_label = Label.new()
	_detail_meta_label.add_theme_font_size_override("font_size", 12)
	_detail_meta_label.modulate = Color(0.84, 0.92, 0.96, 0.70)
	_detail_meta_label.clip_text = true
	text_box.add_child(_detail_meta_label)

	_detail_use_label = Label.new()
	_detail_use_label.add_theme_font_size_override("font_size", 12)
	_detail_use_label.modulate = Color(0.66, 0.86, 1.0, 0.72)
	_detail_use_label.clip_text = true
	text_box.add_child(_detail_use_label)
	return panel

func _build_tabs() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var recent := _tab_button(_t("PALETTE_TAB_RECENT"), "recent")
	row.add_child(recent)
	for cat in lib.creative_categories():
		var meta: Dictionary = cat
		row.add_child(_tab_button(String(meta.get("name", "")), String(meta.get("id", "all"))))
	return row

func _tab_button(label: String, id: String) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(72, 34)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = _category_tooltip(id)
	b.add_theme_font_size_override("font_size", 14)
	b.pressed.connect(func(): _select_category(id))
	_tab_buttons[id] = b
	return b

func _category_tooltip(id: String) -> String:
	match id:
		"recent":
			return _t("PALETTE_TOOLTIP_RECENT")
		"all":
			return _t("PALETTE_TOOLTIP_ALL")
		"terrain":
			return _t("PALETTE_TOOLTIP_TERRAIN")
		"building":
			return _t("PALETTE_TOOLTIP_BUILDING")
		"nature":
			return _t("PALETTE_TOOLTIP_NATURE")
		"decor":
			return _t("PALETTE_TOOLTIP_DECOR")
		"ores":
			return _t("PALETTE_TOOLTIP_ORES")
		_:
			return _t("PALETTE_TOOLTIP_DEFAULT")

func _build_search() -> Control:
	_search_edit = LineEdit.new()
	_search_edit.placeholder_text = _t("PALETTE_SEARCH_PLACEHOLDER")
	_search_edit.clear_button_enabled = true
	_search_edit.custom_minimum_size = Vector2(0, 36)
	_search_edit.tooltip_text = _t("PALETTE_SEARCH_TOOLTIP")
	_search_edit.add_theme_font_size_override("font_size", 15)
	_search_edit.text_changed.connect(_on_search_changed)
	_search_edit.text_submitted.connect(_on_search_submitted)
	return _search_edit

func _block_cell(id: int) -> Control:
	var root := Control.new()
	root.custom_minimum_size = Vector2(114, 66)

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.add_theme_stylebox_override("panel", _style_cell)
	root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 9)
	margin.add_theme_constant_override("margin_bottom", 9)
	panel.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 9)
	margin.add_child(row)

	var icon := TextureRect.new()
	icon.texture = _block_icon(id)
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.custom_minimum_size = Vector2(40, 40)
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)

	var label := Label.new()
	label.text = lib.block_name(id)
	label.add_theme_font_size_override("font_size", 14)
	label.modulate = Color(0.92, 0.96, 1.0, 0.92)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)

	var hit := Button.new()
	hit.set_anchors_preset(Control.PRESET_FULL_RECT)
	hit.focus_mode = Control.FOCUS_NONE
	hit.flat = true
	# 悬停提示用途，提升可发现性（命中按钮在最上层，承载 tooltip）。
	hit.tooltip_text = "%s　·　%s" % [lib.block_name(id), _block_use_label(id)]
	hit.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	hit.add_theme_stylebox_override("hover", StyleBoxEmpty.new())
	hit.add_theme_stylebox_override("pressed", StyleBoxEmpty.new())
	hit.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	hit.pressed.connect(func(): _select_block(id))
	root.add_child(hit)

	_buttons[id] = {"root": root, "panel": panel}
	return root

func _top_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(86, 36)
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", 15)
	return b

func _select_block(id: int) -> void:
	_selected_id = id
	_remember_recent(id)
	_refresh_all()
	block_selected.emit(id)

func set_recent_blocks(blocks: Array) -> void:
	_recent_blocks = _sanitize_recent(blocks)
	if _active_category == "recent" and _recent_blocks.is_empty():
		_active_category = "all"
	_refresh_all()

func recent_blocks() -> Array:
	return _recent_blocks.duplicate()

func _select_category(id: String) -> void:
	if id == "recent" and _recent_blocks.is_empty():
		return
	_active_category = id
	_refresh_all()

func _on_search_changed(text: String) -> void:
	_set_search_text(text)
	_refresh_all()

func _on_search_submitted(text: String) -> void:
	_set_search_text(text)
	_refresh_all()
	request_confirm_selection()

func select_first_visible_block() -> bool:
	var blocks := _visible_blocks()
	if blocks.is_empty():
		return false
	_select_block(int(blocks[0]))
	return true

func _set_search_text(text: String) -> void:
	_search_text = text.strip_edges().to_lower()
	if _search_edit != null and _search_edit.text != text:
		_search_edit.text = text

func _refresh_all() -> void:
	_refresh_tabs()
	_sync_selection_to_visible()
	_refresh_filter()
	_refresh_selected()
	_refresh_detail()

func handle_palette_key(keycode: int) -> bool:
	match keycode:
		KEY_LEFT:
			return request_move_selection(-1)
		KEY_RIGHT:
			return request_move_selection(1)
		KEY_UP:
			return request_move_selection(-_grid_columns())
		KEY_DOWN:
			return request_move_selection(_grid_columns())
		KEY_PAGEUP:
			return request_move_selection(-_grid_columns() * 2)
		KEY_PAGEDOWN:
			return request_move_selection(_grid_columns() * 2)
		KEY_HOME:
			return request_move_selection_to_edge(true)
		KEY_END:
			return request_move_selection_to_edge(false)
		KEY_TAB:
			return cycle_category(1)
		KEY_ENTER, KEY_KP_ENTER:
			return request_confirm_selection()
	return false

# Tab 在分类页签间循环（搜索态下无意义则不处理），方便纯键盘浏览。
func cycle_category(delta: int) -> bool:
	if _search_text != "" or _tab_buttons.is_empty():
		return false
	var ids := _selectable_category_ids()
	if ids.is_empty():
		return false
	var idx := ids.find(_active_category)
	if idx < 0:
		idx = 0
	_select_category(String(ids[posmod(idx + delta, ids.size())]))
	return true

func _selectable_category_ids() -> Array:
	var ids := []
	# 最近页只有在有最近材料时可选。
	if not _recent_blocks.is_empty():
		ids.append("recent")
	for cat in lib.creative_categories():
		var meta: Dictionary = cat
		ids.append(String(meta.get("id", "all")))
	return ids

func request_move_selection(delta: int) -> bool:
	var blocks := _visible_blocks()
	if blocks.is_empty() or delta == 0:
		return false
	var index := blocks.find(_selected_id)
	if index < 0:
		index = 0
	else:
		index = posmod(index + delta, blocks.size())
	_selected_id = int(blocks[index])
	_refresh_selected()
	_refresh_detail()
	return true

func request_move_selection_to_edge(first: bool) -> bool:
	var blocks := _visible_blocks()
	if blocks.is_empty():
		return false
	_selected_id = int(blocks[0 if first else blocks.size() - 1])
	_refresh_selected()
	_refresh_detail()
	return true

func request_confirm_selection() -> bool:
	var blocks := _visible_blocks()
	if blocks.is_empty():
		return false
	if not blocks.has(_selected_id):
		_selected_id = int(blocks[0])
	_select_block(_selected_id)
	return true

func _refresh_tabs() -> void:
	for id in _tab_buttons.keys():
		var b: Button = _tab_buttons[id]
		var active := String(id) == _active_category
		b.disabled = String(id) == "recent" and _recent_blocks.is_empty()
		b.modulate = Color(1.0, 0.88, 0.30, 1.0) if active else Color(1, 1, 1, 0.78)

func _refresh_filter() -> void:
	var visible_blocks := _visible_blocks()
	var visible_count := 0
	for id in _buttons.keys():
		var entry: Dictionary = _buttons[id]
		var root: Control = entry["root"]
		var show := visible_blocks.has(int(id))
		root.visible = show
		if show:
			visible_count += 1
	if _empty_label != null:
		_empty_label.visible = visible_count == 0

func _refresh_selected() -> void:
	for id in _buttons.keys():
		var entry: Dictionary = _buttons[id]
		var root: Control = entry["root"]
		var panel: PanelContainer = entry["panel"]
		var selected := int(id) == _selected_id
		panel.add_theme_stylebox_override("panel", _style_selected if selected else _style_cell)
		root.modulate = Color(1, 0.96, 0.68, 1) if selected else Color(1, 1, 1, 0.88)

func _refresh_detail() -> void:
	if lib == null or _detail_icon == null or _detail_name_label == null or _detail_meta_label == null or _detail_use_label == null:
		return
	_detail_icon.texture = _block_icon(_selected_id)
	_detail_name_label.text = lib.block_name(_selected_id)
	_detail_meta_label.text = "%s · %s · #%d · %s" % [_category_label_for(_selected_id), _block_traits_label(_selected_id), _selected_id, _selection_position_label()]
	_detail_use_label.text = _block_use_label(_selected_id)

func _sync_selection_to_visible() -> void:
	var blocks := _visible_blocks()
	if blocks.is_empty() or blocks.has(_selected_id):
		return
	_selected_id = int(blocks[0])

func _selection_position_label() -> String:
	var blocks := _visible_blocks()
	var total := blocks.size()
	if total <= 0:
		return "0/0"
	var index := blocks.find(_selected_id)
	if index < 0:
		index = 0
	return "%d/%d" % [index + 1, total]

func _grid_columns() -> int:
	return maxi(1, _grid.columns if _grid != null else 6)

func _visible_blocks() -> Array:
	var blocks := []
	if _search_text != "":
		blocks = lib.creative_blocks()
	elif _active_category == "recent":
		blocks = _recent_blocks.duplicate()
	else:
		blocks = lib.creative_category_blocks(_active_category)
	if _search_text == "":
		return blocks
	var filtered := []
	for raw in blocks:
		var id := int(raw)
		if _block_matches_search(id):
			filtered.append(id)
	return filtered

func _block_matches_search(id: int) -> bool:
	var q := _search_text
	if q == "":
		return true
	var haystack := "%s %s %s #%d" % [
		lib.block_name(id).to_lower(),
		_category_label_for(id).to_lower(),
		_block_search_terms(id).to_lower(),
		id,
	]
	return haystack.contains(q)

func _category_label_for(id: int) -> String:
	var labels := PackedStringArray()
	for raw in lib.creative_categories():
		var cat: Dictionary = raw
		var cid := String(cat.get("id", ""))
		if cid == "all":
			continue
		var blocks: Array = cat.get("blocks", [])
		if blocks.has(id):
			labels.append(String(cat.get("name", "")))
		if labels.size() >= 2:
			break
	if labels.is_empty():
		return _t("PALETTE_BLOCK_FALLBACK")
	return " / ".join(labels)

func _block_traits_label(id: int) -> String:
	return " / ".join(_block_trait_terms(id))

func _block_trait_terms(id: int) -> PackedStringArray:
	var tags := PackedStringArray()
	if id == BlockLibrary.LANTERN or id == BlockLibrary.MOONSTONE_LAMP or id == BlockLibrary.BLUE_CRYSTAL:
		tags.append("发光")
	if lib.is_water(id):
		tags.append("流体")
	elif not lib.is_solid(id):
		tags.append("装饰")
	elif lib.is_transparent(id):
		tags.append("透明")
	else:
		tags.append("实体")
	if id == BlockLibrary.COAL_ORE or id == BlockLibrary.IRON_ORE or id == BlockLibrary.COPPER_ORE:
		tags.append("矿物")
	if id == BlockLibrary.WILDFLOWER or id == BlockLibrary.TALL_GRASS or id == BlockLibrary.RED_MUSHROOM or id == BlockLibrary.REEDS:
		tags.append("植物")
	if id == BlockLibrary.BLUE_CRYSTAL:
		tags.append("晶体")
	return tags

func _block_use_label(id: int) -> String:
	match id:
		BlockLibrary.GRASS, BlockLibrary.DIRT, BlockLibrary.SAND, BlockLibrary.SNOW, BlockLibrary.CLAY:
			return "适合地形塑形与自然过渡"
		BlockLibrary.STONE, BlockLibrary.COBBLE, BlockLibrary.MOSSY_STONE, BlockLibrary.BASALT, BlockLibrary.MARBLE:
			return "适合山体、遗迹和结构骨架"
		BlockLibrary.BRICK, BlockLibrary.LOG, BlockLibrary.PLANKS, BlockLibrary.GLASS:
			return "适合建筑外立面和室内细节"
		BlockLibrary.LANTERN, BlockLibrary.MOONSTONE_LAMP:
			return "适合夜景照明、路标和营火焦点"
		BlockLibrary.WILDFLOWER, BlockLibrary.TALL_GRASS, BlockLibrary.RED_MUSHROOM, BlockLibrary.REEDS, BlockLibrary.LEAVES, BlockLibrary.PINE_LEAVES:
			return "适合植被层次和地表装饰"
		BlockLibrary.BLUE_CRYSTAL:
			return "适合晶洞、冷光装饰和神秘焦点"
		BlockLibrary.COAL_ORE, BlockLibrary.IRON_ORE, BlockLibrary.COPPER_ORE:
			return "适合矿脉、洞穴资源和工业细节"
		BlockLibrary.WATER:
			return "适合水景、浅湾和泉池"
		_:
			return "适合自由建造"

func _block_search_terms(id: int) -> String:
	var terms := _block_trait_terms(id)
	terms.append(_block_use_label(id))
	match id:
		BlockLibrary.LANTERN, BlockLibrary.MOONSTONE_LAMP:
			terms.append("灯")
			terms.append("夜景")
			terms.append("照明")
		BlockLibrary.BLUE_CRYSTAL:
			terms.append("蓝晶")
			terms.append("晶洞")
			terms.append("冷光")
		BlockLibrary.WATER, BlockLibrary.REEDS, BlockLibrary.CLAY:
			terms.append("水景")
			terms.append("湿地")
		BlockLibrary.WILDFLOWER, BlockLibrary.TALL_GRASS, BlockLibrary.RED_MUSHROOM, BlockLibrary.REEDS, BlockLibrary.LEAVES, BlockLibrary.PINE_LEAVES:
			terms.append("植物")
			terms.append("自然")
		BlockLibrary.COAL_ORE, BlockLibrary.IRON_ORE, BlockLibrary.COPPER_ORE:
			terms.append("资源")
			terms.append("矿脉")
		BlockLibrary.BRICK, BlockLibrary.LOG, BlockLibrary.PLANKS, BlockLibrary.GLASS:
			terms.append("建筑")
		BlockLibrary.STONE, BlockLibrary.COBBLE, BlockLibrary.MOSSY_STONE, BlockLibrary.BASALT, BlockLibrary.MARBLE:
			terms.append("结构")
			terms.append("遗迹")
	# 拼音首字母 + 英文别名（grass/草/cao 互通），只扩大可命中范围。
	if _BLOCK_ALIASES.has(id):
		terms.append(String(_BLOCK_ALIASES[id]))
	return " ".join(terms)

func _remember_recent(id: int) -> void:
	if not lib.has_def(id) or not lib.is_renderable(id):
		return
	_recent_blocks.erase(id)
	_recent_blocks.push_front(id)
	while _recent_blocks.size() > 8:
		_recent_blocks.pop_back()

func _sanitize_recent(blocks: Array) -> Array:
	var out := []
	for raw in blocks:
		var id := int(raw)
		if not lib.has_def(id) or not lib.is_renderable(id) or out.has(id):
			continue
		out.append(id)
		if out.size() >= 8:
			break
	return out

# 平面图集贴图（侧面 tile），用于植物/流体/透明块等不适合做立方体的图标，也是合成失败时的兜底。
func _icon(id: int) -> AtlasTexture:
	var at := AtlasTexture.new()
	at.atlas = lib.atlas
	var tile: int = lib.tile_for(id, 0)
	var col := tile % BlockLibrary.ATLAS_COLS
	var row := tile / BlockLibrary.ATLAS_COLS
	at.region = Rect2(col * BlockLibrary.TILE, row * BlockLibrary.TILE, BlockLibrary.TILE, BlockLibrary.TILE)
	return at

# 对外图标：优先 2.5D 等距立方体（提升辨识度），不适合立方体的回退平面贴图。带缓存。
func _block_icon(id: int) -> Texture2D:
	if _icon_cache.has(id):
		return _icon_cache[id]
	var tex: Texture2D
	if _use_iso_icon(id):
		tex = _build_iso_icon(id)
	if tex == null:
		tex = _icon(id)
	_icon_cache[id] = tex
	return tex

# 实心不透明方块才做等距立方体；植物/水/玻璃/灯笼等透明或非实心的用平面贴图更清楚。
func _use_iso_icon(id: int) -> bool:
	if _atlas_img == null or lib == null:
		return false
	return lib.is_solid(id) and not lib.is_transparent(id)

# 从图集某 tile 双线性采样一个像素（uv ∈ [0,1]），用于把方块贴图“贴”到等距面上。
func _sample_tile(tile: int, u: float, v: float) -> Color:
	var col := tile % BlockLibrary.ATLAS_COLS
	var row := tile / BlockLibrary.ATLAS_COLS
	var fx := clampf(u, 0.0, 0.999) * float(BlockLibrary.TILE)
	var fy := clampf(v, 0.0, 0.999) * float(BlockLibrary.TILE)
	var px := col * BlockLibrary.TILE + int(fx)
	var py := row * BlockLibrary.TILE + int(fy)
	return _atlas_img.get_pixel(px, py)

# 合成一个 2.5D 等距立方体图标：顶面菱形 + 左右两侧面，三面各取对应 tile 并施加方向光明暗。
func _build_iso_icon(id: int) -> Texture2D:
	var top_tile: int = lib.tile_for(id, 1)
	var side_tile: int = lib.tile_for(id, 0)
	var size := 40
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	# 立方体几何（等距 2:1）。顶面是菱形，左右各一个平行四边形侧面。
	var cx := 20.0
	var hw := 17.0          # 顶面水平半宽
	var hh := 8.5           # 顶面垂直半高（≈ hw/2，标准等距）
	var top_y := 3.0        # 顶点 y
	var mid_y := top_y + hh * 2.0   # 顶面下沿中心 y（也是两侧面顶部）
	var sh := 16.0          # 侧面竖直高度

	# 三面明暗：顶面最亮、右面中、左面暗（模拟左上方向光）。
	var top_lift := 1.12
	var right_lift := 0.86
	var left_lift := 0.66

	for y in range(size):
		for x in range(size):
			var fx := float(x)
			var fy := float(y)
			var dx := fx - cx
			# --- 顶面菱形：|dx|/hw + |fy-? |/hh <= 1 围绕中心 (cx, top_y+hh) ---
			var top_cy := top_y + hh
			var tn := absf(dx) / hw + absf(fy - top_cy) / hh
			if tn <= 1.0 and fy <= mid_y:
				# 菱形局部 uv：沿两条等距轴展开
				var u := 0.5 + (dx / hw + (fy - top_cy) / hh) * 0.5
				var v := 0.5 + (-dx / hw + (fy - top_cy) / hh) * 0.5
				img.set_pixel(x, y, _shade_mul(_sample_tile(top_tile, u, v), top_lift))
				continue
			# --- 侧面：x<cx 为左面，x>=cx 为右面 ---
			if fy >= mid_y - 0.5:
				if dx < 0.0:
					# 左面平行四边形：顶沿从 (cx-hw, mid_y) 斜向下到 (cx, mid_y+hh) ……用 u=横向占比
					var u_l := clampf((fx - (cx - hw)) / hw, 0.0, 1.0)
					# 该列侧面顶部 y 随 u 线性：左端 mid_y、右端(贴中线) mid_y+hh
					var top_edge_l := mid_y + u_l * hh
					var bot_edge_l := top_edge_l + sh
					if fy >= top_edge_l and fy <= bot_edge_l:
						var v_l := (fy - top_edge_l) / sh
						img.set_pixel(x, y, _shade_mul(_sample_tile(side_tile, u_l, v_l), left_lift))
						continue
				else:
					var u_r := clampf((fx - cx) / hw, 0.0, 1.0)
					var top_edge_r := mid_y + (1.0 - u_r) * hh
					var bot_edge_r := top_edge_r + sh
					if fy >= top_edge_r and fy <= bot_edge_r:
						var v_r := (fy - top_edge_r) / sh
						img.set_pixel(x, y, _shade_mul(_sample_tile(side_tile, u_r, v_r), right_lift))
						continue
	return ImageTexture.create_from_image(img)

func _shade_mul(c: Color, f: float) -> Color:
	return Color(clampf(c.r * f, 0, 1), clampf(c.g * f, 0, 1), clampf(c.b * f, 0, 1), c.a)

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
