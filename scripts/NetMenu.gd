extends CanvasLayer
# 游戏内"联机"菜单：开服并游玩 / 加入(填地址)。环境变量启动已能联机，这是它的可点击等价物。
# UI 逻辑（开关、提交）可在 headless 下直接断言；视觉/交互由人工验收。
# 信号交给 Main：host_requested -> 把当前单机世界变成 Host；join_requested(url) -> 以客户端身份连过去。

signal host_requested()
signal join_requested(url: String)
signal login_requested()   # 打开登录界面（账号/云存档）

const DEFAULT_URL := "ws://127.0.0.1:8971"

var _root: Control
var _panel: PanelContainer
var _addr: LineEdit
var _open := false

func setup() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 60
	_build()
	close()

func is_open() -> bool:
	return _open

func open() -> void:
	_open = true
	visible = true
	if _addr != null and _addr.is_inside_tree():
		_addr.grab_focus()

func close() -> void:
	_open = false
	visible = false

func toggle() -> void:
	if _open: close()
	else: open()

func set_address(url: String) -> void:
	if _addr != null:
		_addr.text = url

func address() -> String:
	return _addr.text if _addr != null else DEFAULT_URL

func submit_host() -> void:
	close()
	host_requested.emit()

func submit_join() -> void:
	var url := address().strip_edges()
	if url == "":
		url = DEFAULT_URL
	close()
	join_requested.emit(url)

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	_panel = PanelContainer.new()
	_panel.anchor_left = 0.5; _panel.anchor_right = 0.5
	_panel.anchor_top = 0.5; _panel.anchor_bottom = 0.5
	_panel.offset_left = -220; _panel.offset_right = 220
	_panel.offset_top = -130; _panel.offset_bottom = 130
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.08, 0.92)
	sb.border_color = Color(1, 1, 1, 0.16)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(18)
	_panel.add_theme_stylebox_override("panel", sb)
	_root.add_child(_panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	_panel.add_child(v)

	var title := Label.new()
	title.text = "联机"
	title.theme_type_variation = "H1"
	v.add_child(title)

	var host_btn := Button.new()
	host_btn.text = "开服并游玩（让别人加入我）"
	host_btn.pressed.connect(submit_host)
	v.add_child(host_btn)

	var sep := Label.new()
	sep.text = "或加入某个地址："
	sep.theme_type_variation = "Caption"
	v.add_child(sep)

	_addr = LineEdit.new()
	_addr.text = DEFAULT_URL
	_addr.placeholder_text = DEFAULT_URL
	_addr.text_submitted.connect(func(_t): submit_join())
	v.add_child(_addr)

	var join_btn := Button.new()
	join_btn.text = "加入"
	join_btn.pressed.connect(submit_join)
	v.add_child(join_btn)

	var login_btn := Button.new()
	login_btn.text = "登录 / 账号（云存档）"
	login_btn.pressed.connect(func() -> void: close(); login_requested.emit())
	v.add_child(login_btn)

	var hint := Label.new()
	hint.text = "N 开关此菜单 · Esc 关闭"
	hint.theme_type_variation = "Caption"
	v.add_child(hint)
