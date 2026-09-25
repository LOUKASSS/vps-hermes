#!/usr/bin/env bash
# Keeps the stack up. Run every minute by hermes-heal.timer (see install.sh):
#   - Hermes (host, systemd): a crash is systemd's job (Restart=always). heal.sh handles the hang
#     systemd cannot see — both services active, but the gateway's /health or the dashboard's
#     /api/status not answering for HEAL_AGENT_GRACE checks in a row (a start takes ~1 min) →
#     restart_agent, at most HEAL_MAX_AGENT_RECREATES times in a row: Hermes that never comes back
#     healthy (broken config, broken release) is then left alone and .maintenance is written,
#     instead of cutting its work every few minutes forever. Counters reset once it is healthy.
#     Services stopped on purpose (systemctl stop, command-center hermes stop) are left alone.
#   - containers: restarts those Docker reports unhealthy (its restart policy only reacts to the
#     process exiting) and starts those that exited (the restart policy gives up after repeated
#     failures) — unless no container of the project runs (stack stopped on purpose).
# Does nothing when $STACK_DIR/.maintenance exists (stopped on purpose) or update.sh is running.
set -euo pipefail
# shellcheck disable=SC1091
. "$(dirname "$0")/lib/common.sh"
load_env

[ -e "$MAINTENANCE_FLAG" ] && exit 0
lock_update -n || exit 0
AGENT_FAILS=/run/hermes-heal.agent-recreates     # tmpfs: a reboot is a fresh start
AGENT_UNHEALTHY=/run/hermes-heal.agent-unhealthy  # failed checks in a row
HEAL_MAX_AGENT_RECREATES="${HEAL_MAX_AGENT_RECREATES:-3}"
HEAL_AGENT_GRACE="${HEAL_AGENT_GRACE:-3}"

# ── Hermes (host) ──
if hermes_installed && agent_running; then
  if agent_healthy; then
    rm -f "$AGENT_FAILS" "$AGENT_UNHEALTHY"
  else
    bad="$(( $(cat "$AGENT_UNHEALTHY" 2>/dev/null || echo 0) + 1 ))"
    echo "$bad" > "$AGENT_UNHEALTHY"
    if [ "$bad" -ge "$HEAL_AGENT_GRACE" ]; then
      rm -f "$AGENT_UNHEALTHY"
      fails="$(cat "$AGENT_FAILS" 2>/dev/null || echo 0)"
      if [ "$fails" -ge "$HEAL_MAX_AGENT_RECREATES" ]; then
        warn "heal: Hermes still unhealthy after $fails restarts — giving up. Fix it (journalctl -u hermes-gateway -u hermes-dashboard), then: rm $MAINTENANCE_FLAG"
        printf 'heal.sh: Hermes did not come back healthy after %s restarts (%s). Remove this file to resume healing.\n' "$fails" "$(date -Is)" > "$MAINTENANCE_FLAG"
        rm -f "$AGENT_FAILS"
        notify "heal.sh: Hermes did not come back healthy after $fails restarts — healing paused ($MAINTENANCE_FLAG). journalctl -u hermes-gateway"
        exit 0
      fi
      echo $((fails + 1)) > "$AGENT_FAILS"
      info "heal: Hermes active but not answering for $bad min → restart ($((fails + 1))/$HEAL_MAX_AGENT_RECREATES)"
      restart_agent
    fi
  fi
fi

# ── containers ──
mapfile -t rows < <(compose ps -a --format '{{.Name}}\t{{.State}}\t{{.Health}}')
[ "${#rows[@]}" -gt 0 ] || exit 0
enabled="$(compose config --format json 2>/dev/null | python3 -c 'import json,sys; print(" ".join(s.get("container_name", n) for n, s in json.load(sys.stdin)["services"].items()))' 2>/dev/null || true)"
[ -n "$enabled" ] || enabled="$(printf '%s\n' "${rows[@]}" | cut -f1 | tr '\n' ' ')"   # config unreadable: consider all
running=0; unhealthy=(); stopped=()
for row in "${rows[@]}"; do
  IFS=$'\t' read -r name state health <<<"$row"
  case "$state" in
    running) running=$((running + 1)); [ "$health" = unhealthy ] && unhealthy+=("$name") ;;
    restarting) unhealthy+=("$name") ;;   # Docker's own backoff loop (e.g. bind failed at boot): kick it now
    exited|created|dead) case " $enabled " in *" $name "*) stopped+=("$name") ;; esac ;;   # not a disabled profile's leftover
  esac
done
[ "$running" -gt 0 ] || exit 0   # whole stack down: leave it alone
for name in "${unhealthy[@]}"; do
  info "heal: $name unhealthy → restart"
  docker restart -t 20 "$name" >/dev/null || warn "heal: restart of $name failed"
done
if [ "${#stopped[@]}" -gt 0 ]; then
  info "heal: stopped: ${stopped[*]} → docker compose up -d"
  compose up -d --no-recreate >/dev/null || warn "heal: compose up failed"
fi
