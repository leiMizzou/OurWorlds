extends Node3D
# 联机里"别人"的身体：方块小人 + 头顶名牌 + 朝网络目标平滑插值（区别于 AgentAvatar 的瞬移）。
# 位置/朝向由 NetworkManager 的玩家快照驱动（set_net_target）。每个玩家一个不同的工装色。
# 与 AgentAvatar 一致：作为 world 的子节点（world 在原点），用 global_position 移动。

const LERP_POS := 10.0             # 位置插值速率（越大越跟手；localhost 用大值几乎贴目标）
const LERP_YAW := 12.0

var _rig: Node3D
var _label: Label3D
var _target_pos := Vector3.ZERO
var _target_yaw := 0.0
var _color := Color(0.30, 0.62, 1.00)   # 默认蓝工装；set_color 可改（未设 look 时生效）
var _look: Dictionary = {}               # 由 eid 派生的"长相"（AvatarLook.look_for）；空则走默认造型
var _pending_label := ""                 # _ready 前设的名字，建好名牌后回填

func _ready() -> void:
	_rig = Node3D.new()
	add_child(_rig)
	_build_body(_rig)
	_build_nameplate()
	_target_pos = global_position

func set_label(text: String) -> void:
	if _label == null:
		_pending_label = text
	else:
		_label.text = text

func label_text() -> String:
	if _label != null:
		return _label.text
	return _pending_label

func set_color(c: Color) -> void:
	_color = c

# 设置由身份派生的"长相"。_ready 前设则进树时按它造；已建好身体则就地重建（先后调用都生效）。
func set_look(look: Dictionary) -> void:
	_look = look
	if _rig != null:
		for ch in _rig.get_children():
			ch.queue_free()
		_build_body(_rig)

func set_net_target(pos: Vector3, yaw: float) -> void:
	_target_pos = pos
	_target_yaw = yaw

func _process(delta: float) -> void:
	_net_step(delta)

# 纯插值步进（测试直接调用；要求节点已进树，global_position 才有效）：朝目标平滑移动 + 转向。
func _net_step(delta: float) -> void:
	var t := clampf(LERP_POS * delta, 0.0, 1.0)
	global_position = global_position.lerp(_target_pos, t)
	var ty := clampf(LERP_YAW * delta, 0.0, 1.0)
	rotation.y = lerp_angle(rotation.y, _target_yaw, ty)

# ---------- 造型（仿 AgentAvatar；按 _look 派生配色/发型/体型/配件，空则走默认）----------
# 头=skin；身体+手臂=jacket（一臂用 accent 做点缀）；腿=pants；按 hair_style 加头发、
# 按 build 调整身体/腿的宽窄与站姿、按 accessory 加安全帽/天线/护目镜。
func _build_body(rootn: Node3D) -> void:
	var skin: Color = _look.get("skin", Color(0.85, 0.66, 0.50))
	var jacket: Color = _look.get("jacket", _color)      # 未设 look 时沿用 set_color/_color
	var accent: Color = _look.get("accent", jacket)
	var pants: Color = _look.get("pants", Color(0.20, 0.22, 0.28))
	var hair_col: Color = _look.get("hair", Color(0.10, 0.09, 0.09))
	var hair_style := str(_look.get("hair_style", "short"))
	var build := str(_look.get("build", "slim"))
	var accessory := str(_look.get("accessory", "none"))

	# 体型：broad 身体更宽、站姿更开；slim 更窄、腿更靠拢。
	var broad := build == "broad"
	var body_w := 0.62 if broad else 0.50
	var arm_x := 0.40 if broad else 0.33
	var leg_x := 0.17 if broad else 0.12
	var leg_w := 0.24 if broad else 0.20

	rootn.add_child(_box(Vector3(0.50, 0.50, 0.50), Vector3(0, 1.45, 0), skin))            # 头
	rootn.add_child(_box(Vector3(body_w, 0.62, 0.30), Vector3(0, 0.94, 0), jacket))        # 身体
	rootn.add_child(_box(Vector3(0.18, 0.62, 0.22), Vector3(-arm_x, 0.94, 0), accent))     # 左臂（accent 点缀）
	rootn.add_child(_box(Vector3(0.18, 0.62, 0.22), Vector3(arm_x, 0.94, 0), jacket))      # 右臂
	rootn.add_child(_box(Vector3(0.10, 0.40, 0.31), Vector3(0, 0.96, 0.005), accent))      # 胸前竖条（accent）
	rootn.add_child(_box(Vector3(leg_w, 0.64, 0.24), Vector3(-leg_x, 0.32, 0), pants))     # 左腿
	rootn.add_child(_box(Vector3(leg_w, 0.64, 0.24), Vector3(leg_x, 0.32, 0), pants))      # 右腿

	_build_hair(rootn, hair_style, hair_col)
	_build_accessory(rootn, accessory, accent)

# 头发：头顶 y≈1.45、半高 0.25（顶面 ≈1.70）。各风格用少量方块拼出剪影。
func _build_hair(rootn: Node3D, style: String, col: Color) -> void:
	match style:
		"short":
			rootn.add_child(_box(Vector3(0.54, 0.10, 0.54), Vector3(0, 1.72, 0), col))      # 薄顶盖
		"long":
			rootn.add_child(_box(Vector3(0.54, 0.12, 0.54), Vector3(0, 1.73, 0), col))      # 顶
			rootn.add_child(_box(Vector3(0.52, 0.46, 0.14), Vector3(0, 1.40, -0.20), col))  # 后披长发
		"mohawk":
			rootn.add_child(_box(Vector3(0.12, 0.22, 0.52), Vector3(0, 1.80, 0), col))      # 中央竖条
		"bun":
			rootn.add_child(_box(Vector3(0.54, 0.10, 0.54), Vector3(0, 1.72, 0), col))      # 薄顶
			rootn.add_child(_box(Vector3(0.20, 0.20, 0.20), Vector3(0, 1.78, -0.22), col))  # 脑后发髻
		"cap":
			rootn.add_child(_box(Vector3(0.56, 0.18, 0.56), Vector3(0, 1.74, 0), col))      # 帽体
			rootn.add_child(_box(Vector3(0.40, 0.06, 0.22), Vector3(0, 1.70, 0.34), col))   # 帽檐
		"bald", _:
			pass                                                                            # 无发

# 配件：覆盖在头部上方/前方的小物件。
func _build_accessory(rootn: Node3D, accessory: String, accent: Color) -> void:
	match accessory:
		"hardhat":
			rootn.add_child(_box(Vector3(0.58, 0.20, 0.58), Vector3(0, 1.76, 0), Color(0.98, 0.80, 0.10)))  # 亮黄安全帽
		"antenna":
			rootn.add_child(_box(Vector3(0.04, 0.34, 0.04), Vector3(0, 1.92, 0), Color(0.15, 0.15, 0.17)))  # 细杆
			rootn.add_child(_box(Vector3(0.10, 0.10, 0.10), Vector3(0, 2.12, 0), accent))                   # 顶端球（accent）
		"visor":
			rootn.add_child(_box(Vector3(0.54, 0.12, 0.06), Vector3(0, 1.50, 0.26), Color(0.10, 0.12, 0.16)))  # 深色护目镜
		"none", _:
			pass

func _box(size: Vector3, pos: Vector3, col: Color) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	bm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	return mi

func _build_nameplate() -> void:
	_label = Label3D.new()
	_label.text = _pending_label
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.0014
	_label.font_size = 72
	_label.outline_size = 12
	_label.modulate = Color(0.85, 0.95, 1.0)
	_label.position = Vector3(0, 2.25, 0)
	add_child(_label)
