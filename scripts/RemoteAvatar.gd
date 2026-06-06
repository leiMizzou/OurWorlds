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
var _color := Color(0.30, 0.62, 1.00)   # 默认蓝工装；set_color 可改
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

# ---------- 造型（仿 AgentAvatar，配色可变）----------
func _build_body(rootn: Node3D) -> void:
	var skin := Color(0.85, 0.66, 0.50)
	var jacket := _color
	var pants := Color(0.20, 0.22, 0.28)
	rootn.add_child(_box(Vector3(0.50, 0.50, 0.50), Vector3(0, 1.45, 0), skin))      # 头
	rootn.add_child(_box(Vector3(0.52, 0.62, 0.30), Vector3(0, 0.94, 0), jacket))    # 身体
	rootn.add_child(_box(Vector3(0.18, 0.62, 0.22), Vector3(-0.35, 0.94, 0), jacket))# 左臂
	rootn.add_child(_box(Vector3(0.18, 0.62, 0.22), Vector3(0.35, 0.94, 0), jacket)) # 右臂
	rootn.add_child(_box(Vector3(0.22, 0.64, 0.24), Vector3(-0.13, 0.32, 0), pants)) # 左腿
	rootn.add_child(_box(Vector3(0.22, 0.64, 0.24), Vector3(0.13, 0.32, 0), pants))  # 右腿

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
