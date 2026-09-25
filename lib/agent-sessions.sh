# shellcheck shell=bash
# Hermes work around a restart of its services. Sourced by lib/common.sh; used by update.sh (busy
# gate) and restart_agent (heal.sh, auth.sh, `command-center hermes restart`).
#
# A restart of hermes-gateway / hermes-dashboard cuts every in-flight gateway turn, cron job,
# kanban run and embedded dashboard chat. Hermes CLIs started with bin/hermes (herdr panes, SSH)
# are separate processes pinned to their release: a restart or a new release never cuts them.
#   hermes_busy             what a restart would cut right now (lib/hermes-probe.py)
#   hermes_wait_idle <deadline>   poll hermes_busy until empty or $SECONDS reaches <deadline>
#   hermes_pause <reason>   Hermes' global emergency stop: no NEW gateway turn / cron / kanban
#                           dispatch while the services restart (in-flight work is never killed)
#   hermes_unpause          lift our pause (never an ESTOP the operator set)

: "${UPDATE_BUSY_RECENT:=120}"   # an open session that wrote a message this recently counts as working
: "${UPDATE_BUSY_POLL:=60}"
HERMES_ESTOP_OURS=0

hermes_up() { [ -e "$HERMES_CURRENT/.release" ] && agent_running; }
hermes_probe() { agent_run python3 - "$@" < "$STACK_DIR/lib/hermes-probe.py"; }

# One line per piece of work a restart would cut; empty = idle. Fails closed: a probe that cannot
# run is reported as a line (the update then waits / skips and says why).
hermes_busy() {
  local rc=0
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
  if agent_run hermes pause --reason "$1" >/dev/null 2>&1; then HERMES_ESTOP_OURS=1
  else warn "hermes pause failed — new gateway / cron / kanban work is not held during the restart"; fi
}
hermes_unpause() {
  [ "$HERMES_ESTOP_OURS" = 1 ] || return 0
  { hermes_up && agent_run hermes resume >/dev/null 2>&1; } || rm -f "$HERMES_DATA_DIR/ESTOP"
  HERMES_ESTOP_OURS=0
}
