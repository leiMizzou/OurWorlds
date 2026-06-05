extends Control
# 标题页世界封面：用种子和进度生成稳定的“体素明信片”。

const WorldCatalog = preload("res://scripts/WorldCatalog.gd")

var _meta := {}
var _empty := true
var _cover_path := ""
var _cover_texture: ImageTexture

func _ready() -> void:
	clip_contents = true
	custom_minimum_size = Vector2(0, 118)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	queue_redraw()

func set_world_meta(meta: Dictionary, empty: bool = false) -> void:
	_meta = meta.duplicate()
	_empty = empty
	_load_cover_texture()
	queue_redraw()

func current_seed() -> int:
	return int(_meta.get("seed", 0))

func is_empty_preview() -> bool:
	return _empty

func cover_path() -> String:
	return _cover_path

func has_real_cover() -> bool:
	return _cover_texture != null

func restored_count() -> int:
	return maxi(0, int(_meta.get("restored_count", 0)))

func best_restore_percent() -> int:
	return clampi(int(_meta.get("best_restore_percent", 0)), 0, 100)

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if r.size.x < 8 or r.size.y < 8:
		return
	var seed := int(_meta.get("seed", 1337))
	var edit_count := maxi(0, int(_meta.get("edit_count", 0)))
	var discovery_count := maxi(0, int(_meta.get("discovery_count", 0)))
	var restored := restored_count()
	var best_restore := best_restore_percent()
	var journey_count := maxi(0, int(_meta.get("journey_count", 0)))
	var journey_total := maxi(1, int(_meta.get("journey_total", WorldCatalog.JOURNEY_TOTAL)))
	if _cover_texture != null:
		_draw_real_cover(r)
		_draw_restore_badge(r, restored, best_restore)
		_draw_progress(r, journey_count, journey_total)
		_draw_finish(r, false)
		return
	var theme := WorldCatalog.world_biome_label(seed)
	_draw_sky(r, seed, theme)
	_draw_sun(seed, r)
	_draw_landforms(r, seed, theme)
	_draw_voxel_foreground(r, seed, edit_count, discovery_count)
	_draw_restore_badge(r, restored, best_restore)
	_draw_progress(r, journey_count, journey_total)
	_draw_finish(r, _empty)

func _load_cover_texture() -> void:
	_cover_path = String(_meta.get("cover_path", ""))
	_cover_texture = null
	if _empty or _cover_path == "" or not FileAccess.file_exists(_cover_path):
		return
	var img := Image.new()
	if img.load(_cover_path) != OK or img.is_empty():
		return
	_cover_texture = ImageTexture.create_from_image(img)

func _draw_real_cover(r: Rect2) -> void:
	draw_texture_rect(_cover_texture, r, false, Color(1, 1, 1, 0.96))
	draw_rect(Rect2(Vector2(0, r.size.y * 0.62), Vector2(r.size.x, r.size.y * 0.38)), Color(0.0, 0.0, 0.0, 0.22))

func _draw_sky(r: Rect2, seed: int, theme: String) -> void:
	var top := _theme_sky_top(theme)
	var bottom := _theme_sky_bottom(theme)
	if _empty:
		top = top.darkened(0.08)
		bottom = bottom.darkened(0.04)
	for i in range(10):
		var t0 := float(i) / 10.0
		var t1 := float(i + 1) / 10.0
		var band := Rect2(Vector2(0, r.size.y * t0), Vector2(r.size.x, r.size.y * (t1 - t0) + 1.0))
		draw_rect(band, top.lerp(bottom, t0))
	var haze := Color(1.0, 1.0, 1.0, 0.05 + _unit(seed, 41) * 0.05)
	draw_rect(Rect2(Vector2(0, r.size.y * 0.46), Vector2(r.size.x, r.size.y * 0.18)), haze)

func _draw_sun(seed: int, r: Rect2) -> void:
	var x := lerpf(r.size.x * 0.18, r.size.x * 0.78, _unit(seed, 9))
	var y := lerpf(r.size.y * 0.20, r.size.y * 0.34, _unit(seed, 12))
	var radius := lerpf(10.0, 17.0, _unit(seed, 15))
	var glow := Color(1.0, 0.86, 0.42, 0.12)
	var core := Color(1.0, 0.83, 0.36, 0.86 if not _empty else 0.62)
	draw_circle(Vector2(x, y), radius * 2.15, glow)
	draw_circle(Vector2(x, y), radius, core)

func _draw_landforms(r: Rect2, seed: int, theme: String) -> void:
	var far := _theme_land(theme).darkened(0.20)
	var mid := _theme_land(theme).darkened(0.05)
	var water := _theme_water(theme)
	var horizon := r.size.y * 0.56
	var far_poly := PackedVector2Array([
		Vector2(0, r.size.y),
		Vector2(0, horizon + 18.0),
		Vector2(r.size.x * 0.16, horizon - 12.0 - _unit(seed, 3) * 12.0),
		Vector2(r.size.x * 0.34, horizon + 8.0),
		Vector2(r.size.x * 0.52, horizon - 20.0 - _unit(seed, 5) * 14.0),
		Vector2(r.size.x * 0.74, horizon + 4.0),
		Vector2(r.size.x, horizon - 10.0 - _unit(seed, 7) * 18.0),
		Vector2(r.size.x, r.size.y),
	])
	draw_colored_polygon(far_poly, far)
	var mid_poly := PackedVector2Array([
		Vector2(0, r.size.y),
		Vector2(0, horizon + 34.0),
		Vector2(r.size.x * 0.18, horizon + 8.0),
		Vector2(r.size.x * 0.36, horizon + 18.0),
		Vector2(r.size.x * 0.56, horizon - 2.0 - _unit(seed, 22) * 10.0),
		Vector2(r.size.x * 0.78, horizon + 18.0),
		Vector2(r.size.x, horizon + 4.0),
		Vector2(r.size.x, r.size.y),
	])
	draw_colored_polygon(mid_poly, mid)
	if theme == "湖岸" or theme == "浅湾" or theme == "溪谷":
		draw_rect(Rect2(Vector2(0, horizon + 34.0), Vector2(r.size.x, r.size.y * 0.22)), water)
		for i in range(6):
			var y := horizon + 42.0 + float(i) * 4.0
			draw_line(Vector2(16.0 + float(i) * 9.0, y), Vector2(r.size.x - 20.0, y + _unit(seed, i + 30) * 3.0), Color(1, 1, 1, 0.12), 1.0)

func _draw_voxel_foreground(r: Rect2, seed: int, edit_count: int, discovery_count: int) -> void:
	var block := maxf(7.0, floorf(r.size.x / 42.0))
	var base_y := r.size.y - 20.0
	var columns := int(ceil(r.size.x / block))
	for x in range(columns):
		var n := _unit(seed, x + 100)
		var h := 2 + int(n * 4.0)
		if _empty:
			h = maxi(1, h - 1)
		for y in range(h):
			var c := _block_color(seed, x, y)
			var px := float(x) * block
			var py := base_y - float(y) * block
			draw_rect(Rect2(Vector2(px, py), Vector2(block + 0.5, block + 0.5)), c)
	var built_blocks := clampi(int(sqrt(float(edit_count))), 0, 12)
	for i in range(built_blocks):
		var px := lerpf(r.size.x * 0.12, r.size.x * 0.86, _unit(seed, 200 + i))
		var height := 1 + int(_unit(seed, 250 + i) * 4.0)
		for y in range(height):
			draw_rect(Rect2(Vector2(px, base_y - float(y + 3) * block), Vector2(block, block)), Color(0.72, 0.62, 0.44, 0.88))
	var marks := clampi(discovery_count, 0, 5)
	for i in range(marks):
		var px := lerpf(r.size.x * 0.16, r.size.x * 0.88, _unit(seed, 400 + i))
		var py := lerpf(r.size.y * 0.50, r.size.y * 0.68, _unit(seed, 430 + i))
		draw_rect(Rect2(Vector2(px - 2.0, py), Vector2(4.0, 18.0)), Color(0.72, 0.95, 1.0, 0.72))
		draw_circle(Vector2(px, py - 2.0), 5.0, Color(0.92, 0.98, 1.0, 0.42))

func _draw_progress(r: Rect2, journey_count: int, journey_total: int) -> void:
	var pad := 12.0
	var gap := 5.0
	var h := 4.0
	var w := maxf(10.0, (r.size.x - pad * 2.0 - gap * float(journey_total - 1)) / float(journey_total))
	var y := r.size.y - 10.0
	for i in range(journey_total):
		var x := pad + float(i) * (w + gap)
		var filled := i < journey_count
		var c := Color(0.78, 0.96, 1.0, 0.86) if filled else Color(1, 1, 1, 0.18)
		if _empty:
			c = Color(1, 1, 1, 0.14)
		draw_rect(Rect2(Vector2(x, y), Vector2(w, h)), c)

func _draw_restore_badge(r: Rect2, restored_count: int, best_percent: int) -> void:
	if restored_count <= 0 and best_percent <= 0:
		return
	var percent := clampi(best_percent, 0, 100)
	var center := Vector2(r.size.x - 24.0, 22.0)
	var radius := 13.0
	draw_circle(center, radius + 5.0, Color(0.24, 0.98, 0.72, 0.14))
	draw_circle(center, radius, Color(0.05, 0.12, 0.10, 0.62))
	draw_arc(center, radius + 1.0, -PI * 0.5, -PI * 0.5 + TAU * float(percent) / 100.0, 32, Color(0.64, 1.0, 0.74, 0.92), 3.0)
	draw_circle(center, 4.0 + float(clampi(restored_count, 0, 6)) * 0.6, Color(0.96, 0.82, 0.28, 0.88))

func _draw_finish(r: Rect2, empty: bool) -> void:
	draw_rect(Rect2(Vector2.ZERO, r.size), Color(0, 0, 0, 0.10))
	draw_rect(Rect2(Vector2.ZERO, r.size), Color(1, 1, 1, 0.16 if not empty else 0.10), false, 1.0)
	draw_line(Vector2(0, 0), Vector2(r.size.x, 0), Color(1, 1, 1, 0.20), 1.0)

func _block_color(seed: int, x: int, y: int) -> Color:
	var moss := Color(0.31, 0.52, 0.24, 0.94)
	var grass := Color(0.42, 0.66, 0.29, 0.96)
	var soil := Color(0.38, 0.30, 0.22, 0.96)
	var stone := Color(0.46, 0.50, 0.50, 0.96)
	if y == 0:
		return moss.lerp(grass, _unit(seed, x + 500))
	if y > 2 and _unit(seed, x * 3 + y + 520) > 0.62:
		return stone
	return soil.lerp(stone, _unit(seed, x * 5 + y + 540) * 0.22)

func _theme_sky_top(theme: String) -> Color:
	match theme:
		"雪峰":
			return Color(0.42, 0.60, 0.86)
		"暮岭":
			return Color(0.40, 0.30, 0.52)
		"湖岸", "浅湾":
			return Color(0.26, 0.55, 0.82)
		_:
			return Color(0.30, 0.50, 0.78)

func _theme_sky_bottom(theme: String) -> Color:
	match theme:
		"雪峰":
			return Color(0.78, 0.86, 0.92)
		"暮岭":
			return Color(0.76, 0.52, 0.42)
		"湖岸", "浅湾":
			return Color(0.68, 0.84, 0.88)
		_:
			return Color(0.72, 0.82, 0.84)

func _theme_land(theme: String) -> Color:
	match theme:
		"雪峰":
			return Color(0.74, 0.78, 0.78)
		"石环", "荒丘":
			return Color(0.50, 0.48, 0.40)
		"湖岸", "浅湾":
			return Color(0.38, 0.58, 0.34)
		"暮岭":
			return Color(0.43, 0.38, 0.32)
		_:
			return Color(0.36, 0.54, 0.30)

func _theme_water(theme: String) -> Color:
	if theme == "雪峰":
		return Color(0.42, 0.72, 0.84, 0.58)
	return Color(0.22, 0.56, 0.76, 0.56)

func _unit(seed: int, salt: int) -> float:
	var h := absi(seed * 1103515245 + salt * 1013904223 + 12345)
	h = absi(h ^ (h >> 16))
	return float(h % 10000) / 9999.0
