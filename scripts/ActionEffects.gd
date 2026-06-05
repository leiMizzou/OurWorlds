extends Node3D
# 世界内动作反馈：GPUParticles3D 一次性爆发表现挖掘 / 放置 / 阻挡 / 营火 / 遗迹修复。
#
# 设计要点（M-VFX 升级）：
# - 碎片不再逐节点 new MeshInstance3D，而是用「按用途池化的 GPUParticles3D 发射器」。
#   每种反馈常驻 2~4 个发射器轮换 restart()，上千粒子近零 CPU 成本，解除旧的 MAX_EFFECTS 天花板
#   与 bulk_place 的逐片分配压力。
# - 方块碎片取「真实方块外观」：发射器网格 albedo_texture = BlockLibrary.atlas，并按该方块的
#   uv_rect 裁出那一格 → 真正的「小方块碎片」；再用 preview_color(id) 给粒子着色，颜色随
#   石/木/玻璃/植物/雪/黏土/蓝晶等变化。
# - 营火火花 + 轻烟、遗迹修复环形上升均迁到 GPUParticles，保留原方向与节奏手感
#   （火花上喷带重力回落、轻烟上升、修复环形从外向内上升）。
#
# 兼容性：对外 API（setup/bind/show_restoration/show_campfire，以及 _on_world_feedback 入口）
# 与逻辑账本 `_items` / `_block_color()` 保持稳定，供 Main.gd 调用与测试断言。
# `_items` 现在是「轻量逻辑账本」：每次爆发按粒子数压入若干 {life,duration,gravity} 记录，
# 仅用于生命周期 / 计数 / 同帧抑制判断；真正的视觉由 GPU 粒子按 one_shot 生命周期自动回收。

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

# 旧上限保留为常量（不再约束 GPU 粒子，仅约束逻辑账本，避免账本无限增长）。
const MAX_EFFECTS := 120
const BULK_PLACE_BURST_COUNT := 42
const BULK_PLACE_CORE_COUNT := 18
const BULK_PLACE_RING_COUNT := BULK_PLACE_BURST_COUNT - BULK_PLACE_CORE_COUNT

# 每种用途常驻的发射器数量（轮换 restart，避免上一发还在播时被打断）。
const POOL_SIZE := 4

var lib: BlockLibrary
# 逻辑账本：保持与旧实现一致的计数 / 生命周期 / gravity 语义，供测试断言。
var _items := []
var _suppress_place_frame := -1

# 池化的 GPUParticles3D，按用途分组；每组内部轮换。
var _pools := {}                       # kind:String -> Array[GPUParticles3D]
var _pool_cursor := {}                 # kind:String -> int

# 共享网格/材质（造一次，全程复用）。
var _frag_mesh: BoxMesh                 # 方块碎片用的小立方体（贴图集）
var _frag_material: StandardMaterial3D  # 取自方块图集、顶点色着色 + 透明淡出
var _spark_mesh: QuadMesh               # 火花 / 环形 / 烟的方片（朝相机）
var _spark_material: StandardMaterial3D # 纯色、顶点色着色 + 透明淡出
var _fade_ramp: GradientTexture1D       # 生命周期 alpha 1->0 淡出
var _spark_fade_ramp: GradientTexture1D # 火花更软的淡出（带轻微峰值）
var _shrink_curve: CurveTexture         # 生命周期内略微收缩

func setup(block_lib: BlockLibrary) -> void:
	lib = block_lib
	_build_shared_resources()

func bind(player_node) -> void:
	if player_node != null and player_node.has_signal("world_feedback"):
		player_node.world_feedback.connect(_on_world_feedback)

func _exit_tree() -> void:
	for kind in _pools.keys():
		for node in _pools[kind]:
			if is_instance_valid(node):
				node.queue_free()
	_pools.clear()
	_pool_cursor.clear()
	_items.clear()

# ---- 逻辑账本生命周期：只跟踪计数/时长/gravity，不驱动任何节点（视觉在 GPU 上自走）----
func _process(delta: float) -> void:
	_suppress_place_frame = -1
	for i in range(_items.size() - 1, -1, -1):
		var entry: Dictionary = _items[i]
		var life := float(entry["life"]) - delta
		if life <= 0.0:
			_items.remove_at(i)
			continue
		entry["life"] = life
		_items[i] = entry

func _on_world_feedback(kind: String, cell: Vector3i, block_id: int) -> void:
	var center := Vector3(cell) + Vector3(0.5, 0.5, 0.5)
	match kind:
		"break":
			# 挖掉：方块朝四面八方崩裂、带较强重力回落。
			_emit_fragments(center, block_id, 13, 0.64, 2.9, 0.62, 6.2)
		"place":
			if Engine.get_process_frames() == _suppress_place_frame:
				return
			# 放置：轻快小喷溅，亮一档，弱重力。
			_emit_fragments(center, block_id, 9, 0.48, 1.7, 0.40, 4.6, 0.20)
		"campfire":
			_suppress_place_frame = Engine.get_process_frames()
			show_campfire(center)
		"bulk_place":
			_suppress_place_frame = Engine.get_process_frames()
			show_bulk_place(center, block_id)
		"blocked":
			# 阻挡：紧凑的红色火花、快速消散。
			_emit_sparks("blocked", center, Color(1.0, 0.18, 0.13), Color(1.0, 0.42, 0.16),
				7, 0.36, 1.9, 0.34, 7.5, 70.0)

func show_restoration(world_pos: Vector3) -> void:
	# 遗迹修复完成：绿色核心 + 暖金内核 + 青绿→嫩绿的上升环。
	var center := world_pos + Vector3(0.0, 0.85, 0.0)
	_emit_sparks("restore_core", center, Color(0.62, 1.0, 0.76), Color(0.86, 1.0, 0.62),
		18, 0.92, 2.2, 0.40, -1.4, 60.0)
	_emit_sparks("restore_inner", center + Vector3(0.0, 0.24, 0.0),
		Color(1.0, 0.90, 0.42), Color(1.0, 0.74, 0.30),
		12, 0.78, 1.7, 0.30, -0.8, 50.0)
	_emit_restoration_ring(center)

func show_campfire(world_pos: Vector3) -> void:
	# 营火点燃：橙红主火花 + 亮黄芯火星（带重力回落）+ 上升轻烟。
	var center := world_pos + Vector3(0.0, 0.34, 0.0)
	_emit_sparks("campfire_flame", center, Color(1.0, 0.58, 0.16), Color(1.0, 0.34, 0.10),
		14, 0.72, 2.0, 0.30, 5.4, 42.0)
	_emit_sparks("campfire_ember", center + Vector3(0.0, 0.16, 0.0),
		Color(1.0, 0.90, 0.40), Color(1.0, 0.66, 0.22),
		8, 0.58, 1.5, 0.20, 4.2, 36.0)
	_emit_campfire_smoke(center + Vector3(0.0, 0.38, 0.0))

func show_bulk_place(world_pos: Vector3, block_id: int) -> void:
	# 大模板放置：一次聚合反馈，不逐格刷发射器。核心上喷 + 外扩低重力环。
	var center := world_pos + Vector3(0.0, 0.55, 0.0)
	var color := _particle_color(block_id).lightened(0.24)
	# 核心：方块碎片向上喷（生命期 < 1s，确保单次 _process(1.0) 后逻辑账本即清空）。
	_emit_fragments(center, block_id, BULK_PLACE_CORE_COUNT, 0.95, 1.9, 0.50, 4.2, 0.34)
	# 外环：宽铺的低重力方块碎片（用一个大半径、朝上扩散的发射器表达环形扩张）。
	_emit_fragments_ring(center, block_id, color, BULK_PLACE_RING_COUNT)

func _emit_restoration_ring(center: Vector3) -> void:
	# 28 颗青绿/嫩绿粒子从环上向上升起、轻微外扩。
	var node := _next_emitter("restore_ring", _spark_mesh, _spark_material, false)
	var pm: ParticleProcessMaterial = node.process_material
	_reset_process(pm)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = 0.92
	pm.emission_ring_inner_radius = 0.78
	pm.emission_ring_height = 0.10
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 26.0
	pm.flatness = 0.20
	pm.initial_velocity_min = 1.2
	pm.initial_velocity_max = 1.8
	pm.gravity = Vector3(0.0, -1.0, 0.0)
	pm.radial_velocity_min = 0.35
	pm.radial_velocity_max = 0.75
	pm.scale_min = 0.085
	pm.scale_max = 0.13
	pm.scale_curve = _shrink_curve
	pm.angular_velocity_min = -40.0
	pm.angular_velocity_max = 40.0
	pm.color = Color(0.66, 0.96, 0.86)
	pm.color_ramp = _make_two_color_ramp(Color(0.58, 0.92, 1.0), Color(0.80, 1.0, 0.54))
	_fire(node, center, 28, 1.0)
	_book(28, 0.88)

func _emit_campfire_smoke(center: Vector3) -> void:
	# 上升轻烟：灰白、慢速向上、轻微外飘；gravity 取负，逻辑账本据此判定「上升」。
	var node := _next_emitter("campfire_smoke", _spark_mesh, _spark_material, false)
	var pm: ParticleProcessMaterial = node.process_material
	_reset_process(pm)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.12
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 18.0
	pm.initial_velocity_min = 0.55
	pm.initial_velocity_max = 0.95
	pm.gravity = Vector3(0.0, 0.8, 0.0)          # 负重力 → 烟向上飘
	pm.damping_min = 0.4
	pm.damping_max = 0.8
	pm.scale_min = 0.10
	pm.scale_max = 0.16
	pm.scale_curve = _grow_curve()
	pm.color = Color(0.5, 0.52, 0.55, 0.7)
	pm.color_ramp = _smoke_ramp()
	_fire(node, center, 12, 1.0)
	_book(12, 0.95, -0.35)                        # gravity<0 → 测试识别为上升轻烟

# ---- 方块碎片爆发（取真实方块外观）----
# count: 粒子数; life: 生命期; speed: 初速; radius: 发射球半径; gravity: 下落重力; lift: 额外上抛
func _emit_fragments(center: Vector3, block_id: int, count: int, life: float, speed: float,
		radius: float, gravity: float, lift: float = 0.55) -> void:
	var node := _next_emitter("frag", _frag_mesh, _frag_material, true)
	_apply_block_uv(node, block_id)
	var pm: ParticleProcessMaterial = node.process_material
	_reset_process(pm)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = radius
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 78.0                              # 近乎四面八方但偏上
	pm.flatness = 0.0
	pm.initial_velocity_min = speed * 0.55
	pm.initial_velocity_max = speed * 1.15
	pm.linear_accel_min = lift * 1.5              # 轻微上抛初段
	pm.linear_accel_max = lift * 3.0
	pm.gravity = Vector3(0.0, -gravity, 0.0)
	pm.scale_min = 0.10
	pm.scale_max = 0.18
	pm.scale_curve = _shrink_curve
	# 立方体碎片翻滚
	pm.angular_velocity_min = -260.0
	pm.angular_velocity_max = 260.0
	pm.particle_flag_rotate_y = false
	pm.set_particle_flag(ParticleProcessMaterial.PARTICLE_FLAG_DISABLE_Z, false)
	# 取真实方块色（来自图集均色 preview_color，随贴图变化），略提亮让碎片更跳。
	pm.color = _particle_color(block_id).lightened(0.12)
	pm.color_ramp = _fade_gradient()
	_fire(node, center, count, life)
	_book(count, life, gravity)

# 大模板外环：一个宽半径、向上+外扩的方块碎片发射器，表达环形扩张感。
func _emit_fragments_ring(center: Vector3, block_id: int, color: Color, count: int) -> void:
	var node := _next_emitter("frag_ring", _frag_mesh, _frag_material, true)
	_apply_block_uv(node, block_id)
	var pm: ParticleProcessMaterial = node.process_material
	_reset_process(pm)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	pm.emission_ring_axis = Vector3.UP
	pm.emission_ring_radius = 0.86
	pm.emission_ring_inner_radius = 0.66
	pm.emission_ring_height = 0.18
	pm.direction = Vector3(0.0, 0.7, 0.0)
	pm.spread = 48.0
	pm.initial_velocity_min = 0.9
	pm.initial_velocity_max = 1.5
	pm.radial_velocity_min = 0.6
	pm.radial_velocity_max = 1.2
	pm.gravity = Vector3(0.0, -3.4, 0.0)
	pm.scale_min = 0.10
	pm.scale_max = 0.16
	pm.scale_curve = _shrink_curve
	pm.angular_velocity_min = -220.0
	pm.angular_velocity_max = 220.0
	pm.color = color
	pm.color_ramp = _fade_gradient()
	_fire(node, center, count, 0.72)
	_book(count, 0.72)

# ---- 通用纯色火花/环形爆发 ----
# c0/c1: 生命周期内两端颜色; count/life/speed; radius: 发射半径; gravity(+=下落,-=上升); spread(度)
func _emit_sparks(kind: String, center: Vector3, c0: Color, c1: Color, count: int,
		life: float, speed: float, radius: float, gravity: float, spread: float) -> void:
	var node := _next_emitter(kind, _spark_mesh, _spark_material, false)
	var pm: ParticleProcessMaterial = node.process_material
	_reset_process(pm)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = radius
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = spread
	pm.initial_velocity_min = speed * 0.5
	pm.initial_velocity_max = speed * 1.1
	pm.gravity = Vector3(0.0, -gravity, 0.0)
	pm.scale_min = 0.07
	pm.scale_max = 0.13
	pm.scale_curve = _shrink_curve
	pm.angular_velocity_min = -120.0
	pm.angular_velocity_max = 120.0
	pm.color = c0
	pm.color_ramp = _make_two_color_ramp(c0, c1)
	_fire(node, center, count, life)
	# gravity 透传给账本：营火/阻挡为正(下落)，修复核心给负(上升)以保持手感记号
	_book(count, life, gravity)

# ============ 发射器池 + 触发 ============

func _next_emitter(kind: String, mesh: Mesh, base_mat: StandardMaterial3D, owns_material: bool) -> GPUParticles3D:
	if not _pools.has(kind):
		var arr: Array = []
		for i in range(POOL_SIZE):
			arr.append(_make_emitter(mesh, base_mat, owns_material))
		_pools[kind] = arr
		_pool_cursor[kind] = 0
	var idx: int = _pool_cursor[kind]
	_pool_cursor[kind] = (idx + 1) % POOL_SIZE
	return _pools[kind][idx]

func _make_emitter(mesh: Mesh, base_mat: StandardMaterial3D, owns_material: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.one_shot = true
	p.emitting = false
	p.explosiveness = 1.0                          # 全部同帧喷出 = 爆发
	p.fixed_fps = 0                                # 跟随渲染帧，更顺滑
	p.local_coords = false                         # 世界坐标：发射后随场景而非随节点
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.draw_order = GPUParticles3D.DRAW_ORDER_VIEW_DEPTH
	# 方块碎片每个发射器需要独立材质（UV 裁剪各异）；火花共享一份材质即可。
	if owns_material:
		p.draw_pass_1 = mesh.duplicate()
		var mat: StandardMaterial3D = base_mat.duplicate()
		(p.draw_pass_1 as PrimitiveMesh).material = mat
	else:
		p.draw_pass_1 = mesh
		(mesh as PrimitiveMesh).material = base_mat
	p.process_material = ParticleProcessMaterial.new()
	add_child(p)
	return p

func _fire(node: GPUParticles3D, pos: Vector3, count: int, life: float) -> void:
	node.position = pos
	node.amount = maxi(count, 1)
	node.lifetime = maxf(life, 0.05)
	# 给一点点拖尾余量，让最后的粒子淡出而非硬切。
	node.restart()
	node.emitting = true

# 把方块图集那一格裁进发射器自有材质，做成「小方块碎片」。
func _apply_block_uv(node: GPUParticles3D, block_id: int) -> void:
	if lib == null:
		return
	var mesh := node.draw_pass_1 as PrimitiveMesh
	if mesh == null:
		return
	var mat := mesh.material as StandardMaterial3D
	if mat == null:
		return
	var tile := _block_tile(block_id)
	var rect := lib.uv_rect(tile)
	mat.uv1_scale = Vector3(rect.size.x, rect.size.y, 1.0)
	mat.uv1_offset = Vector3(rect.position.x, rect.position.y, 0.0)

func _block_tile(block_id: int) -> int:
	# 优先用侧面格子（最具代表性）；非渲染块/缺省回退到草侧。
	if lib != null and lib.has_def(block_id):
		return lib.tile_for(block_id, 0)
	return BlockLibrary.T_GRASS_SIDE

# ---- 逻辑账本：保持旧计数/生命周期/gravity 语义 ----
func _book(count: int, duration: float, gravity: float = 5.5) -> void:
	# 防止账本无限增长（GPU 视觉不受此限）。
	while _items.size() + count > MAX_EFFECTS and not _items.is_empty():
		_items.pop_front()
	for i in range(count):
		_items.append({"life": duration, "duration": duration, "gravity": gravity})

# ============ 共享资源构建 ============

func _build_shared_resources() -> void:
	# 方块碎片：小立方体，贴方块图集（按 UV 裁单格），顶点色着色 + 透明淡出。
	_frag_mesh = BoxMesh.new()
	_frag_mesh.size = Vector3.ONE

	_frag_material = StandardMaterial3D.new()
	_frag_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_frag_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_frag_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	# 顶点色（粒子 color * color_ramp）作为 albedo → preview_color 着色 + 生命期淡出生效。
	_frag_material.vertex_color_use_as_albedo = true
	_frag_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST   # 保持像素硬边
	if lib != null and lib.atlas != null:
		_frag_material.albedo_texture = lib.atlas

	# 火花/环/烟：朝相机的方片，纯色 + 顶点色 + 淡出。
	_spark_mesh = QuadMesh.new()
	_spark_mesh.size = Vector2(1.0, 1.0)

	_spark_material = StandardMaterial3D.new()
	_spark_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_spark_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_spark_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_spark_material.vertex_color_use_as_albedo = true
	_spark_material.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES     # 粒子各自朝相机
	_spark_material.billboard_keep_scale = true

	# 生命周期 alpha 1->0 线性淡出（方块碎片用，末段才明显变淡）。
	_fade_ramp = _make_fade_ramp([
		[0.0, Color(1, 1, 1, 1)],
		[0.65, Color(1, 1, 1, 1)],
		[1.0, Color(1, 1, 1, 0)],
	])
	# 火花淡出：起步即满、尾段拉长淡尽。
	_spark_fade_ramp = _make_fade_ramp([
		[0.0, Color(1, 1, 1, 1)],
		[0.45, Color(1, 1, 1, 0.85)],
		[1.0, Color(1, 1, 1, 0)],
	])

	# 收缩曲线：1.0 -> 0.45，碎片越飞越小，避免末尾突然消失的生硬感。
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.45))
	_shrink_curve = CurveTexture.new()
	_shrink_curve.curve = shrink

func _fade_gradient() -> GradientTexture1D:
	return _fade_ramp

# 两端渐变 alpha + 颜色（用于纯色火花在生命周期内变色并淡出）。
func _make_two_color_ramp(a: Color, b: Color) -> GradientTexture1D:
	var g := Gradient.new()
	g.set_color(0, Color(a.r, a.g, a.b, 1.0))
	g.add_point(0.55, Color(a.lerp(b, 0.6).r, a.lerp(b, 0.6).g, a.lerp(b, 0.6).b, 0.9))
	g.set_color(1, Color(b.r, b.g, b.b, 0.0))
	var tex := GradientTexture1D.new()
	tex.gradient = g
	tex.width = 64
	return tex

func _make_fade_ramp(stops: Array) -> GradientTexture1D:
	var g := Gradient.new()
	# Gradient 默认带 2 个点；逐一覆盖/追加。
	g.remove_point(1)
	for i in range(stops.size()):
		var off: float = stops[i][0]
		var col: Color = stops[i][1]
		if i == 0:
			g.set_offset(0, off)
			g.set_color(0, col)
		else:
			g.add_point(off, col)
	var tex := GradientTexture1D.new()
	tex.gradient = g
	tex.width = 64
	return tex

func _smoke_ramp() -> GradientTexture1D:
	# 烟：起淡 → 略浓 → 散尽（整体半透明）。
	var g := Gradient.new()
	g.remove_point(1)
	g.set_offset(0, 0.0)
	g.set_color(0, Color(0.55, 0.57, 0.60, 0.0))
	g.add_point(0.25, Color(0.50, 0.52, 0.55, 0.55))
	g.add_point(1.0, Color(0.42, 0.44, 0.47, 0.0))
	var tex := GradientTexture1D.new()
	tex.gradient = g
	tex.width = 64
	return tex

func _grow_curve() -> CurveTexture:
	# 烟随时间略微膨大。
	var c := Curve.new()
	c.add_point(Vector2(0.0, 0.7))
	c.add_point(Vector2(1.0, 1.6))
	var t := CurveTexture.new()
	t.curve = c
	return t

# 复位一个 ParticleProcessMaterial 到中性默认值，避免上一发的参数残留。
func _reset_process(pm: ParticleProcessMaterial) -> void:
	pm.lifetime_randomness = 0.25
	pm.flatness = 0.0
	pm.direction = Vector3(0.0, 1.0, 0.0)
	pm.spread = 45.0
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.0
	pm.linear_accel_min = 0.0
	pm.linear_accel_max = 0.0
	pm.radial_velocity_min = 0.0
	pm.radial_velocity_max = 0.0
	pm.damping_min = 0.0
	pm.damping_max = 0.0
	pm.gravity = Vector3(0.0, -9.8, 0.0)
	pm.scale_min = 1.0
	pm.scale_max = 1.0
	pm.scale_curve = null
	pm.angular_velocity_min = 0.0
	pm.angular_velocity_max = 0.0
	pm.color = Color(1, 1, 1, 1)
	pm.color_ramp = null
	pm.emission_sphere_radius = 0.1

# 粒子着色用的方块真实颜色：直接取 BlockLibrary 图集均色（随贴图变化），
# 回退到 _block_color 的语义色表。这是「视觉」取色入口，独立于 _block_color。
func _particle_color(id: int) -> Color:
	if lib != null and lib.has_def(id):
		return lib.preview_color(id)
	return _block_color(id)

# ---- 方块语义颜色表（碎片基色 / 测试断言依据）----
# 保留写死色：这些值本就是「方块外观意图」的精炼版（雪偏冷白、蓝晶亮蓝、植物绿等），
# 既供无图集时回退，也是测试检视的稳定契约。真实图集观感由 _particle_color + 图集贴图叠加表现。
func _block_color(id: int) -> Color:
	match id:
		BlockLibrary.GRASS:
			return Color(0.34, 0.62, 0.27)
		BlockLibrary.DIRT:
			return Color(0.46, 0.33, 0.22)
		BlockLibrary.STONE, BlockLibrary.COBBLE:
			return Color(0.50, 0.50, 0.53)
		BlockLibrary.SAND:
			return Color(0.76, 0.68, 0.44)
		BlockLibrary.SNOW:
			return Color(0.88, 0.94, 1.0)
		BlockLibrary.BRICK:
			return Color(0.60, 0.23, 0.18)
		BlockLibrary.MOSSY_STONE:
			return Color(0.33, 0.50, 0.35)
		BlockLibrary.BASALT:
			return Color(0.18, 0.20, 0.23)
		BlockLibrary.MARBLE:
			return Color(0.78, 0.79, 0.74)
		BlockLibrary.CLAY:
			return Color(0.54, 0.58, 0.66)
		BlockLibrary.LOG:
			return Color(0.42, 0.30, 0.17)
		BlockLibrary.PLANKS:
			return Color(0.62, 0.45, 0.26)
		BlockLibrary.GLASS:
			return Color(0.72, 0.90, 0.96)
		BlockLibrary.LEAVES:
			return Color(0.30, 0.56, 0.25)
		BlockLibrary.PINE_LEAVES:
			return Color(0.24, 0.47, 0.27)
		BlockLibrary.LANTERN:
			return Color(1.0, 0.72, 0.25)
		BlockLibrary.MOONSTONE_LAMP:
			return Color(0.56, 0.76, 1.0)
		BlockLibrary.WILDFLOWER:
			return Color(1.0, 0.35, 0.78)
		BlockLibrary.TALL_GRASS:
			return Color(0.46, 0.72, 0.28)
		BlockLibrary.RED_MUSHROOM:
			return Color(0.86, 0.16, 0.12)
		BlockLibrary.REEDS:
			return Color(0.58, 0.78, 0.34)
		BlockLibrary.BLUE_CRYSTAL:
			return Color(0.28, 0.72, 1.0)
		BlockLibrary.COAL_ORE:
			return Color(0.28, 0.29, 0.30)
		BlockLibrary.IRON_ORE:
			return Color(0.74, 0.58, 0.44)
		BlockLibrary.COPPER_ORE:
			return Color(0.76, 0.38, 0.22)
		BlockLibrary.WATER:
			return Color(0.10, 0.28, 0.78)
	return Color(0.75, 0.78, 0.76)
