# shellcheck shell=bash
# Hermes work and sessions around a recreate of hermes-agent. Sourced by lib/common.sh; used by
# update.sh (busy gate) and restart_agent (heal.sh, auth.sh, `command-center hermes restart`).
#
# A recreate kills every Hermes CLI started through bin/hermes (docker exec) and every in-flight
# gateway turn, cron job and kanban run. So, before it:
#   hermes_busy             what is working right now: herdr panes where Hermes is working/blocked
#                           + the container's own work (lib/hermes-probe.py)
#   hermes_wait_idle <deadline>   poll hermes_busy until empty or $SECONDS reaches <deadline>
#   hermes_pause <reason>   Hermes' global emergency stop: no NEW gateway turn / cron / kanban
#                           dispatch while the container is swapped (in-flight work is never killed)
#   hermes_panes_snapshot   the herdr panes whose foreground is the Hermes CLI
# and once hermes-agent is healthy again:
#   hermes_sessions_restore lift our pause, then `hermes --resume <id>` in each snapshotted pane
#
# herdr is the operator's (herdr.sh); every herdr step is skipped when it is not installed/running.
# Pane output is written by whatever runs in the pane — the agent included — so an id read from it
# is typed back into a shell only if it matches the Hermes session-id format exactly AND is a CLI
# session that ended after the snapshot (i.e. the one this recreate closed, not old scrollback).

HERMES_SESSION_ID_RE='^[0-9]{8}_[0-9]{6}_[0-9a-f]{6,}$'
: "${UPDATE_BUSY_RECENT:=120}"   # an open session that wrote a message this recently counts as working
: "${UPDATE_BUSY_POLL:=60}"
: "${UPDATE_RESUME_HERDR:=1}"
HERMES_PANES=()          # "<pane id><TAB><args after `hermes`>" — filled by hermes_panes_snapshot
HERMES_PANES_SINCE=0
HERMES_ESTOP_OURS=0

# herdr API of the operator's server (HERDR_SESSION=<name> targets a named test session).
herdr_api() {
  local bin="$OP_HOME/.local/bin/herdr"
  [ -x "$bin" ] || return 1
  if [ "${EUID:-$(id -u)}" -eq 0 ]; then
    as_op "$bin" ${HERDR_SESSION:+--session "$HERDR_SESSION"} "$@"
  elif [ "$(id -un)" = "$OP_USER" ]; then
    "$bin" ${HERDR_SESSION:+--session "$HERDR_SESSION"} "$@"
  else
    return 1
  fi
}

hermes_up() { [ "$(docker inspect -f '{{.State.Running}}' hermes-agent 2>/dev/null)" = true ]; }
hermes_cli() { docker exec -u "${HERMES_UID}:${HERMES_GID}" -e HOME=/opt/data/home hermes-agent hermes "$@"; }
hermes_probe() { docker exec -i -u "${HERMES_UID}:${HERMES_GID}" hermes-agent python3 - "$@" < "$STACK_DIR/lib/hermes-probe.py"; }

# One line per piece of work a recreate would cut; empty = idle. Fails closed: a probe that cannot
# run is reported as a line (the update then waits / skips and says why).
hermes_busy() {
  local agents rc=0
  if agents="$(herdr_api agent list 2>/dev/null)"; then
    printf '%s' "$agents" | python3 -c 'import json, sys
for a in json.load(sys.stdin)["result"]["agents"]:
    if a.get("agent") == "hermes" and a.get("agent_status") in ("working", "blocked"):
        print("herdr %s: hermes %s (%s)" % (a["pane_id"], a["agent_status"], a.get("terminal_title_stripped", "")[:60]))' \
      || echo "herdr agent list: unreadable answer"
  fi
  hermes_up || return 0
  hermes_probe busy "$UPDATE_BUSY_RECENT" || rc=$?
  [ "$rc" -eq 0 ] || echo "hermes-probe failed (exit $rc) — cannot tell whether the gateway / cron / kanban are working"
}

# hermes_wait_idle <deadline> — 0 once idle, 1 if still busy when $SECONDS reaches <deadline>.
# HERMES_BUSY = the last report. Logs only when the report changes (not once a minute).
hermes_wait_idle() {
  local deadline="$1" last="" now
  while HERMES_BUSY="$(hermes_busy)"; [ -n "$HERMES_BUSY" ]; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    # shellcheck disable=SC2001  # per-line regex
    now="$(sed 's/ active [0-9]* s ago$//' <<<"$HERMES_BUSY")"   # the ages change every poll
    if [ "$now" != "$last" ]; then
      info "Hermes is working — waiting (≤ $(( (deadline - SECONDS + 59) / 60 )) min more):"
      printf '%s\n' "$HERMES_BUSY" | sed 's/^/  /'
      last="$now"
    fi
    sleep "$UPDATE_BUSY_POLL"
  done
}

# An ESTOP the operator set is theirs: left alone, and not lifted by hermes_unpause.
hermes_pause() {
  [ ! -e "$HERMES_DATA_DIR/ESTOP" ] || return 0
  hermes_up || return 0
  if hermes_cli pause --reason "$1" >/dev/null 2>&1; then HERMES_ESTOP_OURS=1
  else warn "hermes pause failed — new gateway / cron / kanban work is not held during the recreate"; fi
}
hermes_unpause() {
  [ "$HERMES_ESTOP_OURS" = 1 ] || return 0
  { hermes_up && hermes_cli resume >/dev/null 2>&1; } || rm -f "$HERMES_DATA_DIR/ESTOP"
  HERMES_ESTOP_OURS=0
}

# Foreground of a pane is the Hermes CLI (bin/hermes → docker exec, or `command-center hermes chat`
# → docker compose exec): prints the arguments given to `hermes`, exit 1 otherwise.
_HERMES_FG_PY='import json, sys
for p in json.load(sys.stdin)["result"]["process_info"]["foreground_processes"]:
    a = p.get("argv") or []
    if len(a) > 3 and a[0].rsplit("/", 1)[-1] == "docker" and "exec" in a[1:3] and "hermes-agent" in a:
        i = a.index("hermes-agent")
        if a[i + 1:i + 2] == ["hermes"]:
            print(" ".join(a[i + 2:]))
            sys.exit(0)
sys.exit(1)'

hermes_panes_snapshot() {
  HERMES_PANES=(); HERMES_PANES_SINCE="$(date +%s)"
  [ "$UPDATE_RESUME_HERDR" = 1 ] || return 0
  local panes p args
  panes="$(herdr_api pane list 2>/dev/null)" || return 0
  for p in $(printf '%s' "$panes" | python3 -c 'import json, sys
for p in json.load(sys.stdin)["result"]["panes"]: print(p["pane_id"])'); do
    args="$(herdr_api pane process-info --pane "$p" 2>/dev/null | python3 -c "$_HERMES_FG_PY")" || continue
    HERMES_PANES+=("$p"$'\t'"$args")
  done
  [ "${#HERMES_PANES[@]}" -eq 0 ] || info "herdr: Hermes CLI in ${HERMES_PANES[*]%%$'\t'*} — resumed once hermes-agent is back"
}

herdr_pane_at_shell() {
  herdr_api pane process-info --pane "$1" 2>/dev/null | python3 -c 'import json, sys
i = json.load(sys.stdin)["result"]["process_info"]
sys.exit(0 if i.get("shell_pid") and i.get("foreground_process_group_id") == i.get("shell_pid") else 1)'
}
# herdr_wait_shell <pane> <secs> — the shell owns the foreground again (the Hermes CLI exited).
herdr_wait_shell() {
  local deadline=$((SECONDS + $2))
  until herdr_pane_at_shell "$1"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}

# resume_pane <pane> <args> — sets RESUMED (what was started) or FAILED (why not).
resume_pane() {
  local pane="$1" args="$2" id
  RESUMED=""; FAILED=""
  herdr_wait_shell "$pane" 60 || { FAILED="$pane: no shell prompt after 60 s"; return; }
  id="$(herdr_api pane read "$pane" --source recent-unwrapped --lines 80 2>/dev/null \
        | sed -n 's/^[[:space:]]*hermes --resume \([^[:space:]]*\)[[:space:]]*$/\1/p' | tail -n1)" || id=""   # errexit-safe
  if [ -n "$id" ]; then
    if ! grep -qE "$HERMES_SESSION_ID_RE" <<<"$id" || ! hermes_probe ended "$id" "$HERMES_PANES_SINCE"; then
      FAILED="$pane: resume id not recognised as the session this recreate closed — nothing typed"; return
    fi
    herdr_api pane run "$pane" "hermes --resume $id" >/dev/null || { FAILED="$pane: herdr pane run failed"; return; }
    RESUMED="$pane → $id"
  elif [ -z "$args" ]; then
    # No resume hint: the session had no message yet (or died before printing one) → plain CLI back.
    herdr_api pane run "$pane" "hermes" >/dev/null || { FAILED="$pane: herdr pane run failed"; return; }
    RESUMED="$pane → new session (no resume id printed)"
  else
    FAILED="$pane: no resume id printed (was: hermes $args)"
  fi
}

hermes_sessions_restore() {
  hermes_unpause
  [ "${#HERMES_PANES[@]}" -gt 0 ] || return 0
  local entry panes="${HERMES_PANES[*]%%$'\t'*}" resumed=() failed=()
  if [ "$(docker inspect -f '{{.State.Health.Status}}' hermes-agent 2>/dev/null)" != healthy ]; then
    HERMES_PANES=()
    warn "herdr: hermes-agent is not healthy — Hermes not resumed in $panes"
    notify "hermes-agent is not healthy: the Hermes sessions of herdr ($panes) were not resumed — hermes --resume <id> in each pane once it is back"
    return 0
  fi
  for entry in "${HERMES_PANES[@]}"; do
    resume_pane "${entry%%$'\t'*}" "${entry#*$'\t'}"
    if [ -n "$RESUMED" ]; then resumed+=("$RESUMED"); info "herdr: resumed $RESUMED"
    else failed+=("$FAILED"); warn "herdr: $FAILED"; fi
  done
  HERMES_PANES=()
  [ "${#failed[@]}" -eq 0 ] || notify "hermes-agent recreated; Hermes not resumed in herdr: ${failed[*]}${resumed[*]:+ (resumed: ${resumed[*]})}"
}
