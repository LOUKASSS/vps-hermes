#!/bin/sh
# Install obsidian-headless into the persistent HOME volume when missing/stale, then exec ob.
set -eu
PREFIX="${NPM_CONFIG_PREFIX:-/data}"
export PATH="$PREFIX/bin:$PATH"
export HOME=/data
ver="${OBSIDIAN_HEADLESS_VERSION:-0.0.14}"
stamp="$PREFIX/.ob-version"
need=0
command -v ob >/dev/null 2>&1 || need=1
[ -f "$stamp" ] && [ "$(cat "$stamp")" = "$ver" ] || need=1
if [ "$need" = 1 ]; then
  npm install -g --prefix "$PREFIX" --no-audit --no-fund --fetch-retries=5 \
    "obsidian-headless@${ver}"
  echo "$ver" > "$stamp"
fi
exec ob "$@"
