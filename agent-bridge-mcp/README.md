# ourworlds-mcp

An **MCP server** that bridges an LLM agent (e.g. driven via **OpenClaw**) to a
running **OurWorlds** game. It speaks the Model Context Protocol over **STDIO**
to the agent host, and forwards each tool call to the game over the game's
**TCP agent-control API** (newline-delimited JSON on `127.0.0.1`).

The full wire contract the game implements is documented in
[`../docs/agent-bridge-contract.md`](../docs/agent-bridge-contract.md). This
server is the thin client side: it exposes one MCP tool per contract command and
relays envelopes.

## What it exposes

One MCP tool per OurWorlds agent command (contract §4):

| Tool | Purpose |
| --- | --- |
| `observe` | Full situational snapshot (pos, facing, region, time, hotbar, local heightmap, landmarks, recent actions). |
| `look` | Aim the view (absolute yaw / pitch in degrees). |
| `goto` | Teleport to the surface at `(x, z)` (or an exact `y`). |
| `scan` | Compact area summary (heights, surface blocks, histogram, regions, build-spot suggestion). |
| `place` | Set a batch of cells to a block (max 4096; `air` clears). |
| `break` | Clear a batch of cells to air. |
| `build` | Stamp a named structure template (`campfire`, `beacon_tower`, `cabin`, …) at an anchor. |
| `get_block` | Read one cell. |
| `say` | Show a message on the in-game HUD. |
| `set_goal` | Record the agent's current objective (persisted by the game). |
| `remember` | Append a note to the agent scratchpad (persisted). |
| `get_memory` | Read goal + notes. |

Each tool returns the game's `result` object both as JSON text and as MCP
`structuredContent`. Game-level failures (`ok:false`, e.g. `unknown block: …`)
and bridge-level failures (game not running, timeout) come back as MCP error
results with a clear, single-line message — the agent can read and react.

## How it talks to the game

- **Transport:** plain TCP stream (not WebSocket/HTTP), NDJSON framing — exactly
  one JSON object per line, `\n`-terminated, UTF-8.
- **Endpoint:** `127.0.0.1` : **`OW_AGENT_PORT`** (default **`8970`**).
- **Socket:** ONE persistent socket, created lazily on the first tool call and
  **auto-reconnected** on the next call after a drop. Requests are correlated by
  an `id` the bridge generates and the game echoes. Each request has a 15s
  response timeout; a connect attempt has a 4s timeout. If the game isn't
  listening you get a clear `connection refused` message telling you to launch
  OurWorlds.

## Requirements

- **Node.js ≥ 18** (developed/tested on Node 20+; uses ESM + `node:net`).
- The OurWorlds game running with its **AgentBridge** enabled
  (`OW_AGENT_PORT` set, default `8970`). The bridge can build without the game;
  it only needs the game **at runtime** to actually act.

## Build

```bash
cd OurWorlds/agent-bridge-mcp
npm install
npm run build      # tsc -> dist/index.js
```

Output is ESM JavaScript in `dist/`. `dist/index.js` has a shebang and is the
executable entry point (also exposed as the `ourworlds-mcp` bin).

## Run (standalone, for a quick sanity check)

```bash
# Optionally point at a non-default game port:
export OW_AGENT_PORT=8970
npm start          # node dist/index.js
```

The process then waits for an MCP client on STDIO. It logs to **stderr**
(stdout is reserved for the JSON-RPC stream), so you'll see a
`MCP server ready on STDIO …` line. It will not connect to the game until the
first tool call arrives.

## Register with OpenClaw (via the `mcporter` skill)

OpenClaw discovers MCP servers through its **`mcporter`** skill, which reads an
`mcporter` config listing servers to spawn over STDIO. Add this server as a
STDIO entry that runs the built `dist/index.js`.

1. **Build first** so `dist/index.js` exists (see above).
2. Add an entry to your `mcporter` servers config (commonly
   `~/.config/mcporter/config.json`, or wherever your `mcporter` skill reads
   it — `mcporter --help` / the skill's docs show the exact path):

   ```json
   {
     "mcpServers": {
       "ourworlds": {
         "command": "node",
         "args": ["./agent-bridge-mcp/dist/index.js"],
         "env": {
           "OW_AGENT_PORT": "8970"
         }
       }
     }
   }
   ```

   Use an **absolute path** to `dist/index.js`. Set `OW_AGENT_PORT` only if your
   game uses a non-default port. (If you `npm link` / install this package
   globally, you can instead use `"command": "ourworlds-mcp"` with no args.)

3. Have the `mcporter` skill (re)load servers — e.g. `mcporter list` to confirm
   `ourworlds` is registered and its tools are visible, then use it from
   OpenClaw. The agent will see the 12 tools above.

> Generic MCP clients: any client that launches STDIO MCP servers works. The
> command is `node /abs/path/to/dist/index.js` with optional `OW_AGENT_PORT` in
> the environment. For example, a Claude Desktop `mcpServers` block uses the
> exact same `command` / `args` / `env` shape shown above.

## Typical agent loop

1. `observe` to perceive surroundings (terrain heightmap + landmarks).
2. `set_goal` / `remember` to track intent across runs.
3. `goto` to travel, `scan` to study a spot, `look` to frame it.
4. `build` a template (or `place` / `break` for custom geometry).
5. `say` to narrate; `get_memory` to recall.

## Troubleshooting

- **`connection refused` / `cannot reach the OurWorlds agent bridge`** — the
  game isn't running or `OW_AGENT_PORT` doesn't match. Launch OurWorlds with
  the AgentBridge enabled and confirm the port.
- **`world not ready`** — the game is on the title/loading screen; acting tools
  return this until a world and player exist. Wait, then retry (or `observe`).
- **`timed out waiting for game response`** — the game accepted the connection
  but didn't answer in 15s (paused/stalled). Check the game window.
- **Nothing happens / no logs** — remember logs go to **stderr**; stdout is the
  MCP protocol channel and must not be polluted.

## Notes

- The server forwards args structurally; the **game is the source of truth** for
  validation. Things like block-name resolution, the 4096-cell cap, template
  ids, and coordinate ranges are enforced game-side and returned as `ok:false`.
- This client deliberately ignores unsolicited game **event** lines (contract
  §7); a v1 bridge may. They're logged to stderr for visibility.
