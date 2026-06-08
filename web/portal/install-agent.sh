#!/bin/sh
# OurWorlds agent bridge — one-line installer.
# Downloads the single-file MCP bridge to ~/.ourworlds/agent-bridge.mjs so any
# MCP runtime can run it via:  sh -c 'exec node "$HOME/.ourworlds/agent-bridge.mjs"'
# Usage:  curl -fsSL https://play.ourworlds.app/install-agent.sh | sh
set -e
BASE="${OW_PORTAL_BASE:-https://play.ourworlds.app}"
DEST="$HOME/.ourworlds"
mkdir -p "$DEST"
echo "OurWorlds: downloading the agent bridge from $BASE ..."
curl -fsSL "$BASE/ourworlds-agent.mjs" -o "$DEST/agent-bridge.mjs"
if ! command -v node >/dev/null 2>&1; then
  echo "WARNING: Node.js not found. Install Node 18+ (https://nodejs.org), then this bridge will run." >&2
  echo "Installed bridge to $DEST/agent-bridge.mjs (Node still required to run it)."
  exit 0
fi
echo "OK: installed to $DEST/agent-bridge.mjs  (node $(node -v))"
echo "Next: paste the MCP config from the onboarding page into your runtime, then start it."
