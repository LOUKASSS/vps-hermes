#!/usr/bin/env bash
# Update the stack: rebuild the derived image on the newest base, pull other images, recreate.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
need_root
load_env
cd "$STACK_DIR"
info "Rebuilding hermes-agent-vps on latest nousresearch/hermes-agent…"
compose build --pull
info "Pulling traefik + hermes-workspace…"
compose pull --ignore-buildable
info "Recreating containers…"
compose up -d --remove-orphans
docker image prune -f >/dev/null
compose ps
