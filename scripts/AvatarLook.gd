extends RefCounted
# 从网络身份（eid）确定性派生一套"长相"，让每个联机小人/Agent 一眼可区分，
# 而不是全部渲染成同一个蓝方块人。RemoteAvatar 调 look_for(eid) 拿到字典后按它造身体。
#
# 设计：对 eid 做"加盐"哈希——每个属性用不同的盐，于是各属性彼此独立地变化；
# 同一 eid -> 完全相同的 look；不同 eid -> （几乎总是）某些属性不同。纯函数、无副作用、可单测。

# ---- 调色板（保持可读/养眼）----
const SKINS := [
	Color(0.96, 0.80, 0.69),   # 浅
	Color(0.85, 0.66, 0.50),   # 中浅（原默认）
	Color(0.76, 0.57, 0.42),
	Color(0.58, 0.41, 0.30),
	Color(0.40, 0.28, 0.21),   # 深
]

const HAIRS := [
	Color(0.10, 0.09, 0.09),   # 黑
	Color(0.36, 0.24, 0.13),   # 棕
	Color(0.62, 0.44, 0.20),   # 浅棕
	Color(0.86, 0.72, 0.36),   # 金
	Color(0.74, 0.16, 0.12),   # 红/橙
	Color(0.62, 0.62, 0.66),   # 灰
	Color(0.30, 0.55, 0.78),   # 染蓝（俏皮）
]

const JACKETS := [
	Color(0.30, 0.62, 1.00),   # 蓝（原默认）
	Color(0.86, 0.31, 0.27),   # 红
	Color(0.30, 0.72, 0.42),   # 绿
	Color(0.95, 0.70, 0.20),   # 黄
	Color(0.66, 0.38, 0.80),   # 紫
	Color(0.95, 0.55, 0.25),   # 橙
	Color(0.20, 0.72, 0.74),   # 青
	Color(0.92, 0.46, 0.66),   # 粉
]

const PANTS := [
	Color(0.20, 0.22, 0.28),   # 深灰蓝（原默认）
	Color(0.30, 0.26, 0.20),   # 卡其
	Color(0.16, 0.30, 0.45),   # 牛仔蓝
	Color(0.14, 0.14, 0.16),   # 近黑
]

const ACCENTS := [
	Color(0.97, 0.97, 0.98),   # 白
	Color(0.12, 0.12, 0.14),   # 黑
	Color(0.95, 0.78, 0.20),   # 金
	Color(0.85, 0.25, 0.30),   # 红
	Color(0.25, 0.78, 0.92),   # 亮青
]

const HAIR_STYLES := ["short", "long", "mohawk", "bun", "cap", "bald"]
const BUILDS := ["slim", "broad"]
const ACCESSORIES := ["none", "hardhat", "antenna", "visor"]

# 加盐哈希取索引：同一 (eid, salt) 稳定；不同 salt 让各属性独立变化。
static func _pick(arr: Array, eid: String, salt: int) -> Variant:
	var h: int = abs(("%s#%d" % [eid, salt]).hash())
	return arr[h % arr.size()]

static func look_for(eid: String) -> Dictionary:
	return {
		"skin": _pick(SKINS, eid, 11),
		"hair": _pick(HAIRS, eid, 23),
		"jacket": _pick(JACKETS, eid, 31),
		"accent": _pick(ACCENTS, eid, 47),
		"pants": _pick(PANTS, eid, 59),
		"hair_style": _pick(HAIR_STYLES, eid, 71),
		"build": _pick(BUILDS, eid, 83),
		"accessory": _pick(ACCESSORIES, eid, 97),
	}
