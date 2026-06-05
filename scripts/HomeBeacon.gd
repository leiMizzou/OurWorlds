extends Node3D
# 出生点归途信标：玩家走远后显示柔和光柱，作为探索时的世界锚点。

const VISIBLE_DISTANCE := 18.0

var target: Node3D
var home_position := Vector3.ZERO

var _beam: MeshInstance3D
var _core: MeshInstance3D
var _ring := []
var _mat: StandardMaterial3D
var _base_mat: StandardMaterial3D
var _t := 0.0

func setup(home_pos: Vector3, target_node: Node3D) -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	home_position = home_pos
	target = target_node
	_build()
	_set_home_position(home_position)
	visible = false

func distance_to_home() -> float:
	if target == null:
		return 0.0
	var p := target.global_position if target.is_inside_tree() else target.position
	return Vector2(p.x - home_position.x, p.z - home_position.z).length()

func _build() -> void:
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(0.34, 0.86, 1.0, 0.0)
	_mat.emission_enabled = true
	_mat.emission = Color(0.20, 0.72, 1.0)
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_base_mat = StandardMaterial3D.new()
	_base_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_base_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_base_mat.albedo_color = Color(0.46, 0.94, 1.0, 0.30)
	_base_mat.emission_enabled = true
	_base_mat.emission = Color(0.22, 0.72, 1.0) * 0.55
	_base_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_beam = MeshInstance3D.new()
	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3(0.18, 9.0, 0.18)
	_beam.mesh = beam_mesh
	_beam.position = Vector3(0, 4.8, 0)
	_beam.material_override = _mat
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beam)

	_core = MeshInstance3D.new()
	var core_mesh := BoxMesh.new()
	core_mesh.size = Vector3(0.62, 0.16, 0.62)
	_core.mesh = core_mesh
	_core.position = Vector3(0, 0.18, 0)
	_core.material_override = _base_mat
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_core)

	_add_ring_piece(Vector3(0, 0.26, 1.05), Vector3(1.72, 0.07, 0.11))
	_add_ring_piece(Vector3(0, 0.26, -1.05), Vector3(1.72, 0.07, 0.11))
	_add_ring_piece(Vector3(1.05, 0.26, 0), Vector3(0.11, 0.07, 1.72))
	_add_ring_piece(Vector3(-1.05, 0.26, 0), Vector3(0.11, 0.07, 1.72))

func _set_home_position(pos: Vector3) -> void:
	if is_inside_tree():
		global_position = pos
	else:
		position = pos

func _process(delta: float) -> void:
	if _mat == null or _base_mat == null:
		return
	var distance := distance_to_home()
	visible = distance >= VISIBLE_DISTANCE
	if not visible:
		return
	_t += delta
	var pulse := 0.5 + sin(_t * 2.7) * 0.5
	var alpha := 0.14 + pulse * 0.10
	_mat.albedo_color = Color(0.34, 0.86, 1.0, alpha)
	_mat.emission = Color(0.18, 0.68, 1.0) * (0.75 + pulse * 0.35)
	_base_mat.albedo_color = Color(0.46, 0.94, 1.0, 0.24 + pulse * 0.12)
	_beam.scale.y = 0.92 + pulse * 0.18
	var ring_scale := 1.0 + pulse * 0.12
	for node in _ring:
		var mi: MeshInstance3D = node
		mi.scale = Vector3(ring_scale, 1.0, ring_scale)

func _add_ring_piece(pos: Vector3, size: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = _base_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_ring.append(mi)
