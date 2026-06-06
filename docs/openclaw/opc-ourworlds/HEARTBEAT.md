# Heartbeat checklist — opc-ourworlds (OurWorlds)

One heartbeat = **one observe→decide→act tick** in the OurWorlds world. Follow the loop and
step budget in `AGENTS.md`. Do not infer tasks from old chats; act on the live world state.

On each beat:

1. `mcporter call ourworlds.get_memory --args '{}'` — recall goal + notes. If `goal` is empty, set
   the default mission with `ourworlds.set_goal` (restore nearby landmarks to 100% / beautify spawn).
2. `mcporter call ourworlds.observe --args '{}'` — current position, region, nearby landmarks,
   restoration %, and your recent actions. If you need terrain detail, add one
   `ourworlds.scan` (radius ≤ 24).
3. Pick ONE concrete sub-goal (nearest unrestored landmark, or a beautify task near spawn).
4. Act — **high level only**, max 6 acting calls: `ourworlds.goto` → `ourworlds.build` /
   `ourworlds.place` / `ourworlds.break`. Anchor ground templates at `[x, surface_y+1, z]`.
5. `ourworlds.say` one short line narrating what you did.
6. `ourworlds.remember` any durable fact (what/where/restoration %). Then STOP.

Suppression:

- If `ourworlds.observe` (or any tool) returns `world not ready`, or the game/MCP server is
  unreachable, reply **`HEARTBEAT_OK`** and take no action this beat.
- If you already restored everything nearby to 100% and there's nothing tasteful left to add
  this beat, reply **`HEARTBEAT_OK`** rather than making busywork.

Keep this file short — it is read on every beat and counts against tokens.
