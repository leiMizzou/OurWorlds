# 主题岛世界 — SP1：地基（新世界类型 + 有限浮空岛生成 + 扇区框架）

日期：2026-06-06 · 状态：待评审（草案）

## 背景

用户希望新增一个外观像概念图的浮空主题岛世界（7 个主题区：雪山、沙漠金字塔、热带灯塔、中世纪村庄、赛博霓虹城、农田、天文台），**与现有的无限 / 二维群系世界并存**——现有世界一字节不动。已选实现方式：**程序化、按种子生成、多人安全**（目标"神似"，非逐像素复刻）。

终态 = 全 7 区 + 新增霓虹/铁轨方块；该终态拆为 SP1–SP4，**本文档只覆盖 SP1**。

拆分（上下文）：
- **SP1（本文）**：新世界类型 + 有限浮空岛生成 + 扇区框架 + 标题入口 + 多人 + 自检。只用现有方块；扇区只铺主题地形；标志建筑占位。
- **SP2**：新方块（霓虹/发光、铁轨）+ 程序图集。
- **SP3**：各扇区标志建筑生成器（金字塔、天文台穹顶、赛博塔群、风车、灯塔+码头、村屋、铁轨/桥网）。
- **SP4**：风格打磨（真瀑布、漂浮碎块、分区氛围、光照/天空、展示视角）。

## SP1 目标
- 可在标题页创建、并持久化、且能与无限世界区分的"主题岛"世界类型。
- 按种子确定性生成的有限浮空岛：有界 footprint、界外为空气、边缘崖壁 + 薄水环、出生于中央广场。
- 确定性扇区框架：把岛划成 3×3 网格，映射到 7 主题 + 中央广场 + 海湾，每扇区用**现有方块**铺其主题地表。
- 单人**与**多人都跑通（服务器+客户端按种子重生同一座岛；入场握手携带世界 kind）。
- 无头自检 + 一张俯瞰截图。

## SP1 非目标（明确推迟）
- 标志建筑（金字塔/天文台穹顶/赛博塔群/风车/灯塔/村屋/铁轨桥网）→ SP3。
- 新方块（霓虹/发光、铁轨）→ SP2。SP1 只用现有方块；赛博城与天文台扇区为**平整主题地基占位**（石/钢/玻璃、大理石/石）。
- 真瀑布、漂浮碎块、分区天气/光照、展示相机 → SP4。

## 架构

### 新增 `scripts/IslandGenerator.gd`
作为 `WorldGenerator` 的同级类，实现 `WorldData`/`World` 已依赖的**同一读取接口**：
- `_init(world_seed: int)`
- `generate(chunk: Chunk) -> void`
- `surface_height(wx, wz) -> int`
- `region_label(wx, wz) -> String`
- `region_description(wx, wz) -> String`

它是 **(seed, wx, wz) 的纯函数**——每线程独占一套由 `world_seed` 播种的噪声，沿用 WorldGenerator 的线程安全模式；`generate` 期间不触碰全局可变状态。

### 世界类型（kind）
引入世界类型字符串：`"infinite"`（默认 = 现有）与 `"themed_island"`。
- `WorldData._init(world_seed, kind := "infinite")` 据 kind 选生成器：infinite → `WorldGenerator`（路径不变）；themed_island → `IslandGenerator`。
- `World.setup(block_lib, world_seed, save_file, kind := "infinite")` 把 kind 透传给 `WorldData.new(world_seed, kind)`。
- **infinite 路径逐字节不变**（默认值保持现行为）。

### 持久化（`WorldCatalog` + 存档）
- 世界存档 JSON（`user://saves/world_<seed>.json`）新增顶层 `"kind"` 字段（缺省 ⇒ `"infinite"`，兼容旧存档）。
- `WorldCatalog._read_world_meta` 读出 `kind`（默认 `"infinite"`），使标题列表能标注主题世界、且 `Main` "继续"时知道建哪种生成器。
- 服务器存档（`NetworkManager.save_world`，`user://server_worlds/<seed>.json`）同样写入并在 load 时恢复 `kind`。

### 多人
- `NetworkManager.build_welcome` 增加 `"kind"`；`apply_welcome` 存下；`Main._on_welcomed` 用该 kind 建客户端世界。服务器/HOST 用 kind 构建权威 `WorldData`。
- 确定性：相同 seed+kind ⇒ 各端生成同一座岛，仅 delta 不同。除握手载荷多一个字符串外，不新增同步面。

### 标题入口（`TitleScreen` + `Main`）
- 新建世界面板在种子输入旁加**世界类型选择（无限 / 主题岛）**。
- `new_world_requested(seed)` → `new_world_requested(seed, kind)`。`Main._start_new_world(seed, kind)` → `_enter_world(seed, spawn, kind)` → `world.setup(..., kind)`；存档写 kind。
- "继续"从世界 meta 读 kind 并据此构建。

## 浮岛几何与扇区布局

- **Footprint**：正方形，边长 `ISLAND_SIZE = 512` 格（32×32 区块），以原点为中心（x,z 约 ∈ [-256, 256]）。footprint 之外 `generate` 写空气（浮空）。`ISLAND_SIZE` 为单一可调常量。
  - 选 512 的理由：3×3 中每扇区约 170×170 格，足够 SP3 放下城/金字塔；区块按需生成，放大只增漫游范围、不增前期开销。（后续改一个常量即可。）
- **边缘**：临近边界的余量带内地表跌成崖壁；边缘有一圈薄水环。（真·层叠瀑布 = SP4。）
- **垂直**：岛体为一块陆地板、底部石壳，其下为空气（读起来是"浮"的）。海平面沿用现有常量。
- **出生点**：中央广场（草地），平整安全。

### 扇区划分（确定性）
按 (wx,wz) 落在 footprint 的哪个三分之一映射扇区（3×3 网格）。每格主题：

```
              北
   ┌─────────┬─────────┬─────────┐
   │ 雪山     │ 沙漠     │ 热带     │
   │         │         │ (含水)   │
   ├─────────┼─────────┼─────────┤
   │ 中世纪村 │ 中央广场 │ 赛博城   │
   │         │ (出生)   │ (平整)   │
   ├─────────┼─────────┼─────────┤
   │ 天文台   │ 农田     │ 海湾     │
   │ (平整)   │         │ (含水)   │
   └─────────┴─────────┴─────────┘
```

每扇区 SP1 地表（仅现有方块）：
| 扇区 | SP1 地表主题 |
|---|---|
| 雪山 | 雪覆石；脊状高峰；松树 |
| 沙漠 | 沙 / 红沙 / 赤陶；沙丘；干灌木 |
| 热带 | 沙滩 + 水 + 草；树叶/树（灯塔→SP3） |
| 中世纪村 | 草 + 泥土路；树（房屋→SP3） |
| 中央广场 | 平整草/石；出生点 |
| 赛博城 | 平整 石/钢块/玻璃 地基（塔群→SP3） |
| 天文台 | 平整 大理石/石 地基（穹顶→SP3） |
| 农田 | 泥/草 平整翻耕观感（作物/风车→SP3） |
| 海湾 | 水 + 沙岸 |

扇区边界用一条短过渡带做高度/群系的轻微 lerp，避免硬墙接缝。

## 数据流
1. 标题 → 用户选 seed + kind=themed_island → `new_world_requested(seed, "themed_island")`。
2. `Main._start_new_world` → `_enter_world(seed, null, "themed_island")` → `world.setup(lib, seed, save, "themed_island")` → `WorldData.new(seed, "themed_island")` → `IslandGenerator.new(seed)`。
3. 区块流式 → `WorldData.ensure_data` → `IslandGenerator.generate(chunk)`（纯函数、可多线程）。
4. 存档写 `{kind, seed, edits, ...}`；"继续"读回 kind。
5. 多人：服务器以 kind 建权威 WorldData；welcome 携带 seed+kind；客户端建对应 IslandGenerator。

## 测试（无头 + 视觉）
- `tests/test_island_generator.gd`：确定性（同种子两实例生成的区块逐字节一致）；有界（超出 `ISLAND_SIZE/2 + 余量` 的列各 y 全为空气）；扇区→主题映射（各扇区采样格的地表方块属于预期族）；出生列为实地；边缘有水环。
- `tests/test_world_kind.gd`：`WorldData.new(seed,"themed_island")` 用 IslandGenerator；`"infinite"`/默认仍用 WorldGenerator 且对样本区块与现行输出一致（回归保护）。
- 多人：扩网络测试，断言 welcome 载荷带 `kind`，且由 welcome(kind=themed_island) 构建的客户端对样本列重生出与服务器一致的地表。
- `tests/shot_island.gd`：某主题岛种子的俯瞰截图，供唯一的人工肉眼确认。
- 把新无头测试接入 `tests/run_all.sh`。

## 改动文件
- **新增**：`scripts/IslandGenerator.gd`、`tests/test_island_generator.gd`、`tests/test_world_kind.gd`、`tests/shot_island.gd`。
- **修改**：`scripts/WorldData.gd`（kind 分派）、`scripts/World.gd`（setup 增 kind 参）、`scripts/Main.gd`（进入/新建/继续/服务器/HOST 携带 kind）、`scripts/TitleScreen.gd`（类型选择 + 信号）、`scripts/WorldCatalog.gd`（读写 kind）、`scripts/NetworkManager.gd`（welcome 带 kind；save/load kind）、`tests/run_all.sh`。

## 可调旋钮（后续可安全更改）
- `ISLAND_SIZE`（512）、扇区网格（3×3）、各扇区调色板、边缘余量/水环宽度、出生位置。
