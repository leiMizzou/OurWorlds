extends CanvasLayer
# 登录界面：邮箱/密码 登录或注册（经 NakamaClient），或「游客进入」。
# 登录成功 → 拿到 session（token+user_id），交给 Main 用作"入场票"连世界服务器 + 云存档键。
# 游客 = 沿用现在的本地玩法（不需账号）。社交登录(Google/GitHub/Twitter)后续在此加按钮。
# UI 逻辑（提交/校验/信号）可无头单测（用 NakamaClient 桩）；视觉人工验。
#
# i18n：经 _loc()（/root/Locale 节点路径）访问 Locale 单例，而不是裸标识符 `Locale` ——
# 因为 GDScript 在 `godot --script` 编译被 preload 的脚本时不会注入 autoload 全局名。

signal logged_in(session: Dictionary)   # {token, refresh_token, created, user_id}
signal guest_chosen()

var nakama                              # NakamaClient（Main 注入）
var _root: Control
var _email: LineEdit
var _password: LineEdit
var _status: Label
var _open := false
# i18n：需在切换语言时重译的标签/按钮引用（_retranslate 逐项重设文案）。
var _title_label: Label
var _hint_label: Label
var _login_btn: Button
var _reg_btn: Button
var _guest_btn: Button
var _loc_cached: Node               # 缓存的 Locale 自动加载单例（经 /root/Locale 取，见 _loc()）

func setup(nakama_client) -> void:
	nakama = nakama_client
	if nakama != null:
		nakama.authenticated.connect(_on_authenticated)
		nakama.auth_failed.connect(_on_auth_failed)
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 70
	_build()
	close()

func is_open() -> bool:
	return _open

func open() -> void:
	_open = true
	visible = true
	_set_status("")
	if _email != null:
		_email.grab_focus()

func close() -> void:
	_open = false
	visible = false

func email() -> String:
	return _email.text if _email != null else ""

func set_credentials(e: String, p: String) -> void:   # 便于测试/预填
	if _email != null: _email.text = e
	if _password != null: _password.text = p

# 提交登录(create=false)或注册(create=true)。结果经 NakamaClient 信号回到 _on_authenticated/_on_auth_failed。
func submit(create: bool) -> void:
	var e := (_email.text if _email != null else "").strip_edges()
	var p := _password.text if _password != null else ""
	if e == "" or p == "":
		_set_status(_t("LOGIN_NEED_FIELDS"))
		return
	if nakama == null:
		_set_status(_t("LOGIN_NO_SERVICE"))
		return
	_set_status(_t("LOGIN_REGISTERING") if create else _t("LOGIN_SIGNING_IN"))
	nakama.authenticate_email(e, p, create)

func choose_guest() -> void:
	close()
	guest_chosen.emit()

func _on_authenticated(s: Dictionary) -> void:
	_set_status(_t("LOGIN_SUCCESS"))
	close()
	logged_in.emit(s)

func _on_auth_failed(msg: String) -> void:
	_set_status(_t("LOGIN_FAILED") % msg)

func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text

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

	var panel := PanelContainer.new()
	panel.anchor_left = 0.5; panel.anchor_right = 0.5
	panel.anchor_top = 0.5; panel.anchor_bottom = 0.5
	panel.offset_left = -210; panel.offset_right = 210
	panel.offset_top = -160; panel.offset_bottom = 160
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.06, 0.08, 0.94)
	sb.border_color = Color(1, 1, 1, 0.16)
	sb.set_border_width_all(1); sb.set_corner_radius_all(8); sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	_root.add_child(panel)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	panel.add_child(v)

	_title_label = Label.new()
	_title_label.text = _t("LOGIN_TITLE")
	_title_label.theme_type_variation = "H1"
	v.add_child(_title_label)

	_hint_label = Label.new()
	_hint_label.text = _t("LOGIN_HINT")
	_hint_label.theme_type_variation = "Caption"
	_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint_label.custom_minimum_size = Vector2(380, 0)
	v.add_child(_hint_label)

	_email = LineEdit.new()
	_email.placeholder_text = _t("LOGIN_EMAIL_PLACEHOLDER")
	v.add_child(_email)
	_password = LineEdit.new()
	_password.placeholder_text = _t("LOGIN_PASSWORD_PLACEHOLDER")
	_password.secret = true
	_password.text_submitted.connect(func(_t): submit(false))
	v.add_child(_password)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	_login_btn = Button.new()
	_login_btn.text = _t("LOGIN_SIGN_IN")
	_login_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_login_btn.pressed.connect(func(): submit(false))
	row.add_child(_login_btn)
	_reg_btn = Button.new()
	_reg_btn.text = _t("LOGIN_REGISTER")
	_reg_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reg_btn.pressed.connect(func(): submit(true))
	row.add_child(_reg_btn)

	_guest_btn = Button.new()
	_guest_btn.text = _t("LOGIN_GUEST")
	_guest_btn.pressed.connect(choose_guest)
	v.add_child(_guest_btn)

	_status = Label.new()
	_status.theme_type_variation = "Caption"
	_status.modulate = Color(1.0, 0.85, 0.6)
	v.add_child(_status)

	_retranslate()
	# 语言切换时即时重译（界面打开期间切换也能立刻生效）。
	var l := _loc()
	if l != null and not l.language_changed.is_connected(_retranslate):
		l.language_changed.connect(_retranslate)

# i18n：把全部静态文案按当前语言重设一遍。构建后调用一次，并接到
# _loc().language_changed —— 界面打开期间切换语言也会立刻生效。
# 注意：_status 是动态状态文案（登录中/失败等），由各回调按当前语言设置，不在此重译。
func _retranslate() -> void:
	if _title_label != null:
		_title_label.text = _t("LOGIN_TITLE")
	if _hint_label != null:
		_hint_label.text = _t("LOGIN_HINT")
	if _email != null:
		_email.placeholder_text = _t("LOGIN_EMAIL_PLACEHOLDER")
	if _password != null:
		_password.placeholder_text = _t("LOGIN_PASSWORD_PLACEHOLDER")
	if _login_btn != null:
		_login_btn.text = _t("LOGIN_SIGN_IN")
	if _reg_btn != null:
		_reg_btn.text = _t("LOGIN_REGISTER")
	if _guest_btn != null:
		_guest_btn.text = _t("LOGIN_GUEST")

# 自动加载单例 Locale 比本界面存活更久：销毁时断开信号，避免悬空回调。
func _exit_tree() -> void:
	var l := _loc()
	if l != null and l.language_changed.is_connected(_retranslate):
		l.language_changed.disconnect(_retranslate)
