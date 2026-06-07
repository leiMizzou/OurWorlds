extends CharacterBody3D
# 第一人称/第三人称：鼠标转视角、WASD 走、空格跳、双击空格切飞行、F5 切视角、Esc 放/抓鼠标。
# 顺带管"挖/放/准星高亮"和快捷栏选块（v1 先放一起，以后可拆成 Interactor）。
#
# i18n：动作反馈 / 建造意图等界面文案经 _loc()（/root/Locale 节点路径）取当前语言，
# 而不是裸标识符 `Locale`（GDScript 在 `godot --script` 编译被 preload 的脚本时不注入
# autoload 全局名）。这些文案由信号发给 HUD 或被 HUD 每帧拉取，无需在本节点常驻重译。
# 建造模板「名称」（平台/立柱…）属于世界内容，保持中文，仅翻译包裹它的界面词（模板/朝向）。

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const Chunk = preload("res://scripts/Chunk.gd")
const BuildTemplates = preload("res://scripts/BuildTemplates.gd")

signal action_feedback(kind: String, label: String)
signal world_feedback(kind: String, cell: Vector3i, block_id: int)
signal material_picked(block_id: int)
signal footstep(block_id: int)
signal landed(block_id: int)
signal splashed()

const BRUSH_RADII := [0, 1]
const BULK_PLACE_EFFECT_THRESHOLD := 24
const BUILD_TEMPLATES := [
	{"id": "off", "label": "关闭"},
	{"id": "platform", "label": "平台"},
	{"id": "pillar", "label": "立柱"},
	{"id": "arch", "label": "拱门"},
	{"id": "wall", "label": "墙面"},
	{"id": "stairs", "label": "楼梯"},
	{"id": "room_frame", "label": "房架"},
	{"id": "cabin", "label": "小屋"},
	{"id": "campfire", "label": "营火"},
	{"id": "bridge", "label": "小桥"},
	{"id": "garden", "label": "花圃"},
	{"id": "beacon_tower", "label": "灯塔"},
	{"id": "signpost", "label": "路标"},
]
# 命名动作 → 物理按键。集中在此处，方便将来切到 InputMap（本任务不改 project.godot，
# 仅把散落的硬编码 KEY_* 收敛成命名入口，调用点统一走 _action_pressed/_action_just_pressed）。
const ACTION_KEYS := {
	"move_forward": [KEY_W],
	"move_back": [KEY_S],
	"move_left": [KEY_A],
	"move_right": [KEY_D],
	"sprint": [KEY_SHIFT],
	"jump": [KEY_SPACE],
	"fly_descend": [KEY_SHIFT],
	"toggle_view": [KEY_F5, KEY_V],
	"cycle_recent": [KEY_R],
	"toggle_brush": [KEY_B],
	"prev_template": [KEY_Q],
	"toggle_template": [KEY_T],
	"rotate_template": [KEY_G],
	"undo": [KEY_Z],
	"redo": [KEY_Y],
}

const DEFAULT_SENS := 0.0025
const WALK := 5.5
const RUN := 9.0
const FLY := 16.0
const JUMP := 7.5
const GRAVITY := 22.0
const REACH := 6.0
const CAM_DIST := 4.5     # 第三人称相机离身后多远

var world                          # World 节点（由 Main 注入）
var lib: BlockLibrary              # 由 Main 注入
var spring: SpringArm3D            # 相机吊臂（自动避开身后地形）
var camera: Camera3D
var avatar: Node3D                 # 方块小人（第三人称才显示）
var _arm_l: Node3D                 # 四肢关节(pivot)，走路时绕 X 摆动
var _arm_r: Node3D
var _leg_l: Node3D
var _leg_r: Node3D
var _anim_amount := 0.0            # 走路动画幅度（移动淡入、静止淡出）
var _cape: Node3D                  # 披风（站立下垂、飞行后扬）
var _fly_amount := 0.0             # 飞行(超人)姿态混合
var _anim_t := 0.0                 # 动画计时（披风抖动）
# 隐藏技能：飞行中长按 C 蓄力 ≥5 秒，松手发射龟派气功波（蓄越久威力越大）。
const KAME_KEY := KEY_C
const KAME_CHARGE_MIN := 5.0
const KAME_CHARGE_MAX := 8.0
const KAME_RADIUS := 4
const KAME_RADIUS_MAX := 7
const KAME_LENGTH := 50
const KAME_LENGTH_MAX := 92
var _kame_charge := 0.0
var _charging := false
var _kame_cooldown := 0.0
var _kame_fire_t := 0.0
var _charge_ball: MeshInstance3D
var _charge_mat: StandardMaterial3D
var _cine_cam: Camera3D            # 放招运镜相机（侧面电影感）
var _cine_t := 0.0                 # 运镜保持计时（发射后）
var _kame_beam_from := Vector3.ZERO   # 光柱起点(小人)/终点(命中)，给全景运镜框图
var _kame_beam_to := Vector3.ZERO
var highlight: MeshInstance3D
var placement_preview: MeshInstance3D
var placement_blocked_preview: MeshInstance3D
var brush_preview_lines: MeshInstance3D

var fly := false
var view_mode := 0   # 0=第一人称, 1=第三人称(身后), 2=第三人称(正面)
var input_enabled := true
var mouse_sensitivity := DEFAULT_SENS
var pitch := 0.0
var sel_index := 0
var selected_block_id := BlockLibrary.GRASS
var brush_index := 0
var template_index := 0
var template_orientation_index := 0
var recent_block_ids := []
var overlays_visible := true
var _last_space := -1000
var _has_target := false
var _target := Vector3i.ZERO
var _place := Vector3i.ZERO
var _target_normal := Vector3i.UP
var _bob := 0.0
var _step_phase := 0
var _was_on_floor := true
var _was_in_water := false
var _preview_material: StandardMaterial3D
var _blocked_preview_material: StandardMaterial3D
var _preview_box_mesh: BoxMesh
var _preview_mesh_key := ""
var _blocked_preview_mesh_key := ""
var _brush_line_material: StandardMaterial3D

func _ready() -> void:
	_ensure_input_map()
	var cs := CollisionShape3D.new()
	var caps := CapsuleShape3D.new()
	caps.radius = 0.35
	caps.height = 1.7
	cs.shape = caps
	cs.position = Vector3(0, 0.9, 0)
	add_child(cs)

	# 相机吊臂：第一人称 length=0（贴在头上）；第三人称 length>0（拉到身后，且自动避免穿墙）
	spring = SpringArm3D.new()
	spring.position = Vector3(0, 1.62, 0)
	spring.spring_length = 0.0
	spring.margin = 0.3
	spring.add_excluded_object(get_rid())   # 别撞到自己
	add_child(spring)

	camera = Camera3D.new()
	camera.far = 800.0
	spring.add_child(camera)

	avatar = _make_avatar()
	avatar.visible = false                   # 第一人称看不到自己（正常）
	add_child(avatar)
	_charge_ball = _beam_ball(0.6, Color(0.62, 0.92, 1.0), 3.0)   # 蓄力能量球
	_charge_ball.visible = false
	_charge_mat = _charge_ball.mesh.material
	add_child(_charge_ball)
	_cine_cam = Camera3D.new()                                   # 放招侧面运镜相机
	_cine_cam.fov = 55
	add_child(_cine_cam)

	highlight = _make_highlight()
	placement_preview = _make_placement_preview()
	placement_blocked_preview = _make_blocked_placement_preview()
	brush_preview_lines = _make_brush_preview_lines()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _exit_tree() -> void:
	_free_overlay_node(highlight)
	_free_overlay_node(placement_preview)
	_free_overlay_node(placement_blocked_preview)
	_free_overlay_node(brush_preview_lines)

# 经节点路径取 Locale 自动加载单例（不要用裸标识符 `Locale`）：见顶部 i18n 注释。
var _loc_cached: Node
func _loc() -> Node:
	if _loc_cached != null and is_instance_valid(_loc_cached):
		return _loc_cached
	var tree := get_tree() if is_inside_tree() else null
	if tree != null and tree.root != null:
		_loc_cached = tree.root.get_node_or_null("Locale")
	if _loc_cached == null:
		_loc_cached = (load("res://scripts/Locale.gd") as GDScript).new()
		_loc_cached.call("load_strings")
	return _loc_cached

func _t(key: String) -> String:
	var l := _loc()
	return l.t(key) if l != null else key

func current_block() -> int:
	if lib != null and lib.has_def(selected_block_id):
		return selected_block_id
	return lib.hotbar_blocks()[sel_index]

func select_block_id(id: int, feedback_kind: String = "select") -> bool:
	if lib == null or not lib.has_def(id) or not lib.is_renderable(id):
		return false
	selected_block_id = id
	var blocks := lib.hotbar_blocks()
	for i in range(blocks.size()):
		if int(blocks[i]) == id:
			sel_index = i
			break
	var label := lib.block_name(current_block())
	if feedback_kind == "pick":
		label = _t("BUILD_PICK") % label
	action_feedback.emit(feedback_kind, label)
	return true

func set_recent_blocks(blocks: Array) -> void:
	recent_block_ids.clear()
	if lib == null:
		return
	for raw in blocks:
		var id := int(raw)
		if lib.has_def(id) and lib.is_renderable(id) and not recent_block_ids.has(id):
			recent_block_ids.append(id)
		if recent_block_ids.size() >= 8:
			break

func cycle_recent(step: int = 1) -> bool:
	if recent_block_ids.is_empty():
		return false
	var current := current_block()
	var idx := recent_block_ids.find(current)
	var next_idx := 0 if idx < 0 else posmod(idx + step, recent_block_ids.size())
	select_block_id(int(recent_block_ids[next_idx]))
	return true

func set_overlays_visible(enabled: bool) -> void:
	overlays_visible = enabled
	if not enabled:
		_hide_build_overlays()

# ---------- 命名动作入口（为发布期切 InputMap 预留；现在读 ACTION_KEYS 映射的物理键） ----------
func _action_keys(action: String) -> Array:
	return ACTION_KEYS.get(action, [])

# 把命名动作注册进 InputMap（用物理键），让游戏拥有正式输入映射：
# 可在此基础上加手柄事件 / 做重绑定 UI；_action_pressed 会优先读 InputMap，物理键查作兜底。
func _ensure_input_map() -> void:
	for action in ACTION_KEYS:
		if not InputMap.has_action(action):
			InputMap.add_action(action, 0.2)
		for code in ACTION_KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = int(code)
			if not _input_map_has_key(action, int(code)):
				InputMap.action_add_event(action, ev)

func _input_map_has_key(action: String, physical_keycode: int) -> bool:
	for existing in InputMap.action_get_events(action):
		if existing is InputEventKey and int(existing.physical_keycode) == physical_keycode:
			return true
	return false

# 持续按住型（移动/冲刺/飞行升降）——每帧轮询。
func _action_pressed(action: String) -> bool:
	# 优先走 InputMap（支持手柄/重绑定），同时保留物理键直查作兜底（零回归）。
	if InputMap.has_action(action) and Input.is_action_pressed(action):
		return true
	for code in _action_keys(action):
		if Input.is_physical_key_pressed(int(code)):
			return true
	return false

# 按下边沿型（切视角/模板/撤销等）——配合 _on_key 的按键码使用。
func _action_matches(action: String, code: int) -> bool:
	return _action_keys(action).has(code)

# 给 HUD 准星读：是否瞄准了方块。
func has_target() -> bool:
	return _has_target

# 给 HUD 准星读：当前放置意图状态 idle/ok/blocked（轻量，不重建预览网格）。
func aim_state() -> String:
	if not _has_target:
		return "idle"
	for cell in _placement_cells():
		if _place_blocked_reason(cell) != "":
			return "blocked"
	return "ok"

func _input(event: InputEvent) -> void:
	if not input_enabled:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		rotate_y(-event.relative.x * mouse_sensitivity)
		pitch = clampf(pitch - event.relative.y * mouse_sensitivity, -1.4, 1.4)
		spring.rotation.x = pitch
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event.keycode)
	elif event is InputEventMouseButton and event.pressed:
		_on_click(event.button_index)

func _on_key(code: int) -> void:
	if _action_matches("toggle_view", code):
		_toggle_view()
	elif _action_matches("jump", code):
		var now := Time.get_ticks_msec()
		if now - _last_space < 300:        # 双击跳跃键 = 切换飞行
			fly = not fly
			velocity.y = 0.0
			action_feedback.emit("mode", _t("HUD_MODE_FLY") if fly else _t("HUD_MODE_WALK"))
		_last_space = now
	elif _action_matches("cycle_recent", code):
		if not cycle_recent(1):
			action_feedback.emit("blocked", _t("FEEDBACK_NO_RECENT_MATERIAL"))
	elif _action_matches("toggle_brush", code):
		_toggle_build_brush()
	elif _action_matches("prev_template", code):
		_previous_build_template()
	elif _action_matches("toggle_template", code):
		_toggle_build_template()
	elif _action_matches("rotate_template", code):
		_rotate_build_template()
	elif _action_matches("undo", code):
		if world != null and world.has_method("undo_last_edit"):
			world.undo_last_edit()
	elif _action_matches("redo", code):
		if world != null and world.has_method("redo_last_edit"):
			world.redo_last_edit()
	elif code >= KEY_1 and code <= KEY_9:
		var i := code - KEY_1
		_select_slot(i)

func _toggle_view() -> void:
	view_mode = (view_mode + 1) % 3
	match view_mode:
		0:   # 第一人称
			spring.spring_length = 0.0
			spring.rotation.y = 0.0
			avatar.visible = false
		1:   # 第三人称：身后
			spring.spring_length = CAM_DIST
			spring.rotation.y = 0.0
			avatar.visible = true
		2:   # 第三人称：正面（相机绕到身前看脸）
			spring.spring_length = CAM_DIST
			spring.rotation.y = PI
			avatar.visible = true

func _on_click(button: int) -> void:
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED   # 先点回来抓鼠标
		return
	# 命名点击意图：break=左键挖 / place=右键放 / pick=中键取材（发布期可重映射到 InputMap）。
	if button == MOUSE_BUTTON_LEFT and _has_target:
		_try_break_target()
	elif button == MOUSE_BUTTON_RIGHT and _has_target:
		_try_place_current()
	elif button == MOUSE_BUTTON_MIDDLE:
		pick_target_block()
	elif button == MOUSE_BUTTON_WHEEL_UP:
		_select_slot(sel_index - 1)
	elif button == MOUSE_BUTTON_WHEEL_DOWN:
		_select_slot(sel_index + 1)

func pick_target_block() -> bool:
	if not _has_target or world == null or lib == null:
		action_feedback.emit("blocked", _t("FEEDBACK_NO_PICK_BLOCK"))
		return false
	var block_id: int = world.get_block(_target.x, _target.y, _target.z)
	if not lib.is_renderable(block_id):
		action_feedback.emit("blocked", _t("FEEDBACK_CANNOT_PICK"))
		return false
	if not select_block_id(block_id, "pick"):
		action_feedback.emit("blocked", _t("FEEDBACK_CANNOT_PICK"))
		return false
	material_picked.emit(block_id)
	return true

func _select_slot(i: int) -> void:
	var n := lib.hotbar_blocks().size()
	if n == 0:
		return
	var next := posmod(i, n)
	var next_id := int(lib.hotbar_blocks()[next])
	if next == sel_index and selected_block_id == next_id:
		return
	sel_index = next
	selected_block_id = next_id
	action_feedback.emit("select", lib.block_name(current_block()))

func _try_place_current() -> bool:
	if not _has_target:
		return false
	var edits := _placement_edits()
	var cells := _edit_cells(edits)
	var reason := _placement_blocked_reason(cells)
	if reason != "":
		action_feedback.emit("blocked", reason)
		world_feedback.emit("blocked", _place, current_block())
		return false
	var block_id := current_block()
	var placed := 0
	if world != null and world.has_method("request_block_edits"):
		placed = world.request_block_edits(edits)
	elif world != null and world.has_method("request_edits") and not _template_uses_fixed_blocks():
		placed = world.request_edits(cells, block_id)
	else:
		for raw in edits:
			var edit: Dictionary = raw
			var c: Vector3i = edit["pos"]
			var id := int(edit["id"])
			if world.request_edit(c.x, c.y, c.z, id):
				placed += 1
	if placed > 0:
		var label := build_template_label() if _template_uses_fixed_blocks() else lib.block_name(block_id)
		if build_template_id() != "off" and not _template_uses_fixed_blocks():
			label = _t("BUILD_TEMPLATE_PREFIX") % [build_template_label(), label]
		if placed > 1:
			label = _t("BUILD_COUNT_SUFFIX") % [label, placed]
		action_feedback.emit("place", label)
		if placed >= BULK_PLACE_EFFECT_THRESHOLD and build_template_id() != "campfire":
			world_feedback.emit("bulk_place", _bulk_feedback_cell(edits), _bulk_feedback_block_id(edits))
		if build_template_id() == "campfire":
			world_feedback.emit("campfire", _place, BlockLibrary.LANTERN)
		for raw in edits:
			var edit: Dictionary = raw
			var c: Vector3i = edit["pos"]
			world_feedback.emit("place", c, int(edit["id"]))
		return true
	action_feedback.emit("blocked", _t("FEEDBACK_CANNOT_PLACE"))
	world_feedback.emit("blocked", _place, block_id)
	return false

func _try_break_target() -> bool:
	if not _has_target or world == null:
		return false
	var cells := _break_cells()
	var removed := []
	for cell in cells:
		var c: Vector3i = cell
		var before: int = world.get_block(c.x, c.y, c.z)
		if before != BlockLibrary.AIR:
			removed.append({"cell": c, "id": before})
	var changed := 0
	if world.has_method("request_edits"):
		changed = world.request_edits(cells, BlockLibrary.AIR)
	else:
		for entry in removed:
			var item: Dictionary = entry
			var c: Vector3i = item["cell"]
			if world.request_edit(c.x, c.y, c.z, BlockLibrary.AIR):
				changed += 1
	if changed <= 0:
		action_feedback.emit("blocked", _t("FEEDBACK_NO_BREAK_BLOCK"))
		world_feedback.emit("blocked", _target, BlockLibrary.AIR)
		return false
	var label := _t("BUILD_MINE")
	if changed > 1:
		label = _t("BUILD_COUNT_SUFFIX") % [_t("BUILD_MINE"), changed]
	action_feedback.emit("break", label)
	var emitted := 0
	for entry in removed:
		if emitted >= changed:
			break
		var item: Dictionary = entry
		var c: Vector3i = item["cell"]
		world_feedback.emit("break", c, int(item["id"]))
		emitted += 1
	return true

func _physics_process(delta: float) -> void:
	_kame_cooldown = maxf(0.0, _kame_cooldown - delta)
	_kame_fire_t = maxf(0.0, _kame_fire_t - delta)
	_update_kame_charge(delta)
	_update_cinematic(delta)
	if not input_enabled:
		velocity = Vector3.ZERO
		return
	var dir := Vector3.ZERO
	if _action_pressed("move_forward"): dir -= transform.basis.z
	if _action_pressed("move_back"): dir += transform.basis.z
	if _action_pressed("move_left"): dir -= transform.basis.x
	if _action_pressed("move_right"): dir += transform.basis.x

	var moving := dir.length_squared() > 0.01
	var running := _action_pressed("sprint")

	if fly:
		dir.y = 0.0
		if _action_pressed("jump"): dir.y += 1.0
		if _action_pressed("fly_descend"): dir.y -= 1.0
		velocity = dir.normalized() * FLY
	else:
		var speed := RUN if running else WALK
		var flat := Vector3(dir.x, 0, dir.z).normalized()
		velocity.x = flat.x * speed
		velocity.z = flat.z * speed
		velocity.y -= GRAVITY * delta
		if _action_pressed("jump") and is_on_floor():
			velocity.y = JUMP

	move_and_slide()
	_check_void_respawn()
	_update_ground_audio()
	_update_camera_motion(delta, moving, running)
	_update_highlight()

func _update_camera_motion(delta: float, moving: bool, running: bool) -> void:
	var target_y := 1.62
	if moving and is_on_floor() and not fly:
		_bob += delta * (13.0 if running else 9.0)
		target_y += sin(_bob) * (0.045 if running else 0.028)
		var step_phase := int(_bob / PI)
		if step_phase != _step_phase:
			_step_phase = step_phase
			footstep.emit(_block_under_feet())
	else:
		_bob = lerpf(_bob, 0.0, minf(delta * 4.0, 1.0))
		_step_phase = int(_bob / PI)
	spring.position.y = lerpf(spring.position.y, target_y, minf(delta * 9.0, 1.0))
	var target_fov := 79.0 if fly else (76.0 if running and moving else 72.0)
	camera.fov = lerpf(camera.fov, target_fov, minf(delta * 5.0, 1.0))
	_animate_avatar(delta, moving and is_on_floor() and not fly, running)

# 掉出世界底部时重生回当前位置地表，避免永久坠落。
func _check_void_respawn() -> void:
	if global_position.y >= -8.0 or world == null:
		return
	var gx := int(floor(global_position.x))
	var gz := int(floor(global_position.z))
	var sy: int = world.surface_y(gx, gz)
	global_position = Vector3(gx + 0.5, float(sy) + 3.0, gz + 0.5)
	velocity = Vector3.ZERO
	action_feedback.emit("blocked", _t("FEEDBACK_VOID_RESPAWN"))

# 落地 / 入水的音频事件（脚步在 _update_camera_motion 里按步幅触发）。
func _update_ground_audio() -> void:
	var on_floor := is_on_floor()
	if on_floor and not _was_on_floor and not fly:
		landed.emit(_block_under_feet())
	_was_on_floor = on_floor
	var in_water := _block_under_feet() == 9   # WATER
	if in_water and not _was_in_water:
		splashed.emit()
	_was_in_water = in_water

# 脚下所踩方块的 id（给脚步音选材质）。
func _block_under_feet() -> int:
	if world == null:
		return 0
	var gx := int(floor(global_position.x))
	var gy := int(floor(global_position.y - 0.5))
	var gz := int(floor(global_position.z))
	return world.get_block(gx, gy, gz)

# ---------- 准星射线：找瞄准的方块 ----------
func _update_highlight() -> void:
	if world == null:
		return
	if overlays_visible and not highlight.is_inside_tree():
		world.add_child(highlight)     # 挂在世界下（不随玩家旋转）
	# 从头部沿"玩家朝向(偏航+俯仰)"射线 —— 与相机模式无关，正面视角下也照样朝前方挖
	var from := spring.global_position
	var aim := global_transform.basis * (Basis(Vector3.RIGHT, pitch) * Vector3(0, 0, -1))
	var to := from + aim * REACH
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collide_with_bodies = true
	q.exclude = [get_rid()]            # 别打到自己（第三人称相机在身后时尤其要排除）
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit.is_empty():
		_has_target = false
		_hide_build_overlays()
		return
	var pos: Vector3 = hit["position"]
	var nrm: Vector3 = hit["normal"]
	_target = Vector3i((pos - nrm * 0.5).floor())
	_place = Vector3i((pos + nrm * 0.5).floor())
	_target_normal = _normal_to_cell(nrm)
	_has_target = true
	if not overlays_visible:
		_hide_build_overlays()
		return
	highlight.visible = true
	highlight.global_position = Vector3(_target) + Vector3(0.5, 0.5, 0.5)
	_update_placement_preview()

func _update_placement_preview() -> void:
	if world == null or placement_preview == null or placement_blocked_preview == null:
		return
	if not overlays_visible:
		_hide_build_overlays()
		return
	if not placement_preview.is_inside_tree():
		world.add_child(placement_preview)
	if not placement_blocked_preview.is_inside_tree():
		world.add_child(placement_blocked_preview)
	var edits := _placement_edits()
	var cells := _edit_cells(edits)
	var blocked_cells := _blocked_placement_cells(cells)
	var ok := blocked_cells.is_empty()
	placement_preview.visible = true
	var origin := _preview_center(cells)
	var multi := cells.size() > 1
	var alpha := 0.24 if multi else 0.42
	var preview_color := _current_preview_color(alpha)
	_preview_material.albedo_color = preview_color
	_preview_material.emission = _preview_material.albedo_color
	_update_placement_preview_mesh(placement_preview, edits, origin, false, alpha)
	placement_preview.global_position = origin
	placement_preview.scale = Vector3.ONE
	_update_blocked_placement_preview(blocked_cells, origin, multi)
	_update_brush_preview_lines(cells, ok)

func placement_intent_summary() -> Dictionary:
	var mode := build_mode_label()
	var material := lib.block_name(current_block()) if lib != null else _t("BUILD_MATERIAL_FALLBACK")
	if not _has_target:
		return {
			"state": _t("BUILD_AWAIT_TARGET"),
			"state_kind": "idle",
			"mode": mode,
			"material": material,
			"detail": _t("BUILD_NO_AIM"),
			"count": 0,
			"blocked_count": 0,
			"footprint": "",
			"reason": "",
		}
	var edits := _placement_edits()
	var cells := _edit_cells(edits)
	var reason := _placement_blocked_reason(cells)
	var blocked_cells := _blocked_placement_cells(cells)
	var footprint := _placement_footprint_label(cells)
	var count := cells.size()
	var material_label := _t("BUILD_MULTI_MATERIAL") if _template_uses_fixed_blocks() else material
	var detail := _t("BUILD_DETAIL") % [material_label, count]
	if footprint != "":
		detail = _t("BUILD_DETAIL_FOOTPRINT") % [detail, footprint]
	var state := _t("BUILD_PLACEABLE")
	var state_kind := "ok"
	if reason != "":
		state_kind = "blocked"
		state = _t("BUILD_BLOCKED_COUNT") % maxi(1, blocked_cells.size())
	return {
		"state": state,
		"state_kind": state_kind,
		"mode": mode,
		"material": material_label,
		"detail": detail,
		"count": count,
		"blocked_count": blocked_cells.size(),
		"footprint": footprint,
		"reason": reason,
	}

func build_mode_label() -> String:
	if build_template_id() != "off":
		return _t("BUILD_MODE_TEMPLATE") % [build_template_label(), build_template_orientation_label()]
	if brush_radius() > 0:
		return _t("BUILD_MODE_BRUSH") % brush_label()
	return _t("BUILD_MODE_SINGLE")

func _placement_footprint_label(cells: Array) -> String:
	if cells.is_empty():
		return ""
	var min_cell: Vector3i = cells[0]
	var max_cell: Vector3i = cells[0]
	for raw in cells:
		var c: Vector3i = raw
		min_cell.x = mini(min_cell.x, c.x)
		min_cell.y = mini(min_cell.y, c.y)
		min_cell.z = mini(min_cell.z, c.z)
		max_cell.x = maxi(max_cell.x, c.x)
		max_cell.y = maxi(max_cell.y, c.y)
		max_cell.z = maxi(max_cell.z, c.z)
	var size := max_cell - min_cell + Vector3i.ONE
	return _t("BUILD_FOOTPRINT") % [size.x, size.y, size.z]

func _can_place_at(cell: Vector3i) -> bool:
	return _place_blocked_reason(cell) == ""

func _placement_blocked_reason(cells: Array) -> String:
	for cell in cells:
		var c: Vector3i = cell
		var reason := _place_blocked_reason(c)
		if reason != "":
			return reason
	return ""

func _blocked_placement_cells(cells: Array) -> Array:
	var blocked := []
	for cell in cells:
		var c: Vector3i = cell
		if _place_blocked_reason(c) != "":
			blocked.append(c)
	return blocked

func _current_preview_color(alpha: float) -> Color:
	var col := Color(0.05, 1.0, 0.92, 1.0)
	if build_template_id() == "campfire":
		col = Color(1.0, 0.56, 0.18, 1.0)
	elif build_template_id() == "bridge" and lib != null and lib.has_method("preview_color"):
		col = lib.preview_color(BlockLibrary.PLANKS)
	elif build_template_id() == "garden":
		col = Color(0.82, 1.0, 0.52, 1.0)
	elif build_template_id() == "cabin" and lib != null and lib.has_method("preview_color"):
		col = lib.preview_color(BlockLibrary.PLANKS)
	elif build_template_id() == "beacon_tower" and lib != null and lib.has_method("preview_color"):
		col = lib.preview_color(BlockLibrary.MOONSTONE_LAMP)
	elif build_template_id() == "signpost" and lib != null and lib.has_method("preview_color"):
		col = lib.preview_color(BlockLibrary.LOG)
	elif lib != null and lib.has_method("preview_color"):
		col = lib.preview_color(current_block())
	col.a = alpha
	return col

func brush_radius() -> int:
	return int(BRUSH_RADII[brush_index])

func brush_label() -> String:
	var diameter := brush_radius() * 2 + 1
	return "%dx%d" % [diameter, diameter]

func _toggle_build_brush() -> void:
	brush_index = posmod(brush_index + 1, BRUSH_RADII.size())
	if brush_radius() > 0:
		template_index = 0
	action_feedback.emit("mode", _t("BUILD_MODE_BRUSH") % brush_label())

func build_template_id() -> String:
	var meta: Dictionary = BUILD_TEMPLATES[template_index]
	return String(meta.get("id", "off"))

func build_template_label() -> String:
	var meta: Dictionary = BUILD_TEMPLATES[template_index]
	return String(meta.get("label", "关闭"))

func build_template_count() -> int:
	return BUILD_TEMPLATES.size()

func build_template_index() -> int:
	return template_index

func build_template_id_at(index: int) -> String:
	var meta: Dictionary = BUILD_TEMPLATES[posmod(index, BUILD_TEMPLATES.size())]
	return String(meta.get("id", "off"))

func build_template_label_at(index: int) -> String:
	var meta: Dictionary = BUILD_TEMPLATES[posmod(index, BUILD_TEMPLATES.size())]
	return String(meta.get("label", "关闭"))

func build_template_orientation_label() -> String:
	if build_template_id() == "off":
		return ""
	return _t("BUILD_ORIENT_EW") if template_orientation_index == 0 else _t("BUILD_ORIENT_NS")

# ---------- 外部代理 / 脚本入口：按模板 id 在指定锚点一键放置 ----------
# 纯几何由 BuildTemplates.edits_for 计算（不依赖 Player 上下文）；
# 结果直接提交到 world.request_block_edits。
# template_id：BUILD_TEMPLATES 里的 id（如 "campfire"）；"off"/未知返回 -1。
# orientation：0=东西，1=南北。返回实际改动的方块数。
func apply_build_template(template_id: String, origin: Vector3i, orientation: int = 0) -> int:
	if world == null:
		return -1
	if template_id == "off" or _build_template_index_for(template_id) < 0:
		return -1
	# 纯几何来自 BuildTemplates（与游戏内放置同一来源）；不改动玩家的任何放置上下文。
	var edits := BuildTemplates.edits_for(template_id, origin, posmod(orientation, 2), current_block())
	if world.has_method("request_block_edits"):
		return int(world.request_block_edits(edits))
	return 0

func _build_template_index_for(template_id: String) -> int:
	for i in range(BUILD_TEMPLATES.size()):
		var meta: Dictionary = BUILD_TEMPLATES[i]
		if String(meta.get("id", "")) == template_id:
			return i
	return -1

func _toggle_build_template() -> void:
	_step_build_template(1)

func _previous_build_template() -> void:
	_step_build_template(-1)

func _step_build_template(step: int) -> void:
	template_index = posmod(template_index + step, BUILD_TEMPLATES.size())
	if build_template_id() != "off":
		brush_index = 0
	action_feedback.emit("mode", _build_template_status_label())

func _rotate_build_template() -> bool:
	if build_template_id() == "off":
		action_feedback.emit("blocked", _t("FEEDBACK_SELECT_TEMPLATE_FIRST"))
		return false
	template_orientation_index = posmod(template_orientation_index + 1, 2)
	action_feedback.emit("mode", _build_template_status_label())
	if _has_target:
		_update_placement_preview()
	return true

func _build_template_status_label() -> String:
	if build_template_id() == "off":
		return _t("BUILD_TEMPLATE_OFF")
	return _t("BUILD_MODE_TEMPLATE") % [build_template_label(), build_template_orientation_label()]

func _placement_cells() -> Array:
	var template_cells := _edit_cells(_template_edits())
	if not template_cells.is_empty():
		return template_cells
	var radius := brush_radius()
	if radius <= 0:
		return [_place]
	var axes := _brush_axes(_target_normal)
	var axis_a: Vector3i = axes[0]
	var axis_b: Vector3i = axes[1]
	var cells := []
	for b in range(-radius, radius + 1):
		for a in range(-radius, radius + 1):
			cells.append(_place + axis_a * a + axis_b * b)
	return cells

# 模板格/方块的唯一几何来源：委托给 node-free 的 BuildTemplates。
# 简单模板用当前选中方块（current_block）填充；装饰模板自带方块 id。非模板返回 []。
# 例外：交互式 platform 用 _brush_axes(_target_normal) 计算 5×5 footprint，
# 这样对着竖直墙面瞄准时平台会贴合墙面（保留重构前的手感）。地面(法线=UP)与
# BuildTemplates 朝向0 等价。Agent/headless 的 apply_build_template 仍直接用
# BuildTemplates.edits_for（服务端没有法线），保持几何来源单一。
func _template_edits() -> Array:
	if build_template_id() == "platform":
		return _interactive_platform_edits()
	return BuildTemplates.edits_for(build_template_id(), _place, template_orientation_index, current_block())

func _interactive_platform_edits() -> Array:
	var axes := _brush_axes(_target_normal)
	var axis_a: Vector3i = axes[0]
	var axis_b: Vector3i = axes[1]
	var block_id := current_block()
	var edits := []
	for b in range(-2, 3):
		for a in range(-2, 3):
			edits.append({"pos": _place + axis_a * a + axis_b * b, "id": block_id})
	return edits

func _placement_edits() -> Array:
	var template_edits := _template_edits()
	if not template_edits.is_empty():
		return template_edits
	var edits := []
	var block_id := current_block()
	for raw in _placement_cells():
		var cell: Vector3i = raw
		edits.append({"pos": cell, "id": block_id})
	return edits

func _edit_cells(edits: Array) -> Array:
	var cells := []
	for raw in edits:
		var edit: Dictionary = raw
		cells.append(edit.get("pos", Vector3i.ZERO))
	return cells

func _bulk_feedback_cell(edits: Array) -> Vector3i:
	if edits.is_empty():
		return _place
	var sum := Vector3.ZERO
	for raw in edits:
		var edit: Dictionary = raw
		var c: Vector3i = edit.get("pos", _place)
		sum += Vector3(c)
	var avg := sum / float(edits.size())
	return Vector3i(roundi(avg.x), roundi(avg.y), roundi(avg.z))

func _bulk_feedback_block_id(edits: Array) -> int:
	if edits.is_empty():
		return current_block()
	match build_template_id():
		"bridge", "cabin":
			return BlockLibrary.PLANKS
		"garden":
			return BlockLibrary.GRASS
		"beacon_tower":
			return BlockLibrary.MOONSTONE_LAMP
		"signpost":
			return BlockLibrary.LOG
	var first: Dictionary = edits[0]
	return int(first.get("id", current_block()))

func _cell_edits(cells: Array, block_id: int) -> Array:
	var edits := []
	for raw in cells:
		var cell: Vector3i = raw
		edits.append({"pos": cell, "id": block_id})
	return edits

func _template_uses_fixed_blocks() -> bool:
	return build_template_id() in BuildTemplates.DECORATED

func _break_cells() -> Array:
	var radius := brush_radius()
	if radius <= 0:
		return [_target]
	var axes := _brush_axes(_target_normal)
	var axis_a: Vector3i = axes[0]
	var axis_b: Vector3i = axes[1]
	var cells := []
	for b in range(-radius, radius + 1):
		for a in range(-radius, radius + 1):
			cells.append(_target + axis_a * a + axis_b * b)
	return cells

func _preview_center(cells: Array) -> Vector3:
	if cells.is_empty():
		return Vector3(_place) + Vector3(0.5, 0.5, 0.5)
	var sum := Vector3.ZERO
	for cell in cells:
		var c: Vector3i = cell
		sum += Vector3(c) + Vector3(0.5, 0.5, 0.5)
	return sum / float(cells.size())

func _update_placement_preview_mesh(node: MeshInstance3D, edits: Array, origin: Vector3, blocked: bool, alpha: float = 0.42) -> void:
	var key := _placement_preview_key(edits)
	if blocked and key == _blocked_preview_mesh_key:
		return
	if not blocked and key == _preview_mesh_key:
		return
	if blocked:
		_blocked_preview_mesh_key = key
	else:
		_preview_mesh_key = key
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_blocked_preview_material if blocked else _preview_material)
	var half := Vector3(0.47, 0.47, 0.47)
	for raw in edits:
		var edit: Dictionary = raw
		var c: Vector3i = edit.get("pos", Vector3i.ZERO)
		var id := int(edit.get("id", current_block()))
		var center := Vector3(c) + Vector3(0.5, 0.5, 0.5) - origin
		var color := Color(1, 1, 1, alpha) if blocked else _preview_color_for_block(id, alpha)
		_add_box_mesh(st, center - half, center + half, color)
	node.mesh = st.commit()

func _update_blocked_placement_preview(cells: Array, origin: Vector3, multi: bool) -> void:
	if cells.is_empty():
		placement_blocked_preview.visible = false
		placement_blocked_preview.mesh = null
		_blocked_preview_mesh_key = ""
		return
	var alpha := 0.34 if multi else 0.50
	_blocked_preview_material.albedo_color = Color(1.0, 0.12, 0.10, alpha)
	_blocked_preview_material.emission = _blocked_preview_material.albedo_color
	_update_placement_preview_mesh(placement_blocked_preview, _cell_edits(cells, current_block()), origin, true, alpha)
	placement_blocked_preview.global_position = origin
	placement_blocked_preview.scale = Vector3.ONE
	placement_blocked_preview.visible = true

func _placement_preview_key(edits: Array) -> String:
	var key := ""
	for raw in edits:
		var edit: Dictionary = raw
		var c: Vector3i = edit.get("pos", Vector3i.ZERO)
		key += "%d,%d,%d:%d|" % [c.x, c.y, c.z, int(edit.get("id", current_block()))]
	return key

func _update_brush_preview_lines(cells: Array, ok: bool) -> void:
	if brush_preview_lines == null:
		return
	if not overlays_visible or cells.size() <= 1:
		brush_preview_lines.visible = false
		brush_preview_lines.mesh = null
		return
	if world != null and not brush_preview_lines.is_inside_tree():
		world.add_child(brush_preview_lines)
	var col := Color(0.78, 1.0, 0.38, 0.94) if ok else Color(1.0, 0.18, 0.12, 0.96)
	_brush_line_material.albedo_color = col
	_brush_line_material.emission = Color(col.r, col.g, col.b) * 0.8
	var origin := _preview_center(cells)
	brush_preview_lines.global_position = origin
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_material(_brush_line_material)
	for cell in cells:
		var c: Vector3i = cell
		for segment in _cell_face_segments(c, _target_normal):
			var pair: Array = segment
			var a: Vector3 = pair[0]
			var b: Vector3 = pair[1]
			_add_brush_bar(st, a - origin, b - origin)
	brush_preview_lines.mesh = st.commit()
	brush_preview_lines.visible = true

func _cell_face_segments(cell: Vector3i, normal: Vector3i) -> Array:
	var p := Vector3(cell)
	var a := Vector3.ZERO
	var b := Vector3.ZERO
	var c := Vector3.ZERO
	var d := Vector3.ZERO
	var inset := 0.025
	if abs(normal.y) > 0:
		var y := p.y + (1.0 + inset if normal.y > 0 else -inset)
		a = Vector3(p.x, y, p.z)
		b = Vector3(p.x + 1.0, y, p.z)
		c = Vector3(p.x + 1.0, y, p.z + 1.0)
		d = Vector3(p.x, y, p.z + 1.0)
	elif abs(normal.x) > 0:
		var x := p.x + (1.0 + inset if normal.x > 0 else -inset)
		a = Vector3(x, p.y, p.z)
		b = Vector3(x, p.y + 1.0, p.z)
		c = Vector3(x, p.y + 1.0, p.z + 1.0)
		d = Vector3(x, p.y, p.z + 1.0)
	else:
		var z := p.z + (1.0 + inset if normal.z > 0 else -inset)
		a = Vector3(p.x, p.y, z)
		b = Vector3(p.x + 1.0, p.y, z)
		c = Vector3(p.x + 1.0, p.y + 1.0, z)
		d = Vector3(p.x, p.y + 1.0, z)
	return [[a, b], [b, c], [c, d], [d, a]]

func _add_brush_bar(st: SurfaceTool, a: Vector3, b: Vector3) -> void:
	var delta := b - a
	var length := delta.length()
	if length <= 0.001:
		return
	var thickness := 0.06
	var scale := Vector3(thickness, thickness, thickness)
	if absf(delta.x) >= absf(delta.y) and absf(delta.x) >= absf(delta.z):
		scale.x = length
	elif absf(delta.y) >= absf(delta.x) and absf(delta.y) >= absf(delta.z):
		scale.y = length
	else:
		scale.z = length
	var center := (a + b) * 0.5
	var half := scale * 0.5
	_add_box_mesh(st, center - half, center + half)

func _add_box_mesh(st: SurfaceTool, min_v: Vector3, max_v: Vector3, color: Color = Color(1, 1, 1, 1)) -> void:
	var v := [
		Vector3(min_v.x, min_v.y, min_v.z), Vector3(max_v.x, min_v.y, min_v.z),
		Vector3(max_v.x, max_v.y, min_v.z), Vector3(min_v.x, max_v.y, min_v.z),
		Vector3(min_v.x, min_v.y, max_v.z), Vector3(max_v.x, min_v.y, max_v.z),
		Vector3(max_v.x, max_v.y, max_v.z), Vector3(min_v.x, max_v.y, max_v.z),
	]
	var idx := [
		0, 1, 2, 0, 2, 3,
		5, 4, 7, 5, 7, 6,
		4, 0, 3, 4, 3, 7,
		1, 5, 6, 1, 6, 2,
		3, 2, 6, 3, 6, 7,
		4, 5, 1, 4, 1, 0,
	]
	for i in idx:
		st.set_color(color)
		st.add_vertex(v[i])

func _preview_color_for_block(block_id: int, alpha: float) -> Color:
	var col := Color(0.05, 1.0, 0.92, 1.0)
	if lib != null and lib.has_method("preview_color"):
		col = lib.preview_color(block_id)
	col.a = alpha
	return col

func _brush_axes(normal: Vector3i) -> Array:
	if abs(normal.y) > 0:
		return [Vector3i.RIGHT, Vector3i(0, 0, 1)]
	if abs(normal.x) > 0:
		return [Vector3i(0, 1, 0), Vector3i(0, 0, 1)]
	return [Vector3i.RIGHT, Vector3i(0, 1, 0)]

func _template_right_axis() -> Vector3i:
	return Vector3i.RIGHT if template_orientation_index == 0 else Vector3i(0, 0, 1)

func _template_depth_axis() -> Vector3i:
	return Vector3i(0, 0, 1) if template_orientation_index == 0 else Vector3i.RIGHT

func _normal_to_cell(normal: Vector3) -> Vector3i:
	var ax := absf(normal.x)
	var ay := absf(normal.y)
	var az := absf(normal.z)
	if ax >= ay and ax >= az:
		return Vector3i(1 if normal.x >= 0.0 else -1, 0, 0)
	if ay >= ax and ay >= az:
		return Vector3i(0, 1 if normal.y >= 0.0 else -1, 0)
	return Vector3i(0, 0, 1 if normal.z >= 0.0 else -1)

func _hide_build_overlays() -> void:
	if highlight != null:
		highlight.visible = false
	if placement_preview != null:
		placement_preview.visible = false
	if placement_blocked_preview != null:
		placement_blocked_preview.visible = false
	if brush_preview_lines != null:
		brush_preview_lines.visible = false

func _place_blocked_reason(cell: Vector3i) -> String:
	if world == null or lib == null:
		return _t("BLOCKED_CANNOT_PLACE")
	if cell.y < 0 or cell.y >= Chunk.SY:
		return _t("BLOCKED_ABOVE_HEIGHT")
	if _blocked_by_self(cell):
		return _t("BLOCKED_TRAP_PLAYER")
	var existing: int = world.get_block(cell.x, cell.y, cell.z)
	if existing != BlockLibrary.AIR and lib.is_solid(existing):
		return _t("BLOCKED_CELL_OCCUPIED")
	return ""

func _blocked_by_self(cell: Vector3i) -> bool:
	var p := global_position
	return cell.x >= floori(p.x - 0.35) and cell.x <= floori(p.x + 0.35) \
		and cell.z >= floori(p.z - 0.35) and cell.z <= floori(p.z + 0.35) \
		and cell.y >= floori(p.y) and cell.y <= floori(p.y + 1.7)

func _free_overlay_node(node: Node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var parent := node.get_parent()
	if parent != null:
		parent.remove_child(node)
	node.free()

# ---------- 方块小人 Avatar ----------
func _make_avatar() -> Node3D:
	var root := Node3D.new()
	var skin := Color(0.86, 0.68, 0.54)
	var hair := Color(0.12, 0.08, 0.04)
	var eye := Color(0.05, 0.06, 0.08)
	var shirt := Color(0.20, 0.50, 0.80)
	var pants := Color(0.26, 0.27, 0.38)
	root.add_child(_box(Vector3(0.5, 0.5, 0.5), Vector3(0, 1.45, 0), skin))       # 头
	root.add_child(_box(Vector3(0.52, 0.16, 0.52), Vector3(0, 1.64, 0), hair))     # 头发
	root.add_child(_box(Vector3(0.07, 0.07, 0.025), Vector3(-0.11, 1.48, -0.265), eye))
	root.add_child(_box(Vector3(0.07, 0.07, 0.025), Vector3(0.11, 1.48, -0.265), eye))
	root.add_child(_box(Vector3(0.5, 0.62, 0.28), Vector3(0, 0.94, 0), shirt))    # 身体
	# 四肢用关节(pivot)挂在肩/胯，绕 X 轴摆动 = 走路动画（不再是钉死的方块）
	_arm_l = _limb_pivot(Vector3(-0.34, 1.25, 0), Vector3(0.18, 0.62, 0.22), shirt)
	_arm_r = _limb_pivot(Vector3(0.34, 1.25, 0), Vector3(0.18, 0.62, 0.22), shirt)
	_leg_l = _limb_pivot(Vector3(-0.13, 0.64, 0), Vector3(0.22, 0.64, 0.24), pants)
	_leg_r = _limb_pivot(Vector3(0.13, 0.64, 0), Vector3(0.22, 0.64, 0.24), pants)
	root.add_child(_arm_l); root.add_child(_arm_r)
	root.add_child(_leg_l); root.add_child(_leg_r)
	# 披风：挂在上背关节，站立下垂、飞行后扬抖动（超人红）
	_cape = Node3D.new()
	_cape.position = Vector3(0, 1.28, 0.17)
	_cape.add_child(_box(Vector3(0.46, 0.72, 0.05), Vector3(0, -0.36, 0), Color(0.72, 0.10, 0.10)))
	root.add_child(_cape)
	return root

# 关节肢体：pivot 在关节(肩/胯)，盒子挂在 pivot 正下方半长 -> 绕 pivot 摆动自然。
func _limb_pivot(joint: Vector3, size: Vector3, col: Color) -> Node3D:
	var pivot := Node3D.new()
	pivot.position = joint
	pivot.add_child(_box(size, Vector3(0, -size.y * 0.5, 0), col))
	return pivot

# 走路循环：腿前后摆、手反向摆，整体随步幅轻微起伏；幅度随移动平滑淡入淡出。
func _animate_avatar(delta: float, walking: bool, running: bool) -> void:
	if avatar == null:
		return
	_anim_t += delta
	_anim_amount = lerpf(_anim_amount, 1.0 if walking else 0.0, minf(delta * 10.0, 1.0))
	_fly_amount = lerpf(_fly_amount, 1.0 if fly else 0.0, minf(delta * 6.0, 1.0))
	var swing := sin(_bob) * _anim_amount
	var leg := swing * (0.85 if running else 0.68)
	var arm := swing * (0.62 if running else 0.48)
	var flutter := sin(_anim_t * 9.0) * 0.16
	# 身体：地面直立；飞行时前倾近水平（超人姿态）
	avatar.rotation.x = lerpf(0.0, -1.35, _fly_amount)
	avatar.position.y = absf(sin(_bob)) * 0.045 * _anim_amount + lerpf(0.0, 0.2, _fly_amount)
	# 腿：走路前后交替；飞行并直后拖
	if _leg_l != null: _leg_l.rotation.x = lerpf(leg, -0.06, _fly_amount)
	if _leg_r != null: _leg_r.rotation.x = lerpf(-leg, -0.16, _fly_amount)
	# 手：走路反向摆；飞行右臂前伸(超人拳)、左臂贴身
	if _arm_l != null: _arm_l.rotation.x = lerpf(-arm, 0.4, _fly_amount)
	if _arm_r != null: _arm_r.rotation.x = lerpf(arm, -2.8, _fly_amount)
	# 披风：站立微摆下垂；飞行后扬 + 抖动
	if _cape != null:
		var cape_ground := 0.16 + sin(_bob) * 0.06 * _anim_amount
		_cape.rotation.x = lerpf(cape_ground, -1.75 + flutter, _fly_amount)
	# 龟派气功波手臂配合：蓄力时双手前伸合拢抱住能量球；发射瞬间双手猛推到底
	if _kame_fire_t > 0.0:
		if _arm_l != null: _arm_l.rotation.x = -2.85
		if _arm_r != null: _arm_r.rotation.x = -2.85
	elif _charging:
		# 随蓄力从微张到合拢前伸（抱球感）
		var cup := lerpf(-2.25, -2.55, clampf(_kame_charge / KAME_CHARGE_MIN, 0.0, 1.0))
		if _arm_l != null: _arm_l.rotation.x = cup
		if _arm_r != null: _arm_r.rotation.x = cup

# ---------- 隐藏技能：龟派气功波（飞行中长按 C 蓄力 ≥5 秒，松手发射；蓄越久威力越大）----------
func _aim_dir() -> Vector3:
	return (global_transform.basis * (Basis(Vector3.RIGHT, pitch) * Vector3(0, 0, -1))).normalized()

func _update_kame_charge(delta: float) -> void:
	var can_charge := fly and input_enabled and _kame_cooldown <= 0.0
	var holding := can_charge and Input.is_physical_key_pressed(KAME_KEY)
	if holding:
		_charging = true
		_kame_charge = minf(_kame_charge + delta, KAME_CHARGE_MAX)
		_update_charge_ball()
	else:
		if _charging and fly and input_enabled and _kame_charge >= KAME_CHARGE_MIN:
			_fire_kamehameha(_kame_charge)
		_charging = false
		_kame_charge = 0.0
		if _charge_ball != null:
			_charge_ball.visible = false

# 蓄力能量球：随蓄力变大变亮，满（≥5秒）后强烈脉动提示可发射。
func _update_charge_ball() -> void:
	if _charge_ball == null:
		return
	var frac := clampf(_kame_charge / KAME_CHARGE_MIN, 0.0, 1.0)
	var ready := _kame_charge >= KAME_CHARGE_MIN
	_charge_ball.global_position = spring.global_position + _aim_dir() * 1.9
	var pulse := 1.0 + (0.15 * sin(_anim_t * 20.0) if ready else 0.0)
	var s := lerpf(0.12, 0.95, frac) * pulse
	_charge_ball.scale = Vector3(s, s, s)
	_charge_ball.visible = true
	if _charge_mat != null:
		var e := lerpf(2.0, 7.5, frac)
		if ready:
			e += 3.0 + 2.0 * sin(_anim_t * 20.0)
		_charge_mat.emission_energy_multiplier = e

# 放招运镜：蓄力≥1秒起 + 发射后 1.2 秒，切到侧面电影机位；结束切回原相机。
func _update_cinematic(delta: float) -> void:
	if _cine_cam == null or camera == null:
		return
	if _cine_t > 0.0:
		_cine_t = maxf(0.0, _cine_t - delta)
	var want := (_charging and _kame_charge >= 1.0) or _cine_t > 0.0
	if want:
		if avatar != null:
			avatar.visible = true          # 运镜时强制显示小人（即使第一人称也要看到他放招）
		_position_cine_cam()
		if not _cine_cam.current:
			_cine_cam.current = true
	elif _cine_cam.current:
		camera.current = true              # 切回玩家原相机（第一/第三人称）
		if avatar != null:
			avatar.visible = view_mode != 0

func _position_cine_cam() -> void:
	var aim := _aim_dir()
	# 发射后先近景 ~0.3 秒看清"猛推手 + 光柱喷出"，再拉成全景看整条光柱贯穿
	if _cine_t > 0.0 and _cine_t <= 0.9 and _kame_beam_to != _kame_beam_from:
		var a := _kame_beam_from
		var b := _kame_beam_to
		var mid := (a + b) * 0.5
		var dir := (b - a).normalized()
		var side := dir.cross(Vector3.UP).normalized()
		if side.length() < 0.1:
			side = global_transform.basis.x
		var blen := a.distance_to(b)
		var dist := blen * 0.6 + 8.0                        # 按光柱长度拉远
		_cine_cam.fov = 62.0
		# 高一点的 3/4 侧俯视：既看到整条光柱横贯，又能俯瞰命中点炸开的坑
		_cine_cam.global_position = mid + side * dist + Vector3(0, clampf(blen * 0.42, 10.0, 42.0), 0)
		_cine_cam.look_at(mid, Vector3.UP)
		return
	# 蓄力中：近景看小人聚气
	var body: Vector3 = global_position + Vector3(0, 0.9, 0)
	var side2 := aim.cross(Vector3.UP).normalized()
	if side2.length() < 0.1:
		side2 = global_transform.basis.x
	_cine_cam.fov = 50.0
	_cine_cam.global_position = body + side2 * 6.0 + Vector3(0, 1.7, 0) - aim * 1.0
	_cine_cam.look_at(body + aim * 2.5, Vector3.UP)

func _fire_kamehameha(charge: float = 5.0) -> void:
	if world == null:
		return
	_kame_cooldown = 1.5
	_kame_fire_t = 0.8
	_cine_t = 1.2                                 # 发射后侧面运镜保持
	var power := clampf((charge - KAME_CHARGE_MIN) / (KAME_CHARGE_MAX - KAME_CHARGE_MIN), 0.0, 1.0)
	var radius := int(round(lerpf(float(KAME_RADIUS), float(KAME_RADIUS_MAX), power)))
	var length := int(round(lerpf(float(KAME_LENGTH), float(KAME_LENGTH_MAX), power)))
	var aim := _aim_dir()
	var from: Vector3 = spring.global_position + aim * 1.2
	_kame_beam_from = from
	_kame_beam_to = from + aim * float(length)
	_clear_beam_volume(from, aim, radius, length)
	_spawn_beam_visual(from, aim, radius, length)
	if _charge_ball != null:
		_charge_ball.visible = false
	action_feedback.emit("mode", "龟派气功波！")

# 沿气功波清出一条圆柱（球串）形的空腔。
func _clear_beam_volume(from: Vector3, aim: Vector3, radius: int, length: int) -> void:
	var offsets := _sphere_offsets(radius)
	var seen := {}
	var t := 3.0
	while t <= float(length):
		var c := from + aim * t
		var bx := int(floor(c.x)); var by := int(floor(c.y)); var bz := int(floor(c.z))
		for o in offsets:
			seen[Vector3i(bx + o.x, by + o.y, bz + o.z)] = true
		t += float(radius) * 0.7
	var edits := []
	for p in seen:
		edits.append({"pos": p, "id": 0})
	if not edits.is_empty():
		world.request_block_edits(edits)

func _sphere_offsets(r: int) -> Array:
	var out := []
	var rr := r * r
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if dx * dx + dy * dy + dz * dz <= rr:
					out.append(Vector3i(dx, dy, dz))
	return out

func _spawn_beam_visual(from: Vector3, aim: Vector3, radius: int, length: int) -> void:
	var host := get_parent()
	if host == null:
		return
	var start: Vector3 = from + aim * 0.6                  # 从手前(聚气球)位置喷出（侧面运镜，不怕糊屏）
	var beam_len := maxf(float(length) - 0.6, 6.0)
	var vis_r := clampf(float(radius) * 0.4, 1.0, 1.8)     # 偏圆形的细光柱（不铺满画面）
	var node := Node3D.new()
	host.add_child(node)
	node.global_position = start
	var up := Vector3.UP
	if absf(aim.dot(Vector3.UP)) > 0.99:
		up = Vector3.FORWARD
	node.look_at(start + aim, up)
	# 圆柱光柱：蓝色外晕(柔,alpha混合) + 白色亮核心
	node.add_child(_beam_cyl(vis_r * 1.45, beam_len, Color(0.28, 0.64, 1.0), 1.3, 0.26, false))
	node.add_child(_beam_cyl(vis_r * 0.6, beam_len, Color(0.92, 0.97, 1.0), 3.0, 0.92, true))
	# 枪口余球 + 命中点光球（打到地面处）
	node.add_child(_beam_ball(vis_r * 0.55, Color(0.75, 0.93, 1.0), 2.4))
	var impact := _beam_ball(vis_r * 1.6, Color(0.60, 0.90, 1.0), 2.6)
	impact.position.z = -beam_len
	node.add_child(impact)
	# 动画：沿长度射出 → 保持(配合运镜) → 收束消失
	node.scale = Vector3(1.0, 1.0, 0.05)
	var tw := node.create_tween()
	tw.tween_property(node, "scale", Vector3.ONE, 0.14).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.50)
	tw.tween_property(node, "scale", Vector3(0.2, 0.2, 1.0), 0.28).set_ease(Tween.EASE_IN)
	tw.tween_callback(node.queue_free)

# 圆柱光柱（round beam）。CylinderMesh 默认沿 Y，转 90° 对齐到本节点 -Z(瞄准方向)。
func _beam_cyl(radius: float, length: float, col: Color, energy: float, alpha: float, additive: bool = true) -> MeshInstance3D:
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = length
	cm.radial_segments = 16
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	m.no_depth_test = true                  # 光柱画在地形之上，全程可见（它本就在气化这条路径）
	cm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = cm
	mi.rotation.x = PI / 2.0
	mi.position = Vector3(0, 0, -length * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _beam_box(radius: float, length: float, col: Color, energy: float, alpha: float, additive: bool = true) -> MeshInstance3D:
	var bm := BoxMesh.new()
	bm.size = Vector3(radius * 2.0, radius * 2.0, length)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
	m.albedo_color = Color(col.r, col.g, col.b, alpha)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	bm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = bm
	mi.position = Vector3(0, 0, -length * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _beam_ball(radius: float, col: Color, energy: float) -> MeshInstance3D:
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(col.r, col.g, col.b, 0.85)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	sm.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

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

# ---------- 瞄准框（方块描边）----------
func _make_highlight() -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.86, 0.28, 0.95)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var c := 0.502
	var v := [
		Vector3(-c, -c, -c), Vector3(c, -c, -c), Vector3(c, -c, c), Vector3(-c, -c, c),
		Vector3(-c, c, -c), Vector3(c, c, -c), Vector3(c, c, c), Vector3(-c, c, c)]
	var edges := [0, 1, 1, 2, 2, 3, 3, 0, 4, 5, 5, 6, 6, 7, 7, 4, 0, 4, 1, 5, 2, 6, 3, 7]
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
	for e in edges:
		im.surface_add_vertex(v[e])
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _make_placement_preview() -> MeshInstance3D:
	_preview_material = StandardMaterial3D.new()
	_preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_preview_material.albedo_color = Color(0.05, 1.0, 0.92, 0.42)
	_preview_material.emission_enabled = true
	_preview_material.emission = Color(0.05, 1.0, 0.92, 0.42)
	_preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_preview_material.vertex_color_use_as_albedo = true

	_preview_box_mesh = BoxMesh.new()
	_preview_box_mesh.size = Vector3(0.94, 0.94, 0.94)
	var mi := MeshInstance3D.new()
	mi.mesh = _preview_box_mesh
	mi.material_override = _preview_material
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _make_blocked_placement_preview() -> MeshInstance3D:
	_blocked_preview_material = StandardMaterial3D.new()
	_blocked_preview_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_blocked_preview_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_blocked_preview_material.albedo_color = Color(1.0, 0.12, 0.10, 0.50)
	_blocked_preview_material.emission_enabled = true
	_blocked_preview_material.emission = Color(1.0, 0.12, 0.10, 0.50)
	_blocked_preview_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mi := MeshInstance3D.new()
	mi.name = "BlockedPlacementPreview"
	mi.mesh = _preview_box_mesh
	mi.material_override = _blocked_preview_material
	mi.visible = false
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi

func _make_brush_preview_lines() -> MeshInstance3D:
	_brush_line_material = StandardMaterial3D.new()
	_brush_line_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_brush_line_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_brush_line_material.albedo_color = Color(0.78, 1.0, 0.38, 0.94)
	_brush_line_material.emission_enabled = true
	_brush_line_material.emission = Color(0.78, 1.0, 0.38) * 0.8
	_brush_line_material.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mi := MeshInstance3D.new()
	mi.name = "BrushPreviewLines"
	mi.visible = false
	mi.extra_cull_margin = 512.0
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.material_override = _brush_line_material
	return mi
