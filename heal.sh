#!/usr/bin/env bash
# Keeps the stack up. Run every minute by hermes-heal.timer (see install.sh):
#   - restarts containers Docker reports unhealthy (Docker's restart policy only reacts to the
#     process exiting — a hung gateway stays "running");
#   - starts containers that exited (Docker's restart policy gives up after repeated failures);
#   - hermes-agent itself is always recreated with `compose up -d --force-recreate` (restart_agent).
# Does nothing when: no container of the project is running (stack stopped on purpose),
# $STACK_DIR/.maintenance exists (single service stopped on purpose), or update.sh is running.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
load_env

[ -e "$MAINTENANCE_FLAG" ] && exit 0
lock_update -n || exit 0

mapfile -t rows < <(compose ps -a --format '{{.Name}}\t{{.State}}\t{{.Health}}')
[ "${#rows[@]}" -gt 0 ] || exit 0
enabled="$(compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(s.get("container_name", n) for n, s in json.load(sys.stdin)["services"].items()))' 2>/dev/null || true)"
[ -n "$enabled" ] || enabled="$(printf '%s\n' "${rows[@]}" | cut -f1 | tr '\n' ' ')"   # config unreadable: consider all
running=0; unhealthy=(); stopped=()
for row in "${rows[@]}"; do
  IFS=$'\t' read -r name state health <<<"$row"
  case "$state" in
    running) running=$((running + 1)); [ "$health" = unhealthy ] && unhealthy+=("$name") ;;
    exited|created|dead) case " $enabled " in *" $name "*) stopped+=("$name") ;; esac ;;   # not a disabled profile's leftover
  esac
done
[ "$running" -gt 0 ] || exit 0   # whole stack down: leave it alone

# hermes-agent itself: recreate it, nothing else.
case " ${unhealthy[*]} ${stopped[*]} " in *" hermes-agent "*)
  info "heal: hermes-agent unhealthy/stopped → recreate it"
  restart_agent
  exit 0 ;;
esac
for name in "${unhealthy[@]}"; do
  info "heal: $name unhealthy → restart"
  docker restart -t 20 "$name" >/dev/null || warn "heal: restart of $name failed"
done
if [ "${#stopped[@]}" -gt 0 ]; then
  info "heal: stopped: ${stopped[*]} → docker compose up -d"
  compose up -d --no-recreate >/dev/null || warn "heal: compose up failed"
fi
