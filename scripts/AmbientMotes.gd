extends Node3D
# 轻量环境微光：在玩家附近绘制漂浮微粒，白天像尘光，夜晚更像暖色光点。

const MAX_MOTES := 96
const AREA := 34.0
const MIN_HEIGHT := 1.4
const HEIGHT_SPAN := 9.5

var target: Node3D
var daylight := 1.0
var rain := 0.0
var _region_label := "草原"

var _seed := 1337
var _phase := 0.0
var _motes: MultiMeshInstance3D
var _mat: StandardMaterial3D
var _first_mote_origin := Vector3.ZERO

func setup(track_target: Node3D, world_seed: int) -> void:
	target = track_target
	_seed = world_seed
	_build_motes()
	_update_motes(0.0)

func set_atmosphere(daylight_value: float, rain_value: float) -> void:
	daylight = clampf(daylight_value, 0.0, 1.0)
	rain = clampf(rain_value, 0.0, 1.0)

func set_region_label(label: String) -> void:
	_region_label = label if label != "" else "草原"

func visible_mote_count() -> int:
	if _motes == null or _motes.multimesh == null:
		return 0
	return _motes.multimesh.visible_instance_count

func first_mote_origin() -> Vector3:
	return _first_mote_origin

func current_region_label() -> String:
	return _region_label

func current_theme_color() -> Color:
	return _region_tint(_region_label)

func _process(delta: float) -> void:
	_update_motes(delta)

func _build_motes() -> void:
	if _motes != null:
		return
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE

	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat.albedo_color = Color(1.0, 0.86, 0.34, 0.0)
	_mat.emission_enabled = true
	_mat.emission = Color(1.0, 0.76, 0.24) * 0.25
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = MAX_MOTES
	mm.visible_instance_count = 0

	_motes = MultiMeshInstance3D.new()
	_motes.name = "AmbientMotes"
	_motes.multimesh = mm
	_motes.material_override = _mat
	_motes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_motes.extra_cull_margin = 64.0
	_motes.visible = false
	add_child(_motes)

func _update_motes(delta: float) -> void:
	if _motes == null or _motes.multimesh == null:
		return
	_phase = fmod(_phase + delta, 10000.0)
	var clear := 1.0 - clampf(rain, 0.0, 1.0)
	var night := clampf((0.60 - daylight) * 2.25, 0.0, 1.0)
	var base_strength := lerpf(0.18, 0.92, night)
	var strength := base_strength * lerpf(0.20, 1.0, clear) * _region_density(_region_label)
	var active := clampi(int(round(float(MAX_MOTES) * strength)), 0, MAX_MOTES)
	_motes.multimesh.visible_instance_count = active
	_motes.visible = active > 0
	if active <= 0 or target == null:
		return

	var tint := _region_tint(_region_label)
	var day_color := Color(1.0, 0.86, 0.44).lerp(tint, 0.38)
	var night_color := Color(1.0, 0.72, 0.22).lerp(tint, 0.52)
	var color := day_color.lerp(night_color, night)
	var alpha := lerpf(0.16, 0.72, night) * lerpf(0.35, 1.0, clear)
	_mat.albedo_color = Color(color.r, color.g, color.b, alpha)
	_mat.emission = color * lerpf(0.12, 0.85, night) * lerpf(0.35, 1.0, clear)

	var origin := target.global_position if target.is_inside_tree() else target.position
	for i in range(active):
		var angle := _hash01(i, 7) * TAU + sin(_phase * 0.23 + float(i) * 0.31) * 0.18
		var radius := sqrt(_hash01(i, 19)) * AREA
		var drift := Vector2(cos(angle), sin(angle)) * radius
		var y := MIN_HEIGHT + _hash01(i, 31) * HEIGHT_SPAN + sin(_phase * (0.65 + _hash01(i, 43)) + float(i)) * 0.55
		var size := lerpf(0.045, 0.115, night) * lerpf(0.75, 1.15, _hash01(i, 59))
		var basis := Basis.IDENTITY.scaled(Vector3(size, size, size))
		var mote_origin := origin + Vector3(drift.x, y, drift.y)
		if i == 0:
			_first_mote_origin = mote_origin
		_motes.multimesh.set_instance_transform(i, Transform3D(basis, mote_origin))

func _hash01(i: int, salt: int) -> float:
	var h := i * 1103515245 + salt * 12345 + _seed * 97
	h = ((h >> 16) ^ h) * 73244475
	h = (h >> 16) ^ h
	return float(h & 0xffff) / 65535.0

func _region_tint(label: String) -> Color:
	if label == "湿地" or label == "浅水湾" or label == "黏土滩":
		return Color(0.54, 0.94, 0.82)
	if label == "沙岸":
		return Color(1.0, 0.78, 0.42)
	if label == "雪峰" or label == "雪山":
		return Color(0.78, 0.92, 1.0)
	if label == "岩岭" or label == "玄武岩岭":
		return Color(0.66, 0.78, 0.86)
	if _is_forest_region(label):
		return Color(0.58, 0.92, 0.52)
	if label == "风草原":
		return Color(0.86, 1.0, 0.58)
	# ---- 主题岛扇区 ----
	if label == "沙漠":
		return Color(1.0, 0.82, 0.36)           # warm gold sand dust
	if label == "热带海岸":
		return Color(0.38, 0.96, 0.72)           # tropical turquoise
	if label == "村庄":
		return Color(0.92, 0.88, 0.62)           # cozy warm straw
	if label == "中央广场":
		return Color(1.0, 0.92, 0.72)            # golden plaza glow
	if label == "霓虹城":
		return Color(0.28, 0.92, 1.0)            # electric cyan
	if label == "天文台":
		return Color(0.72, 0.76, 1.0)            # cool starlight blue
	if label == "农田":
		return Color(0.72, 0.96, 0.48)           # fresh green pollen
	if label == "海湾":
		return Color(0.46, 0.82, 0.96)           # coastal mist blue
	return Color(1.0, 0.86, 0.44)

func _region_density(label: String) -> float:
	if label == "湿地" or label == "浅水湾":
		return 1.16
	if label == "雪峰" or label == "雪山":
		return 0.82
	if label == "岩岭" or label == "玄武岩岭":
		return 0.74
	if _is_forest_region(label):
		return 1.08
	# ---- 主题岛扇区 ----
	if label == "霓虹城":
		return 1.35                               # dense digital sparks
	if label == "热带海岸" or label == "海湾":
		return 1.18                               # humid mist
	if label == "沙漠":
		return 0.72                               # sparse desert dust
	if label == "天文台":
		return 0.88                               # crisp mountain air
	return 1.0

func _is_forest_region(label: String) -> bool:
	return label == "针叶林" or label == "苔林"
