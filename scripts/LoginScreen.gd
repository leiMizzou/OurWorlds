extends CanvasLayer
# 登录界面：邮箱/密码 登录或注册（经 NakamaClient），或「游客进入」。
# 登录成功 → 拿到 session（token+user_id），交给 Main 用作"入场票"连世界服务器 + 云存档键。
# 游客 = 沿用现在的本地玩法（不需账号）。社交登录(Google/GitHub/Twitter)后续在此加按钮。
# UI 逻辑（提交/校验/信号）可无头单测（用 NakamaClient 桩）；视觉人工验。

signal logged_in(session: Dictionary)   # {token, refresh_token, created, user_id}
signal guest_chosen()

var nakama                              # NakamaClient（Main 注入）
var _root: Control
var _email: LineEdit
var _password: LineEdit
var _status: Label
var _open := false

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
		_set_status("请填写邮箱和密码")
		return
	if nakama == null:
		_set_status("账号服务未配置")
		return
	_set_status("注册中…" if create else "登录中…")
	nakama.authenticate_email(e, p, create)

func choose_guest() -> void:
	close()
	guest_chosen.emit()

func _on_authenticated(s: Dictionary) -> void:
	_set_status("已登录")
	close()
	logged_in.emit(s)

func _on_auth_failed(msg: String) -> void:
	_set_status("登录失败：" + msg)

func _set_status(text: String) -> void:
	if _status != null:
		_status.text = text

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

	var title := Label.new()
	title.text = "登录 OurWorlds"
	title.theme_type_variation = "H1"
	v.add_child(title)

	var hint := Label.new()
	hint.text = "登录可在任意设备续上你的世界与建造；也可直接以游客进入。"
	hint.theme_type_variation = "Caption"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(380, 0)
	v.add_child(hint)

	_email = LineEdit.new()
	_email.placeholder_text = "邮箱"
	v.add_child(_email)
	_password = LineEdit.new()
	_password.placeholder_text = "密码"
	_password.secret = true
	_password.text_submitted.connect(func(_t): submit(false))
	v.add_child(_password)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	var login_btn := Button.new()
	login_btn.text = "登录"
	login_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	login_btn.pressed.connect(func(): submit(false))
	row.add_child(login_btn)
	var reg_btn := Button.new()
	reg_btn.text = "注册"
	reg_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reg_btn.pressed.connect(func(): submit(true))
	row.add_child(reg_btn)

	var guest_btn := Button.new()
	guest_btn.text = "以游客进入"
	guest_btn.pressed.connect(choose_guest)
	v.add_child(guest_btn)

	_status = Label.new()
	_status.theme_type_variation = "Caption"
	_status.modulate = Color(1.0, 0.85, 0.6)
	v.add_child(_status)
