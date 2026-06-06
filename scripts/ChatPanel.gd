extends CanvasLayer
# ChatPanel —— 游戏内大厅 / 私聊面板：左侧在线列表，右侧频道标题 + 消息流 + 输入框。
# 数据来自 ChatHub（Main 注入）。Main 用 Enter 打开本面板；面板内 LineEdit Enter 发送。
# 纯读 ChatHub，所以 presence_names()/rendered_log() 等可在 headless 下直接断言。

signal visit_requested(target_id: String)   # 在线列表点"前往" → Main 把玩家传送到该玩家旁

var chat_hub
var player_id := "player"
var current_channel := ""            # "" = 公共大厅；否则 = 私聊对象 entity id

var _root: Control
var _panel: PanelContainer
var _presence_box: VBoxContainer
var _channel_label: Label
var _log_label: RichTextLabel
var _input: LineEdit
var _open := false

func setup(hub, p_id: String) -> void:
	chat_hub = hub
	player_id = p_id
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 50
	_build()
	if chat_hub != null:
		chat_hub.message_posted.connect(_on_message_posted)
		chat_hub.presence_changed.connect(_on_presence_changed)
	_refresh()
	close()

# ---------- 公共 API（Main / 测试用）----------

func is_open() -> bool:
	return _open

func open() -> void:
	_open = true
	visible = true
	_refresh()
	if _input != null:
		_input.grab_focus()

func close() -> void:
	_open = false
	visible = false

func toggle() -> void:
	if _open:
		close()
	else:
		open()

func set_channel(target_id: String) -> void:
	current_channel = target_id
	_refresh()

func presence_names() -> Array:
	var out := []
	if chat_hub != null:
		for e in chat_hub.entities():
			out.append(str(e["name"]))
	return out

func rendered_log() -> String:
	if chat_hub == null:
		return ""
	var msgs: Array = (chat_hub.lobby_recent(50) if current_channel == ""
		else chat_hub.thread(player_id, current_channel, 50))
	var lines := []
	for m in msgs:
		lines.append("%s: %s" % [_name_of(str(m["from"])), str(m["text"])])
	return "\n".join(lines)

func submit_text(text: String) -> void:
	text = text.strip_edges()
	if text == "" or chat_hub == null:
		return
	chat_hub.post(player_id, current_channel, text)

# ---------- 内部 ----------

func _on_input_submitted(text: String) -> void:
	submit_text(text)
	if _input != null:
		_input.clear()

func _on_message_posted(_msg: Dictionary) -> void:
	if _open:
		_refresh_log()

func _on_presence_changed() -> void:
	if _open:
		_refresh_presence()

func _refresh() -> void:
	_refresh_presence()
	_refresh_log()

func _refresh_presence() -> void:
	if _presence_box == null or chat_hub == null:
		return
	for c in _presence_box.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = "在线"
	_presence_box.add_child(title)
	for e in chat_hub.entities():
		var eid := str(e["id"])
		var icon := "🧑" if str(e["kind"]) == "human" else "🤖"
		var status := str(e.get("status", ""))
		var row := HBoxContainer.new()
		var btn := Button.new()
		btn.text = "%s %s%s" % [icon, str(e["name"]), ("  ·  " + status if status != "" else "")]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var target := "" if eid == player_id else eid    # 点名字：自己=回大厅，别人=私聊
		btn.pressed.connect(func() -> void: set_channel(target))
		row.add_child(btn)
		if eid != player_id:                              # 别人：加「前往」按钮，传送过去参观
			var go := Button.new()
			go.text = "前往"
			go.tooltip_text = "传送到 ta 旁边参观"
			go.pressed.connect(func() -> void: visit_requested.emit(eid))
			row.add_child(go)
		_presence_box.add_child(row)

func _refresh_log() -> void:
	if _channel_label != null:
		_channel_label.text = "# 大厅" if current_channel == "" else "私聊 · " + _name_of(current_channel)
	if _log_label != null:
		_log_label.text = rendered_log()

func _name_of(id: String) -> String:
	if chat_hub != null:
		for e in chat_hub.entities():
			if str(e["id"]) == id:
				return str(e["name"])
	return id

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 1.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -380
	_panel.offset_right = 380
	_panel.offset_top = -320
	_panel.offset_bottom = -28
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.08, 0.86)
	sb.border_color = Color(1, 1, 1, 0.16)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", sb)
	_root.add_child(_panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	_panel.add_child(hbox)

	_presence_box = VBoxContainer.new()
	_presence_box.custom_minimum_size = Vector2(170, 0)
	hbox.add_child(_presence_box)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(right)

	_channel_label = Label.new()
	_channel_label.theme_type_variation = "H2"
	right.add_child(_channel_label)

	_log_label = RichTextLabel.new()
	_log_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_label.custom_minimum_size = Vector2(520, 230)
	_log_label.scroll_following = true
	right.add_child(_log_label)

	_input = LineEdit.new()
	_input.placeholder_text = "说点什么…（Enter 发送，Esc 关闭）"
	_input.text_submitted.connect(_on_input_submitted)
	right.add_child(_input)
