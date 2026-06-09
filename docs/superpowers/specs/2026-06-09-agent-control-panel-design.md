# Agent Control Panel (Web) — Design

**Date:** 2026-06-09
**Status:** Approved (brainstormed), implementing.

## Goal
A web admin page where the operator can see each resident agent's status and **toggle it on/off** — no terminal `launchctl` needed.

## Current state
Resident agents are launchd user-agents (`app.ourworlds.resident-{codexbot,gardenbot,openclaw}`), controlled only via `launchctl bootout/bootstrap` in a terminal. `serve_web.py` (the play-web service, runs as the user on :8060, already serves `/onboard` + `/api/agent-token`) is the natural backend — it can `launchctl` the user-agents directly.

## Components
1. **`/agents` page** (`web/portal/agents.html`, static, bilingual) — enter the admin token, then see a row per resident agent: name, **status** (running / stopped), and a **Start/Stop toggle** (+ a "run one shift now" button).
2. **serve_web admin API** (added to `serve_web.py`, all admin-gated):
   - `GET /api/agents` → list of resident agents (discovered from `~/Library/LaunchAgents/app.ourworlds.resident-*.plist`) with status.
   - `POST /api/agents/<label>/start` → `launchctl bootstrap gui/<uid> <plist>`.
   - `POST /api/agents/<label>/stop` → `launchctl bootout gui/<uid>/<label>`.
   - `POST /api/agents/<label>/kick` (optional) → `launchctl kickstart -k gui/<uid>/<label>` (run one shift now).

## Discovery + status (no hardcoding)
- **Whitelist = the plist set:** glob `~/Library/LaunchAgents/app.ourworlds.resident-*.plist`. The label is the filename stem. Only labels in this discovered set are controllable — so new residents appear automatically, and the core services (`play-server/web/tunnel`) can NEVER be touched by this API.
- **Status:** `launchctl print gui/<uid>/<label>` — has a live `pid` → running; present but no pid → loaded/idle; non-zero rc → not loaded (booted out / stopped).

## Security (the crux — these run launchctl on the host)
- Gated by a **dedicated admin token** `OW_ADMIN_TOKEN` (env on play-web), **separate from** the public invite code `OW_PORTAL_GATE`. If `OW_ADMIN_TOKEN` is unset/empty → the whole admin API returns `503 {"error":"admin disabled"}`.
- Wrong/missing token → `403`.
- `<label>` is validated against the discovered plist whitelist (regex `^app\.ourworlds\.resident-[a-z0-9-]+$` **and** must exist as a plist). Anything else → `404`. No shell interpolation of the label into a command string — pass as argv to `subprocess` with a fixed command list.
- Per-IP rate limit on the control endpoints. The static page embeds no token (entered per session).

## Testing
- Python `packaging/test_agent_control.py`: admin-disabled (503 when no token), bad token (403), unknown/invalid label rejected (404, incl. an injection-y label like `../play-server`), discovery lists only `resident-*`, and the launchctl command is built as argv (not a shell string). Mock/stub `subprocess` so the test doesn't actually start/stop services.
- Keep `packaging/test_serve_web.py` green; portal `/onboard` + `/api/agent-token` unaffected.

## Out of scope (v1)
Editing a resident's task/cadence from the UI; adding NEW agents from here (that's `/onboard`); per-agent logs in the UI; in-game panel.

## Deploy
Set `OW_ADMIN_TOKEN` in the play-web plist env; restart play-web. Page at `https://play.ourworlds.app/agents`.
