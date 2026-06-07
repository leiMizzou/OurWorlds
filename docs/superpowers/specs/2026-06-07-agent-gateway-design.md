# Agent Gateway — Remote BYO-Agent Integration (SP1) Design

**Date:** 2026-06-07
**Status:** Proposed — design approved in brainstorming, pre-plan
**Topic:** Let people connect their own locally-installed AI agent runtimes to the shared OurWorlds online world.

---

## Goal

Let anyone run their own locally-installed agent runtime (Hermes, Claude Code, Codex, …) and have it join the **shared** OurWorlds online world (`play.ourworlds.app`) as a visible, moving, building player. The connector configures only a **connection token** + a **persona prompt** — no Godot install required on the connector side. The agent's behaviour (build skill, creativity, style) emerges entirely from *which runtime × which model × which persona prompt*; the server is identical for every agent.

SP1 delivers the **end-to-end pipe** with **trusted-first** auth (hand-issued tokens). Account-binding, quotas, and the in-game control panel come in later sub-projects.

---

## Decision record (from brainstorming)

| Fork | Decision | Consequence |
|---|---|---|
| Where does the agent **body** run? | **β — server-hosted** | Server holds the avatar; connector only sends tool-calls over the internet |
| SP1 implementation of server bodies | **β-1 — virtual peers in the server process** | Lightest; reuses NetworkManager roster/snapshot/edit + AgentBridge tool logic; single-process deploy |
| v1 auth level | **Trusted-first** | Static hand-issued tokens + existing edit rate-limit; accounts/quotas deferred to SP2 |
| Acceptance test runtimes | **Hermes + Claude Code** (simultaneously) | Two genuinely different runtimes + model families (OpenClaw≡Hermes here, so it would be the same brain twice) |

---

## The bigger picture — decomposition

This feature is multiple subsystems. Each is its own spec → plan → build cycle:

- **SP1 (this doc) — Agent Gateway core.** Server WebSocket endpoint + remote-mode `ourworlds-mcp` + server-controlled virtual-peer bodies + shared tool-core + simple token gate. Proves the cross-internet vision end-to-end.
- **SP2 — Identity & safety.** Account-tied tokens (Nakama M4), per-owner agent caps, quotas, kick/revoke, abuse handling, audit log.
- **SP3 — In-game control panel (the "T3" surface).** Mint tokens, set per-slot persona/permissions, live roster, kick — all in-game. Depends on SP2's token model.
- **SP4 — Multi-runtime onboarding.** Docs + a small config helper for Hermes / Claude Code / Codex / local-model (Ollama) pointing at the remote endpoint.

---

## Architecture (β-1: server-hosted virtual peers)

```
Connector machine (anywhere on the internet)        Server (play.ourworlds.app — Mac, headless)
┌────────────────────────────────────┐              ┌─────────────────────────────────────────────┐
│ Agent runtime                       │              │ Dedicated server process                       │
│ (Hermes / Claude Code / Codex / …)  │              │  ┌──────────────┐        ┌──────────────────┐  │
│   ↕ MCP (stdio)                     │              │  │ AgentGateway │        │  NetworkManager  │  │
│ ourworlds-mcp  [REMOTE MODE]        │── wss ──────▶│  │   (NEW)      │─register▶  + virtual peers │  │
│   OW_REMOTE_URL=wss://…/agent       │   NDJSON     │  │ • WS listen  │  peer  │   (NEW, additive) │  │
│   OW_AGENT_TOKEN=<token>            │   over WS    │  │ • token gate │        │ • snapshots/roster│  │
│                                     │              │  │ • 1 body/conn│        │ • edit apply      │  │
└────────────────────────────────────┘              │  └──────┬───────┘        └─────────┬────────┘  │
                                                     │         ▼ bind body → tools        ▼           │
                                                     │   ┌───────────────────────────────────────┐    │
                                                     │   │ AgentToolCore (NEW — extracted)         │   │
                                                     │   │ observe/scan/get_block/goto/look/       │   │
                                                     │   │ place/break/build/say/set_goal/         │   │
                                                     │   │ remember/get_memory                     │   │
                                                     │   └───────────────────┬───────────────────┘    │
                                                     │                       ▼  WorldData (authoritative)
                                                     └─────────────────────────────────────────────┘
                                                          → broadcast to all human clients
                                                            (each renders a RemoteAvatar per agent)
```

**Key insight that makes β-1 cheap:** the server already represents every player as just a roster entry `{eid, name, pos, yaw}` broadcast in snapshots; clients render a `RemoteAvatar` for each. A server-hosted agent body is therefore a **server-controlled "virtual peer"** — a roster entry the gateway owns directly, not backed by a real multiplayer connection. No avatar *node* is needed server-side.

---

## Components

Each component is a focused unit with one responsibility and a clear interface.

### 1. `scripts/AgentToolCore.gd` (NEW — extracted from `AgentBridge.gd`)
The 12 tools (`observe`, `scan`, `get_block`, `goto`, `look`, `place`, `break`, `build`, `say`, `set_goal`, `remember`, `get_memory`) implemented against an **abstract context**, not against a concrete game client:

Reads work against either a `World` node (live path) or `WorldData` (server path) — both expose `surface_y` / `region_label` / `get_block` / `chunk_of`. The context supplies everything node-specific:

```
context (interface):
  read         # surface_y / region_label / get_block / chunk_of / is_solid  (World node OR WorldData)
  body         # eid, get_pos/set_pos, get_yaw/set_yaw, get_pitch/set_pitch, selected_block_id
  apply_edits  # (Array[{pos,id}]) -> int  (live: World.request_block_edits; server: NetworkManager.apply_virtual_edit)
  say          # (text, to) -> bool  (chat_hub.post)
  memory       # get_goal/set_goal/notes/append_note  (per-agent, persisted)
```

- No transport, no hard dependency on live nodes.
- **Single source of truth** for tool semantics; **both** the localhost `AgentBridge` (via a `LiveAgentContext`) and the `AgentGateway` (via a `ServerAgentContext`) call it → no divergence.
- `build` calls the new **`BuildTemplates`** module (below), so it works without a `Player` node. `observe`'s `hotbar`/`selected_block` come from the context (server agents get a default + a settable selected block).
- Tool result shapes match `docs/agent-bridge-contract.md` §4.

**Interface:** `handle(tool_name: String, args: Dictionary, ctx) -> Dictionary` returning `{ok, result/error}`.

#### 1b. `scripts/BuildTemplates.gd` (NEW — extracted from `Player.gd`)
The 12 build templates currently live **inside `Player.gd`** as a state-machine (`apply_build_template` @737, `_placement_edits` @819, `_template_cells` @1059, and the `_*_template_cells()`/`_*_template_edits()` family @1088–1296), coupled to Player's placement fields. Extract the **pure geometry** into a node-free module:

`BuildTemplates.edits_for(template_id: String, origin: Vector3i, orientation: int, default_block_id: int) -> Array` → `[{pos: Vector3i, id: int}]` (empty if unknown template). Decorated templates (campfire/bridge/garden/cabin/beacon_tower/signpost) carry their own block ids; simple templates use `default_block_id`.

`Player.apply_build_template` and the HUD preview then **delegate** to it (Player keeps its behaviour). This is the main refactor cost of β-1; it is regression-gated by the existing `tests/test_build_templates.gd` + `tests/test_agent_bridge.gd`.

### 2. `scripts/AgentGateway.gd` (NEW — server-side)
Owns a **WebSocket listener** on `127.0.0.1:OW_AGENT_GATEWAY_PORT` (default `8972`). Per connection:

1. Require an **auth frame** as the first message; validate token against the token store. On failure → error envelope + close.
2. On success → `NetworkManager.register_virtual_peer(name)` (spawn position via existing `_scatter_spawn`) → returns `eid`; reply with `eid` + spawn.
3. Read NDJSON tool envelopes; for each, build a `context` bound to this connection's body and dispatch to `AgentToolCore`; write the response envelope.
4. On WS close / idle timeout → `NetworkManager.remove_virtual_peer(eid)` (body despawns, roster broadcast).

Enforces a **per-connection request rate cap** and a **max concurrent agents** cap.

### 3. NetworkManager virtual-peer extension (MODIFY `scripts/NetworkManager.gd` — additive only)
New methods mirroring the real-peer path but for server-owned entities:

- `register_virtual_peer(name: String) -> String` (eid) — assigns `"agent-N"` from a **separate counter**; stores in a virtual-peer registry; included in outgoing snapshots/roster.
- `update_virtual_peer(eid, pos, yaw)` — for `goto`/`look`; reflected in next snapshot.
- `apply_virtual_edit(eid, wx, wy, wz, id) -> bool` — reuses the existing **8-block reach** + **96 edits/s** window (`EDIT_RATE_MAX`/`EDIT_RATE_WINDOW`), attributed to the virtual peer; on accept, writes WorldData and broadcasts via the existing `_rpc_apply_edit` path to all real clients.
- `virtual_say(eid, text)` — broadcast chat as this body.
- `remove_virtual_peer(eid)` — drop from registry + roster broadcast.

**Invariants:**
- Virtual-peer eids (`agent-N`) never collide with real-player eids (`player-N`) — separate counters, distinct prefixes.
- Virtual peers are **included in snapshots sent to clients** but **never receive RPCs** (no multiplayer peer_id).
- A virtual peer's rate-limit/reach state is independent per agent.

### 4. `ourworlds-mcp` remote mode (MODIFY `agent-bridge-mcp/src/index.ts`)
Add a transport branch:

- If `OW_REMOTE_URL` is set → connect via **WebSocket** to that URL, send the **auth frame first** (`OW_AGENT_TOKEN`, optional `OW_AGENT_NAME`), then relay the same NDJSON envelopes.
- Else → existing **localhost TCP** behaviour (`OW_AGENT_PORT`), unchanged.
- **Same 12 tools, same envelopes, same contract** — only the transport differs. Auto-reconnect + per-request timeout preserved.

### 5. Token store (NEW — minimal, server-side)
- v1: valid tokens loaded from `OW_AGENT_TOKENS` (comma-separated, or a file path), each mapping to a display label.
- Per-agent **memory persisted server-side keyed by token** (goal + notes survive reconnect).
- No accounts (SP2).

### 6. Cloudflare ingress (MODIFY tunnel config)
Add an ingress rule `path: /agent → http://127.0.0.1:8972` **before** the catch-all, alongside existing `/ws → 8971` and web `→ 8060`. WebSocket upgrade passes through Cloudflare.

---

## Wire protocol

Transport: **WebSocket text frames**, one JSON envelope per frame (NDJSON-compatible).

**Auth (first frame, required):**
```json
→ {"id":0,"tool":"auth","args":{"token":"<token>","name":"BrutalistBot"}}
← {"id":0,"ok":true,"result":{"eid":"agent-7","spawn":{"x":12,"y":40,"z":-8}}}
← {"id":0,"ok":false,"error":"unauthorized"}        // then connection closed
```

**Tool calls (after auth):**
```json
→ {"id":N,"tool":"observe","args":{}}
← {"id":N,"ok":true,"result":{ …contract §4 observe shape… }}
→ {"id":N,"tool":"build","args":{"template":"cabin","anchor":{"x":12,"z":-8}}}
← {"id":N,"ok":false,"error":"edit rejected: out of reach"}
```

Tool set and result shapes are identical to `docs/agent-bridge-contract.md` §4. The contract gets a new section documenting the remote transport + the `auth` frame.

---

## Data flow (one agent session)

1. Connector's runtime spawns `ourworlds-mcp` (remote mode) with `OW_REMOTE_URL` + `OW_AGENT_TOKEN`.
2. First tool-call → MCP opens WS to `wss://play.ourworlds.app/agent`, sends the **auth frame**.
3. Gateway validates token → `register_virtual_peer` (scatter-spawned) → body appears in everyone's next snapshot → replies with `eid`.
4. Runtime drives the body: `observe`/`scan` (read around body), `goto`/`look` (move → avatar moves for all clients), `place`/`break`/`build` (edits attributed to the body → reach + rate-limit → broadcast), `say` (chat), `set_goal`/`remember`/`get_memory` (token-keyed memory).
5. Disconnect / idle timeout → `remove_virtual_peer` → body vanishes from snapshots.

Result: a remote agent driven by **any** MCP runtime appears as a normal moving/building avatar in the shared world, visible to humans and other agents.

---

## Error handling

| Case | Behaviour |
|---|---|
| Bad / missing token | `{"ok":false,"error":"unauthorized"}` + close WS; no body spawned |
| Malformed envelope (not JSON / no `tool`) | `{"ok":false,"error":"bad request: …"}`, connection kept (close after repeated abuse) |
| Unknown tool | `{"ok":false,"error":"unknown tool: X"}` |
| World not loaded yet | `{"ok":false,"error":"world not ready"}` (existing contract behaviour) |
| Edit out of reach / too fast | `apply_virtual_edit` returns false → `"edit rejected: out of reach"` / `"rate limited"` |
| WS drop / idle timeout | `remove_virtual_peer` → despawn + roster broadcast; MCP wrapper auto-reconnects on next call (re-auth) |
| Duplicate `auth` on a connection | ignored (idempotent), or `"already authenticated"` |
| At capacity | `{"ok":false,"error":"server at capacity"}` on auth |

---

## Security & abuse limits (v1 trusted-first)

- **Token gate:** only tokens present in `OW_AGENT_TOKENS` are accepted; no token → no body.
- **Reuse existing protections:** per-peer **8-block reach** + **96 edits/s** window, applied to virtual peers.
- **Per-connection request cap:** throttle tool requests (default e.g. 20/s) to prevent non-edit floods (observe spam).
- **Max concurrent agents:** `OW_AGENT_MAX` (default ~8) caps total virtual peers.
- **Bounded payloads:** `place`/`break` keep the contract's 4096-cell cap (enforced server-side).
- **Loopback bind:** gateway binds `127.0.0.1:8972`; only the Cloudflare `/agent` route exposes it — no raw public port (same pattern as the game WS).

**Deferred to SP2:** account-tied tokens (Nakama), per-owner agent caps, kick/revoke, persistent ban, audit log.

---

## Testing strategy (TDD)

### Unit — Godot / GUT (headless)
- **AgentToolCore:** each of the 12 tools against a fake `world`/`body`/`chat`/`memory` context — `observe` returns expected snapshot; `goto` updates body pos; `build` stamps a template; `place`/`break` edit cells; `say` emits chat; `set_goal`/`remember`/`get_memory` round-trip. Pure logic, no transport.
- **NetworkManager virtual peers:** `register_virtual_peer` → appears in snapshot roster; `update_virtual_peer` → pos changes; `apply_virtual_edit` respects reach + rate-limit; `remove_virtual_peer` → drops from roster; `agent-N` eids never collide with `player-N`.
- **AgentGateway protocol:** feed framed NDJSON envelopes through an abstracted socket — assert auth gating (bad token rejected; good token spawns peer), tool dispatch, error envelopes, disconnect despawns.
- **Token store:** valid/invalid resolution; per-token memory keying.

### Unit — TypeScript (`ourworlds-mcp`)
- **Remote-mode transport:** with `OW_REMOTE_URL` set, opens WS, sends auth frame first, relays envelopes; falls back to TCP when unset. Tested against a local mock WS server.

### Integration — headless, CI-repeatable
- A tiny scripted **"fake runtime"** (node or python) that speaks the NDJSON/WS directly drives a **two-agent** scenario end-to-end against a locally-run server+gateway — *no real LLMs needed*. Asserts two distinct bodies, independent rate-limits, correct eid attribution, despawn on disconnect.

### Acceptance — manual demo (the heterogeneity proof)
- Real **Hermes + Claude Code** connect **simultaneously** to `wss://…/agent` with distinct tokens and distinct persona prompts:
  - Hermes via `hermes mcp add` (stdio `ourworlds-mcp`, env `OW_REMOTE_URL` + `OW_AGENT_TOKEN=<tokenH>`), persona A.
  - Claude Code via `.mcp.json` (same server, `OW_AGENT_TOKEN=<tokenC>`), persona B.
  - Assert: server roster shows **2 distinct agent bodies**; each observes/moves/builds per its persona; edits attributed to the correct eid; rate-limits independent; **a human web client at `play.ourworlds.app` sees BOTH agents** moving/building (visibility — relies on the earlier RemoteAvatar fix); disconnecting each despawns its body.

---

## Deployment

- Gateway runs **in-process** in the existing dedicated server. New env flags:
  - `OW_AGENT_GATEWAY_PORT=8972` (enables the gateway)
  - `OW_AGENT_TOKENS=<token1>,<token2>` (or a file path)
  - `OW_AGENT_MAX=8`
- **No new launchd service** — the existing server LaunchAgent runs it; add the env vars to that plist.
- Cloudflare tunnel config: add `/agent → http://127.0.0.1:8972` before the catch-all. `/ws` (8971) and web (8060) unchanged.

---

## Definition of Done

- [ ] A remote MCP runtime connects via `wss://play.ourworlds.app/agent` + token, gets a server-hosted body, and runs all 12 tools.
- [ ] **Hermes + Claude Code** connect **simultaneously**, each building per its persona, both visible to a human web client and to each other.
- [ ] Bad token rejected; disconnect despawns; 8-block reach + 96/s rate-limit + `OW_AGENT_MAX` enforced.
- [ ] All unit tests (Godot + TS) green; headless scripted two-agent integration test green; manual Hermes+Claude acceptance demo performed.
- [ ] Docs: a short "connect your agent" guide (remote endpoint + token + the two runtime configs) + `agent-bridge-contract.md` updated with the remote transport + `auth` frame.
- [ ] `AgentToolCore` extraction leaves the existing localhost `AgentBridge` behaviour unchanged (regression: existing agent tests still green).

---

## Out of scope (SP1)

- Account-bound tokens / Nakama integration, per-owner quotas, kick/revoke, audit log → **SP2**.
- In-game control-plane panel (mint tokens, set persona/permissions, live roster) → **SP3**.
- Config-generator/onboarding helper + multi-runtime docs beyond the two test runtimes → **SP4**.
- Server-pushed proactive events to agents (agents are pull-based via `observe` in v1).
- Server-side persona templates (persona lives connector-side as the runtime's system prompt).

---

## Risks & open questions

- **Godot WebSocket server on a path:** confirm the gateway's `WebSocketPeer`/`TCPServer` handshake works behind Cloudflare's `/agent` path routing (the game WS already works on `/ws`, so the pattern is proven; validate during the deploy task).
- **Virtual-peer integration points:** ensure every place that iterates `_peers` for snapshot/roster building also includes virtual peers, and every place that sends RPCs to peers **excludes** them. Audit needed during implementation.
- **Memory keying:** token-keyed memory means rotating a token loses that agent's memory; acceptable for v1, revisit when accounts land (SP2).
- **Extraction risk (the main β-1 cost):** moving Player's template geometry → `BuildTemplates` and AgentBridge's tools → `AgentToolCore` must preserve existing behaviour exactly. Mitigation: the existing `tests/test_agent_bridge.gd` (all 12 tools via `dispatch_line`) and `tests/test_build_templates.gd` stay green throughout — refactor *under* them, never edit them to pass.
- **`observe` fidelity on the server:** server agents have no hotbar/HUD; `observe.hotbar`/`selected_block` come from context defaults. Acceptable — the contract fields stay present; values differ from a human's. Documented in the contract update.
</content>
</invoke>
