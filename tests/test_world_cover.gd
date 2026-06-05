extends SceneTree
# 验证标题页世界封面控件的状态和确定性：
#   godot --headless --path <项目> --script res://tests/test_world_cover.gd

const WorldCover = preload("res://scripts/WorldCover.gd")
const WorldCatalog = preload("res://scripts/WorldCatalog.gd")

var failed := 0

func check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		failed += 1
		printerr("  FAIL ", msg)

func _initialize() -> void:
	var cover_path := "user://tests/world_cover/real_cover.png"
	_write_cover_png(cover_path)
	var cover: WorldCover = WorldCover.new()
	root.add_child(cover)
	var meta := {
		"seed": 20260604,
		"name": WorldCatalog.world_name(20260604),
		"biome_label": WorldCatalog.world_biome_label(20260604),
		"cover_path": cover_path,
		"edit_count": 12,
		"discovery_count": 3,
		"restored_count": 2,
		"best_restore_percent": 80,
		"journey_count": 2,
		"journey_total": WorldCatalog.JOURNEY_TOTAL,
	}
	cover.set_world_meta(meta, false)
	check(cover.current_seed() == 20260604, "封面保存当前世界种子")
	check(not cover.is_empty_preview(), "已有世界封面不是空预览")
	check(cover.cover_path() == cover_path, "封面记录真实图片路径")
	check(cover.has_real_cover(), "封面优先加载真实图片")
	check(cover.restored_count() == 2, "封面记录修复遗迹数量")
	check(cover.best_restore_percent() == 80, "封面记录最佳修复度")
	check(abs(cover._unit(20260604, 7) - cover._unit(20260604, 7)) < 0.0001, "封面随机辅助函数稳定")
	check(cover._unit(20260604, 7) >= 0.0 and cover._unit(20260604, 7) <= 1.0, "封面随机辅助函数范围有效")
	check(cover._theme_sky_top(WorldCatalog.world_biome_label(20260604)).a > 0.0, "封面地貌主题颜色有效")
	cover.set_world_meta({"seed": 1337, "journey_total": WorldCatalog.JOURNEY_TOTAL}, true)
	check(cover.current_seed() == 1337, "空预览封面可切换种子")
	check(cover.is_empty_preview(), "空预览状态可切换")
	check(not cover.has_real_cover(), "空预览不沿用上一张真实封面")
	_cleanup_cover(cover_path)
	if failed == 0:
		print("✅ ALL WORLD COVER TESTS PASSED")
	else:
		printerr("❌ ", failed, " 个世界封面测试失败")
	quit(failed)

func _write_cover_png(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var img := Image.create(64, 36, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.24, 0.56, 0.86, 1.0))
	img.save_png(path)

func _cleanup_cover(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
