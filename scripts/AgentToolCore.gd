extends RefCounted
# AgentToolCore —— 节点无关的代理工具核心（Agent Control Contract v1 的"逻辑"）。
#
# 同一套工具逻辑必须既能跑在现有 localhost 桥（活 World/Player/HUD 节点），
# 也能（后续）跑在无头服务器（WorldData + 虚拟 peer，无任何节点）。把工具体从
# AgentBridge 抽到这个只吃抽象上下文(ctx)的核心，正是让两者复用同一份逻辑的关键。
#
# 约定：所有函数都是 STATIC，绝不触碰场景树/活节点——只通过 ctx 访问世界、身体、记忆、聊天。
# ctx 由各自的适配器实现（AgentContext.LiveAgentContext 包活节点；后续 ServerAgentContext 包 WorldData）。
#
# ctx 接口（适配器须实现）：
#   ctx.read.surface_y(x,z) / region_label(x,z) / get_block(x,y,z) / chunk_of(x,z) / is_solid(id)
#   ctx.body.eid:String  get_pos()->Vector3  set_pos(Vector3)  get_yaw()->float  set_yaw(float)
#   ctx.body.get_pitch()->float  set_pitch(float)  selected_block_id:int
#   ctx.world_ready()->bool
#   ctx.apply_edits(edits:Array)->int            # edits = [{pos:Vector3i, id:int}]
#   ctx.say(text,to)->Dictionary {shown:bool,to:String}
#   ctx.memory.get_goal()/set_goal(s)/notes()->Array/append_note(s)/save()
#   ctx.resolve_block(name)->int(-1 未知)  ctx.alias_for(id)->String  ctx.hotbar_aliases()->Array
#   ctx.time_info()->{fraction,phase,clock}  ctx.nearby_landmarks()->Array
#   ctx.landmarks_in_range(center:Vector3i,radius:float)->Array  ctx.chat_observe()->Dictionary
#   ctx.record_action(tool,summary,ok)  ctx.recent_actions()->Array
#   ctx.prime(x,z)  ctx.note_build()
#   ctx.set_goal_status(text)（可选；记忆 set_goal 后同步在线状态/角标）
#   ctx.identify(name)->Dictionary（可选；报名设显示名，无 chat 时返回 {entity_id,name}）
#   ctx.capture_blueprint(a:Vector3i,b:Vector3i,name:String)->Dictionary（可选；蓝图捕获）
#   ctx.paste_blueprint(name:String,anchor:Vector3i)->Dictionary（可选；蓝图粘贴）

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")
const BuildTemplates = preload("res://scripts/BuildTemplates.gd")
const Chunk = preload("res://scripts/Chunk.gd")

const MAX_CELLS := 4096
const SY := Chunk.SY                 # 96
const LOBBY_CHAT_RECENT := 20        # observe.chat 返回的最近大厅消息条数

# 公共入口：分发 tool 到对应实现，把内部 result / {"__error"} 统一包成
# {"ok":true,"result":{...}} 或 {"ok":false,"error":"..."}（信封 id 由桥/调用方补）。
static func handle(tool: String, args: Dictionary, ctx) -> Dictionary:
	var result := _handle(tool, args, ctx)
	if result.has("__error"):
		return {"ok": false, "error": str(result["__error"])}
	return {"ok": true, "result": result}

static func _err(msg: String) -> Dictionary:
	return {"__error": msg}

# 工具分发表。返回 result Dictionary，或 {"__error": "..."}。
static func _handle(tool: String, args: Dictionary, ctx) -> Dictionary:
	match tool:
		"observe":
			return _tool_observe(args, ctx)
		"identify":
			return _tool_identify(args, ctx)
		"look":
			return _tool_look(args, ctx)
		"goto":
			return _tool_goto(args, ctx)
		"scan":
			return _tool_scan(args, ctx)
		"place":
			return _tool_place(args, ctx)
		"break":
			return _tool_break(args, ctx)
		"build":
			return _tool_build(args, ctx)
		"capture_build":
			return _tool_capture_build(args, ctx)
		"paste_build":
			return _tool_paste_build(args, ctx)
		"get_block":
			return _tool_get_block(args, ctx)
		"say":
			return _tool_say(args, ctx)
		"set_goal":
			return _tool_set_goal(args, ctx)
		"remember":
			return _tool_remember(args, ctx)
		"get_memory":
			return _tool_get_memory(args, ctx)
		_:
			return _err("unknown tool: " + tool)

# ============ 工具实现 ============

static func _tool_observe(args: Dictionary, ctx) -> Dictionary:
	if not ctx.world_ready():
		return {"ready": false}
	var hsize := int(args.get("heightmap_size", 16))
	if hsize <= 0 or hsize > 16:
		hsize = 16
	if hsize % 2 != 0:
		hsize -= 1
	var pos := _body_cell(ctx)
	var yaw_deg := _body_yaw_deg(ctx)
	var pitch_deg := _body_pitch_deg(ctx)
	var region := str(ctx.read.region_label(pos.x, pos.z))
	var tod: Dictionary = ctx.time_info()
	var frac := float(tod.get("fraction", 0.30))
	var half := int(hsize / 2)
	var origin_x := pos.x - half
	var origin_z := pos.z - half
	var rows := []
	for r in range(hsize):
		var row := []
		for c in range(hsize):
			row.append(int(ctx.read.surface_y(origin_x + c, origin_z + r)))
		rows.append(row)
	var result := {
		"pos": [pos.x, pos.y, pos.z],
		"facing": {
			"yaw_deg": yaw_deg,
			"pitch_deg": pitch_deg,
			"cardinal": _cardinal_from_yaw(yaw_deg),
		},
		"region": region,
		"region_en": _region_alias(region),
		"time_of_day": {
			"fraction": snappedf(frac, 0.01),
			"phase": str(tod.get("phase", _time_phase(frac))),
			"clock": str(tod.get("clock", _time_clock(frac))),
		},
		"selected_block": ctx.alias_for(ctx.body.selected_block_id),
		"hotbar": ctx.hotbar_aliases(),
		"heightmap": {
			"size": hsize,
			"origin": [origin_x, origin_z],
			"rows": rows,
		},
		"nearby_landmarks": ctx.nearby_landmarks(),
		"recent_actions": ctx.recent_actions(),
	}
	var chat: Dictionary = ctx.chat_observe()
	if not chat.is_empty():
		if chat.has("chat"):
			result["chat"] = chat["chat"]
		if chat.has("inbox"):
			result["inbox"] = chat["inbox"]
	return result

static func _tool_look(args: Dictionary, ctx) -> Dictionary:
	if not ctx.world_ready():
		return _err("world not ready")
	if args.has("yaw_deg"):
		var yaw := fposmod(float(args["yaw_deg"]), 360.0)
		ctx.body.set_yaw(deg_to_rad(yaw))
	if args.has("pitch_deg"):
		var pitch_deg := clampf(float(args["pitch_deg"]), -80.0, 80.0)
		ctx.body.set_pitch(clampf(deg_to_rad(pitch_deg), -1.4, 1.4))
	var yaw_now := _body_yaw_deg(ctx)
	var pitch_now := _body_pitch_deg(ctx)
	var facing := {"yaw_deg": yaw_now, "pitch_deg": pitch_now, "cardinal": _cardinal_from_yaw(yaw_now)}
	ctx.record_action("look", "yaw %.0f pitch %.0f" % [yaw_now, pitch_now], true)
	return {"facing": facing}

static func _tool_goto(args: Dictionary, ctx) -> Dictionary:
	if not ctx.world_ready():
		return _err("world not ready")
	if not args.has("x") or not args.has("z"):
		return _err("bad args: x/z (required)")
	var x := int(args["x"])
	var z := int(args["z"])
	var sy := int(ctx.read.surface_y(x, z))
	var place_y := sy + 1
	if args.has("y"):
		place_y = clampi(int(args["y"]), 0, SY - 1)
	# 让目标点立即可踩（同步生成该处区块）
	ctx.prime(x, z)
	var dest := Vector3(float(x) + 0.5, float(place_y), float(z) + 0.5)
	ctx.body.set_pos(dest)
	var region := str(ctx.read.region_label(x, z))
	ctx.record_action("goto", "-> (%d,%d,%d)" % [x, place_y, z], true)
	return {
		"pos": [x, place_y, z],
		"region": region,
		"region_en": _region_alias(region),
		"surface_y": sy,
	}

static func _tool_scan(args: Dictionary, ctx) -> Dictionary:
	if not ctx.world_ready():
		return _err("world not ready")
	var radius := int(args.get("radius", 8))
	radius = clampi(radius, 1, 24)
	var center := _body_cell(ctx)
	var span := 2 * radius + 1
	var step := int(ceil(float(span) / 16.0))
	if step < 1:
		step = 1
	var origin_x := center.x - radius
	var origin_z := center.z - radius
	var heights := []
	var surface_blocks := []
	var histogram := {}
	var regions_seen := {}
	var min_y := 1 << 30
	var max_y := -(1 << 30)
	var sum_y := 0
	var count := 0
	var water_cols := 0
	# 平整度评估：记录每个采样列高度，找局部方差小的列做建议建造点
	var best_spot: Variant = null
	var best_variance := 1 << 30
	var z := origin_z
	while z <= center.z + radius:
		var hrow := []
		var brow := []
		var x := origin_x
		while x <= center.x + radius:
			var sy := int(ctx.read.surface_y(x, z))
			hrow.append(sy)
			min_y = mini(min_y, sy)
			max_y = maxi(max_y, sy)
			sum_y += sy
			count += 1
			var top_id := int(ctx.read.get_block(x, sy, z))
			var alias: String = ctx.alias_for(top_id)
			brow.append(alias)
			histogram[alias] = int(histogram.get(alias, 0)) + 1
			if alias == "water":
				water_cols += 1
			var rlabel := str(ctx.read.region_label(x, z))
			if rlabel != "":
				regions_seen[rlabel] = true
			# 局部高度方差（与四个 step 邻居比），找平地
			var variance := absi(sy - int(ctx.read.surface_y(x + step, z))) \
				+ absi(sy - int(ctx.read.surface_y(x - step, z))) \
				+ absi(sy - int(ctx.read.surface_y(x, z + step))) \
				+ absi(sy - int(ctx.read.surface_y(x, z - step)))
			if variance < best_variance or (variance == best_variance and best_spot == null):
				best_variance = variance
				best_spot = [x, sy + 1, z]
			x += step
		heights.append(hrow)
		surface_blocks.append(brow)
		z += step
	var avg_y := int(round(float(sum_y) / float(maxi(1, count))))
	var regions_present := regions_seen.keys()
	regions_present.sort()
	return {
		"center": [center.x, center.z],
		"radius": radius,
		"surface_y": {"min": min_y, "max": max_y, "avg": avg_y},
		"columns": {
			"step": step,
			"origin": [origin_x, origin_z],
			"height": heights,
			"surface_block": surface_blocks,
		},
		"block_histogram": histogram,
		"regions_present": regions_present,
		"water_fraction": snappedf(float(water_cols) / float(maxi(1, count)), 0.01),
		"landmarks_in_range": ctx.landmarks_in_range(center, float(radius)),
		"suggested_build_spot": best_spot,
	}

static func _tool_place(args: Dictionary, ctx) -> Dictionary:
	if not ctx.world_ready():
		return _err("world not ready")
	if not args.has("block"):
		return _err("bad args: block (required)")
	var block_name := str(args["block"])
	var id := int(ctx.resolve_block(block_name))
	if id < 0:
		return _err("unknown block: " + block_name)
	var cells_raw: Variant = args.get("cells", [])
	if typeof(cells_raw) != TYPE_ARRAY:
		return _err("bad args: cells (expected array)")
	var cells: Array = cells_raw
	if cells.size() > MAX_CELLS:
		return _err("too many cells: %d > %d" % [cells.size(), MAX_CELLS])
	var edits := _cells_to_edits(cells, id)
	var changed := int(ctx.apply_edits(edits))
	var alias: String = ctx.alias_for(id)
	ctx.record_action("place", "%s x%d @ %d cells" % [alias, changed, cells.size()], true)
	return {"requested": cells.size(), "changed": changed, "block": alias}

static func _tool_break(args: Dictionary, ctx) -> Dictionary:
	if not ctx.world_ready():
		return _err("world not ready")
	var cells_raw: Variant = args.get("cells", [])
	if typeof(cells_raw) != TYPE_ARRAY:
		return _err("bad args: cells (expected array)")
	var cells: Array = cells_raw
	if cells.size() > MAX_CELLS:
		return _err("too many cells: %d > %d" % [cells.size(), MAX_CELLS])
	var edits := _cells_to_edits(cells, BlockLibrary.AIR)
	var changed := int(ctx.apply_edits(edits))
	ctx.record_action("break", "cleared %d / %d cells" % [changed, cells.size()], true)
	return {"requested": cells.size(), "changed": changed}

static func _tool_build(args: Dictionary, ctx) -> Dictionary:
	if not ctx.world_ready():
		return _err("world not ready")
	if not args.has("template"):
		return _err("bad args: template (required)")
	var template := str(args["template"])
	if template == "off" or template == "":
		return _err("unknown template: " + template)
	if not BuildTemplates.TEMPLATE_IDS.has(template):
		return _err("unknown template: " + template)
	if not args.has("x") or not args.has("y") or not args.has("z"):
		return _err("bad args: x/y/z (required)")
	var x := int(args["x"])
	var y := int(args["y"])
	var z := int(args["z"])
	var rotation := _rotation_to_index(args.get("rotation", 0))
	var origin := Vector3i(x, y, z)
	var edits := BuildTemplates.edits_for(template, origin, rotation, ctx.body.selected_block_id)
	var changed := int(ctx.apply_edits(edits))
	ctx.note_build()                  # 小人闪一下，表示"它在这儿盖的"（服务器 no-op）
	ctx.record_action("build", "%s @ (%d,%d,%d)" % [template, x, y, z], true)
	return {"template": template, "anchor": [x, y, z], "rotation": rotation, "changed": changed}

# 捕获一块长方体区域存成蓝图文件（可分享/异地重现）：args name + x1,y1,z1, x2,y2,z2
static func _tool_capture_build(args: Dictionary, ctx) -> Dictionary:
	if not ctx.world_ready():
		return _err("world not ready")
	if not ctx.has_method("capture_blueprint"):
		return _err("world not ready")
	var name := str(args.get("name", "")).strip_edges()
	if name == "" or not name.is_valid_filename():
		return _err("bad args: name (required, 须为合法文件名)")
	for k in ["x1", "y1", "z1", "x2", "y2", "z2"]:
		if not args.has(k):
			return _err("bad args: x1/y1/z1/x2/y2/z2 (required)")
	var a := Vector3i(int(args["x1"]), int(args["y1"]), int(args["z1"]))
	var b := Vector3i(int(args["x2"]), int(args["y2"]), int(args["z2"]))
	var res: Dictionary = ctx.capture_blueprint(a, b, name)
	if res.has("__error"):
		return res
	ctx.record_action("capture_build", "%s (%d 块)" % [name, int(res.get("blocks", 0))], true)
	return res

# 把蓝图贴到锚点（走正常编辑链路，联机会广播）：args name + x,y,z
static func _tool_paste_build(args: Dictionary, ctx) -> Dictionary:
	if not ctx.world_ready():
		return _err("world not ready")
	if not ctx.has_method("paste_blueprint"):
		return _err("world not ready")
	var name := str(args.get("name", "")).strip_edges()
	if name == "" or not name.is_valid_filename():
		return _err("bad args: name (required)")
	for k in ["x", "y", "z"]:
		if not args.has(k):
			return _err("bad args: x/y/z (required)")
	var anchor := Vector3i(int(args["x"]), int(args["y"]), int(args["z"]))
	var res: Dictionary = ctx.paste_blueprint(name, anchor)
	if res.has("__error"):
		return res
	ctx.record_action("paste_build", "%s @ (%d,%d,%d) -> %d 块" % [name, anchor.x, anchor.y, anchor.z, int(res.get("changed", 0))], true)
	return res

static func _tool_get_block(args: Dictionary, ctx) -> Dictionary:
	if not ctx.world_ready():
		return _err("world not ready")
	if not args.has("x") or not args.has("y") or not args.has("z"):
		return _err("bad args: x/y/z (required)")
	var x := int(args["x"])
	var y := int(args["y"])
	var z := int(args["z"])
	var id := 0
	if y >= 0 and y < SY:
		id = int(ctx.read.get_block(x, y, z))
	var solid := bool(ctx.read.is_solid(id))
	return {"pos": [x, y, z], "block": ctx.alias_for(id), "solid": solid}

static func _tool_say(args: Dictionary, ctx) -> Dictionary:
	var text := str(args.get("text", "")).strip_edges()
	if text.length() > 120:
		text = text.substr(0, 120)
	var to_raw := str(args.get("to", "")).strip_edges()
	var routed: Dictionary = ctx.say(text, to_raw)
	var shown := bool(routed.get("shown", false))
	var to_label := str(routed.get("to", "lobby"))
	ctx.record_action("say", text, shown)
	return {"shown": shown, "to": to_label}

static func _tool_set_goal(args: Dictionary, ctx) -> Dictionary:
	var text := str(args.get("text", "")).strip_edges()
	if text.length() > 200:
		text = text.substr(0, 200)
	ctx.memory.set_goal(text)
	ctx.memory.save()
	if ctx.has_method("set_goal_status"):
		ctx.set_goal_status(text)
	return {"goal": text}

static func _tool_remember(args: Dictionary, ctx) -> Dictionary:
	var text := str(args.get("text", "")).strip_edges()
	if text.length() > 280:
		text = text.substr(0, 280)
	ctx.memory.append_note(text)
	ctx.memory.save()
	return {"remembered": true, "note_count": ctx.memory.notes().size()}

static func _tool_get_memory(_args: Dictionary, ctx) -> Dictionary:
	return {
		"goal": str(ctx.memory.get_goal()),
		"notes": (ctx.memory.notes() as Array).duplicate(),
		"updated_at": int(ctx.memory.updated_at()) if ctx.memory.has_method("updated_at") else 0,
	}

# 报名：设置当前实体在在线列表里的显示名（连接后调用；默认名为 agent-N）。
static func _tool_identify(args: Dictionary, ctx) -> Dictionary:
	var name := str(args.get("name", "")).strip_edges()
	if name.length() > 40:
		name = name.substr(0, 40)
	if ctx.has_method("identify"):
		return ctx.identify(name)
	return {"entity_id": str(ctx.body.eid), "name": name}

# ============ 辅助：身体读数（经 ctx.body） ============

static func _body_cell(ctx) -> Vector3i:
	var p: Vector3 = ctx.body.get_pos()
	return Vector3i(floori(p.x), floori(p.y), floori(p.z))

static func _body_yaw_deg(ctx) -> float:
	return fposmod(rad_to_deg(ctx.body.get_yaw()), 360.0)

static func _body_pitch_deg(ctx) -> float:
	return rad_to_deg(ctx.body.get_pitch())

static func _cardinal_from_yaw(yaw_deg: float) -> String:
	# yaw 0 = 面朝 -Z (北)。顺时针每 45° 一档。
	var labels := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	var idx := int(round(yaw_deg / 45.0)) % 8
	return labels[idx]

static func _time_phase(frac: float) -> String:
	if frac < 0.20 or frac >= 0.85:
		return "night"
	if frac < 0.28:
		return "dawn"
	if frac < 0.42:
		return "morning"
	if frac < 0.58:
		return "noon"
	if frac < 0.75:
		return "afternoon"
	return "dusk"

static func _time_clock(frac: float) -> String:
	var total := fmod(frac * 24.0, 24.0)
	var h := int(total)
	var m := int((total - float(h)) * 60.0)
	return "%02d:%02d" % [h, m]

static func _region_alias(label: String) -> String:
	return str(REGION_ALIASES.get(label, label))

# 中文地貌标签 -> 英文别名（契约 §6）—— 纯静态映射，随核心走（与桥保持一致）。
const REGION_ALIASES := {
	"草原": "meadow", "风草原": "windswept_plains", "花海草甸": "flower_meadow",
	"针叶林": "taiga", "苔林": "mossy_forest", "沙漠": "desert",
	"红土台地": "mesa", "岩岭": "rocky_ridge", "玄武岩岭": "basalt_ridge",
	"雪峰": "snow_peaks", "湿地": "wetland", "沙岸": "sandy_shore",
	"黏土滩": "clay_flat", "浅水湾": "shallow_cove",
	# 主题岛扇区
	"雪山": "snow_mountain", "热带海岸": "tropical_coast",
	"村庄": "village", "中央广场": "central_plaza",
	"霓虹城": "neon_city", "天文台": "observatory",
	"农田": "farmland", "海湾": "bay", "虚空": "void",
}

# ============ 辅助：动作（纯几何/解析） ============

static func _cells_to_edits(cells: Array, id: int) -> Array:
	var edits := []
	for raw in cells:
		var cell: Variant = _to_vec3i(raw)
		if cell == null:
			continue
		var c: Vector3i = cell
		if c.y < 0 or c.y >= SY:
			continue
		edits.append({"pos": c, "id": id})
	return edits

static func _to_vec3i(raw: Variant):
	if typeof(raw) == TYPE_ARRAY:
		var arr: Array = raw
		if arr.size() == 3:
			return Vector3i(int(arr[0]), int(arr[1]), int(arr[2]))
	if typeof(raw) == TYPE_VECTOR3I:
		return raw
	if typeof(raw) == TYPE_VECTOR3:
		var v: Vector3 = raw
		return Vector3i(int(v.x), int(v.y), int(v.z))
	return null

static func _rotation_to_index(raw: Variant) -> int:
	var val := int(raw)
	# 接受 0/1，或角度 0/90/180/270（偶=0，奇=1）
	if val == 0 or val == 1:
		return val
	var steps := int(round(float(val) / 90.0))
	return posmod(steps, 2)
