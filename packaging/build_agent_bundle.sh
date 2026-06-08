#!/bin/sh
# Bundle the agent bridge (agent-bridge-mcp) into ONE self-contained ESM file,
# served at /ourworlds-agent.mjs for the one-line installer (web/portal/install-agent.sh).
# The createRequire banner lets bundled CommonJS deps (ws) require() Node built-ins
# under ESM output. Re-run after changing the bridge source.
set -e
cd "$(dirname "$0")/.."
npx --yes esbuild agent-bridge-mcp/src/index.ts \
  --bundle --platform=node --format=esm --target=node18 \
  --banner:js="import{createRequire as __cr}from'module';const require=__cr(import.meta.url);" \
  --outfile=web/portal/ourworlds-agent.mjs
echo "bundled -> web/portal/ourworlds-agent.mjs ($(wc -c < web/portal/ourworlds-agent.mjs | tr -d ' ') bytes)"
