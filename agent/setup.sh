#!/usr/bin/env bash
# Default agent: build the MCP servers config.yaml declares (mcp_servers: hevy, yazio, renpho)
# from mcp/ vendored in the repo. agent.sh sync-files rsyncs that tree to DIST_DIR=/opt/data/mcp-src
# and installs this script as /opt/data/mcp-src/setup.sh (the repo is not mounted in the container).
# Runs inside hermes-agent as the runtime user:
#   PROFILE_DIR=/opt/data DIST_DIR=/opt/data/mcp-src → writes /opt/data/mcp/
#
#   mcp-src/node/               hevy-mcp + yazio-mcp from the npm registry, lockfile-pinned
#   mcp-src/renpho-mcp-server/  renpho-mcp-server 1.2.0 source (StartupBros/renpho-mcp-server@69eb7aa, MIT)
#
# Credentials (HEVY_API_KEY, YAZIO_*, RENPHO_*) come from Bitwarden Secrets at runtime — nothing is
# written here. Idempotent: each server is rebuilt only when its vendored files changed since the
# last build (.built-from stamp); delete $PROFILE_DIR/mcp/<server> to force a rebuild.
set -euo pipefail
src="${DIST_DIR:?}"; mcp="${PROFILE_DIR:?}/mcp"
npm_opts=(--no-audit --no-fund --fetch-retries=5)

stamp() { (cd "$1" && find . -path ./node_modules -prune -o -path ./dist -prune -o -type f -print0 | sort -z | xargs -0 sha256sum) | sha256sum | cut -c1-16; }
up_to_date() { [ -f "$1/.built-from" ] && [ "$(cat "$1/.built-from")" = "$2" ]; }

# hevy-mcp + yazio-mcp
want="$(stamp "$src/node")"
if up_to_date "$mcp/node" "$want" && [ -f "$mcp/node/node_modules/hevy-mcp/dist/cli.mjs" ]; then
  echo "  hevy-mcp / yazio-mcp up to date"
else
  echo "  npm ci hevy-mcp + yazio-mcp"
  mkdir -p "$mcp/node"
  cp "$src/node/package.json" "$src/node/package-lock.json" "$mcp/node/"
  (cd "$mcp/node" && npm ci --omit=dev "${npm_opts[@]}")
  echo "$want" > "$mcp/node/.built-from"
fi

# renpho-mcp-server: sync the vendored source (never its build products), install, compile.
want="$(stamp "$src/renpho-mcp-server")"
if up_to_date "$mcp/renpho-mcp-server" "$want" && [ -f "$mcp/renpho-mcp-server/dist/index.js" ]; then
  echo "  renpho-mcp-server up to date"
else
  echo "  building renpho-mcp-server from vendored source"
  # (no rsync in the image) replace everything but node_modules/ so retired files disappear
  mkdir -p "$mcp/renpho-mcp-server"
  find "$mcp/renpho-mcp-server" -mindepth 1 -maxdepth 1 ! -name node_modules -exec rm -rf {} +
  (cd "$src/renpho-mcp-server" && tar -cf - --exclude=./node_modules --exclude=./dist --exclude=./.built-from .) | tar -xf - -C "$mcp/renpho-mcp-server"
  (cd "$mcp/renpho-mcp-server" && npm ci "${npm_opts[@]}" && npm run build && npm prune --omit=dev "${npm_opts[@]}")
  echo "$want" > "$mcp/renpho-mcp-server/.built-from"
fi

for f in node/node_modules/hevy-mcp/dist/cli.mjs node/node_modules/yazio-mcp/dist/index.js renpho-mcp-server/dist/index.js; do
  [ -f "$mcp/$f" ] || { echo "  missing: $mcp/$f" >&2; exit 1; }
done
echo "  MCP servers ready: hevy, yazio, renpho"
