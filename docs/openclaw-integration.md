# OpenClaw Integration — Let an AI Agent Live In & Play OurWorlds

This guide wires an autonomous OpenClaw agent ("opc-ourworlds") into a running **OurWorlds**
instance so it can perceive the world and act on it (move, scan, build templates, restore
landmarks, narrate, keep a goal/memory) — driven by your **Codex / ChatGPT (GPT-5.5)**
subscription via OpenClaw's native OAuth.

```
┌────────────┐  TCP NDJSON   ┌────────────────────┐   stdio MCP   ┌──────────────────────┐
│ OurWorlds │◀────:8970────▶│ agent-bridge-mcp   │◀────tools────▶│ OpenClaw agent        │
│  (Godot)   │  127.0.0.1    │ (Node MCP server)  │  observe/...  │  "opc-ourworlds" (GPT-5.5)│
│ AgentBridge│  one client   │  ../agent-bridge-mcp│               │  heartbeat + chat     │
└────────────┘               └────────────────────┘               └──────────────────────┘
```

The full perception/action interface (transport, every tool, every game method it maps to)
is the **contract**: [`docs/agent-bridge-contract.md`](./agent-bridge-contract.md). The MCP
server in `../agent-bridge-mcp` is a thin translator: each MCP tool (`observe`, `look`,
`goto`, `scan`, `place`, `break`, `build`, `get_block`, `say`, `set_goal`, `remember`,
`get_memory`) opens the TCP socket and forwards one NDJSON request, returning the reply.

---

## Prerequisites / current state (read first)

Both core components now **exist and are wired up** — you do not need to build them from the
contract:

1. **Game side — `AgentBridge` node** (`scripts/AgentBridge.gd`): a `TCPServer` bound to
   `127.0.0.1:$OW_AGENT_PORT`, NDJSON read/dispatch/write in `_process` on the main thread,
   with a readiness guard (`Main.world != null and Main.player != null`). `Main.gd` creates it
   only when `OW_AGENT_PORT` is set (opt-in).
2. **Bridge side — `agent-bridge-mcp/`**: the Node MCP server (stdio) exposing the 12 contract
   tools and forwarding them as NDJSON over TCP. The only build step is `npm run build`,
   handled for you by `agent-bridge-mcp/setup.sh`.

**Fast path:** `bash agent-bridge-mcp/setup.sh` then `bash run_with_agent.sh`. Steps A–G below
spell out every piece if you'd rather do it by hand or debug a layer.

Other prerequisites:

- **Godot 4.6** (`/opt/homebrew/bin/godot`) or the exported app under `<repo>/build/macos/OurWorlds.app`.
- **OpenClaw** installed and its gateway running (`openclaw status`). Repo at
  `<openclaw>`, user config at `~/.openclaw`.
- **Node** ≥ 18 (for the MCP server and for `mcporter`).
- A **ChatGPT/Codex subscription** for the GPT-5.5 model (OAuth, step E).

---

## A. Launch the game with the agent port open

The bridge stays **disabled** unless `OW_AGENT_PORT` is set, so agent control is opt-in.

From `<repo>`:

```bash
# Editor / source run (recommended while iterating):
OW_AGENT_PORT=8970 godot --path .

# …or the exported macOS app:
OW_AGENT_PORT=8970 open -a "$(pwd)/build/macos/OurWorlds.app"   # adjust to the real .app name
# (if `open -W` env passing is unreliable, launch the binary inside the .app directly:)
OW_AGENT_PORT=8970 "$(pwd)/build/macos/OurWorlds.app/Contents/MacOS/OurWorlds"
```

Load (or create) a world from the title screen so `Main.world`/`Main.player` exist — until
then the bridge answers acting tools with `{"ok":false,"error":"world not ready"}` (contract
§8). Confirm the port is listening:

```bash
nc -z 127.0.0.1 8970 && echo "OurWorlds agent bridge is listening on 8970"
```

> The bridge accepts **one** client at a time (the MCP server). Loopback only; no WebSocket,
> no HTTP, no CORS.

---

## B. Build + run the MCP server in `../agent-bridge-mcp`  **[needs build]**

The MCP server is a sibling of OurWorlds so it can be versioned alongside the game without
living inside the Godot project. Target layout:

```
<projects>/
├── OurWorlds/            (game)
└── agent-bridge-mcp/      (this server)  ← <repo>/agent-bridge-mcp
```

**Scaffold (one-time).** A minimal TypeScript MCP server using the official SDK:

```bash
mkdir -p <repo>/agent-bridge-mcp
cd <repo>/agent-bridge-mcp
npm init -y
npm install @modelcontextprotocol/sdk zod
npm install -D typescript tsx @types/node
```

What the server must do (each MCP tool ⇒ one NDJSON line per the contract):

- On startup, read `process.env.OW_AGENT_PORT` (default `8970`) and connect a TCP socket to
  `127.0.0.1:<port>` (lazy-reconnect on drop).
- Register the **12 tools** with the same names/args/results as the contract §4
  (`observe`, `look`, `goto`, `scan`, `place`, `break`, `build`, `get_block`, `say`,
  `set_goal`, `remember`, `get_memory`).
- For each tool call: send `{"id":<n>,"tool":"<name>","args":{...}}\n`, await the line whose
  `id` matches, and return `result` (or surface `error`). Ignore unsolicited `event` lines
  (contract §7).
- Expose itself over **stdio** (so OpenClaw/mcporter can spawn it as a child process).

**Build + smoke-test** (with the game running from step A):

```bash
cd <repo>/agent-bridge-mcp
npm run build   # or: npx tsc

# Quick manual smoke test with mcporter calling the server over stdio:
OW_AGENT_PORT=8970 mcporter call --stdio "node ./dist/index.js" observe --args '{}'
```

A healthy response echoes the game's `observe` snapshot (`pos`, `region_en`, `heightmap`, …).

> Until this server exists, you can still validate the **game** side by hand:
> `printf '{"id":1,"tool":"observe","args":{}}\n' | nc 127.0.0.1 8970` should return one JSON line.

---

## C. Register the MCP server with `mcporter`  **[needs build of B]**

OpenClaw's MCP access goes through the **`mcporter`** skill/CLI
(your OpenClaw install's `skills/mcporter/SKILL.md`). Install the binary if missing, then
register the server under a short name (`ourworlds`):

```bash
# Install mcporter if `command -v mcporter` is empty:
npm install -g mcporter

# Inspect the exact add/import surface on your installed version:
mcporter config --help
mcporter --help
```

Register the stdio server. The mcporter config lives at `./config/mcporter.json` by default
(override with `--config`); to make `ourworlds` available everywhere, point at a stable path and
reuse it from the agent. **Confirm the precise flag names against `mcporter config --help`**
— the intent is "add a stdio server named `ourworlds` that runs the Node server with
`OW_AGENT_PORT` set":

```bash
# Most likely form (VERIFY against `mcporter config --help` before relying on it):
mcporter config add ourworlds \
  --command "node ./agent-bridge-mcp/dist/index.js" \
  --env OW_AGENT_PORT=8970
```

If `config add` does not take those flags on your build, fall back to writing the config file
directly. Create `agent-bridge-mcp/config/mcporter.json` (repo-relative):

```json
{
  "mcpServers": {
    "ourworlds": {
      "command": "node",
      "args": ["./agent-bridge-mcp/dist/index.js"],
      "env": { "OW_AGENT_PORT": "8970" }
    }
  }
}
```

Verify the tools enumerate (game must be running):

```bash
mcporter --config ./agent-bridge-mcp/config/mcporter.json list ourworlds --schema
mcporter --config ./agent-bridge-mcp/config/mcporter.json call ourworlds.observe --args '{}'
```

> ⚠️ **FLAG — verify before trusting:** the exact `mcporter config add` flag spelling
> (`--command` / `--env` vs `--stdio` vs an `import` subcommand) differs by mcporter version.
> Run `mcporter config --help` and adjust. The **fallback JSON file above is the reliable
> path** and is what the agent will reference.

The agent reaches these tools by invoking the `mcporter` skill (it shells
`mcporter call ourworlds.<tool> …`). No `mcpServers` block is required in `openclaw.json`.

---

## D. Create the agent "opc-ourworlds"

OpenClaw agents are isolated workspaces declared in `~/.openclaw/openclaw.json` under
`agents.list[]`, each backed by a workspace dir of markdown prompt files
(`AGENTS.md` = role/system prompt, `HEARTBEAT.md` = periodic checklist, `IDENTITY.md`,
`TOOLS.md`). **Do not hand-edit `~/.openclaw` from this repo.** Create the agent with the CLI,
then copy in the proposed prompt files from this repo (see the companion folder
`docs/openclaw/opc-ourworlds/`).

```bash
# 1) Create the isolated agent + its workspace:
openclaw agents add opc-ourworlds --workspace ~/.openclaw/agents/opc-ourworlds/workspace

# 2) Copy the PROPOSED prompt files from this repo into that workspace (review them first):
cp <repo>/docs/openclaw/opc-ourworlds/AGENTS.md    ~/.openclaw/agents/opc-ourworlds/workspace/AGENTS.md
cp <repo>/docs/openclaw/opc-ourworlds/HEARTBEAT.md ~/.openclaw/agents/opc-ourworlds/workspace/HEARTBEAT.md
cp <repo>/docs/openclaw/opc-ourworlds/IDENTITY.md  ~/.openclaw/agents/opc-ourworlds/workspace/IDENTITY.md
cp <repo>/docs/openclaw/opc-ourworlds/TOOLS.md     ~/.openclaw/agents/opc-ourworlds/workspace/TOOLS.md

# 3) Set its visible identity (optional, cosmetic):
openclaw agents set-identity --agent opc-ourworlds --name "OurWorlds" --emoji "🧱"
```

The **recommended system prompt** (full text shipped in `docs/openclaw/opc-ourworlds/AGENTS.md`)
makes opc-ourworlds an **autonomous builder/explorer** that:

- **Keeps a goal**: on its first turn (and whenever the goal is empty) it calls
  `set_goal(...)` and persists durable facts with `remember(...)`; it reloads them with
  `get_memory()` at the start of each tick (memory survives game restarts —
  `user://agent_memory.json`).
- **Observes, then acts**: every tick starts with `observe` (and `scan` when it needs terrain
  detail), reasons, then issues **high-level** actions only — `goto`, `build` (named
  templates like `beacon_tower`, `cabin`, `bridge`, `campfire`, `garden`), and bulk `place`/
  `break`. It never streams single coordinates.
- **Narrates**: calls `say(...)` so a human watching the screen sees what it's doing and why.
- **Respects a step budget**: at most ~6–8 acting calls per tick, then stops and waits for the
  next heartbeat (prevents runaway loops and token burn).
- **Has a default mission**: discover and **restore nearby landmarks to 100%** (build ≥20
  renderable blocks within a landmark's radius), and otherwise beautify the area around spawn.

If you also want opc-ourworlds to have the `mcporter` skill explicitly listed, add it to that
agent's `skills` array in `openclaw.json` (see the proposed `agent.config.json5` snippet in
`docs/openclaw/opc-ourworlds/`). On most setups `mcporter` is already globally available as a
skill; listing it is belt-and-suspenders.

---

## E. Point opc-ourworlds at Codex GPT-5.5 via OpenClaw's native OAuth

Your `~/.openclaw` already has a working Codex OAuth profile
(`auth.profiles["openai-codex:…@gmail.com"]`, `mode: "oauth"`, `provider: "openai-codex"`) and
the default model is `"openai/gpt-5.5"` routed through the **codex** agent runtime
(`agents.defaults.models["openai/gpt-5.5"].agentRuntime.id = "codex"`). Every existing
`opc-*` agent (e.g. `opc-jobs`, `opc-elon`, `opc-ive`) uses exactly `"model": "openai/gpt-5.5"`.
So the **simplest, consistent choice** is to give opc-ourworlds the same model string and let it
inherit the OAuth + codex-runtime defaults.

**1) (Re)authenticate the ChatGPT/Codex subscription** (only needed if not already logged in —
check `openclaw models status` first):

```bash
# THE Codex OAuth command (documented, not a guess):
openclaw models auth login --provider openai-codex
#   ↳ opens https://auth.openai.com/oauth/authorize…, captures the callback on
#     http://127.0.0.1:1455/auth/callback (or paste the redirect URL if headless),
#     and stores { access, refresh, expires, accountId } as an OAuth profile.

# Equivalent wizard path:
openclaw onboard --auth-choice openai-codex
```

**2) Select the model for opc-ourworlds.** Set it on the agent (run with the agent targeted):

```bash
# Inspect what opc-ourworlds currently resolves to:
openclaw models status --agent opc-ourworlds

# Set GPT-5.5 for this agent (matches every other opc-* agent in your config):
OPENCLAW_AGENT_DIR=~/.openclaw/agents/opc-ourworlds/agent openclaw models set openai/gpt-5.5
```

Or set it declaratively in `openclaw.json` on the opc-ourworlds entry:
`"model": "openai/gpt-5.5"` (this is what the proposed `agent.config.json5` does).

**Model-string note / FLAG:**
- `openai/gpt-5.5` is the string your other agents use and it is wired to the codex runtime +
  OAuth — **recommended**.
- The provider docs' canonical "Codex subscription" form is `openai-codex/gpt-5.4`
  (docs list `gpt-5.4` as the current Codex model). If `openai/gpt-5.5` ever fails to resolve
  for a *new* agent, fall back to `openai-codex/gpt-5.4`, or re-confirm the exact id with
  `openclaw models list` / `openclaw models scan`.
- ⚠️ **FLAG — confirm before relying on it:** that GPT-5.5 is reachable specifically under
  your Codex/ChatGPT *subscription* (vs an API-key provider). `openclaw models status --agent
  opc-ourworlds --probe` runs a live auth probe (consumes a tiny amount of tokens) and will tell
  you definitively which provider/profile serves `openai/gpt-5.5`.

**3) Verify:**

```bash
openclaw models status --agent opc-ourworlds        # should show openai/gpt-5.5 + an OAuth profile
openclaw models status --agent opc-ourworlds --probe # live check (optional; uses a few tokens)
```

---

## F. Tick it every few minutes (observe + act)

Use a **heartbeat** (not cron): periodic, context-aware, batched, and it self-suppresses with
`HEARTBEAT_OK` when nothing's needed — ideal for an agent that should glance at the world and
take a few actions. Set it on the opc-ourworlds agent.

Declaratively (in the opc-ourworlds `openclaw.json` entry — see proposed `agent.config.json5`):

```json5
{
  id: "opc-ourworlds",
  model: "openai/gpt-5.5",
  heartbeat: {
    every: "3m",
    activeHours: { start: "09:00", end: "23:00", timezone: "Asia/Shanghai" },
    prompt: "Read HEARTBEAT.md and follow it. One tick = observe -> decide -> at most 6 high-level actions (goto/build/place/break) -> say what you did. If the game is unreachable or world is not ready, reply HEARTBEAT_OK."
  }
}
```

The checklist itself lives in the workspace `HEARTBEAT.md` (shipped in
`docs/openclaw/opc-ourworlds/HEARTBEAT.md`). Each heartbeat the agent reads it and runs one
observe→act tick through the `ourworlds` MCP tools.

Alternative if you want **exact** cadence or a clean isolated session each run (e.g. every 5
min, only while you're watching):

```bash
openclaw cron add \
  --name "OurWorlds tick" \
  --every "5m" \
  --session main \
  --system-event "OurWorlds tick: observe the world and take a few high-level actions toward your goal." \
  --wake now
```

> Heartbeat is recommended; it shares context across ticks so the agent remembers what it just
> built. Keep `HEARTBEAT.md` short to bound token cost.

---

## G. Connect a chat channel so you can talk to it

Bind a channel account to opc-ourworlds so messages you send there are handled by this agent (and
it can reply / take direction like "build a lighthouse on the eastern shore").

```bash
# List channels you already have configured:
openclaw channels list

# Example: bind your Telegram account to opc-ourworlds (use a channel you already added):
openclaw agents bind --agent opc-ourworlds --bind telegram

# Or add a fresh channel account, then bind it:
openclaw channels add --channel telegram --token <bot-token>
openclaw agents bind --agent opc-ourworlds --bind telegram:<accountId>

# Confirm the binding:
openclaw agents bindings --agent opc-ourworlds
```

Now anything you say in that channel routes to opc-ourworlds; it can answer, adjust its
`set_goal`, and act in-game on its next turn. Its `say(...)` output also shows on the in-game
HUD, so you get two-way visibility (screen + chat).

---

## End-to-end checklist

1. **[needs build]** `AgentBridge` node added to `scenes/Main.tscn` per contract §8.
2. **[needs build]** `../agent-bridge-mcp` Node MCP server implemented (12 tools → NDJSON).
3. `OW_AGENT_PORT=8970 godot --path .`, load a world, `nc -z 127.0.0.1 8970` ✅ (A).
4. `mcporter` installed; `ourworlds` server registered; `mcporter call ourworlds.observe` returns a
   snapshot (B, C).
5. `openclaw agents add opc-ourworlds`; copy proposed prompt files into its workspace (D).
6. `openclaw models auth login --provider openai-codex`; `models set openai/gpt-5.5`;
   `models status --agent opc-ourworlds` shows GPT-5.5 + OAuth (E).
7. Heartbeat `every: "3m"` set; `HEARTBEAT.md` in place (F).
8. A chat channel bound to opc-ourworlds (G).

## Security notes

- **Never** put OAuth tokens / API keys / refresh tokens in this repo or in the proposed agent
  files. Authentication is created and stored only by `openclaw models auth login`, under
  `~/.openclaw/agents/<agentId>/agent/` (the codex OAuth home + `auth-profiles.json`). This
  guide and the proposed files reference models **by name only**.
- The bridge is **loopback-only** and **opt-in** (`OW_AGENT_PORT` unset ⇒ no server). Don't
  expose port 8970 beyond `127.0.0.1`.
- Commands explicitly flagged ⚠️ (the `mcporter config add` flag spelling, and confirming
  GPT-5.5 is served by your Codex subscription) should be verified with the `--help` / `models
  status --probe` checks shown before you depend on them.

## Reference map (where each fact came from)

| Topic | Source |
| --- | --- |
| Tools / transport / game-method mapping | `OurWorlds/docs/agent-bridge-contract.md` |
| MCP add/list/call CLI | `<openclaw>/skills/mcporter/SKILL.md` |
| Codex OAuth command + flow | `<openclaw>/docs/concepts/oauth.md`, `docs/providers/openai.md` |
| `models set` / `models status` / auth | `<openclaw>/docs/cli/models.md` |
| Agent create / bind / identity | `<openclaw>/docs/cli/agents.md`, `docs/cli/channels.md` |
| Heartbeat vs cron | `<openclaw>/docs/automation/cron-vs-heartbeat.md` |
| Live config shapes (model `openai/gpt-5.5`, codex runtime, agent entry) | `~/.openclaw/openclaw.json` (read-only) |
