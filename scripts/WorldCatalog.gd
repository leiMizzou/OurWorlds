extends RefCounted
# 本地世界目录：扫描 user://saves 下的世界存档，供标题页选择/删除。

const DEFAULT_DIR := "user://saves"
const JOURNEY_TOTAL := 8
const WorldGenerator = preload("res://scripts/WorldGenerator.gd")

const NAME_PREFIXES := [
	"晨雾", "星火", "青苔", "白石", "松影", "月湾",
	"风铃", "云脊", "蓝晶", "远山", "浅溪", "暮光",
]
const NAME_SUFFIXES := [
	"草原", "湿地", "山岭", "溪谷", "石环", "雪峰",
	"林地", "海岸", "高塔", "浅湾", "云原", "荒丘",
]
const BIOME_LABELS := [
	"草甸", "湿地", "山岭", "溪谷", "石环", "雪峰",
	"林地", "湖岸", "暮岭", "浅湾", "云原", "荒丘",
]

static func save_dir() -> String:
	if OS.has_environment("VC_SAVE_DIR"):
		return OS.get_environment("VC_SAVE_DIR")
	return DEFAULT_DIR

static func save_path_for_seed(seed: int) -> String:
	if OS.has_environment("VC_SAVE_PATH"):
		return OS.get_environment("VC_SAVE_PATH")
	return "%s/world_%d.json" % [save_dir(), seed]

static func cover_dir() -> String:
	return "%s/covers" % save_dir()

static func cover_path_for_seed(seed: int) -> String:
	return "%s/world_%d.png" % [cover_dir(), seed]

static func list_worlds() -> Array:
	if OS.has_environment("VC_NO_SAVE"):
		return []
	var dir_path := save_dir()
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return []
	var worlds := []
	var candidates := {}
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.begins_with("world_"):
			if file_name.ends_with(".json"):
				candidates["%s/%s" % [dir_path, file_name]] = true
			elif file_name.ends_with(".json.bak"):
				candidates["%s/%s" % [dir_path, file_name.trim_suffix(".bak")]] = true
		file_name = dir.get_next()
	dir.list_dir_end()
	for raw_path in candidates.keys():
		var path := String(raw_path)
		var meta := _read_world_meta(path)
		if not meta.is_empty():
			worlds.append(meta)
	worlds.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("updated_at", 0)) > int(b.get("updated_at", 0))
	)
	return worlds

static func latest_seed(default_seed: int) -> int:
	var worlds := list_worlds()
	if worlds.is_empty():
		return default_seed
	return int(worlds[0].get("seed", default_seed))

static func world_name(seed: int) -> String:
	var h: int = absi(seed * 1103515245 + 12345)
	var prefix_index: int = h % NAME_PREFIXES.size()
	var suffix_index: int = int(h / NAME_PREFIXES.size()) % NAME_SUFFIXES.size()
	var prefix := String(NAME_PREFIXES[prefix_index])
	var suffix := String(NAME_SUFFIXES[suffix_index])
	return "%s%s" % [prefix, suffix]

static func world_biome_label(seed: int) -> String:
	var h: int = absi(seed * 1664525 + 1013904223)
	return String(BIOME_LABELS[h % BIOME_LABELS.size()])

static func has_world(seed: int) -> bool:
	return not _read_world_meta(save_path_for_seed(seed)).is_empty()

static func delete_world(seed: int) -> bool:
	var path := save_path_for_seed(seed)
	var backup_path := path + ".bak"
	if not FileAccess.file_exists(path) and not FileAccess.file_exists(backup_path):
		return false
	var meta := _read_world_meta(path)
	var ok := true
	if FileAccess.file_exists(path):
		ok = DirAccess.remove_absolute(ProjectSettings.globalize_path(path)) == OK
	if ok:
		_remove_file_if_exists(backup_path)
		_remove_file_if_exists(path + ".tmp")
		var cover_path := String(meta.get("cover_path", ""))
		if _is_owned_cover_path(seed, cover_path) and FileAccess.file_exists(cover_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(cover_path))
	return ok

static func _remove_file_if_exists(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

static func edit_count_from_edits(edits: Dictionary) -> int:
	var n := 0
	for chunk_key in edits.keys():
		var chunk: Variant = edits[chunk_key]
		if typeof(chunk) == TYPE_DICTIONARY:
			n += (chunk as Dictionary).size()
	return n

static func discovery_count_from_data(data: Dictionary) -> int:
	if data.has("discovery_count"):
		return maxi(0, int(data.get("discovery_count", 0)))
	var discoveries: Variant = data.get("discoveries", [])
	return (discoveries as Array).size() if typeof(discoveries) == TYPE_ARRAY else 0

static func restored_count_from_data(data: Dictionary) -> int:
	return clampi(int(data.get("restored_count", 0)), 0, discovery_count_from_data(data))

static func best_restore_percent_from_data(data: Dictionary) -> int:
	return clampi(int(data.get("best_restore_percent", 0)), 0, 100)

static func journey_count_from_data(data: Dictionary) -> int:
	if data.has("journey_count"):
		return clampi(int(data.get("journey_count", 0)), 0, JOURNEY_TOTAL)
	var steps: Variant = data.get("journey_steps", [])
	return clampi((steps as Array).size(), 0, JOURNEY_TOTAL) if typeof(steps) == TYPE_ARRAY else 0

static func region_count_from_data(data: Dictionary) -> int:
	if data.has("region_count"):
		return clampi(int(data.get("region_count", 0)), 0, WorldGenerator.REGION_LABELS.size())
	var regions: Variant = data.get("visited_regions", [])
	return clampi((regions as Array).size(), 0, WorldGenerator.REGION_LABELS.size()) if typeof(regions) == TYPE_ARRAY else 0

static func _read_world_meta(path: String) -> Dictionary:
	var loaded := _read_world_data_with_backup(path)
	if loaded.is_empty():
		return {}
	var data: Dictionary = loaded["data"]
	var seed := int(data.get("seed", 0))
	if seed == 0:
		seed = _seed_from_path(path)
	if seed == 0:
		return {}
	var edits_raw: Variant = data.get("edits", {})
	var edits := edits_raw as Dictionary if typeof(edits_raw) == TYPE_DICTIONARY else {}
	return {
		"seed": seed,
		"kind": String(data.get("kind", "infinite")),
		"name": world_name(seed),
		"biome_label": world_biome_label(seed),
		"cover_path": String(data.get("cover_path", "")),
		"cover_exists": FileAccess.file_exists(String(data.get("cover_path", ""))),
		"path": path,
		"from_backup": bool(loaded.get("from_backup", false)),
		"updated_at": int(data.get("updated_at", 0)),
		"edit_count": int(data.get("edit_count", edit_count_from_edits(edits))),
		"discovery_count": discovery_count_from_data(data),
		"restored_count": restored_count_from_data(data),
		"best_restore_percent": best_restore_percent_from_data(data),
		"journey_count": journey_count_from_data(data),
		"journey_total": JOURNEY_TOTAL,
		"region_count": region_count_from_data(data),
		"region_total": WorldGenerator.REGION_LABELS.size(),
	}

static func _read_world_data_with_backup(path: String) -> Dictionary:
	var primary := _read_world_data(path)
	if not primary.is_empty():
		return {"data": primary, "from_backup": false}
	var backup := _read_world_data(path + ".bak")
	if backup.is_empty():
		return {}
	return {"data": backup, "from_backup": true}

static func _read_world_data(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var parser := JSON.new()
	var err := parser.parse(FileAccess.get_file_as_string(path))
	if err != OK or typeof(parser.data) != TYPE_DICTIONARY:
		return {}
	return parser.data

static func _seed_from_path(path: String) -> int:
	var base := path.get_file().trim_prefix("world_").trim_suffix(".json")
	return int(base) if base.is_valid_int() else 0

static func _is_owned_cover_path(seed: int, path: String) -> bool:
	if path == "":
		return false
	return path == cover_path_for_seed(seed)
