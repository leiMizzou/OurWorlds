extends SceneTree
# 验证创造模式建造模板：平台、立柱、拱门、墙面、楼梯、房架、小屋、营火、小桥、花圃、灯塔、路标的一键放置和预览反馈。
#   godot --headless --path <项目> --script res://tests/test_build_templates.gd

const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

var _f := 0
var _main = null
var failed := 0
var _last_kind := ""
var _last_label := ""
var _world_events := []

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _process(_delta: float) -> bool:
	_f += 1
	if _f == 1:
		OS.set_environment("VC_NO_SAVE", "1")
		OS.set_environment("VC_SKIP_TITLE", "1")
		OS.set_environment("VC_SETTINGS_PATH", "user://tests/build_templates/settings.json")
		_main = load("res://scenes/Main.tscn").instantiate()
		root.add_child(_main)
	elif _f == 35:
		var player = _main.player
		player.action_feedback.connect(func(kind: String, label: String) -> void:
			_last_kind = kind
			_last_label = label
		)
		player.world_feedback.connect(func(kind: String, cell: Vector3i, block_id: int) -> void:
			_world_events.append({"kind": kind, "cell": cell, "block_id": block_id})
		)
		player.select_block_id(BlockLibrary.MARBLE)
		player._has_target = true
		player._target_normal = Vector3i.UP
		var p: Vector3 = player.global_position

		player.brush_index = 1
		player._on_key(KEY_T)
		check(player.build_template_id() == "platform", "T 键切到平台模板")
		check(player.brush_label() == "1x1", "切到模板会关闭 3x3 画笔")
		check(player.build_template_orientation_label() == "东西", "模板默认朝向为东西")
		check(_last_kind == "mode" and _last_label == "模板 平台 东西", "模板切换发出带朝向反馈")
		_main.hud._process(0.0)
		check(_main.hud._template_panel.visible, "HUD 模板条可见")
		check(_main.hud._template_slots.size() == player.build_template_count(), "HUD 模板条列出全部模板")
		check(_template_labels().has("楼梯") and _template_labels().has("房架") and _template_labels().has("小屋") and _template_labels().has("营火") and _template_labels().has("小桥") and _template_labels().has("花圃") and _template_labels().has("灯塔") and _template_labels().has("路标"), "HUD 模板条包含发布向模板")
		check(_template_icons_ready(), "HUD 模板条每项都有体素剪影图标")
		check(_template_icon_cell_count("房架") > _template_icon_cell_count("平台"), "复杂模板图标使用更多方块表达轮廓")
		var selected_template_label: Label = _main.hud._template_slots[player.build_template_index()]["label"]
		check(selected_template_label.text == "平台" and selected_template_label.modulate.a > 0.9, "HUD 模板条高亮当前模板")
		check(_main.hud._template_orientation_label.text == "东西", "HUD 模板条显示当前朝向")
		var platform := Vector3i(int(floor(p.x)) + 9, int(floor(p.y)) + 7, int(floor(p.z)) + 9)
		player._target = platform - Vector3i.UP
		player._place = platform
		var platform_cells: Array = player._placement_cells()
		check(platform_cells.size() == 25, "平台模板生成 25 个放置格")
		_clear_cells(platform_cells)
		player._update_placement_preview()
		check(player.placement_preview.visible, "平台模板预览可见")
		var platform_preview_size := _preview_world_size(player)
		check(platform_preview_size.x > 4.8 and platform_preview_size.z > 4.8, "平台模板预览覆盖 5x5 范围")
		check(player.placement_preview.scale == Vector3.ONE, "平台模板预览使用真实网格尺寸")
		check(_preview_vertex_count(player) >= platform_cells.size() * 36, "平台模板预览按每格生成幽灵方块")
		check(player.brush_preview_lines.visible and player.brush_preview_lines.mesh != null, "平台模板显示范围线框")
		check(player._try_place_current(), "平台模板可一次放置")
		check(_last_kind == "place" and _last_label.contains("平台") and _last_label.contains("x25"), "平台放置反馈包含模板和数量")
		check(_all_cells_are(platform_cells, BlockLibrary.MARBLE), "平台模板全部写入当前材料")
		_main.hud._process(0.0)
		check(_main.hud._status_label.text.contains("模板 平台 东西"), "HUD 状态栏显示当前模板和朝向")
		check(_main.world.undo_last_edit(), "一次撤销可撤销平台模板")
		check(_all_cells_are(platform_cells, BlockLibrary.AIR), "撤销后平台区域恢复为空")

		player._on_key(KEY_T)
		check(player.build_template_id() == "pillar", "T 键切到立柱模板")
		var pillar := platform + Vector3i(10, 0, 0)
		player._target = pillar - Vector3i.UP
		player._place = pillar
		var pillar_cells: Array = player._placement_cells()
		check(pillar_cells.size() == 5, "立柱模板生成 5 个放置格")
		_clear_cells(pillar_cells)
		check(player._try_place_current(), "立柱模板可一次放置")
		check(_last_label.contains("立柱") and _last_label.contains("x5"), "立柱放置反馈包含模板和数量")
		check(_all_cells_are(pillar_cells, BlockLibrary.MARBLE), "立柱模板全部写入当前材料")

		player._on_key(KEY_T)
		check(player.build_template_id() == "arch", "T 键切到拱门模板")
		var arch := platform + Vector3i(0, 0, 10)
		player._target = arch - Vector3i.UP
		player._place = arch
		var arch_cells: Array = player._placement_cells()
		check(arch_cells.size() == 13, "拱门模板生成 13 个放置格")
		check(arch_cells.has(arch + Vector3i(-2, 0, 0)) and arch_cells.has(arch + Vector3i(2, 0, 0)), "默认拱门沿东西方向展开")
		player._on_key(KEY_G)
		check(_last_kind == "mode" and _last_label == "模板 拱门 南北", "G 键旋转当前模板")
		check(player.build_template_orientation_label() == "南北", "模板朝向切到南北")
		arch_cells = player._placement_cells()
		check(arch_cells.size() == 13, "旋转后拱门仍生成 13 个放置格")
		check(arch_cells.has(arch + Vector3i(0, 0, -2)) and arch_cells.has(arch + Vector3i(0, 0, 2)), "旋转后拱门沿南北方向展开")
		check(not arch_cells.has(arch + Vector3i(-2, 0, 0)) and not arch_cells.has(arch + Vector3i(2, 0, 0)), "旋转后拱门不再占用东西立柱位")
		_clear_cells(arch_cells)
		check(player._try_place_current(), "拱门模板可一次放置")
		check(_last_label.contains("拱门") and _last_label.contains("x13"), "拱门放置反馈包含模板和数量")
		check(_all_cells_are(arch_cells, BlockLibrary.MARBLE), "拱门模板全部写入当前材料")

		var blocked: Vector3i = arch_cells[0]
		_clear_cells(arch_cells)
		_main.world.set_block(blocked.x, blocked.y, blocked.z, BlockLibrary.STONE)
		player._update_placement_preview()
		check(player.placement_blocked_preview.visible, "模板阻挡时显示阻挡格幽灵预览")
		check(player._blocked_preview_material.albedo_color.r > player._blocked_preview_material.albedo_color.g, "阻挡格幽灵预览为红色")
		check(_mesh_vertex_count(player.placement_blocked_preview) >= 36, "阻挡格幽灵预览只需标出具体阻挡方块")
		check(player._brush_line_material.albedo_color.r > player._brush_line_material.albedo_color.g, "模板阻挡时线框为红色")
		check(not player._try_place_current(), "模板存在实体方块时整组放置失败")
		check(_last_kind == "blocked" and _last_label == "目标格已占用", "模板阻挡反馈沿用具体原因")
		check(_main.world.get_block(blocked.x, blocked.y, blocked.z) == BlockLibrary.STONE, "失败模板不会改动阻挡格")
		check(_unchanged_empty_except(arch_cells, blocked), "失败模板不会部分写入其它格")
		_clear_cells(arch_cells)

		player._on_key(KEY_T)
		check(player.build_template_id() == "wall", "T 键切到墙面模板")
		var wall := platform + Vector3i(16, 0, 16)
		player._target = wall - Vector3i.UP
		player._place = wall
		var wall_cells: Array = player._placement_cells()
		check(wall_cells.size() == 15, "墙面模板生成 15 个放置格")
		check(wall_cells.has(wall + Vector3i(0, 0, -2)) and wall_cells.has(wall + Vector3i(0, 2, 2)), "墙面沿当前南北朝向展开")
		player._on_key(KEY_G)
		check(player.build_template_orientation_label() == "东西", "G 键可把墙面转回东西朝向")
		wall_cells = player._placement_cells()
		check(wall_cells.has(wall + Vector3i(-2, 0, 0)) and wall_cells.has(wall + Vector3i(2, 2, 0)), "旋转后墙面沿东西方向展开")
		_clear_cells(wall_cells)
		check(player._try_place_current(), "墙面模板可一次放置")
		check(_last_label.contains("墙面") and _last_label.contains("x15"), "墙面放置反馈包含模板和数量")
		check(_all_cells_are(wall_cells, BlockLibrary.MARBLE), "墙面模板全部写入当前材料")

		player._on_key(KEY_T)
		check(player.build_template_id() == "stairs", "T 键切到楼梯模板")
		var stairs := platform + Vector3i(26, 0, 16)
		player._target = stairs - Vector3i.UP
		player._place = stairs
		var stair_cells: Array = player._placement_cells()
		check(stair_cells.size() == 45, "楼梯模板生成 45 个放置格")
		check(stair_cells.has(stairs + Vector3i(0, 4, 4)), "楼梯最高一级沿当前深度方向抬升")
		check(stair_cells.has(stairs + Vector3i(-1, 0, 0)) and stair_cells.has(stairs + Vector3i(1, 0, 0)), "楼梯为三格宽")
		_clear_cells(stair_cells)
		player._update_placement_preview()
		var stair_preview_size := _preview_world_size(player)
		check(stair_preview_size.y > 4.8 and stair_preview_size.z > 4.8, "楼梯预览显示真实高度和进深")
		check(_preview_vertex_count(player) >= stair_cells.size() * 36, "楼梯预览按阶梯格生成幽灵方块")
		check(player._try_place_current(), "楼梯模板可一次放置")
		check(_last_label.contains("楼梯") and _last_label.contains("x45"), "楼梯放置反馈包含模板和数量")
		check(_all_cells_are(stair_cells, BlockLibrary.MARBLE), "楼梯模板全部写入当前材料")

		player._on_key(KEY_T)
		check(player.build_template_id() == "room_frame", "T 键切到房架模板")
		var frame := platform + Vector3i(38, 0, 16)
		player._target = frame - Vector3i.UP
		player._place = frame
		var frame_cells: Array = player._placement_cells()
		check(frame_cells.size() == 40, "房架模板生成 40 个放置格")
		check(frame_cells.has(frame + Vector3i(-3, 0, -3)) and frame_cells.has(frame + Vector3i(3, 3, 3)), "房架包含四角立柱")
		check(frame_cells.has(frame + Vector3i(0, 4, -3)) and frame_cells.has(frame + Vector3i(3, 4, 0)), "房架包含顶部横梁")
		_clear_cells(frame_cells)
		check(player._try_place_current(), "房架模板可一次放置")
		check(_last_label.contains("房架") and _last_label.contains("x40"), "房架放置反馈包含模板和数量")
		check(_all_cells_are(frame_cells, BlockLibrary.MARBLE), "房架模板全部写入当前材料")

		player._on_key(KEY_T)
		check(player.build_template_id() == "cabin", "T 键切到小屋模板")
		var cabin := platform + Vector3i(54, 0, 16)
		player._target = cabin - Vector3i.UP
		player._place = cabin
		var cabin_right: Vector3i = player._template_right_axis()
		var cabin_depth: Vector3i = player._template_depth_axis()
		var cabin_cells: Array = player._placement_cells()
		check(cabin_cells.size() == 204, "小屋模板生成 204 个放置格")
		check(cabin_cells.has(cabin + cabin_right * 3 + cabin_depth * 3 + Vector3i.UP * 3), "小屋包含木头角柱")
		check(cabin_cells.has(cabin + cabin_depth * -4) and cabin_cells.has(cabin + cabin_right + cabin_depth * -4), "小屋包含入口石阶")
		check(cabin_cells.has(cabin + Vector3i.UP * 6) and cabin_cells.has(cabin + cabin_right * 4 + cabin_depth * 4 + Vector3i.UP * 4), "小屋包含阶梯式砖屋顶和挑檐")
		check(not cabin_cells.has(cabin + cabin_depth * -3 + Vector3i.UP), "小屋保留门洞")
		_clear_cells(cabin_cells)
		player._update_placement_preview()
		var cabin_preview_size := _preview_world_size(player)
		check(cabin_preview_size.x > 8.8 and cabin_preview_size.y > 6.8 and cabin_preview_size.z > 8.8, "小屋预览显示完整体量")
		check(_preview_unique_color_count(player) >= 6, "小屋模板预览区分木板、木头、玻璃、砖、灯笼和石阶")
		_world_events.clear()
		_main.action_effects._items.clear()
		check(player._try_place_current(), "小屋模板可一次放置")
		check(_last_label.contains("小屋") and _last_label.contains("x204"), "小屋放置反馈包含模板和数量")
		check(_world_event_count("bulk_place") == 1, "小屋模板先发出一次聚合放置反馈")
		check(_world_event_count("place") == 204, "小屋模板仍保留逐格放置事件供修复和统计")
		check(_main.action_effects._items.size() == 42, "小屋模板只生成聚合碎片避免大批量粒子抖动")
		check(_main.world.get_block(cabin.x, cabin.y, cabin.z) == BlockLibrary.PLANKS, "小屋地板使用木板")
		var cabin_post := cabin + cabin_right * 3 + cabin_depth * 3 + Vector3i.UP * 2
		check(_main.world.get_block(cabin_post.x, cabin_post.y, cabin_post.z) == BlockLibrary.LOG, "小屋角柱使用木头")
		var cabin_window := cabin + cabin_right * 3 + Vector3i.UP * 2
		check(_main.world.get_block(cabin_window.x, cabin_window.y, cabin_window.z) == BlockLibrary.GLASS, "小屋侧墙包含玻璃窗")
		check(_main.world.get_block(cabin.x, cabin.y + 6, cabin.z) == BlockLibrary.BRICK, "小屋屋脊使用砖块")
		check(_main.world.get_block(cabin.x, cabin.y + 3, cabin.z) == BlockLibrary.LANTERN, "小屋室内自带灯笼")
		var cabin_step := cabin + cabin_depth * -4
		check(_main.world.get_block(cabin_step.x, cabin_step.y, cabin_step.z) == BlockLibrary.COBBLE, "小屋入口使用圆石台阶")
		var cabin_door := cabin + cabin_depth * -3 + Vector3i.UP
		check(_main.world.get_block(cabin_door.x, cabin_door.y, cabin_door.z) == BlockLibrary.AIR, "小屋门洞保持可进入")
		check(_main.world.undo_last_edit(), "一次撤销可撤销小屋模板")
		check(_all_cells_are(cabin_cells, BlockLibrary.AIR), "撤销后小屋区域恢复为空")

		player._on_key(KEY_T)
		check(player.build_template_id() == "campfire", "T 键切到营火模板")
		var campfire := platform + Vector3i(68, 0, 16)
		player._target = campfire - Vector3i.UP
		player._place = campfire
		var campfire_cells: Array = player._placement_cells()
		check(campfire_cells.size() == 10, "营火模板生成 10 个放置格")
		check(campfire_cells.has(campfire) and campfire_cells.has(campfire + Vector3i.UP), "营火包含底火和上方灯笼")
		check(campfire_cells.has(campfire + Vector3i.RIGHT) and campfire_cells.has(campfire + Vector3i(1, 0, 1)), "营火包含原木和石环")
		_clear_cells(campfire_cells)
		player._update_placement_preview()
		check(player._preview_material.albedo_color.r > player._preview_material.albedo_color.g, "营火模板预览使用暖色")
		check(_preview_unique_color_count(player) >= 3, "营火模板预览按不同材料分色")
		_world_events.clear()
		_main.action_effects._items.clear()
		check(player._try_place_current(), "营火模板可一次放置")
		check(_last_label.contains("营火") and _last_label.contains("x10"), "营火放置反馈包含模板和数量")
		check(_has_world_event("campfire"), "营火模板放置会发出点燃世界反馈")
		check(_main.action_effects._items.size() == 34, "营火模板只保留专属点燃碎片")
		check(_world_event_count("place") == 10, "营火模板仍发出每格放置事件供系统统计")
		check(_main.world.get_block(campfire.x, campfire.y, campfire.z) == BlockLibrary.MOONSTONE_LAMP, "营火中心使用月石灯")
		check(_main.world.get_block(campfire.x, campfire.y + 1, campfire.z) == BlockLibrary.LANTERN, "营火上方使用灯笼火光")
		check(_main.world.get_block(campfire.x + 1, campfire.y, campfire.z) == BlockLibrary.LOG, "营火横木使用原木")
		check(_main.world.get_block(campfire.x + 1, campfire.y, campfire.z + 1) == BlockLibrary.COBBLE, "营火石环使用圆石")
		check(_main.world.undo_last_edit(), "一次撤销可撤销营火模板")
		check(_all_cells_are(campfire_cells, BlockLibrary.AIR), "撤销后营火区域恢复为空")

		player._on_key(KEY_T)
		check(player.build_template_id() == "bridge", "T 键切到小桥模板")
		var bridge := platform + Vector3i(84, 0, 16)
		player._target = bridge - Vector3i.UP
		player._place = bridge
		var bridge_cells: Array = player._placement_cells()
		check(bridge_cells.size() == 39, "小桥模板生成 39 个放置格")
		check(bridge_cells.has(bridge + Vector3i(0, 0, -3)) and bridge_cells.has(bridge + Vector3i(0, 0, 3)), "小桥默认沿南北方向延伸")
		check(bridge_cells.has(bridge + Vector3i(2, 1, 0)) and bridge_cells.has(bridge + Vector3i(-2, 1, 0)), "小桥包含两侧原木栏杆")
		check(bridge_cells.has(bridge + Vector3i(2, 2, 3)) and bridge_cells.has(bridge + Vector3i(-2, 2, -3)), "小桥四角包含灯笼")
		player._on_key(KEY_G)
		check(player.build_template_orientation_label() == "南北", "G 键可旋转小桥朝向")
		bridge_cells = player._placement_cells()
		check(bridge_cells.has(bridge + Vector3i(-3, 0, 0)) and bridge_cells.has(bridge + Vector3i(3, 0, 0)), "旋转后小桥沿东西方向延伸")
		_clear_cells(bridge_cells)
		player._update_placement_preview()
		check(player._preview_material.albedo_color.r > 0.6 and player._preview_material.albedo_color.g > 0.45, "小桥模板预览使用木色")
		check(_preview_unique_color_count(player) >= 3, "小桥模板预览区分桥面、栏杆和灯笼")
		check(player._try_place_current(), "小桥模板可一次放置")
		check(_last_label.contains("小桥") and _last_label.contains("x39"), "小桥放置反馈包含模板和数量")
		check(_main.world.get_block(bridge.x, bridge.y, bridge.z) == BlockLibrary.PLANKS, "小桥桥面使用木板")
		check(_main.world.get_block(bridge.x, bridge.y + 1, bridge.z + 2) == BlockLibrary.LOG, "小桥栏杆使用原木")
		check(_main.world.get_block(bridge.x + 3, bridge.y + 2, bridge.z + 2) == BlockLibrary.LANTERN, "小桥角灯使用灯笼")
		check(_main.world.undo_last_edit(), "一次撤销可撤销小桥模板")
		check(_all_cells_are(bridge_cells, BlockLibrary.AIR), "撤销后小桥区域恢复为空")

		player._on_key(KEY_T)
		check(player.build_template_id() == "garden", "T 键切到花圃模板")
		var garden := platform + Vector3i(104, 0, 16)
		player._target = garden - Vector3i.UP
		player._place = garden
		var garden_cells: Array = player._placement_cells()
		check(garden_cells.size() == 34, "花圃模板生成 34 个放置格")
		check(garden_cells.has(garden + Vector3i(-2, 0, -2)) and garden_cells.has(garden + Vector3i(2, 0, 2)), "花圃包含黏土边框")
		check(garden_cells.has(garden) and garden_cells.has(garden + Vector3i.UP), "花圃包含草床和上层装饰")
		_clear_cells(garden_cells)
		player._update_placement_preview()
		check(player._preview_material.albedo_color.g > player._preview_material.albedo_color.r and player._preview_material.albedo_color.r > 0.6, "花圃模板预览使用鲜亮草花色")
		check(_preview_unique_color_count(player) >= 4, "花圃模板预览区分边框、草床和花草")
		check(player._try_place_current(), "花圃模板可一次放置")
		check(_last_label.contains("花圃") and _last_label.contains("x34"), "花圃放置反馈包含模板和数量")
		check(_main.world.get_block(garden.x - 2, garden.y, garden.z - 2) == BlockLibrary.CLAY, "花圃边框使用黏土")
		check(_main.world.get_block(garden.x, garden.y, garden.z) == BlockLibrary.GRASS, "花圃内芯使用草方块")
		check(_main.world.get_block(garden.x, garden.y + 1, garden.z) == BlockLibrary.RED_MUSHROOM, "花圃中心使用红蘑菇")
		check(_main.world.get_block(garden.x + 1, garden.y + 1, garden.z) == BlockLibrary.WILDFLOWER, "花圃点缀野花")
		check(_main.world.get_block(garden.x + 1, garden.y + 1, garden.z + 1) == BlockLibrary.TALL_GRASS, "花圃角落点缀草丛")
		check(_main.world.undo_last_edit(), "一次撤销可撤销花圃模板")
		check(_all_cells_are(garden_cells, BlockLibrary.AIR), "撤销后花圃区域恢复为空")

		player._on_key(KEY_T)
		check(player.build_template_id() == "beacon_tower", "T 键切到灯塔模板")
		var beacon := platform + Vector3i(124, 0, 16)
		player._target = beacon - Vector3i.UP
		player._place = beacon
		var beacon_right: Vector3i = player._template_right_axis()
		var beacon_depth: Vector3i = player._template_depth_axis()
		var beacon_cells: Array = player._placement_cells()
		check(beacon_cells.size() == 76, "灯塔模板生成 76 个放置格")
		check(beacon_cells.has(beacon + beacon_right * 2) and beacon_cells.has(beacon + beacon_depth * -2), "灯塔包含 5x5 石质基座")
		check(beacon_cells.has(beacon + beacon_right + beacon_depth + Vector3i.UP * 4), "灯塔包含大理石塔身")
		check(beacon_cells.has(beacon + Vector3i.UP * 5) and beacon_cells.has(beacon + Vector3i.UP * 7), "灯塔包含灯室和砖顶")
		_clear_cells(beacon_cells)
		player._update_placement_preview()
		check(player._preview_material.albedo_color.b >= player._preview_material.albedo_color.r, "灯塔模板预览使用冷亮灯色")
		check(_preview_unique_color_count(player) >= 5, "灯塔模板预览区分石基、塔身、玻璃、灯火和砖顶")
		check(player._try_place_current(), "灯塔模板可一次放置")
		check(_last_label.contains("灯塔") and _last_label.contains("x76"), "灯塔放置反馈包含模板和数量")
		check(_main.world.get_block(beacon.x, beacon.y, beacon.z) == BlockLibrary.MOSSY_STONE, "灯塔中心基座使用苔石")
		var base_ring := beacon + beacon_right * 2
		check(_main.world.get_block(base_ring.x, base_ring.y, base_ring.z) == BlockLibrary.COBBLE, "灯塔外圈基座使用圆石")
		var tower_post := beacon + beacon_right + beacon_depth + Vector3i.UP
		check(_main.world.get_block(tower_post.x, tower_post.y, tower_post.z) == BlockLibrary.MARBLE, "灯塔塔身立柱使用大理石")
		var window := beacon + beacon_depth + Vector3i.UP * 2
		check(_main.world.get_block(window.x, window.y, window.z) == BlockLibrary.GLASS, "灯塔中段使用玻璃窗")
		check(_main.world.get_block(beacon.x, beacon.y + 5, beacon.z) == BlockLibrary.MOONSTONE_LAMP, "灯塔灯室中心使用月石灯")
		check(_main.world.get_block(beacon.x, beacon.y + 6, beacon.z) == BlockLibrary.LANTERN, "灯塔顶层使用灯笼")
		var roof := beacon + beacon_right + beacon_depth + Vector3i.UP * 6
		check(_main.world.get_block(roof.x, roof.y, roof.z) == BlockLibrary.BRICK, "灯塔顶棚使用砖块")
		check(_main.world.undo_last_edit(), "一次撤销可撤销灯塔模板")
		check(_all_cells_are(beacon_cells, BlockLibrary.AIR), "撤销后灯塔区域恢复为空")

		player._on_key(KEY_T)
		check(player.build_template_id() == "signpost", "T 键切到路标模板")
		var signpost := platform + Vector3i(144, 0, 16)
		player._target = signpost - Vector3i.UP
		player._place = signpost
		var sign_right: Vector3i = player._template_right_axis()
		var sign_depth: Vector3i = player._template_depth_axis()
		var sign_cells: Array = player._placement_cells()
		check(sign_cells.size() == 13, "路标模板生成 13 个放置格")
		check(sign_cells.has(signpost + Vector3i.UP * 4), "路标包含顶部发光点")
		check(sign_cells.has(signpost + sign_right * 2 + Vector3i.UP * 3), "路标包含指向木牌")
		check(sign_cells.has(signpost - sign_depth + Vector3i.UP * 2), "路标包含侧挂灯笼")
		_clear_cells(sign_cells)
		player._update_placement_preview()
		check(player._preview_material.albedo_color.r > 0.45 and player._preview_material.albedo_color.g > 0.35, "路标模板预览使用木色")
		check(_preview_unique_color_count(player) >= 5, "路标模板预览区分石基、立柱、木牌、灯笼和发光点")
		check(player._try_place_current(), "路标模板可一次放置")
		check(_last_label.contains("路标") and _last_label.contains("x13"), "路标放置反馈包含模板和数量")
		check(_main.world.get_block(signpost.x, signpost.y, signpost.z) == BlockLibrary.MOSSY_STONE, "路标中心基座使用苔石")
		var sign_post := signpost + Vector3i.UP * 2
		check(_main.world.get_block(sign_post.x, sign_post.y, sign_post.z) == BlockLibrary.LOG, "路标立柱使用原木")
		var sign_board := signpost + sign_right * 2 + Vector3i.UP * 3
		check(_main.world.get_block(sign_board.x, sign_board.y, sign_board.z) == BlockLibrary.PLANKS, "路标指向牌使用木板")
		var sign_lamp := signpost - sign_depth + Vector3i.UP * 2
		check(_main.world.get_block(sign_lamp.x, sign_lamp.y, sign_lamp.z) == BlockLibrary.LANTERN, "路标侧面挂灯笼")
		check(_main.world.get_block(signpost.x, signpost.y + 4, signpost.z) == BlockLibrary.MOONSTONE_LAMP, "路标顶部使用月石灯")
		check(_main.world.undo_last_edit(), "一次撤销可撤销路标模板")
		check(_all_cells_are(sign_cells, BlockLibrary.AIR), "撤销后路标区域恢复为空")

		player._on_key(KEY_T)
		check(player.build_template_id() == "off", "T 键可关闭模板")
		_main.hud._process(0.0)
		check(not _main.hud._template_orientation_label.visible, "关闭模板后 HUD 模板方向隐藏")
		selected_template_label = _main.hud._template_slots[player.build_template_index()]["label"]
		check(selected_template_label.text == "关闭" and selected_template_label.modulate.a > 0.9, "HUD 模板条高亮关闭状态")
		player._on_key(KEY_Q)
		check(player.build_template_id() == "signpost", "Q 键可反向切到上一个模板")
		check(_last_kind == "mode" and _last_label.contains("路标"), "Q 键反向切换发出模板反馈")
		_main.hud._process(0.0)
		selected_template_label = _main.hud._template_slots[player.build_template_index()]["label"]
		check(selected_template_label.text == "路标" and selected_template_label.modulate.a > 0.9, "HUD 模板条同步高亮反向切换结果")
		player._on_key(KEY_T)
		check(player.build_template_id() == "off", "T 键可从最后模板回到关闭")
		player._on_key(KEY_G)
		check(_last_kind == "blocked" and _last_label == "先选择模板", "无模板时 G 键提示先选择模板")
		player.template_index = 1
		player.brush_index = 0
		player._on_key(KEY_B)
		check(player.build_template_id() == "off" and player.brush_label() == "3x3", "切到 3x3 画笔会关闭模板")
		if failed == 0:
			print("✅ ALL BUILD TEMPLATE TESTS PASSED")
		else:
			printerr("❌ ", failed, " 个建造模板测试失败")
		return true
	return false

func _clear_cells(cells: Array) -> void:
	for cell in cells:
		var c: Vector3i = cell
		_main.world.set_block(c.x, c.y, c.z, BlockLibrary.AIR)

func _template_labels() -> Array:
	var labels := []
	for entry in _main.hud._template_slots:
		var slot: Dictionary = entry
		var label: Label = slot["label"]
		labels.append(label.text)
	return labels

func _has_world_event(kind: String) -> bool:
	for raw in _world_events:
		var event: Dictionary = raw
		if String(event.get("kind", "")) == kind:
			return true
	return false

func _world_event_count(kind: String) -> int:
	var count := 0
	for raw in _world_events:
		var event: Dictionary = raw
		if String(event.get("kind", "")) == kind:
			count += 1
	return count

func _template_icons_ready() -> bool:
	for entry in _main.hud._template_slots:
		var slot: Dictionary = entry
		var icon: Control = slot["icon"]
		if icon.get_child_count() <= 0:
			return false
	return true

func _template_icon_cell_count(label_text: String) -> int:
	for entry in _main.hud._template_slots:
		var slot: Dictionary = entry
		var label: Label = slot["label"]
		if label.text == label_text:
			var icon: Control = slot["icon"]
			return icon.get_child_count()
	return 0

func _preview_world_size(player) -> Vector3:
	var local_size: Vector3 = player.placement_preview.get_aabb().size
	var scale: Vector3 = player.placement_preview.scale
	return Vector3(local_size.x * scale.x, local_size.y * scale.y, local_size.z * scale.z)

func _preview_vertex_count(player) -> int:
	return _mesh_vertex_count(player.placement_preview)

func _preview_unique_color_count(player) -> int:
	if player.placement_preview.mesh == null or player.placement_preview.mesh.get_surface_count() == 0:
		return 0
	var arrays: Array = player.placement_preview.mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var seen := {}
	for color in colors:
		var c: Color = color
		var key := "%d,%d,%d" % [
			int(c.r * 255.0 + 0.5),
			int(c.g * 255.0 + 0.5),
			int(c.b * 255.0 + 0.5),
		]
		seen[key] = true
	return seen.size()

func _mesh_vertex_count(node: MeshInstance3D) -> int:
	if node.mesh == null or node.mesh.get_surface_count() == 0:
		return 0
	var arrays: Array = node.mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	return vertices.size()

func _all_cells_are(cells: Array, id: int) -> bool:
	for cell in cells:
		var c: Vector3i = cell
		if _main.world.get_block(c.x, c.y, c.z) != id:
			return false
	return true

func _unchanged_empty_except(cells: Array, blocked: Vector3i) -> bool:
	for cell in cells:
		var c: Vector3i = cell
		if c == blocked:
			continue
		if _main.world.get_block(c.x, c.y, c.z) != BlockLibrary.AIR:
			return false
	return true
