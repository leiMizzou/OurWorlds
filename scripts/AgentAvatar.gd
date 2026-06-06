extends Node3D
# opc-ourworlds 的专属小人（"建造者"造型）。桥驱动它移动/建造；它跟玩家是两具独立身体。
# 橙工装 + 黄安全帽，头顶「🧱 OurWorlds」名牌（穿透地形可见，方便玩家找到它），自带柔光夜里也好认。

const NAME_TEXT := "🧱 OurWorlds"

var _rig: Node3D
var _body_mats := []        # 身体各部件材质（build 时整体高亮一下）
var _bob := 0.0
var _pop := 0.0             # goto 落地时的缩放弹跳
var _flash := 0.0           # build 时的高亮

func _ready() -> void:
	_rig = Node3D.new()
	add_child(_rig)
	_build_body(_rig)
	_build_nameplate()
	_build_glow()

# 桥调用：瞬移到目标点（落地有个缩放弹跳，醒目）
func teleport_to(pos: Vector3) -> void:
	global_position = pos
	_pop = 0.35

# 桥调用：建造时整体闪一下
func note_build() -> void:
	_flash = 0.5

func _process(delta: float) -> void:
	_bob += delta
	_rig.position.y = 0.04 * sin(_bob * 3.0)        # 轻微上下浮动=有生命感
	var s := 1.0
	if _pop > 0.0:
		_pop = maxf(0.0, _pop - delta)
		s = 1.0 + 0.25 * (_pop / 0.35)
	_rig.scale = Vector3(s, s, s)
	if _flash >= 0.0:
		_flash = maxf(0.0, _flash - delta)
		var e := (_flash / 0.5) * 2.0
		for m in _body_mats:
			m.emission_energy_multiplier = e
		if _flash == 0.0:
			_flash = -1.0                            # 停止刷新（已归零）

# ---------- 造型 ----------
func _build_body(root: Node3D) -> void:
	var skin := Color(0.85, 0.66, 0.50)
	var vest := Color(1.00, 0.55, 0.10)   # 橙工装
	var pants := Color(0.20, 0.22, 0.28)
	var hat := Color(1.00, 0.85, 0.10)    # 黄安全帽
	root.add_child(_box(Vector3(0.50, 0.50, 0.50), Vector3(0, 1.45, 0), skin))      # 头
	root.add_child(_box(Vector3(0.58, 0.16, 0.58), Vector3(0, 1.74, 0), hat))       # 安全帽
	root.add_child(_box(Vector3(0.52, 0.62, 0.30), Vector3(0, 0.94, 0), vest))      # 身体
	root.add_child(_box(Vector3(0.18, 0.62, 0.22), Vector3(-0.35, 0.94, 0), vest))  # 左臂
	root.add_child(_box(Vector3(0.18, 0.62, 0.22), Vector3(0.35, 0.94, 0), vest))   # 右臂
	root.add_child(_box(Vector3(0.22, 0.64, 0.24), Vector3(-0.13, 0.32, 0), pants)) # 左腿
	root.add_child(_box(Vector3(0.22, 0.64, 0.24), Vector3(0.13, 0.32, 0), pants))  # 右腿

func _box(size: Vector3, pos: Vector3, col: Color) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = size
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 0.0
	bm.material = m
	_body_mats.append(m)
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = pos
	return mi

func _build_nameplate() -> void:
	var lbl := Label3D.new()
	lbl.text = NAME_TEXT
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED   # 始终朝向玩家
	lbl.no_depth_test = true                           # 穿透地形可见，便于找到它
	lbl.fixed_size = true
	lbl.pixel_size = 0.0014
	lbl.font_size = 80
	lbl.outline_size = 14
	lbl.modulate = Color(1, 0.95, 0.7)
	lbl.position = Vector3(0, 2.35, 0)
	add_child(lbl)

func _build_glow() -> void:
	var light := OmniLight3D.new()
	light.light_color = Color(1.0, 0.8, 0.45)
	light.light_energy = 1.4
	light.omni_range = 9.0
	light.position = Vector3(0, 1.4, 0)
	add_child(light)
