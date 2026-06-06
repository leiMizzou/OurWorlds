extends RefCounted
# 建造蓝图：把一块长方体区域的方块存成可分享数据（只存非空气，坐标相对盒子原点），
# 能序列化成 JSON、反序列化、并生成"粘贴"编辑列表（喂给 World.request_block_edits → 联机时也会广播）。
# 纯数据、无节点、可无头单测。数据形如：{ "size":[dx,dy,dz], "blocks":{"lx,ly,lz": block_id} }
const Chunk = preload("res://scripts/Chunk.gd")
const BlockLibrary = preload("res://scripts/BlockLibrary.gd")

# 捕获 [min_v, max_v]（含端点）区域的非空气方块。坐标相对盒子最小角。
static func capture(data, min_v: Vector3i, max_v: Vector3i) -> Dictionary:
	var lo := Vector3i(mini(min_v.x, max_v.x), mini(min_v.y, max_v.y), mini(min_v.z, max_v.z))
	var hi := Vector3i(maxi(min_v.x, max_v.x), maxi(min_v.y, max_v.y), maxi(min_v.z, max_v.z))
	var blocks := {}
	for x in range(lo.x, hi.x + 1):
		for y in range(lo.y, hi.y + 1):
			if y < 0 or y >= Chunk.SY:
				continue
			for z in range(lo.z, hi.z + 1):
				var id := int(data.get_block(x, y, z))
				if id != BlockLibrary.AIR:
					blocks["%d,%d,%d" % [x - lo.x, y - lo.y, z - lo.z]] = id
	return {
		"size": [hi.x - lo.x + 1, hi.y - lo.y + 1, hi.z - lo.z + 1],
		"blocks": blocks,
	}

static func serialize(bp: Dictionary) -> String:
	return JSON.stringify(bp)

static func deserialize(s: String) -> Dictionary:
	# 用 JSON 实例 parse()（返回错误码、不向 stderr 打印）——坏数据安静返回空，不污染日志/自检。
	var p := JSON.new()
	if p.parse(s) != OK:
		return {}
	var parsed: Variant = p.data
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed

# 把蓝图贴到 anchor（蓝图局部原点对齐到 anchor）→ 编辑列表 [{pos:Vector3i, id:int}]。
static func paste_edits(bp: Dictionary, anchor: Vector3i) -> Array:
	var out := []
	var blocks: Dictionary = bp.get("blocks", {})
	for key in blocks:
		var parts := str(key).split(",")
		if parts.size() != 3:
			continue
		var pos := Vector3i(anchor.x + int(parts[0]), anchor.y + int(parts[1]), anchor.z + int(parts[2]))
		if pos.y < 0 or pos.y >= Chunk.SY:
			continue
		out.append({"pos": pos, "id": int(blocks[key])})
	return out
