extends RefCounted
# 一个区块的纯方块数据：16×16 水平铺开、SY 高。
# 故意不含任何节点 —— 纯逻辑，方便单元测试，也方便以后放进后台线程生成。

const SX := 16    # 区块宽（X）
const SZ := 16    # 区块深（Z）
const SY := 96    # 世界高（Y）—— 山可以很高，撑"宏大"

var blocks := PackedByteArray()   # 长度 SX*SY*SZ，每格一个方块ID（0=空气）
var base_blocks := PackedByteArray()  # 程序化基线快照（未套用玩家增量前）。运行期缓存，不存档。
var cx := 0                        # 区块坐标（以"区块"为单位，不是方块）
var cz := 0
var dirty := true                 # 数据变了、网格需要重建

func _init(chunk_x: int = 0, chunk_z: int = 0) -> void:
	cx = chunk_x
	cz = chunk_z
	blocks.resize(SX * SY * SZ)   # PackedByteArray.resize 会自动填 0（空气）

# 三维坐标 -> 一维下标。y 放最外层，方便按"竖列"遍历。
static func index(x: int, y: int, z: int) -> int:
	return (y * SZ + z) * SX + x

func in_bounds(x: int, y: int, z: int) -> bool:
	return x >= 0 and x < SX and y >= 0 and y < SY and z >= 0 and z < SZ

func get_block(x: int, y: int, z: int) -> int:
	if not in_bounds(x, y, z):
		return 0   # 越界一律当空气
	return blocks[index(x, y, z)]

func set_block(x: int, y: int, z: int, id: int) -> void:
	if not in_bounds(x, y, z):
		return
	blocks[index(x, y, z)] = id
	dirty = true
