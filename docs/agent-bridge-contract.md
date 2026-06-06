# OurWorlds Agent Control Contract (v1)

How an external LLM agent (driven via OpenClaw / an MCP bridge) **perceives** and **acts**
inside the running OurWorlds game (Godot 4.6).

This document is the **interface contract** the build agents implement. It maps every agent
tool onto a **real** method that already exists in the game code (verified against
`scripts/World.gd`, `scripts/Player.gd`, `scripts/BlockLibrary.gd`, `scripts/Chunk.gd`,
`scripts/DiscoveryTracker.gd`, `scripts/Main.gd`). The agent works at a **semantic / high
level** — it never places blocks one coordinate at a time; it asks for areas, templates,
and goals, and the game does the voxel work.

---

## 1. Transport

| Property | Value |
| --- | --- |
| Protocol | **Plain TCP** (a raw stream socket — *not* WebSocket, *not* HTTP). |
| Framing | **Newline-delimited JSON** (NDJSON). Exactly one JSON object per line, terminated by `\n`. |
| Encoding | UTF-8. Block names may be Chinese; always UTF-8. |
| Host | `127.0.0.1` (loopback only). |
| Port | From env var **`OW_AGENT_PORT`**, default **`8970`**. |
| Concurrency | **Multi-client.** The game accepts multiple simultaneous connections; each connection is one online entity (`agent-N`, renamable via `identify` — see §11). Requests are dispatched per-connection on the main thread. |
| Direction | Request: bridge → game. Response: game → bridge. The game also MAY push **unsolicited events** (see §7); a client that ignores them is still correct. |

The MCP bridge is the only client; there is no browser, so no WebSocket handshake and no
CORS. Keep it a dumb byte stream.

### 1.1 Request envelope

Every request is a single-line JSON object:

```json
{"id": 7, "tool": "observe", "args": {}}
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `id` | number or string | **yes** | Opaque correlation id. Echoed verbatim in the response. The bridge generates it. |
| `tool` | string | **yes** | One of the tool names in §4. |
| `args` | object | no (default `{}`) | Tool-specific arguments. |

### 1.2 Response envelope

Exactly one of these two shapes, single-line, per request:

```json
{"id": 7, "ok": true,  "result": { ... }}
{"id": 7, "ok": false, "error": "unknown tool: fooberry"}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `id` | number/string | Echo of the request `id`. For protocol-level errors where the id could not be parsed, the game emits `"id": null`. |
| `ok` | bool | `true` ⇒ `result` present. `false` ⇒ `error` present. |
| `result` | object | Tool-specific payload. Present iff `ok`. |
| `error` | string | Human-readable, single-line reason. Present iff `!ok`. |

The game **never** crashes the connection on a bad request; it returns `ok:false`. Malformed
JSON on a line ⇒ `{"id":null,"ok":false,"error":"bad json: <reason>"}` and the line is
discarded (the stream stays open).

### 1.3 Threading note (implementation requirement)

All game-state reads/writes (`World`, `Player`, scene tree) **must run on the main thread**.
The TCP poll + line parsing happens in `_process` on the bridge node; each parsed request is
dispatched synchronously inside that same `_process` tick, so handlers touch live nodes
safely. Do **not** service requests from a `Thread`. `World.request_block_edits` already
off-loads meshing to `WorkerThreadPool` internally, so synchronous calls do not stall.

---

## 2. World model & coordinate conventions

- **Axes**: right-handed Godot. `+X` = east, `+Z` = south, `+Y` = up. Integers are block (voxel) cells.
- **A cell** `[x,y,z]` is the integer lattice coordinate of one ourworlds.
- **Vertical range**: `y ∈ [0, 95]`. (`Chunk.SY == 96`.) Edits or queries outside this range are clamped/rejected per-tool; `get_block` returns `"air"` for out-of-range `y`.
- **Chunks** are `16 × 16` in X/Z (`Chunk.SX == Chunk.SZ == 16`), full height. `chunk_of(x,z)` → `[cx,cz]`.
- **Surface height** `surface_y(x,z)` returns the world Y of the **topmost generated solid** column at `(x,z)` from procedural generation (does **not** account for player edits — it is the generator's terrain height). Standing-on-ground Y for an agent is `surface_y(x,z) + 1`.
- **Block identity** is an integer id in the engine, but **the agent protocol speaks block *names*** (strings). See §3.
- **Facing**: the player's body yaw is `Player.rotation.y` (radians, around +Y) and look pitch is `Player.pitch` (radians, `[-1.4, 1.4]`, + = up). The protocol exposes both as **degrees** and a cardinal label.

---

## 3. Block name ↔ id resolution (normative)

The engine has no built-in name→id lookup, so the bridge builds one **once at startup** and
exposes blocks to the agent **by name**. Build the table by iterating
`BlockLibrary.creative_blocks()` (and `hotbar_blocks()`), and for each id record:

- the **canonical Chinese name** = `BlockLibrary.block_name(id)` (e.g. id `1` → `"草方块"`),
- a stable lowercase **English alias** from the fixed table below.

Accept **either** form (case-insensitive, trim spaces) anywhere a tool takes a `block`
name. Always **emit the English alias** in observations (`selected_block`, `hotbar`,
`get_block`, scan legends) so the LLM gets stable, language-neutral tokens; optionally
include the Chinese in a parallel field if useful.

`air` (id `0`) is always a valid name for `break`/fill semantics.

| id | English alias | 中文 (`block_name`) |
| ---:| --- | --- |
| 0 | `air` | 空气 |
| 1 | `grass` | 草方块 |
| 2 | `dirt` | 泥土 |
| 3 | `stone` | 石头 |
| 4 | `cobblestone` | 圆石 |
| 5 | `log` | 木头 |
| 6 | `planks` | 木板 |
| 7 | `sand` | 沙子 |
| 8 | `glass` | 玻璃 |
| 9 | `water` | 水 |
| 10 | `leaves` | 树叶 |
| 11 | `snow` | 雪 |
| 12 | `coal_ore` | 煤矿 |
| 13 | `iron_ore` | 铁矿 |
| 14 | `brick` | 砖块 |
| 15 | `mossy_stone` | 苔石 |
| 16 | `basalt` | 玄武岩 |
| 17 | `marble` | 大理石 |
| 18 | `lantern` | 灯笼 |
| 19 | `wildflower` | 野花 |
| 20 | `tall_grass` | 草丛 |
| 21 | `pine_leaves` | 针叶 |
| 22 | `copper_ore` | 铜矿 |
| 23 | `red_mushroom` | 红蘑菇 |
| 24 | `reeds` | 芦苇 |
| 25 | `blue_crystal` | 蓝晶 |
| 26 | `clay` | 黏土 |
| 27 | `moonstone_lamp` | 月石灯 |
| 28 | `polished_iron` | 精炼铁 |
| 29 | `copper_panel` | 铜面板 |
| 30 | `steel_block` | 钢块 |
| 31 | `gold_trim` | 鎏金饰板 |
| 32 | `red_sand` | 红沙 |
| 33 | `terracotta` | 赤陶 |
| 34 | `sunstone` | 暖光石 |

An unknown block name in a request ⇒ `ok:false`, `error:"unknown block: <name>"`.
Light-emitting placeable blocks: `lantern`, `moonstone_lamp`, `blue_crystal`, `sunstone`.

---

## 4. Tools

All tools follow §1. Below, each tool lists its `args` and its `result`. Coordinates are
integer cells. Distances are in blocks. Angles are in degrees.

Quick index: `observe`, `look`, `goto`, `scan`, `place`, `break`, `build`, `get_block`,
`say`, `set_goal`, `remember`, `get_memory`.

---

### 4.1 `observe` — full situational snapshot

The agent's primary perception call. One request returns everything needed to decide a next
action, including a local heightmap so the LLM can "see" terrain without per-block queries.

**args**: `{}` *(optionally `{"heightmap_size": 16}`; default and max 16; must be even — it is centered on the player.)*

**result**
```json
{
  "pos": [12, 41, -8],
  "facing": {"yaw_deg": 270.0, "pitch_deg": -12.5, "cardinal": "W"},
  "region": "草原",
  "region_en": "meadow",
  "time_of_day": {"fraction": 0.30, "phase": "morning", "clock": "07:12"},
  "selected_block": "grass",
  "hotbar": ["grass","dirt","stone","brick","mossy_stone","basalt","marble","log","planks","glass","lantern","moonstone_lamp","sunstone","polished_iron","copper_panel","wildflower"],
  "heightmap": {
    "size": 16,
    "origin": [4, -16],
    "rows": [[40,40,41, ...16 ints...], ...16 rows...]
  },
  "nearby_landmarks": [
    {"label": "月华神殿", "pos": [33, 44, -20], "distance": 21, "direction": "NE", "discovered": false, "restoration_percent": 0}
  ],
  "recent_actions": [
    {"tool": "build", "summary": "campfire @ (12,41,-8)", "ok": true},
    {"tool": "goto",  "summary": "-> (12,41,-8)", "ok": true}
  ]
}
```

| Field | Source | Notes |
| --- | --- | --- |
| `pos` | `floor(Player.global_position)` → `[x,y,z]` | Player feet cell. |
| `facing.yaw_deg` | `rad_to_deg(Player.rotation.y)` normalized to `[0,360)` | 0 = facing −Z (north). |
| `facing.pitch_deg` | `rad_to_deg(Player.pitch)` | + = looking up. |
| `facing.cardinal` | derived from yaw | `N,NE,E,SE,S,SW,W,NW`. |
| `region` | `World.region_label(px, pz)` | Chinese label (one of 14, see §6). |
| `region_en` | english alias of region (see §6 table) | |
| `time_of_day.fraction` | `Main._time` (`0..1`) | 0.30 ≈ morning (the game's start). |
| `time_of_day.phase` | bucketed fraction | `night, dawn, morning, noon, afternoon, dusk` (see §6.1). |
| `time_of_day.clock` | `fraction*24h` formatted | Cosmetic. |
| `selected_block` | english alias of `Player.current_block()` | |
| `hotbar` | `BlockLibrary.hotbar_blocks()` mapped to aliases | Length 16. |
| `heightmap` | for each `(x,z)` in the `size×size` window centered on the player, `World.surface_y(x,z)` | `origin` = world `[x,z]` of `rows[0][0]`; `rows[r][c]` is column at `[origin.x + c, origin.z + r]`. Generator terrain height (ignores edits). |
| `nearby_landmarks` | `DiscoveryTracker` (see §5) | Up to 6, nearest first, within ~64 blocks. |
| `recent_actions` | bridge-maintained ring buffer | Last ≤ 8 acting calls + outcome summaries (the bridge fills this; see §4.13). |

---

### 4.2 `look` — aim the view

Rotate the player's body yaw and look pitch (so subsequent `observe`/`scan` framing and the
in-game camera reflect the new heading). Does not move.

**args**
```json
{"yaw_deg": 90.0, "pitch_deg": -10.0}
```
Both optional; omitted axis is left unchanged. `yaw_deg` is absolute, normalized to
`[0,360)`. `pitch_deg` is clamped to `[-80, 80]` (engine clamps `Player.pitch` to ±1.4 rad).

**Mapping**: set `Player.rotation.y = deg_to_rad(yaw_deg)`; set `Player.pitch =
clampf(deg_to_rad(pitch_deg), -1.4, 1.4)` and `Player.spring.rotation.x = Player.pitch`.

**result**
```json
{"facing": {"yaw_deg": 90.0, "pitch_deg": -10.0, "cardinal": "E"}}
```

---

### 4.3 `goto` — move to a surface position

Relocate the player to the surface at horizontal `(x, z)`. v1 is an instantaneous
**teleport** (deterministic, no pathfinding); the player lands standing on the ground.

**args**
```json
{"x": 40, "z": -12}
```
Optional `"y"`: if given, place exactly at that Y instead of the surface (clamped to `[0,95]`).

**Mapping**: `var sy = World.surface_y(x, z)` then `Player.global_position = Vector3(x + 0.5,
sy + 1.0, z + 0.5)` and `Player.velocity = Vector3.ZERO`. The world streams chunks around the
new position automatically (`World.track_target` is the player). Optionally call
`World.prime(World.chunk_of(x,z), 1)` so the destination is solid immediately.

**result**
```json
{"pos": [40, 38, -12], "region": "针叶林", "region_en": "taiga", "surface_y": 37}
```

---

### 4.4 `scan` — compact area summary

A cheap overview of a square area centered on the player: per-column surface height + the
dominant surface block, plus aggregate stats. Lets the LLM understand terrain/biome shape and
pick build spots **without** issuing thousands of `get_block` calls.

**args**
```json
{"radius": 12}
```
`radius` in blocks (default 8, **max 24**). The scanned square is `(2*radius+1)` per side,
centered on the player's `(x,z)`.

**result**
```json
{
  "center": [12, -8],
  "radius": 12,
  "surface_y": {"min": 33, "max": 58, "avg": 41},
  "columns": {
    "step": 3,
    "origin": [0, -20],
    "height": [[40,41, ...], ...],
    "surface_block": [["grass","grass","sand", ...], ...]
  },
  "block_histogram": {"grass": 410, "stone": 88, "water": 51, "sand": 30},
  "regions_present": ["草原", "浅水湾"],
  "water_fraction": 0.07,
  "landmarks_in_range": [
    {"label": "月华神殿", "pos": [33,44,-20], "distance": 21, "discovered": false}
  ],
  "suggested_build_spot": [10, 41, -5]
}
```

To keep responses bounded for large radii, columns are **down-sampled** by `step` (the bridge
picks `step = ceil((2*radius+1) / 16)` so the grid is ≤ 16×16). `origin` is the world `[x,z]`
of `height[0][0]`; cell `[r][c]` is world `[origin.x + c*step, origin.z + r*step]`.

| Field | Source |
| --- | --- |
| `surface_y` stats | `World.surface_y` over the sampled grid. |
| `columns.height` | `World.surface_y(x,z)` per sampled cell. |
| `columns.surface_block` | `get_block(x, surface_y(x,z), z)` per sampled cell → alias (the topmost solid; `water` reported where the column top is water). |
| `block_histogram` | counts of surface blocks over the sampled grid. |
| `regions_present` | distinct `World.region_label` over the grid. |
| `water_fraction` | fraction of sampled columns whose top is `water`. |
| `landmarks_in_range` | `DiscoveryTracker` landmarks within `radius`. |
| `suggested_build_spot` | a flat-ish cell (small local height variance) near center, as `[x, surface_y+1, z]`; heuristic, may be `null`. |

---

### 4.5 `place` — set cells to a block (semantic bulk)

Place a block at a **set** of cells in one atomic batch. The agent supplies the geometry it
already reasoned about (a list of cells); this is the escape hatch for shapes templates do not
cover. It maps **directly** to the engine's batched, single-remesh edit path. The LLM should
pass *meaningful* cell sets (a wall, a floor, an outline) — not stream single cells.

**args**
```json
{"block": "planks", "cells": [[10,41,-5],[11,41,-5],[12,41,-5]]}
```
- `block`: block name (§3). May be `air` (equivalent to `break`).
- `cells`: array of `[x,y,z]`. Out-of-range `y` cells are skipped. **Max 4096 cells** per call (`ok:false` if exceeded).

**Mapping**: build `edits = cells.map(c -> {"pos": Vector3i(c), "id": id})` and call
`World.request_block_edits(edits)`. That dedups, skips no-ops, writes all data, **remeshes each
dirty chunk once**, and records one undo entry.

**result**
```json
{"requested": 3, "changed": 3, "block": "planks"}
```
`changed` = the int returned by `request_block_edits` (cells that actually changed; cells
already equal to the target, or out of range, are not counted).

---

### 4.6 `break` — clear cells to air

Convenience alias of `place` with `block = air`.

**args**
```json
{"cells": [[10,41,-5],[10,42,-5]]}
```
Same limits as `place` (max 4096 cells).

**Mapping**: `World.request_block_edits(cells.map(c -> {"pos": Vector3i(c), "id": 0}))` (or
the equivalent `World.request_edits(cells_as_Vector3i, BlockLibrary.AIR)`).

**result**
```json
{"requested": 2, "changed": 2}
```

---

### 4.7 `build` — stamp a named structure (high-level)

Place one of the game's **build templates** at an anchor cell, reusing the *exact* geometry the
in-game build tool produces. This is the primary "construct something" verb — the LLM names a
structure and a location, and the game generates and places all its blocks (including
multi-material templates) in one batch. **No per-coordinate placement.**

**args**
```json
{"template": "campfire", "x": 12, "y": 41, "z": -8, "rotation": 0}
```

| arg | Type | Notes |
| --- | --- | --- |
| `template` | string | One of the ids below. |
| `x,y,z` | int | **Anchor cell** = the engine's `_place` (the structure's base/origin cell). For ground structures, use `[x, surface_y(x,z)+1, z]` so the base sits on the ground. |
| `rotation` | int | `0` or `1` (also accept degrees: `0/90/180/270` → even = `0`, odd = `1`). Maps to `Player.template_orientation_index` (0 = E–W / 东西, 1 = N–S / 南北). Templates are 0°/90° only. |

**Templates** (`Player.BUILD_TEMPLATES`, id → 中文 label):

| id | label | id | label |
| --- | --- | --- | --- |
| `platform` | 平台 | `room_frame` | 房架 |
| `pillar` | 立柱 | `cabin` | 小屋 |
| `arch` | 拱门 | `campfire` | 营火 |
| `wall` | 墙面 | `bridge` | 小桥 |
| `stairs` | 楼梯 | `garden` | 花圃 |
| | | `beacon_tower` | 灯塔 |
| | | `signpost` | 路标 |

(The 11 requested — `platform, pillar, arch, wall, stairs, room_frame, campfire, bridge,
garden, beacon_tower` — are all present, plus `cabin` and `signpost`. `off` is not a build
target; reject it with `ok:false`.)

**Mapping (normative)** — produce the engine's own edit list, then commit it:
1. Set the player's template context to the requested template:
   `Player.template_index = <index of template in BUILD_TEMPLATES>`,
   `Player.template_orientation_index = rotation_to_index(rotation)`.
2. Set the anchor & face so the template math centers on `(x,y,z)`:
   `Player._place = Vector3i(x, y, z)`, `Player._target_normal = Vector3i.UP`.
3. Compute edits with the engine's own builder:
   `var edits = Player._placement_edits()` (this dispatches to the right
   `_<template>_template_edits()` / `_template_cells()` for the chosen template, anchored at
   `_place`, rotated by `template_orientation_index`).
4. Commit: `var changed = World.request_block_edits(edits)`.

> The build agent MAY instead factor the template geometry into a static helper that takes
> `(template, place, orientation)` and returns the same edit array, to avoid mutating live
> `Player` state. Either way the **resulting cells must be identical** to what the in-game tool
> places, and the commit goes through `World.request_block_edits` (one undo entry, one remesh
> per chunk).

Templates anchored relative to `_place` use template-local axes
`right = (rotation==0 ? +X : +Z)` and `depth = (rotation==0 ? +Z : +X)` (`Player._template_right_axis` / `_template_depth_axis`). Footprints (for spot planning): `platform` 5×5 pad; `pillar` 1×5 tall; `arch`/`wall` 5 wide; `stairs` ~3×5×5; `room_frame` 7×7×5 shell; `cabin` ~9×9×7 house; `campfire` 3×3; `bridge` 5×7 deck; `garden` 5×5 bed; `beacon_tower` 5×5×8 tower; `signpost` small post.

**result**
```json
{"template": "campfire", "anchor": [12,41,-8], "rotation": 0, "changed": 10}
```
`changed` = blocks actually placed/changed. If `0` (e.g. anchor buried, everything already
matches) the call still returns `ok:true` with `changed:0`.

---

### 4.8 `get_block` — read one cell

**args**
```json
{"x": 12, "y": 40, "z": -8}
```

**Mapping**: `World.get_block(x,y,z)` → alias. `y` outside `[0,95]` ⇒ `"air"`.

**result**
```json
{"pos": [12,40,-8], "block": "grass", "solid": true}
```
`solid` = `BlockLibrary.is_solid(id)`.

---

### 4.9 `say` — surface a message in-game

Show an agent message on the in-world HUD (the feedback banner). Lets the agent narrate or
announce intent to a human watching the screen.

**args**
```json
{"text": "Building a campfire by the lake."}
```
`text` trimmed to ≤ 120 chars.

**Mapping**: emit through the HUD feedback channel the game already uses, e.g.
`HUD.show_feedback("agent", text)` (same path as `World.save_feedback`/`edit_feedback` → HUD),
or `Player.action_feedback.emit("agent", text)`. The build agent picks whichever HUD entry
point is wired; the message must appear on-screen.

**result**
```json
{"shown": true}
```

---

### 4.10 `set_goal` — record the agent's current objective

Persist a one-line current goal in the agent scratchpad (and optionally show it via `say`).

**args**: `{"text": "Restore the moonlit shrine to 100%."}` (≤ 200 chars)

**Mapping**: write `memory.goal = text` and persist (see §4.12 / file format). Returns the
stored goal.

**result**: `{"goal": "Restore the moonlit shrine to 100%."}`

---

### 4.11 `remember` — append a note to the scratchpad

Append a free-form note to a bounded memory log the game persists for the agent across runs.

**args**: `{"text": "Shrine is NE of spawn near the lake at (33,44,-20)."}` (≤ 280 chars)

**Mapping**: `memory.notes.push(text)`; keep only the last **50** notes; persist. Returns count.

**result**: `{"remembered": true, "note_count": 12}`

---

### 4.12 `get_memory` — read the scratchpad

**args**: `{}`

**result**
```json
{
  "goal": "Restore the moonlit shrine to 100%.",
  "notes": ["Shrine is NE of spawn ...", "..."],
  "updated_at": 1733383200
}
```

#### Persistence (normative)

`set_goal` / `remember` / `get_memory` operate on a single JSON file the **game** owns:

- Path: **`user://agent_memory.json`** (Godot user data dir).
- Shape:
  ```json
  {"version": 1, "goal": "", "notes": [], "updated_at": 0}
  ```
- Loaded once on bridge startup; written (atomically — temp file + rename, mirroring
  `World._write_save_text`) after every `set_goal` / `remember`. `updated_at` =
  `Time.get_unix_time_from_system()`. Corrupt/missing file ⇒ start from the empty shape.

### 4.13 `recent_actions` (bridge-maintained, not a tool)

The bridge keeps a ring buffer (≤ 8) of the most recent **acting** calls (`goto`, `place`,
`break`, `build`, `look`, `say`) with a one-line `summary` and `ok`, and returns it inside
`observe`. This is bridge state, not persisted, not separately queryable.

---

## 5. Landmarks & discovery (perception source)

`nearby_landmarks` (in `observe`) and `landmarks_in_range` (in `scan`) come from the live
`DiscoveryTracker` node (`Main.$DiscoveryTracker`):

- **Undiscovered, nearby**: from `DiscoveryTracker.nearby_hint_position()` /
  `nearby_hint_distance()` / `nearby_hint_direction()` (the game's "something is near" hint),
  plus a scan of `_all_landmarks_for_chunk(cc)` over chunks around the player for any whose
  anchor still exists (`World.get_block` check) and is within range. Report `discovered:false`.
- **Discovered**: from `DiscoveryTracker.discovered_entries()` →
  `{label, type, guardian, world_pos, restoration{percent,...}}`. Report `discovered:true` and
  `restoration_percent` from `World.landmark_restoration(pos).percent`.

Each landmark entry in the protocol:
```json
{"label":"月华神殿","pos":[33,44,-20],"distance":21,"direction":"NE","discovered":false,"restoration_percent":0}
```
`distance` = Euclidean blocks from player to landmark center (rounded). `direction` = cardinal
from player toward landmark. Sort nearest-first; cap at 6 (`observe`) / unbounded-but-in-radius
(`scan`).

> Restoration target: `World.landmark_restoration` reports `percent` toward a fixed target
> (`LANDMARK_RESTORE_TARGET = 20` rebuilt blocks within radius). An agent "restores" a landmark
> by `build`/`place`-ing renderable blocks near its `pos`.

---

## 6. Regions

`World.region_label(x,z)` returns one of 14 Chinese biome labels
(`WorldGenerator.REGION_LABELS`). Map to English aliases for the protocol's `*_en` fields:

| 中文 | `_en` | 中文 | `_en` |
| --- | --- | --- | --- |
| 草原 | `meadow` | 红土台地 | `mesa` |
| 风草原 | `windswept_plains` | 岩岭 | `rocky_ridge` |
| 花海草甸 | `flower_meadow` | 玄武岩岭 | `basalt_ridge` |
| 针叶林 | `taiga` | 雪峰 | `snow_peaks` |
| 苔林 | `mossy_forest` | 湿地 | `wetland` |
| 沙漠 | `desert` | 沙岸 | `sandy_shore` |
| | | 黏土滩 | `clay_flat` |
| | | 浅水湾 | `shallow_cove` |

`observe.region` / `scan.regions_present` carry the Chinese label; `region_en` carries the
alias. (`region_total()` = 14.)

### 6.1 Time-of-day phases

`Main._time` is a `0..1` day fraction (0 = midnight, 0.25 = sunrise-ish, 0.5 = noon, 0.75 =
sunset-ish; the game starts at `0.30` = morning). Phase buckets for `time_of_day.phase`:

| fraction range | phase |
| --- | --- |
| `[0.00, 0.20)` ∪ `[0.85, 1.0)` | `night` |
| `[0.20, 0.28)` | `dawn` |
| `[0.28, 0.42)` | `morning` |
| `[0.42, 0.58)` | `noon` |
| `[0.58, 0.75)` | `afternoon` |
| `[0.75, 0.85)` | `dusk` |

`clock` = `fmod(fraction*24, 24)` formatted `HH:MM`.

---

## 7. Unsolicited events (optional, forward-compatible)

The game MAY push event lines (no `id`, with a `event` field) for things like a landmark being
discovered while the agent acts:

```json
{"event": "landmark_discovered", "label": "月华神殿", "pos": [33,44,-20]}
{"event": "feedback", "kind": "place", "text": "campfire x10"}
```

A v1 bridge MAY ignore all lines that lack `ok`/`error`. Events are best-effort; tools never
depend on them. Sourced from `DiscoveryTracker.landmark_discovered` and
`World.edit_feedback`/`save_feedback` signals.

---

## 8. Lifecycle & errors

- **Startup**: an autoload/bridge node (e.g. `AgentBridge`, added under `Main`) creates a
  `TCPServer`, binds `127.0.0.1:OW_AGENT_PORT`. If `OW_AGENT_PORT` is unset/`0`, the bridge MAY
  stay disabled (no server) — agent control is opt-in. Loads `user://agent_memory.json`.
- **Per frame** (`_process`): `take_connection()` if no peer; for the active peer, read
  available bytes, split on `\n`, dispatch each complete line synchronously, write each
  response line. Partial trailing bytes are buffered for the next frame.
- **Disconnect**: on peer drop, discard its read buffer and `recent_actions`; keep listening
  for the next connection. Persistent memory survives.
- **Errors** (`{"ok":false,"error":...}`): `unknown tool: X`, `unknown block: X`,
  `unknown template: X`, `bad args: <field> (<why>)`, `too many cells: N > 4096`,
  `out of range: y=<y>`, `world not ready`. All single-line, never fatal to the stream.
- **Readiness**: before the world/player exist (title screen, loading), acting tools return
  `ok:false, error:"world not ready"`; `observe` MAY return a minimal `{ "ready": false }`
  result. The bridge checks `Main.world != null and Main.player != null` (both are set together
  in `Main` after `add_child`).

---

## 9. End-to-end example

```
→ {"id":1,"tool":"observe","args":{}}
← {"id":1,"ok":true,"result":{"pos":[8,41,4],"facing":{"yaw_deg":0.0,"pitch_deg":0.0,"cardinal":"N"},"region":"草原","region_en":"meadow","time_of_day":{"fraction":0.30,"phase":"morning","clock":"07:12"},"selected_block":"grass","hotbar":["grass","dirt", ...],"heightmap":{"size":16,"origin":[0,-4],"rows":[[40,40, ...], ...]},"nearby_landmarks":[{"label":"月华神殿","pos":[33,44,-20],"distance":31,"direction":"NE","discovered":false,"restoration_percent":0}],"recent_actions":[]}}

→ {"id":2,"tool":"set_goal","args":{"text":"Restore the moonlit shrine."}}
← {"id":2,"ok":true,"result":{"goal":"Restore the moonlit shrine."}}

→ {"id":3,"tool":"goto","args":{"x":33,"z":-20}}
← {"id":3,"ok":true,"result":{"pos":[33,45,-20],"region":"草原","region_en":"meadow","surface_y":44}}

→ {"id":4,"tool":"scan","args":{"radius":10}}
← {"id":4,"ok":true,"result":{"center":[33,-20],"radius":10,"surface_y":{"min":42,"max":47,"avg":44},"columns":{...},"block_histogram":{"grass":300,"marble":20},"regions_present":["草原"],"water_fraction":0.0,"landmarks_in_range":[{"label":"月华神殿","pos":[33,44,-20],"distance":1,"discovered":false}],"suggested_build_spot":[35,45,-18]}}

→ {"id":5,"tool":"build","args":{"template":"beacon_tower","x":35,"y":45,"z":-18,"rotation":0}}
← {"id":5,"ok":true,"result":{"template":"beacon_tower","anchor":[35,45,-18],"rotation":0,"changed":61}}

→ {"id":6,"tool":"say","args":{"text":"Beacon raised by the shrine."}}
← {"id":6,"ok":true,"result":{"shown":true}}

→ {"id":7,"tool":"remember","args":{"text":"Built beacon_tower at (35,45,-18) next to shrine."}}
← {"id":7,"ok":true,"result":{"remembered":true,"note_count":1}}
```

---

## 10. Implementation checklist (for build agents)

- [ ] `AgentBridge` node under `Main`; `TCPServer` on `127.0.0.1:OW_AGENT_PORT` (default 8970), disabled if unset.
- [ ] NDJSON read/dispatch/write in `_process` on the **main thread**; trailing-byte buffering.
- [ ] Envelope: parse `{id,tool,args}`; always reply `{id,ok,result|error}`; bad JSON ⇒ `{id:null,...}`.
- [ ] Block name↔id table from `creative_blocks()`/`hotbar_blocks()` + the alias table in §3; case-insensitive; emit aliases.
- [ ] Region alias table (§6); time phase buckets (§6.1).
- [ ] 12 tool handlers (§4) mapping onto the real methods quoted in each tool.
- [ ] `build` reproduces engine template geometry via `_placement_edits()` (or an equivalent static helper) anchored at `_place`, committed through `World.request_block_edits`.
- [ ] `recent_actions` ring buffer (≤8) surfaced in `observe`.
- [ ] `user://agent_memory.json` load + atomic save for `set_goal`/`remember`/`get_memory`.
- [ ] Readiness guard (`Main.world` & `Main.player` non-null) and the §8 error set.
```

## 11. Chat & presence (multi-client) — v1.1

The bridge is **multi-client**: every TCP connection is one online entity (`agent-1`, `agent-2`, …). The game keeps a shared **ChatHub** with a presence roster (the human `player` + all connected agents) and an ephemeral message log (public lobby + direct messages). Three additions cover it:

- **`identify` `{name}`** → `{entity_id, name}`. Sets this connection's display name in the roster (default `agent-N`). Call once after connecting.
- **`say` `{text, to?}`** → `{shown, to}`. Omit `to` to post to the **public lobby**; set `to` (an entity id or display name) to **direct-message** that entity. Still flashes the HUD.
- **`observe`** result gains `chat` (recent lobby messages) and `inbox` (messages addressed to this entity — lobby posts from others + DMs to it — since this entity's previous `observe`). Reading `observe` advances this entity's read cursor, so each message is delivered once.

Message shape: `{seq, from, to, text, t}` (`to == ""` ⇒ lobby). The human player is entity id `player`. Chat is session-only (not persisted); durable agent memory remains `set_goal`/`remember`.
