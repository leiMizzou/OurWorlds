extends CanvasLayer
# 游戏内"联机"菜单：开服并游玩 / 加入(填地址)。环境变量启动已能联机，这是它的可点击等价物。
# UI 逻辑（开关、提交）可在 headless 下直接断言；视觉/交互由人工验收。
# 信号交给 Main：host_requested -> 把当前单机世界变成 Host；join_requested(url) -> 以客户端身份连过去。
#
# i18n：经 _loc()（/root/Locale 节点路径）访问 Locale 单例，而不是裸标识符 `Locale` ——
# 因为 GDScript 在 `godot --script` 编译被 preload 的脚本时不会注入 autoload 全局名。

signal host_requested()
signal join_requested(url: String)
signal login_requested()   # 打开登录界面（账号/云存档）

const DEFAULT_URL := "ws://127.0.0.1:8971"

var _root: Control
var _panel: PanelContainer
var _addr: LineEdit
var _open := false
# i18n：需在切换语言时重译的标签/按钮引用（_retranslate 逐项重设文案）。
var _title_label: Label
var _host_btn: Button
var _join_prompt_label: Label
var _join_btn: Button
var _login_btn: Button
var _hint_label: Label
var _loc_cached: Node               # 缓存的 Locale 自动加载单例（经 /root/Locale 取，见 _loc()）

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

	_title_label = Label.new()
	_title_label.text = _t("NETMENU_TITLE")
	_title_label.theme_type_variation = "H1"
	v.add_child(_title_label)

	_host_btn = Button.new()
	_host_btn.text = _t("NETMENU_HOST")
	_host_btn.pressed.connect(submit_host)
	v.add_child(_host_btn)

	_join_prompt_label = Label.new()
	_join_prompt_label.text = _t("NETMENU_JOIN_PROMPT")
	_join_prompt_label.theme_type_variation = "Caption"
	v.add_child(_join_prompt_label)

	_addr = LineEdit.new()
	_addr.text = DEFAULT_URL
	_addr.placeholder_text = DEFAULT_URL
	_addr.text_submitted.connect(func(_t): submit_join())
	v.add_child(_addr)

	_join_btn = Button.new()
	_join_btn.text = _t("NETMENU_JOIN")
	_join_btn.pressed.connect(submit_join)
	v.add_child(_join_btn)

	_login_btn = Button.new()
	_login_btn.text = _t("NETMENU_LOGIN")
	_login_btn.pressed.connect(func() -> void: close(); login_requested.emit())
	v.add_child(_login_btn)

	_hint_label = Label.new()
	_hint_label.text = _t("NETMENU_HINT")
	_hint_label.theme_type_variation = "Caption"
	v.add_child(_hint_label)

	_retranslate()
	# 语言切换时即时重译（菜单打开期间切换也能立刻生效）。
	var l := _loc()
	if l != null and not l.language_changed.is_connected(_retranslate):
		l.language_changed.connect(_retranslate)

# i18n：把全部静态文案按当前语言重设一遍。构建后调用一次，并接到
# _loc().language_changed —— 菜单打开期间切换语言也会立刻生效。
func _retranslate() -> void:
	if _title_label != null:
		_title_label.text = _t("NETMENU_TITLE")
	if _host_btn != null:
		_host_btn.text = _t("NETMENU_HOST")
	if _join_prompt_label != null:
		_join_prompt_label.text = _t("NETMENU_JOIN_PROMPT")
	if _join_btn != null:
		_join_btn.text = _t("NETMENU_JOIN")
	if _login_btn != null:
		_login_btn.text = _t("NETMENU_LOGIN")
	if _hint_label != null:
		_hint_label.text = _t("NETMENU_HINT")

# 自动加载单例 Locale 比本菜单存活更久：销毁时断开信号，避免悬空回调。
func _exit_tree() -> void:
	var l := _loc()
	if l != null and l.language_changed.is_connected(_retranslate):
		l.language_changed.disconnect(_retranslate)
