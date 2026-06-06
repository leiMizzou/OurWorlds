# 主题岛 SP3 — 各扇区标志建筑（并行）实现计划

> 续 SP1（浮岛+扇区）、SP2（霓虹/铁轨方块）。目标：给每个扇区盖上标志性建筑，让整岛读起来就是概念图里那 7+ 个主题区。**高度可并行** → 用 Workflow 一个 agent 造一个 builder。

**Goal:** 9 个确定性结构 builder（金字塔/天文台穹顶/赛博塔群/风车农田/灯塔码头/村屋群/雪山木屋/中央广场/铁轨桥网），各自独立文件 + 测试，最后统一接入 `IslandGenerator` 按扇区摆放。

## 架构（关键：可并行 + 确定性 + 分块安全）
- 每个结构是一个独立脚本 `scripts/structures/<Name>.gd`（`extends RefCounted`），**纯函数**，暴露：
  ```gdscript
  # 把本结构落在该 chunk 内的方块写进去。anchor=结构世界原点(Vector3i)。lib 供查方块 id。
  static func stamp(chunk, lib, anchor: Vector3i) -> void
  ```
  `stamp` 遍历 chunk 的本地格，算出世界坐标，判断该格是否属于本结构并 `chunk.set_block(lx,wy,lz,id)`。只写落在本 chunk 内的格 → 跨 chunk 结构天然正确、与生成顺序无关、确定性（不依赖随机状态，或用 `anchor`+坐标做确定性哈希）。
- 各 builder **互不依赖、各自文件** → 可并行创建，无冲突。
- 集成（串行、单文件）：`IslandGenerator.generate(chunk)` 在地形之后，对与该 chunk 相交的扇区，算出该扇区的结构 anchor（扇区中心，确定性），调用对应 builder 的 `stamp(chunk, lib, anchor)`。需要给 `IslandGenerator` 注入/preload `lib`（或传 BlockLibrary）。

## Builder 列表（每个 = 1 个并行 agent；各自 `scripts/structures/<Name>.gd` + `tests/test_struct_<name>.gd`）
1. **Pyramid**（沙漠扇区）— 阶梯式砂岩(SAND/RED_SAND/TERRACOTTA)金字塔，底边~24，入口龛。
2. **ObservatoryDome**（天文台扇区）— MARBLE 圆柱基座 + STEEL/GLASS 穹顶（半球）+ 观测缝。
3. **CyberTowers**（赛博扇区）— 3~5 座 STEEL_BLOCK/GLASS 高塔，棱边镶 NEON_CYAN/MAGENTA/LIME（发光）。
4. **WindmillFarm**（农田扇区）— PLANKS/LOG 风车塔 + 十字风叶 + 周边翻耕作物行（用现有自然块表现庄稼）。
5. **LighthouseDock**（热带扇区）— 灯塔（白/红环 BRICK/PLANKS + 顶部 SUNSTONE 光源）+ 木栈桥伸入水 + 小船廓。
6. **Village**（村庄扇区）— 4~6 间 PLANKS/LOG + 坡屋顶的小屋，含门窗(GLASS)、烟囱、石板路。
7. **SnowCabin**（雪山扇区）— 山坡上一间带烟囱的木屋 + 几株针叶（针叶地形已有，补木屋）。
8. **PlazaMonument**（中央广场）— 喷泉/纪念碑(MARBLE/GOLD_TRIM/WATER) + 放射状石板路 + LANTERN 路灯，出生点地标。
9. **RailBridgeNet**（连接）— 用 SP2 的 RAIL 沿主轴铺轨连接相邻扇区，跨水湾处架 PLANKS 桥。这一个依赖其它扇区 anchor，放集成阶段处理或单独 builder 接收多 anchor。

## 执行方式（Workflow 并行）
- **Phase Find/Build（并行）**：`parallel`/`pipeline` 一个 agent 造一个 builder（含 TDD 测试：stamp 到一个 Chunk，断言关键格是预期块）。各 builder agent 只创建自己那两个文件 → 无文件冲突，无需 worktree 隔离。
- **Phase Integrate（串行，单 agent）**：把 9 个 builder 接进 `IslandGenerator.generate`（按扇区算 anchor 调 stamp），加注入 lib；跑 `test_island_generator` + 新结构测试 + `run_all` 全绿。
- **Phase Verify**：俯瞰截图（复用 `shot_island.gd`，prime 半径调大）确认各区立起建筑；肉眼/我审查。

## 验收
进主题岛，各扇区有清晰可辨的标志建筑；赛博区夜间霓虹发光；铁轨连接；run_all 全绿；截图接近概念图布局。
