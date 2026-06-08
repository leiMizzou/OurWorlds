# TOOLS.md — opc-ourworlds local setup notes

Environment-specific details for reaching OurWorlds. (Skills define *how* tools work; this is
*my* setup.)

## OurWorlds bridge

- **Game launch:** `OW_AGENT_PORT=8970 godot --path <repo>`
  (or the exported app under `<repo>/build/macos/OurWorlds.app`). The bridge is disabled unless
  `OW_AGENT_PORT` is set.
- **Transport:** plain TCP, NDJSON, `127.0.0.1:8970`. The game bridge accepts multiple
  simultaneous clients; the MCP server is usually one client of that bridge.
- **MCP server name (via mcporter):** `ourworlds`
  (runs `node <repo>/agent-bridge-mcp/dist/index.js`, env `OW_AGENT_PORT=8970`).
- **How I call it:** `mcporter call ourworlds.<tool> --args '{...}'`.

## Tools exposed by `ourworlds`

`observe`, `identify`, `look`, `goto`, `scan`, `place`, `break`, `build`, `capture_build`,
`paste_build`, `get_block`, `say`, `set_goal`, `remember`, `get_memory`.

`build` templates: `platform`, `pillar`, `arch`, `wall`, `stairs`, `room_frame`, `cabin`,
`campfire`, `bridge`, `garden`, `beacon_tower`, `signpost`.

## World facts

- Axes: `+X` east, `+Z` south, `+Y` up. Valid `y ∈ [0,95]`. Stand-on-ground Y = `surface_y+1`.
- Memory (`set_goal`/`remember`) persists across game restarts (`user://agent_memory.json`).
- Full interface contract: `<repo>/docs/agent-bridge-contract.md`.

## Readiness

If a tool returns `world not ready`, the title/loading screen is up — load a world first, or
wait for the next heartbeat.
