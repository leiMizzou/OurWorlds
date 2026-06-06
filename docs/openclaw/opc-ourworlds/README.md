# Proposed OpenClaw agent: `opc-ourworlds`

This folder is a **proposal** for an OpenClaw agent that lives in and plays
[OurWorlds](../../../README.md). Review it, then copy the parts you want into your own
OpenClaw config. **Nothing here is written into `~/.openclaw` for you** — you install it
yourself (see below). It contains **no secrets**; models are referenced by name only.

See the full wiring guide: [`../../openclaw-integration.md`](../../openclaw-integration.md).

## Files

| File | Goes to | Purpose |
| --- | --- | --- |
| `AGENTS.md` | `~/.openclaw/agents/opc-ourworlds/workspace/AGENTS.md` | System prompt / role: the autonomous builder-explorer behavior. |
| `HEARTBEAT.md` | `~/.openclaw/agents/opc-ourworlds/workspace/HEARTBEAT.md` | What the agent does on each periodic tick. |
| `IDENTITY.md` | `~/.openclaw/agents/opc-ourworlds/workspace/IDENTITY.md` | Cosmetic identity (name/emoji/vibe). |
| `TOOLS.md` | `~/.openclaw/agents/opc-ourworlds/workspace/TOOLS.md` | Environment specifics (port, MCP server name, tool list). |
| `agent.config.json5` | merge into `~/.openclaw/openclaw.json` → `agents.list[]` | The agent entry (model, heartbeat, skills). **Reference only — do not blind-paste.** |

## Install (you run this — not the doc generator)

```bash
# 1) Create the isolated agent + workspace:
openclaw agents add opc-ourworlds --workspace ~/.openclaw/agents/opc-ourworlds/workspace

# 2) Copy the prompt files in:
SRC=<repo>/docs/openclaw/opc-ourworlds
DST=~/.openclaw/agents/opc-ourworlds/workspace
cp "$SRC/AGENTS.md" "$DST/AGENTS.md"
cp "$SRC/HEARTBEAT.md" "$DST/HEARTBEAT.md"
cp "$SRC/IDENTITY.md" "$DST/IDENTITY.md"
cp "$SRC/TOOLS.md" "$DST/TOOLS.md"

# 3) Apply the model + heartbeat. Either via CLI:
openclaw agents set-identity --agent opc-ourworlds --name "OurWorlds" --emoji "🧱"
OPENCLAW_AGENT_DIR=~/.openclaw/agents/opc-ourworlds/agent openclaw models set openai/gpt-5.5
#    …or merge the fields from agent.config.json5 into the opc-ourworlds entry in openclaw.json
#    (open ~/.openclaw/openclaw.json, find agents.list[], and reconcile by hand).
```

`agent.config.json5` shows the **target shape** of the `agents.list[]` entry. `openclaw agents
add` already creates a baseline entry; treat `agent.config.json5` as the diff to fold in
(model + heartbeat + skills), not a wholesale replacement, so you don't clobber fields the CLI
set.

## Before it works

The two build-dependent pieces from the integration guide must exist first:
1. The `AgentBridge` node inside `OurWorlds/scenes/Main.tscn` (contract §8).
2. The `../agent-bridge-mcp` Node MCP server, registered with `mcporter` as `ourworlds`.

Then: launch the game with `OW_AGENT_PORT=8970`, and the agent's heartbeat starts driving it.
