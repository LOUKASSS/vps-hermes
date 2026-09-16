#!/usr/bin/env bash
# Keeps the stack up. Run every minute by hermes-heal.timer (see install.sh):
#   - restarts containers Docker reports unhealthy (Docker's restart policy only reacts to the
#     process exiting — a hung gateway or a netns-orphaned workspace/dashboard stays "running");
#   - starts containers that exited (hermes-dashboard shares hermes-agent's PID namespace and is
#     killed on every agent restart; Docker gives up on it when the agent is not up yet).
# Does nothing when no container of the project is running (stack stopped on purpose).
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
load_env

mapfile -t rows < <(compose ps -a --format '{{.Name}}\t{{.State}}\t{{.Health}}')
[ "${#rows[@]}" -gt 0 ] || exit 0
running=0; unhealthy=(); stopped=()
for row in "${rows[@]}"; do
  IFS=$'\t' read -r name state health <<<"$row"
  case "$state" in
    running) running=$((running + 1)); [ "$health" = unhealthy ] && unhealthy+=("$name") ;;
    exited|created|dead) stopped+=("$name") ;;
  esac
done
[ "$running" -gt 0 ] || exit 0   # whole stack down: leave it alone

for name in "${unhealthy[@]}"; do
  info "heal: $name unhealthy → restart"
  docker restart -t 20 "$name" >/dev/null || warn "heal: restart of $name failed"
done
if [ "${#stopped[@]}" -gt 0 ]; then
  info "heal: stopped: ${stopped[*]} → docker compose up -d"
  compose up -d --no-recreate >/dev/null 2>&1 || warn "heal: compose up failed"
fi
