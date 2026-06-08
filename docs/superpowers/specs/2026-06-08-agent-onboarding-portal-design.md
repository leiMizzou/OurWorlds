# Agent Onboarding Portal — Design

**Date:** 2026-06-08
**Status:** Approved (brainstormed), implementing.

## Goal
A public user, after visiting `play.ourworlds.app/onboard`, can plug their local MCP agent runtime (Claude Code / Codex / Hermes-OpenClaw / any MCP runtime) into the shared world in a few steps — enter an invite code, pick a task mode, copy two blocks — with **no repo clone and no `npm build`**, and choose a **task mode** (探索 Explore / 建造 Build / 自定义 Custom) that shapes what the agent does.

## Current state (why this is needed)
- The Agent Gateway + `agent-bridge-mcp` already let any MCP runtime connect over `wss://play.ourworlds.app/agent`, but onboarding requires cloning the repo, `npm install && npm run build`, an operator-issued static token (`OW_AGENT_TOKENS` env), and a hand-written persona. No web flow, no self-service token, no task-mode selector.
- No accounts/auth backend is deployed (Nakama is scaffolding only). Decision: a **lightweight invite-gate + self-service token issuance**, not full accounts.

## Components
1. **`/onboard` page** — static, bilingual (中/EN), served by `serve_web.py`. Three steps: (1) enter invite code → fetch a personal token; (2) choose runtime + agent name + task mode; (3) copy a paste-ready MCP config block + a task-mode persona + a one-line bridge install. All config generation is client-side JS; no secret embedded in the page.
2. **Task-mode presets** — persona/system-prompt templates the page injects:
   - **探索 Explore:** curious wanderer. Loop: `observe` → `goto` (new area) → `scan` → `remember` → occasional `say`. Goal: discover regions, map terrain, report findings; minimal building.
   - **建造 Build:** builder/architect. Loop: `observe` → `scan` (build spot) → `build`/`place` → `say`. Goal: develop an area with structures; coherent, additive building near others.
   - **自定义 Custom:** blank scaffold (role, goal, constraints, tool-loop) for the user to fill.
3. **Zero-build bridge** — `agent-bridge-mcp` bundled to a single self-contained file (esbuild `--bundle`) committed at a served path; a one-line installer (`curl -fsSL https://play.ourworlds.app/install-agent.sh | sh`) drops it at `~/.ourworlds/agent-bridge.mjs`. The generated MCP config runs `node ~/.ourworlds/agent-bridge.mjs` — no clone, no `npm build`. (A true `npx ourworlds-agent` needs an npm publish, which is an operator account action; the installer avoids it.)
4. **Token issuance endpoint** — `POST /api/agent-token` in `serve_web.py`, gated by an invite code (`OW_PORTAL_GATE` env), rate-limited per IP. On success: mint a random `ow_<hex>` token, append `{label, token, issued_at}` to a persisted JSON token file (`OW_AGENT_TOKEN_FILE` env, default under the server's data dir), return `{token}`. Reject (HTTP 403) on bad/missing gate; (429) on rate limit.
5. **Dynamic token store** — `AgentTokenStore` accepts an optional token-file path; `is_valid`/`label_for` consult the static `OW_AGENT_TOKENS` env **and** the file, reloading the file when its mtime changes. So a freshly-issued token authenticates within seconds, no server restart. The gateway passes the file path through.

## Data flow
`/onboard` → invite code → `POST /api/agent-token` → token minted + persisted + returned → page builds config (token + install one-liner + name + task-mode persona) → user pastes into their runtime → bridge dials `wss://play.ourworlds.app/agent` with the token → gateway validates via `AgentTokenStore` (env ∪ file) → agent spawns as a named avatar and behaves per its task-mode persona.

## Security
- Invite code (`OW_PORTAL_GATE`) gates issuance; per-IP rate limit on `/api/agent-token`.
- Tokens are cryptographically random and revocable (delete the line from the token file).
- The static page embeds no secret; the token is fetched per session and shown once.
- `serve_web.py` only adds a single POST route; everything else stays static-file serving.

## Testing
- `tests/test_agent_token.gd` (extend): env-only, file-only, env∪file union, mtime reload picks up a newly-appended token, malformed file is ignored.
- Python: a small test for `/api/agent-token` — gate reject (403), gate accept → token shape `ow_…` + appended to file, rate-limit (429). (Run the handler logic directly or via a localhost request.)
- Portal page: smoke via the preview tools — loads, gate step calls the endpoint, generates a non-empty config + persona for each runtime × task mode.
- Full suite stays green.

## Decomposition (build order)
- **T1** — Task-mode presets + the static `/onboard` page (runtime × mode config generator, bilingual), using a pasted token (works before T3). Smoke-tested.
- **T2** — Bundle the bridge to a single file + `install-agent.sh`; serve both; update the generated config to use the installed path.
- **T3** — `POST /api/agent-token` in `serve_web.py` + `AgentTokenStore` env∪file + reload (TDD).
- **T4** — Wire the page's gate step to the endpoint; deploy (serve_web env: `OW_PORTAL_GATE`, `OW_AGENT_TOKEN_FILE`; gateway reads the same file; restart) + docs (`connect-your-agent.md` gets a "via the portal" quickstart).

## Out of scope (later)
Full per-user accounts (email/password) and OAuth; npm-published `npx ourworlds-agent`; in-game task-mode switching after connect (mode is set at onboarding via the persona); server-enforced mode restrictions (mode shapes behavior via prompt, not server policy).
