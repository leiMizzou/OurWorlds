extends Node3D
# 附近遗迹的世界内信标：轻量、透明、可脉动，帮助玩家把 HUD 方向和地形对应起来。

var _beam: MeshInstance3D
var _ring := []
var _progress_ticks := []
var _progress_tick_mats := []
var _mat: StandardMaterial3D
var _t := 0.0
var _mode := "hint"
var _progress := -1

func setup() -> void:
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(1.0, 0.78, 0.18, 0.0)
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	_beam = MeshInstance3D.new()
	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3(0.16, 7.0, 0.16)
	_beam.mesh = beam_mesh
	_beam.position = Vector3(0, 3.7, 0)
	_beam.material_override = _mat
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_beam)

	_add_ring_piece(Vector3(0, 0.32, 0.86), Vector3(1.45, 0.08, 0.10))
	_add_ring_piece(Vector3(0, 0.32, -0.86), Vector3(1.45, 0.08, 0.10))
	_add_ring_piece(Vector3(0.86, 0.32, 0), Vector3(0.10, 0.08, 1.45))
	_add_ring_piece(Vector3(-0.86, 0.32, 0), Vector3(0.10, 0.08, 1.45))
	_build_progress_ticks()
	visible = false

func set_marker(pos: Vector3, active: bool, mode: String = "hint", progress: int = -1) -> void:
	visible = active
	if not active:
		_set_progress_ticks_visible(false)
		return
	_mode = mode if mode == "repair" or mode == "complete" else "hint"
	_progress = -1 if progress < 0 else clampi(progress, 0, 100)
	if _mode == "complete":
		_progress = 100
	_set_progress_ticks_visible(_mode == "repair" or _mode == "complete")
	var marker_pos := pos + Vector3(0, 0.2, 0)
	if is_inside_tree():
		global_position = marker_pos
	else:
		position = marker_pos

func marker_mode() -> String:
	return _mode

func marker_progress() -> int:
	return _progress

func progress_tick_count() -> int:
	return _progress_ticks.size()

func active_progress_ticks() -> int:
	if _mode != "repair" and _mode != "complete":
		return 0
	if _mode == "complete":
		return _progress_ticks.size()
	if _progress <= 0:
		return 0
	return clampi(ceili(float(_progress) / 100.0 * float(_progress_ticks.size())), 0, _progress_ticks.size())

func _process(delta: float) -> void:
	if not visible or _mat == null:
		return
	_t += delta
	var pulse := 0.5 + sin(_t * 3.2) * 0.5
	var base := Color(1.0, 0.76, 0.18, 1.0)
	var alpha := 0.16 + pulse * 0.13
	var height_scale := 0.88 + pulse * 0.16
	var ring_scale := 1.0 + pulse * 0.10
	if _mode == "repair":
		var amount := clampf(float(maxi(0, _progress)) / 100.0, 0.0, 1.0)
		base = Color(0.32, 0.96, 0.68, 1.0).lerp(Color(0.86, 1.0, 0.54, 1.0), amount)
		alpha = 0.20 + pulse * 0.16
		height_scale = 0.72 + amount * 0.32 + pulse * 0.14
		ring_scale = 0.94 + amount * 0.18 + pulse * 0.08
	elif _mode == "complete":
		base = Color(0.28, 0.78, 1.0, 1.0).lerp(Color(1.0, 0.68, 0.16, 1.0), pulse * 0.45)
		alpha = 0.42 + pulse * 0.24
		height_scale = 1.02 + pulse * 0.18
		ring_scale = 1.10 + pulse * 0.10
	_mat.albedo_color = Color(base.r, base.g, base.b, alpha)
	_beam.scale.y = height_scale
	for node in _ring:
		var mi: MeshInstance3D = node
		mi.scale = Vector3(ring_scale, 1.0, ring_scale)
	_update_progress_ticks(base, pulse)

func _add_ring_piece(pos: Vector3, size: Vector3) -> void:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = _mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	_ring.append(mi)

func _build_progress_ticks() -> void:
	var tick_count := 10
	for i in range(tick_count):
		var angle := TAU * float(i) / float(tick_count)
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(0.20, 0.32, 0.30, 0.0)
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED

		var mi := MeshInstance3D.new()
		var mesh := BoxMesh.new()
		mesh.size = Vector3(0.28, 0.085, 0.08)
		mi.mesh = mesh
		mi.position = Vector3(cos(angle) * 1.22, 0.54, sin(angle) * 1.22)
		mi.rotation.y = -angle
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_progress_ticks.append(mi)
		_progress_tick_mats.append(mat)

func _set_progress_ticks_visible(value: bool) -> void:
	for node in _progress_ticks:
		var mi: MeshInstance3D = node
		mi.visible = value

func _update_progress_ticks(base: Color, pulse: float) -> void:
	var repair := _mode == "repair" or _mode == "complete"
	var lit := active_progress_ticks()
	for i in range(_progress_ticks.size()):
		var mi: MeshInstance3D = _progress_ticks[i]
		mi.visible = repair
		if not repair:
			continue
		var mat: StandardMaterial3D = _progress_tick_mats[i]
		if i < lit:
			var warmth := float(i) / float(maxi(_progress_ticks.size() - 1, 1))
			var color := base.lerp(Color(1.0, 0.92, 0.42, 1.0), warmth * 0.45)
			if _mode == "complete":
				color = Color(0.56, 0.88, 1.0, 1.0).lerp(Color(1.0, 0.88, 0.36, 1.0), warmth)
			mat.albedo_color = Color(color.r, color.g, color.b, 0.50 + pulse * 0.26)
			var lift := 1.0 + pulse * 0.18
			mi.scale = Vector3(1.0, lift, 1.0)
		else:
			mat.albedo_color = Color(0.22, 0.34, 0.32, 0.14 + pulse * 0.04)
			mi.scale = Vector3.ONE
