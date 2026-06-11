# Agent Control Panel (Web) — Design

**Date:** 2026-06-09
**Status:** Implemented v1/v2.

## Goal
A web admin page where the operator can see each resident agent's status, **toggle it on/off**, and edit the agent's persistent configuration — no terminal `launchctl` needed.

## Current state
Resident agents are launchd user-agents (`app.ourworlds.resident-{codexbot,gardenbot,openclaw}`), controlled only via `launchctl bootout/bootstrap` in a terminal. `serve_web.py` (the play-web service, runs as the user on :8060, already serves `/onboard` + `/api/agent-token`) is the natural backend — it can `launchctl` the user-agents directly.

## Components
1. **`/agents` page** (`web/portal/agents.html`, static, bilingual) — enter the admin token, then see a row per resident agent: name, **status** (running / stopped), runtime/mode summary, and a **Start/Stop toggle** (+ a "run one shift now" button). Expanding a row shows logs, config, task text, and cadence controls.
2. **serve_web admin API** (added to `serve_web.py`, all admin-gated):
   - `GET /api/agents` → list of resident agents (discovered from `~/Library/LaunchAgents/app.ourworlds.resident-*.plist`) with status.
   - `POST /api/agents/<label>/start` → `launchctl bootstrap gui/<uid> <plist>`.
   - `POST /api/agents/<label>/stop` → `launchctl bootout gui/<uid>/<label>`.
   - `POST /api/agents/<label>/kick` (optional) → `launchctl kickstart -k gui/<uid>/<label>` (run one shift now).
   - `GET /api/agents/<label>/config` → read persisted config, defaulting from the resident label + plist interval.
   - `POST /api/agents/<label>/config` → save display name, runtime, mode, model, avatar, color, goal, persona; if `interval` is present, update `ThrottleInterval` and reload the launchd job.

## Config model
- Config files live under `OW_RESIDENT_CONFIG_DIR` (default `~/.ourworlds/agents`) as `<resident-name>.json`, e.g. `codexbot.json`.
- The JSON fields are:
  - `display_name`, `runtime`, `mode`, `model`
  - `avatar`, `color`
  - `goal`, `persona`
  - `interval` (mirrored from the plist; plist remains the runtime source of truth for cadence)
- Saving config without `interval` writes only JSON and does not touch `launchctl`.
- Saving config with `interval` preserves the previous cadence behavior: rewrite `ThrottleInterval`, then `bootout` + `bootstrap`.

## Discovery + status (no hardcoding)
- **Whitelist = the plist set:** glob `~/Library/LaunchAgents/app.ourworlds.resident-*.plist`. The label is the filename stem. Only labels in this discovered set are controllable — so new residents appear automatically, and the core services (`play-server/web/tunnel`) can NEVER be touched by this API.
- **Status:** `launchctl print gui/<uid>/<label>` — has a live `pid` → running; present but no pid → loaded/idle; non-zero rc → not loaded (booted out / stopped).

## Security (the crux — these run launchctl on the host)
- Gated by a **dedicated admin token** `OW_ADMIN_TOKEN` (env on play-web), **separate from** the public invite code `OW_PORTAL_GATE`. If `OW_ADMIN_TOKEN` is unset/empty → the whole admin API returns `503 {"error":"admin disabled"}`.
- Wrong/missing token → `403`.
- `<label>` is validated against the discovered plist whitelist (regex `^app\.ourworlds\.resident-[a-z0-9-]+$` **and** must exist as a plist). Anything else → `404`. No shell interpolation of the label into a command string — pass as argv to `subprocess` with a fixed command list.
- Per-IP rate limit on the control endpoints. Admin rate limiting is separate from `/api/agent-token` issuance rate limiting so normal panel refreshes do not consume the invite-token budget. The static page embeds no token (entered per session).

## Testing
- Python `packaging/test_agent_control.py`: admin-disabled (503 when no token), bad token (403), unknown/invalid label rejected (404, incl. an injection-y label like `../play-server`), discovery lists only `resident-*`, config default/read/write behavior, and the launchctl command is built as argv (not a shell string). Mock/stub `subprocess` so the test doesn't actually start/stop services.
- Keep `packaging/test_serve_web.py` green; portal `/onboard` + `/api/agent-token` unaffected.

## Out of scope (v1)
Adding NEW agents from here (that's still `/onboard` or ops provisioning); in-game management panel; making every third-party resident runtime automatically consume all config fields.

## Deploy
Set `OW_ADMIN_TOKEN` in the play-web plist env; restart play-web. Page at `https://play.ourworlds.app/agents`.
